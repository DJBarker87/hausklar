"""Persist reviewed purchase evidence and reconcile it to the canonical ledger."""

import json
import re
import uuid
from dataclasses import asdict
from datetime import date, datetime, timedelta, timezone

from app.config import settings
from app.models.finance import (
    FinanceEvidenceFileResponse,
    FinanceEvidenceIssueResponse,
    FinanceLineRefundResponse,
    FinancePurchaseDetailResponse,
    FinancePurchaseEvidenceIngest,
    FinancePurchaseEvidenceIngestResponse,
    FinancePurchaseEvidenceResponse,
    FinancePurchaseExceptionResponse,
    FinancePurchaseLineResponse,
    FinancePurchaseMatchReview,
    FinancePurchaseMatchAllocation,
    FinancePurchasePaymentResponse,
    FinancePurchaseSummaryResponse,
    FinancePurchaseTenderResponse,
)
from app.services.finance.evidence import (
    CanonicalPayment,
    EvidenceIssue,
    EvidenceParseResult,
    PaymentAllocation,
    PurchaseDraft,
    TenderKind,
    parse_amazon_payload,
    parse_e_receipt,
    parse_natural_language_payload,
    parse_service_invoice,
    parse_tesco_batch,
    reconcile_allocations,
    suggest_payment_matches,
)
from app.services.finance.foundation import require_finance_access, require_finance_space
from app.services.finance.understanding import apply_learned_purchase_line_assessment
from app.services.documents import family_document_storage_bytes
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

_ADAPTERS = {
    "tesco_batch": parse_tesco_batch,
    "amazon_email": parse_amazon_payload,
    "e_receipt": parse_e_receipt,
    "service_invoice": parse_service_invoice,
    "natural_language": parse_natural_language_payload,
}
_NON_BANK_TENDERS = {TenderKind.CASH, TenderKind.GIFT_CARD, TenderKind.CREDIT}


class FinancePurchaseError(ValueError):
    """Base class for safe purchase-evidence failures."""


class FinancePurchaseNotFoundError(FinancePurchaseError):
    """An authorised purchase-evidence record was not found."""


class FinancePurchaseConflictError(FinancePurchaseError):
    """An immutable source identity was reused with different facts."""


class FinancePurchaseStorageLimitError(FinancePurchaseError):
    """The family document store cannot accept more Finance evidence."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _canonical_json(value: object) -> str:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )


def _refs_json(refs) -> str:
    return _canonical_json([asdict(reference) for reference in refs])


async def _require_evidence_storage_capacity(
    db,
    *,
    family_id: str,
    evidence_files: list[dict[str, object]],
) -> None:
    incoming_bytes = sum(
        int(item["byte_size"])
        for item in evidence_files
        if item.get("storage_status") == "STORED" and item.get("storage_key")
    )
    if incoming_bytes <= 0:
        return
    existing_bytes = await family_document_storage_bytes(db, family_id=family_id)
    if existing_bytes + incoming_bytes > settings.document_family_quota_bytes:
        raise FinancePurchaseStorageLimitError(
            "Family document storage quota exceeded"
        )


async def _authorised_source(db, *, user: dict, source_id: str) -> dict:
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT source.* FROM finance_purchase_sources source
            JOIN finance_spaces space
              ON space.id = source.space_id
             AND space.family_id = source.family_id
             AND space.deleted_at IS NULL
            WHERE source.id = ? AND source.family_id = ?
              AND source.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            """,
            (source_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinancePurchaseNotFoundError("Finance purchase evidence not found")
    return dict(row)


async def _authorised_purchase(db, *, user: dict, purchase_id: str) -> dict:
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT purchase.* FROM finance_purchase_records purchase
            JOIN finance_spaces space
              ON space.id = purchase.space_id
             AND space.family_id = purchase.family_id
             AND space.deleted_at IS NULL
            WHERE purchase.id = ? AND purchase.family_id = ?
              AND purchase.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            """,
            (purchase_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinancePurchaseNotFoundError("Finance purchase not found")
    return dict(row)


def _parse(body: FinancePurchaseEvidenceIngest) -> EvidenceParseResult:
    adapter = _ADAPTERS.get(body.adapter)
    if adapter is None:
        return EvidenceParseResult(
            draft=None,
            issues=(
                EvidenceIssue(
                    code="unsupported_source",
                    message="This source type has no reviewed structured adapter yet.",
                ),
            ),
        )
    result = adapter(body.payload)
    if result.draft is not None and result.draft.provenance.source_id != body.external_source_id:
        return EvidenceParseResult(
            draft=None,
            issues=(
                EvidenceIssue(
                    code="source_identity_mismatch",
                    message="The reviewed payload source does not match its intake identity.",
                ),
            ),
        )
    return result


async def _update_health(
    db,
    *,
    user: dict,
    space_id: str,
    source_kind: str,
    extraction_status: str,
    received_at: str,
    issue_code: str | None,
) -> None:
    if issue_code is not None and not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", issue_code):
        issue_code = "invalid_evidence_issue"
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_purchase_source_health
            WHERE space_id = ? AND source_kind = ? AND deleted_at IS NULL
            """,
            (space_id, source_kind),
        )
    ).fetchone()
    now = _now()
    if extraction_status == "PARSED":
        health_status = "HEALTHY"
        failures = 0
        parsed_at = received_at
    elif extraction_status == "UNSUPPORTED":
        health_status = "UNSUPPORTED"
        failures = (row["consecutive_failures"] if row else 0) + 1
        parsed_at = row["last_parsed_at"] if row else None
    else:
        health_status = "QUARANTINED"
        failures = (row["consecutive_failures"] if row else 0) + 1
        parsed_at = row["last_parsed_at"] if row else None
    if row is None:
        await db.execute(
            """
            INSERT INTO finance_purchase_source_health
                (id, space_id, source_kind, health_status, last_received_at,
                 last_parsed_at, consecutive_failures, latest_issue_code,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                space_id,
                source_kind,
                health_status,
                received_at,
                parsed_at,
                failures,
                issue_code,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        return
    await save_history(
        db,
        "finance_purchase_source_health",
        row["id"],
        user["id"],
        family_id=user["family_id"],
    )
    await db.execute(
        """
        UPDATE finance_purchase_source_health
        SET health_status = ?, last_received_at = ?, last_parsed_at = ?,
            consecutive_failures = ?, latest_issue_code = ?, updated_at = ?
        WHERE id = ? AND space_id = ? AND deleted_at IS NULL
        """,
        (
            health_status,
            received_at,
            parsed_at,
            failures,
            issue_code,
            now,
            row["id"],
            space_id,
        ),
    )


async def _candidate_payments(
    db, *, user: dict, space_id: str, draft: PurchaseDraft
) -> list[CanonicalPayment]:
    earliest = (draft.purchased_on - timedelta(days=14)).isoformat()
    latest = (draft.purchased_on + timedelta(days=30)).isoformat()
    rows = await (
        await db.execute(
            """
            SELECT tx.*, account.account_type, account.last_four,
                   COALESCE((
                       SELECT SUM(ABS(allocation.allocated_minor))
                       FROM finance_purchase_payments allocation
                       WHERE allocation.transaction_id = tx.id
                         AND allocation.space_id = tx.space_id
                         AND allocation.status = 'CONFIRMED'
                         AND allocation.deleted_at IS NULL
                   ), 0) AS allocated_magnitude
            FROM finance_transactions tx
            JOIN finance_accounts account
              ON account.id = tx.account_id AND account.space_id = tx.space_id
             AND account.deleted_at IS NULL
            WHERE tx.space_id = ? AND tx.family_id = ? AND tx.currency = ?
              AND tx.state = 'POSTED' AND tx.canonical_date BETWEEN ? AND ?
              AND tx.deleted_at IS NULL
            ORDER BY tx.canonical_date, tx.id
            """,
            (
                space_id,
                user["family_id"],
                draft.currency,
                earliest,
                latest,
            ),
        )
    ).fetchall()
    payments = []
    for row in rows:
        available = abs(row["amount_minor"]) - row["allocated_magnitude"]
        if available <= 0:
            continue
        payments.append(
            CanonicalPayment(
                payment_id=row["id"],
                merchant=row["merchant_text"] or row["description"],
                booked_on=date.fromisoformat(row["canonical_date"]),
                amount_minor=-available if row["amount_minor"] < 0 else available,
                currency=row["currency"],
                description=row["description"],
                card_suffix=(
                    row["last_four"]
                    if row["account_type"] == "CREDIT_CARD"
                    else None
                ),
            )
        )
    return payments


def _matched_allocations(
    draft: PurchaseDraft,
    payments: list[CanonicalPayment],
) -> tuple[list[PaymentAllocation], list[CanonicalPayment], bool]:
    allocations: list[PaymentAllocation] = []
    used: list[CanonicalPayment] = []
    ambiguous = False
    non_bank_total = 0
    for tender in draft.tenders:
        if tender.kind not in _NON_BANK_TENDERS:
            continue
        non_bank_total += tender.amount_minor
        allocations.append(
            PaymentAllocation(
                allocation_ref=f"evidence:{tender.tender_ref}",
                purchase_ref=draft.purchase_ref,
                tender_kind=tender.kind,
                allocated_minor=tender.amount_minor,
            )
        )

    def match_direction(*, positive_payment: bool, target_minor: int) -> None:
        nonlocal ambiguous
        matched = 0
        remaining_candidates = [
            payment for payment in payments if (payment.amount_minor > 0) == positive_payment
        ]
        while matched < target_minor and remaining_candidates:
            suggestion = suggest_payment_matches([draft], remaining_candidates)[0]
            if suggestion.selected_payment_id is None:
                ambiguous = bool(suggestion.candidates)
                break
            payment = next(
                item
                for item in remaining_candidates
                if item.payment_id == suggestion.selected_payment_id
            )
            amount = abs(payment.amount_minor)
            if amount > target_minor - matched:
                ambiguous = True
                break
            kind = TenderKind.CARD if payment.card_suffix else TenderKind.BANK
            allocations.append(
                PaymentAllocation(
                    allocation_ref=(
                        f"auto-refund:{payment.payment_id}"
                        if positive_payment
                        else f"auto-charge:{payment.payment_id}"
                    ),
                    purchase_ref=draft.purchase_ref,
                    tender_kind=kind,
                    allocated_minor=-amount if positive_payment else amount,
                    payment_id=payment.payment_id,
                )
            )
            used.append(payment)
            matched += amount
            remaining_candidates = [
                item for item in remaining_candidates if item.payment_id != payment.payment_id
            ]

    match_direction(
        positive_payment=False,
        target_minor=max(0, draft.final_total_minor - non_bank_total),
    )
    if draft.refunded_minor:
        match_direction(positive_payment=True, target_minor=draft.refunded_minor)
    return allocations, used, ambiguous


async def _resolve_corrected_purchase(
    db, *, user: dict, space_id: str, corrects_source_id: str | None
) -> dict | None:
    if corrects_source_id is None:
        return None
    source = await _authorised_source(db, user=user, source_id=corrects_source_id)
    if source["space_id"] != space_id:
        raise FinancePurchaseNotFoundError("Finance purchase evidence not found")
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_purchase_records
            WHERE source_id = ? AND space_id = ? AND superseded_by_id IS NULL
              AND deleted_at IS NULL
            ORDER BY created_at DESC LIMIT 1
            """,
            (corrects_source_id, space_id),
        )
    ).fetchone()
    if row is None:
        raise FinancePurchaseConflictError(
            "Only parsed purchase evidence can be corrected"
        )
    return dict(row)


async def _supersede_purchase(
    db, *, user: dict, previous: dict, replacement_id: str, now: str
) -> None:
    await save_history(
        db,
        "finance_purchase_records",
        previous["id"],
        user["id"],
        family_id=user["family_id"],
    )
    await db.execute(
        """
        UPDATE finance_purchase_records SET superseded_by_id = ?, updated_at = ?
        WHERE id = ? AND space_id = ? AND superseded_by_id IS NULL
          AND deleted_at IS NULL
        """,
        (replacement_id, now, previous["id"], previous["space_id"]),
    )
    allocations = await (
        await db.execute(
            """
            SELECT id FROM finance_purchase_payments
            WHERE purchase_id = ? AND space_id = ? AND deleted_at IS NULL
            """,
            (previous["id"], previous["space_id"]),
        )
    ).fetchall()
    for allocation in allocations:
        await save_history(
            db,
            "finance_purchase_payments",
            allocation["id"],
            user["id"],
            family_id=user["family_id"],
        )
    if allocations:
        await db.execute(
            """
            UPDATE finance_purchase_payments SET deleted_at = ?, updated_at = ?
            WHERE purchase_id = ? AND space_id = ? AND deleted_at IS NULL
            """,
            (now, now, previous["id"], previous["space_id"]),
        )
    exceptions = await (
        await db.execute(
            """
            SELECT id FROM finance_purchase_exceptions
            WHERE purchase_id = ? AND space_id = ? AND status = 'OPEN'
              AND deleted_at IS NULL
            """,
            (previous["id"], previous["space_id"]),
        )
    ).fetchall()
    for exception in exceptions:
        await save_history(
            db,
            "finance_purchase_exceptions",
            exception["id"],
            user["id"],
            family_id=user["family_id"],
        )
    if exceptions:
        await db.execute(
            """
            UPDATE finance_purchase_exceptions SET status = 'RESOLVED', updated_at = ?
            WHERE purchase_id = ? AND space_id = ? AND status = 'OPEN'
              AND deleted_at IS NULL
            """,
            (now, previous["id"], previous["space_id"]),
        )


async def _insert_exception(
    db,
    *,
    user: dict,
    space_id: str,
    source_id: str,
    purchase_id: str | None,
    kind: str,
    amount_minor: int | None,
    currency: str | None,
    detail: str,
) -> str:
    titles = {
        "QUARANTINED_EVIDENCE": "Purchase evidence needs review",
        "UNSUPPORTED_SOURCE": "Purchase source is not supported yet",
        "AMBIGUOUS_MATCH": "Purchase payment match needs review",
        "UNMATCHED_PURCHASE": "Purchase has no exact payment match",
        "PARTIAL_ITEMISATION": "Purchase is partly unitemised",
    }
    identifier = str(uuid.uuid4())
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_purchase_exceptions
            (id, space_id, source_id, purchase_id, exception_kind, title,
             detail, amount_minor, currency, status, priority, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'OPEN', ?, ?, ?, ?, ?)
        """,
        (
            identifier,
            space_id,
            source_id,
            purchase_id,
            kind,
            titles[kind],
            detail,
            amount_minor,
            currency,
            amount_minor or 0,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    return identifier


async def ingest_purchase_evidence(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinancePurchaseEvidenceIngest,
    source_id_override: str | None = None,
    forced_issue: EvidenceIssue | None = None,
    email_context: dict[str, object] | None = None,
    evidence_files: list[dict[str, object]] | None = None,
) -> FinancePurchaseEvidenceIngestResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    raw_payload = _canonical_json(body.payload)
    parsed = (
        EvidenceParseResult(draft=None, issues=(forced_issue,))
        if forced_issue is not None
        else _parse(body)
    )
    unsupported = body.adapter not in _ADAPTERS and forced_issue is None
    extraction_status = (
        "PARSED" if parsed.draft is not None else "UNSUPPORTED" if unsupported else "QUARANTINED"
    )
    issue_code = parsed.issues[0].code if parsed.issues else None
    received_at = (
        body.received_at.astimezone(timezone.utc).isoformat()
        if body.received_at
        else _now()
    )
    parsed_at = received_at if parsed.draft is not None else None
    duplicate_source_id: str | None = None
    source_id = source_id_override or str(uuid.uuid4())
    purchase_id: str | None = None
    exception_id: str | None = None
    now = _now()

    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_purchase_sources
                WHERE space_id = ? AND source_kind = ? AND external_source_id = ?
                  AND deleted_at IS NULL
                """,
                (space_id, body.adapter, body.external_source_id),
            )
        ).fetchone()
        if existing is not None:
            if (
                existing["raw_payload_json"] != raw_payload
                or existing["corrects_source_id"] != body.corrects_source_id
            ):
                raise FinancePurchaseConflictError(
                    "Purchase source identity was reused with different facts"
                )
            duplicate_source_id = existing["id"]
        else:
            await _require_evidence_storage_capacity(
                db,
                family_id=user["family_id"],
                evidence_files=evidence_files or [],
            )
            previous = await _resolve_corrected_purchase(
                db,
                user=user,
                space_id=space_id,
                corrects_source_id=body.corrects_source_id,
            )
            draft = parsed.draft
            await db.execute(
                """
                INSERT INTO finance_purchase_sources
                    (id, space_id, external_source_id, source_kind,
                     corrects_source_id, parser_version, extraction_status,
                     confidence_bps, raw_payload_json, issues_json, storage_area,
                     storage_key, media_type, byte_size, email_alias_id,
                     email_enrollment_id, provider_message_id,
                     internet_message_id, visible_sender, email_subject,
                     authentication_json, received_at, parsed_at, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'finance-evidence',
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    source_id,
                    space_id,
                    body.external_source_id,
                    body.adapter,
                    body.corrects_source_id,
                    draft.provenance.parser_version if draft else None,
                    extraction_status,
                    draft.provenance.confidence_bps if draft else None,
                    raw_payload,
                    _canonical_json([asdict(issue) for issue in parsed.issues]),
                    (email_context or {}).get("storage_key"),
                    (email_context or {}).get("media_type"),
                    (email_context or {}).get("byte_size"),
                    (email_context or {}).get("email_alias_id"),
                    (email_context or {}).get("email_enrollment_id"),
                    (email_context or {}).get("provider_message_id"),
                    (email_context or {}).get("internet_message_id"),
                    (email_context or {}).get("visible_sender"),
                    (email_context or {}).get("email_subject"),
                    (email_context or {}).get("authentication_json"),
                    received_at,
                    parsed_at,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
            for evidence_file in evidence_files or []:
                await db.execute(
                    """
                    INSERT INTO finance_purchase_source_files
                        (id, space_id, source_id, file_role, filename, media_type,
                         storage_key, byte_size, storage_status, family_id,
                         created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        space_id,
                        source_id,
                        evidence_file["file_role"],
                        evidence_file["filename"],
                        evidence_file["media_type"],
                        evidence_file.get("storage_key"),
                        evidence_file["byte_size"],
                        evidence_file["storage_status"],
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
            if draft is None:
                exception_id = await _insert_exception(
                    db,
                    user=user,
                    space_id=space_id,
                    source_id=source_id,
                    purchase_id=None,
                    kind=(
                        "UNSUPPORTED_SOURCE" if unsupported else "QUARANTINED_EVIDENCE"
                    ),
                    amount_minor=None,
                    currency=None,
                    detail=parsed.issues[0].message,
                )
            else:
                purchase_id = str(uuid.uuid4())
                if previous is not None:
                    await _supersede_purchase(
                        db,
                        user=user,
                        previous=previous,
                        replacement_id=purchase_id,
                        now=now,
                    )
                lines_subtotal = sum(line.net_minor or 0 for line in draft.lines)
                await db.execute(
                    """
                    INSERT INTO finance_purchase_records
                        (id, space_id, source_id, purchase_ref, merchant_name,
                         external_order_reference, purchased_on, currency,
                         lines_subtotal_minor, shipping_minor, vat_included_minor,
                         order_discount_minor, final_total_minor, refunded_minor,
                         status, source_kind, extraction_confidence_bps,
                         supersedes_purchase_id, family_id, created_at, updated_at,
                         created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?)
                    """,
                    (
                        purchase_id,
                        space_id,
                        source_id,
                        draft.purchase_ref,
                        draft.merchant,
                        draft.order_reference,
                        draft.purchased_on.isoformat(),
                        draft.currency,
                        lines_subtotal,
                        draft.shipping_minor,
                        draft.vat_included_minor,
                        draft.order_discount_minor,
                        draft.final_total_minor,
                        draft.refunded_minor,
                        draft.status.value,
                        draft.provenance.source_kind.value,
                        draft.provenance.confidence_bps,
                        previous["id"] if previous else None,
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
                line_ids = {}
                for line_position, line in enumerate(draft.lines):
                    line_id = str(uuid.uuid4())
                    line_ids[line.line_ref] = line_id
                    await db.execute(
                        """
                        INSERT INTO finance_purchase_lines
                            (id, space_id, source_id, purchase_id,
                             source_line_reference, line_position, line_kind,
                             raw_description, quantity_decimal, unit_description,
                             unit_price_minor, line_gross_minor, line_discount_minor,
                             line_net_minor, evidence_status, source_refs_json,
                             seller, product_reference, replaces_description,
                             shipment_reference,
                             family_id, created_at, updated_at, created_by)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                                ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            line_id,
                            space_id,
                            source_id,
                            purchase_id,
                            line.line_ref,
                            line_position,
                            line.kind.value,
                            line.raw_description,
                            str(line.quantity),
                            line.unit,
                            line.unit_price_minor,
                            line.gross_minor,
                            line.discount_minor,
                            line.net_minor,
                            line.evidence_status.value,
                            _refs_json(line.source_refs),
                            line.seller,
                            line.product_reference,
                            line.replaces_description,
                            line.shipment_reference,
                            user["family_id"],
                            now,
                            now,
                            user["id"],
                        ),
                    )
                    await apply_learned_purchase_line_assessment(
                        db,
                        user=user,
                        line_id=line_id,
                        space_id=space_id,
                        raw_description=line.raw_description,
                        line_kind=line.kind.value,
                    )
                for tender in draft.tenders:
                    await db.execute(
                        """
                        INSERT INTO finance_purchase_tenders
                            (id, space_id, source_id, purchase_id, tender_ref,
                             tender_kind, amount_minor, provider_transaction_id,
                             card_suffix, source_refs_json, family_id, created_at,
                             updated_at, created_by)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            str(uuid.uuid4()),
                            space_id,
                            source_id,
                            purchase_id,
                            tender.tender_ref,
                            tender.kind.value,
                            tender.amount_minor,
                            tender.provider_transaction_id,
                            tender.card_suffix,
                            _refs_json(tender.source_refs),
                            user["family_id"],
                            now,
                            now,
                            user["id"],
                        ),
                    )
                for refund in draft.refunds:
                    await db.execute(
                        """
                        INSERT INTO finance_line_refunds
                            (id, space_id, source_id, purchase_id, line_id,
                             refund_ref, amount_minor, quantity_decimal,
                             source_refs_json, family_id, created_at, updated_at,
                             created_by)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            str(uuid.uuid4()),
                            space_id,
                            source_id,
                            purchase_id,
                            line_ids[refund.line_ref],
                            refund.refund_ref,
                            refund.amount_minor,
                            str(refund.quantity) if refund.quantity is not None else None,
                            _refs_json(refund.source_refs),
                            user["family_id"],
                            now,
                            now,
                            user["id"],
                        ),
                    )

                candidates = await _candidate_payments(
                    db, user=user, space_id=space_id, draft=draft
                )
                allocations, used_payments, ambiguous = _matched_allocations(
                    draft, candidates
                )
                reconciliation = reconcile_allocations(
                    [draft], used_payments, allocations
                )
                if reconciliation.quarantined:
                    raise RuntimeError("Generated purchase allocations failed reconciliation")
                for allocation in allocations:
                    await db.execute(
                        """
                        INSERT INTO finance_purchase_payments
                            (id, space_id, purchase_id, transaction_id, line_id,
                             allocation_ref, tender_kind, allocated_minor,
                             match_method, status, family_id, created_at, updated_at,
                             created_by)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'CONFIRMED', ?, ?, ?, ?)
                        """,
                        (
                            str(uuid.uuid4()),
                            space_id,
                            purchase_id,
                            allocation.payment_id,
                            line_ids.get(allocation.line_ref),
                            allocation.allocation_ref,
                            allocation.tender_kind.value,
                            allocation.allocated_minor,
                            (
                                "AUTO_EXACT"
                                if allocation.payment_id
                                else "EVIDENCED_NON_BANK"
                            ),
                            user["family_id"],
                            now,
                            now,
                            user["id"],
                        ),
                    )
                remainder = reconciliation.purchase_remainders[0]
                exception_kind = None
                detail = ""
                if (
                    remainder.unallocated_purchase_minor
                    or remainder.unallocated_refund_minor
                ):
                    exception_kind = (
                        "AMBIGUOUS_MATCH" if ambiguous else "UNMATCHED_PURCHASE"
                    )
                    detail = (
                        "No unique exact canonical payment allocation covers the "
                        "reviewed purchase and refund evidence."
                    )
                elif any(
                    line.evidence_status.value == "unitemised" for line in draft.lines
                ):
                    exception_kind = "PARTIAL_ITEMISATION"
                    detail = "The purchase reconciles, but part of its contents is unitemised."
                if exception_kind:
                    exception_id = await _insert_exception(
                        db,
                        user=user,
                        space_id=space_id,
                        source_id=source_id,
                        purchase_id=purchase_id,
                        kind=exception_kind,
                        amount_minor=(
                            remainder.unallocated_purchase_minor
                            + remainder.unallocated_refund_minor
                        ),
                        currency=draft.currency,
                        detail=detail,
                    )
            await _update_health(
                db,
                user=user,
                space_id=space_id,
                source_kind=body.adapter,
                extraction_status=extraction_status,
                received_at=received_at,
                issue_code=issue_code,
            )
            if purchase_id is not None:
                from app.services.finance.sharing import apply_purchase_share_rules

                await apply_purchase_share_rules(
                    db, user=user, purchase_id=purchase_id
                )

    if duplicate_source_id is not None:
        source_id = duplicate_source_id
        purchase = await (
            await db.execute(
                """
                SELECT id FROM finance_purchase_records
                WHERE source_id = ? AND space_id = ? AND deleted_at IS NULL
                ORDER BY created_at DESC LIMIT 1
                """,
                (source_id, space_id),
            )
        ).fetchone()
        purchase_id = purchase["id"] if purchase else None
        exception = await (
            await db.execute(
                """
                SELECT id FROM finance_purchase_exceptions
                WHERE source_id = ? AND space_id = ? AND status = 'OPEN'
                  AND deleted_at IS NULL
                """,
                (source_id, space_id),
            )
        ).fetchone()
        exception_id = exception["id"] if exception else None
    return FinancePurchaseEvidenceIngestResponse(
        source=await read_purchase_source(db, user=user, source_id=source_id),
        purchase=(
            await read_purchase(db, user=user, purchase_id=purchase_id)
            if purchase_id
            else None
        ),
        exception=(
            await read_purchase_exception(db, user=user, exception_id=exception_id)
            if exception_id
            else None
        ),
        duplicate=duplicate_source_id is not None,
    )


def _source_response(
    row: dict,
    files: list[dict],
) -> FinancePurchaseEvidenceResponse:
    return FinancePurchaseEvidenceResponse(
        id=row["id"],
        space_id=row["space_id"],
        external_source_id=row["external_source_id"],
        source_kind=row["source_kind"],
        corrects_source_id=row["corrects_source_id"],
        parser_version=row["parser_version"],
        extraction_status=row["extraction_status"],
        confidence_bps=row["confidence_bps"],
        raw_payload=json.loads(row["raw_payload_json"]),
        issues=[
            FinanceEvidenceIssueResponse(**issue)
            for issue in json.loads(row["issues_json"])
        ],
        storage_area=row["storage_area"],
        storage_key=row["storage_key"],
        provider_message_id=row["provider_message_id"],
        visible_sender=row["visible_sender"],
        email_subject=row["email_subject"],
        files=[
            FinanceEvidenceFileResponse(
                id=file["id"],
                file_role=file["file_role"],
                filename=file["filename"],
                media_type=file["media_type"],
                byte_size=file["byte_size"],
                storage_status=file["storage_status"],
            )
            for file in files
        ],
        received_at=row["received_at"],
        parsed_at=row["parsed_at"],
        created_at=row["created_at"],
    )


async def read_purchase_source(
    db, *, user: dict, source_id: str
) -> FinancePurchaseEvidenceResponse:
    source = await _authorised_source(db, user=user, source_id=source_id)
    files = await (
        await db.execute(
            """
            SELECT * FROM finance_purchase_source_files
            WHERE source_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY created_at, id
            """,
            (source_id, source["space_id"], source["family_id"]),
        )
    ).fetchall()
    return _source_response(source, [dict(file) for file in files])


def _purchase_summary_response(
    row: dict,
    *,
    funded: int,
    refunded: int,
    item_descriptions: list[str],
) -> FinancePurchaseSummaryResponse:
    unmatched_purchase = max(0, row["final_total_minor"] - funded)
    unmatched_refund = max(0, row["refunded_minor"] - refunded)
    if unmatched_purchase == 0 and unmatched_refund == 0:
        match_status = "MATCHED"
    elif funded or refunded:
        match_status = "PARTIAL"
    else:
        match_status = "UNMATCHED"
    return FinancePurchaseSummaryResponse(
        id=row["id"],
        space_id=row["space_id"],
        merchant=row["merchant_name"],
        item_descriptions=item_descriptions,
        order_reference=row["external_order_reference"],
        purchased_on=row["purchased_on"],
        currency=row["currency"],
        lines_subtotal_minor=row["lines_subtotal_minor"],
        shipping_minor=row["shipping_minor"],
        vat_included_minor=row["vat_included_minor"],
        order_discount_minor=row["order_discount_minor"],
        final_total_minor=row["final_total_minor"],
        refunded_minor=row["refunded_minor"],
        behavioural_net_minor=row["final_total_minor"] - row["refunded_minor"],
        status=row["status"],
        source_kind=row["source_kind"],
        match_status=match_status,
        unmatched_purchase_minor=unmatched_purchase,
        unmatched_refund_minor=unmatched_refund,
        cashflow_source="canonical_transactions",
        purchase_total_added_to_cashflow=False,
        supersedes_purchase_id=row["supersedes_purchase_id"],
        superseded_by_id=row["superseded_by_id"],
        created_at=row["created_at"],
    )


async def _summary_responses(
    db, rows: list[dict]
) -> list[FinancePurchaseSummaryResponse]:
    if not rows:
        return []
    purchase_ids = [row["id"] for row in rows]
    placeholders = ",".join("?" for _ in purchase_ids)
    space_id = rows[0]["space_id"]
    allocation_rows = await (
        await db.execute(
            f"""
            SELECT purchase_id,
                   SUM(CASE WHEN allocated_minor > 0 THEN allocated_minor ELSE 0 END)
                       AS funded_minor,
                   SUM(CASE WHEN allocated_minor < 0 THEN -allocated_minor ELSE 0 END)
                       AS refunded_minor
            FROM finance_purchase_payments
            WHERE space_id = ? AND purchase_id IN ({placeholders})
              AND status = 'CONFIRMED' AND deleted_at IS NULL
            GROUP BY purchase_id
            """,
            [space_id, *purchase_ids],
        )
    ).fetchall()
    allocations = {
        row["purchase_id"]: (row["funded_minor"], row["refunded_minor"])
        for row in allocation_rows
    }
    line_rows = await (
        await db.execute(
            f"""
            SELECT purchase_id, raw_description
            FROM finance_purchase_lines
            WHERE space_id = ? AND purchase_id IN ({placeholders})
              AND deleted_at IS NULL
            ORDER BY purchase_id, line_position, id
            """,
            [space_id, *purchase_ids],
        )
    ).fetchall()
    descriptions = {purchase_id: [] for purchase_id in purchase_ids}
    for line in line_rows:
        descriptions[line["purchase_id"]].append(line["raw_description"])
    responses = []
    for row in rows:
        funded, refunded = allocations.get(row["id"], (0, 0))
        responses.append(
            _purchase_summary_response(
                row,
                funded=funded,
                refunded=refunded,
                item_descriptions=descriptions[row["id"]],
            )
        )
    return responses


async def _summary_response(db, row: dict) -> FinancePurchaseSummaryResponse:
    return (await _summary_responses(db, [row]))[0]


async def list_purchases(
    db,
    *,
    user: dict,
    space_id: str,
    offset: int,
    limit: int,
    exclude_own_shared_copies: bool = False,
) -> list[FinancePurchaseSummaryResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    own_copy_clause = ""
    parameters: list[object] = [space_id, user["family_id"]]
    if exclude_own_shared_copies:
        own_copy_clause = """
              AND NOT EXISTS (
                  SELECT 1 FROM finance_share_copy_links copy
                  JOIN finance_share_actions share
                    ON share.id = copy.share_action_id AND share.deleted_at IS NULL
                  WHERE copy.household_record_type = 'purchase'
                    AND copy.household_record_id = finance_purchase_records.id
                    AND copy.household_space_id = finance_purchase_records.space_id
                    AND copy.family_id = finance_purchase_records.family_id
                    AND copy.deleted_at IS NULL AND share.owner_user_id = ?
              )
        """
        parameters.append(user["id"])
    parameters.extend((limit, offset))
    raw_rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_purchase_records
            WHERE space_id = ? AND family_id = ? AND superseded_by_id IS NULL
              AND deleted_at IS NULL
              {own_copy_clause}
            ORDER BY purchased_on DESC, created_at DESC, id DESC
            LIMIT ? OFFSET ?
            """,
            parameters,
        )
    ).fetchall()
    return await _summary_responses(db, [dict(row) for row in raw_rows])


async def read_purchase(
    db, *, user: dict, purchase_id: str
) -> FinancePurchaseDetailResponse:
    row = await _authorised_purchase(db, user=user, purchase_id=purchase_id)
    summary = await _summary_response(db, row)
    source = await read_purchase_source(db, user=user, source_id=row["source_id"])
    line_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_purchase_lines
            WHERE purchase_id = ? AND space_id = ? AND deleted_at IS NULL
            ORDER BY line_position, id
            """,
            (purchase_id, row["space_id"]),
        )
    ).fetchall()
    tender_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_purchase_tenders
            WHERE purchase_id = ? AND space_id = ? AND deleted_at IS NULL
            ORDER BY created_at, id
            """,
            (purchase_id, row["space_id"]),
        )
    ).fetchall()
    refund_rows = await (
        await db.execute(
            """
            SELECT refund.*, line.source_line_reference FROM finance_line_refunds refund
            JOIN finance_purchase_lines line
              ON line.id = refund.line_id AND line.deleted_at IS NULL
            WHERE refund.purchase_id = ? AND refund.space_id = ?
              AND refund.deleted_at IS NULL
            ORDER BY refund.created_at, refund.id
            """,
            (purchase_id, row["space_id"]),
        )
    ).fetchall()
    allocation_rows = await (
        await db.execute(
            """
            SELECT allocation.*, tx.amount_minor AS transaction_amount_minor,
                   tx.canonical_date AS transaction_date
            FROM finance_purchase_payments allocation
            LEFT JOIN finance_transactions tx
              ON tx.id = allocation.transaction_id AND tx.deleted_at IS NULL
            WHERE allocation.purchase_id = ? AND allocation.space_id = ?
              AND allocation.deleted_at IS NULL
            ORDER BY allocation.created_at, allocation.id
            """,
            (purchase_id, row["space_id"]),
        )
    ).fetchall()
    return FinancePurchaseDetailResponse(
        **summary.model_dump(),
        evidence=source,
        lines=[
            FinancePurchaseLineResponse(
                id=line["id"],
                line_ref=line["source_line_reference"],
                position=line["line_position"],
                line_kind=line["line_kind"],
                raw_description=line["raw_description"],
                quantity_decimal=line["quantity_decimal"],
                unit_description=line["unit_description"],
                unit_price_minor=line["unit_price_minor"],
                line_gross_minor=line["line_gross_minor"],
                line_discount_minor=line["line_discount_minor"],
                line_net_minor=line["line_net_minor"],
                evidence_status=line["evidence_status"],
                source_refs=json.loads(line["source_refs_json"]),
                seller=line["seller"],
                product_reference=line["product_reference"],
                replaces_description=line["replaces_description"],
                shipment_reference=line["shipment_reference"],
            )
            for line in line_rows
        ],
        tenders=[
            FinancePurchaseTenderResponse(
                id=tender["id"],
                tender_ref=tender["tender_ref"],
                tender_kind=tender["tender_kind"],
                amount_minor=tender["amount_minor"],
                provider_transaction_id=tender["provider_transaction_id"],
                card_suffix=tender["card_suffix"],
                source_refs=json.loads(tender["source_refs_json"]),
            )
            for tender in tender_rows
        ],
        refunds=[
            FinanceLineRefundResponse(
                id=refund["id"],
                refund_ref=refund["refund_ref"],
                line_id=refund["line_id"],
                line_ref=refund["source_line_reference"],
                amount_minor=refund["amount_minor"],
                quantity_decimal=refund["quantity_decimal"],
                source_refs=json.loads(refund["source_refs_json"]),
            )
            for refund in refund_rows
        ],
        payment_allocations=[
            FinancePurchasePaymentResponse(
                id=allocation["id"],
                allocation_ref=allocation["allocation_ref"],
                transaction_id=allocation["transaction_id"],
                line_id=allocation["line_id"],
                tender_kind=allocation["tender_kind"],
                allocated_minor=allocation["allocated_minor"],
                transaction_amount_minor=allocation["transaction_amount_minor"],
                transaction_date=allocation["transaction_date"],
                match_method=allocation["match_method"],
                status=allocation["status"],
            )
            for allocation in allocation_rows
        ],
    )


async def read_purchase_by_source(
    db, *, user: dict, source_id: str
) -> FinancePurchaseDetailResponse:
    """Return the authorised purchase created from one evidence source."""
    source = await _authorised_source(db, user=user, source_id=source_id)
    row = await (
        await db.execute(
            """
            SELECT id FROM finance_purchase_records
            WHERE source_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY created_at DESC, id DESC
            LIMIT 1
            """,
            (source_id, source["space_id"], user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinancePurchaseNotFoundError("Finance purchase not found")
    return await read_purchase(db, user=user, purchase_id=row["id"])


async def read_purchase_by_transaction(
    db, *, user: dict, transaction_id: str
) -> FinancePurchaseDetailResponse:
    """Return the current authorised purchase matched to one bank transaction."""
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT DISTINCT purchase.id
            FROM finance_purchase_payments payment
            JOIN finance_purchase_records purchase
              ON purchase.id = payment.purchase_id
             AND purchase.space_id = payment.space_id
             AND purchase.family_id = payment.family_id
             AND purchase.deleted_at IS NULL
             AND purchase.superseded_by_id IS NULL
            JOIN finance_spaces space
              ON space.id = purchase.space_id
             AND space.family_id = purchase.family_id
             AND space.deleted_at IS NULL
            WHERE payment.transaction_id = ? AND payment.family_id = ?
              AND payment.status = 'CONFIRMED' AND payment.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            ORDER BY purchase.created_at DESC, purchase.id DESC
            LIMIT 1
            """,
            (transaction_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinancePurchaseNotFoundError("Matched Finance purchase not found")
    return await read_purchase(db, user=user, purchase_id=row["id"])


async def read_purchase_by_line(
    db, *, user: dict, line_id: str
) -> FinancePurchaseDetailResponse:
    """Return the authorised purchase containing one receipt line."""
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT line.purchase_id
            FROM finance_purchase_lines line
            JOIN finance_spaces space
              ON space.id = line.space_id
             AND space.family_id = line.family_id
             AND space.deleted_at IS NULL
            WHERE line.id = ? AND line.family_id = ? AND line.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            LIMIT 1
            """,
            (line_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinancePurchaseNotFoundError("Finance purchase line not found")
    return await read_purchase(db, user=user, purchase_id=row["purchase_id"])


async def _stored_purchase_draft(db, purchase: dict) -> PurchaseDraft:
    source = await (
        await db.execute(
            """
            SELECT source_kind, raw_payload_json FROM finance_purchase_sources
            WHERE id = ? AND space_id = ? AND family_id = ?
              AND extraction_status = 'PARSED' AND deleted_at IS NULL
            """,
            (purchase["source_id"], purchase["space_id"], purchase["family_id"]),
        )
    ).fetchone()
    if source is None or source["source_kind"] not in _ADAPTERS:
        raise FinancePurchaseConflictError(
            "Stored purchase evidence cannot be reconciled"
        )
    parsed = _ADAPTERS[source["source_kind"]](json.loads(source["raw_payload_json"]))
    draft = parsed.draft
    if (
        draft is None
        or draft.purchase_ref != purchase["purchase_ref"]
        or draft.currency != purchase["currency"]
        or draft.final_total_minor != purchase["final_total_minor"]
        or draft.refunded_minor != purchase["refunded_minor"]
    ):
        raise FinancePurchaseConflictError(
            "Stored purchase evidence cannot be reconciled"
        )
    return draft


async def _review_payment_rows(
    db,
    *,
    purchase: dict,
    transaction_ids: list[str],
) -> dict[str, dict]:
    placeholders = ", ".join("?" for _ in transaction_ids)
    rows = await (
        await db.execute(
            f"""
            SELECT tx.*, account.account_type, account.last_four,
                   COALESCE((
                       SELECT SUM(ABS(existing.allocated_minor))
                       FROM finance_purchase_payments existing
                       WHERE existing.transaction_id = tx.id
                         AND existing.purchase_id <> ?
                         AND existing.status = 'CONFIRMED'
                         AND existing.deleted_at IS NULL
                   ), 0) AS allocated_elsewhere
            FROM finance_transactions tx
            JOIN finance_accounts account
              ON account.id = tx.account_id AND account.space_id = tx.space_id
             AND account.family_id = tx.family_id AND account.deleted_at IS NULL
            WHERE tx.space_id = ? AND tx.family_id = ? AND tx.deleted_at IS NULL
              AND tx.id IN ({placeholders})
            """,
            (
                purchase["id"],
                purchase["space_id"],
                purchase["family_id"],
                *transaction_ids,
            ),
        )
    ).fetchall()
    by_id = {row["id"]: dict(row) for row in rows}
    if set(by_id) != set(transaction_ids):
        raise FinancePurchaseNotFoundError("Finance transaction not found")
    for row in by_id.values():
        if row["state"] != "POSTED":
            raise FinancePurchaseConflictError(
                "Only posted canonical transactions can be matched"
            )
        if row["currency"] != purchase["currency"]:
            raise FinancePurchaseError(
                "Purchase and transaction currencies must match"
            )
        if row["allocated_elsewhere"] > abs(row["amount_minor"]):
            raise FinancePurchaseConflictError(
                "Canonical transaction allocations are inconsistent"
            )
    return by_id


async def _nonbank_allocations(
    db,
    *,
    purchase: dict,
) -> list[PaymentAllocation]:
    rows = await (
        await db.execute(
            """
            SELECT allocation.*, line.source_line_reference
            FROM finance_purchase_payments allocation
            LEFT JOIN finance_purchase_lines line
              ON line.id = allocation.line_id AND line.deleted_at IS NULL
            WHERE allocation.purchase_id = ? AND allocation.space_id = ?
              AND allocation.transaction_id IS NULL
              AND allocation.status = 'CONFIRMED'
              AND allocation.deleted_at IS NULL
            ORDER BY allocation.created_at, allocation.id
            """,
            (purchase["id"], purchase["space_id"]),
        )
    ).fetchall()
    return [
        PaymentAllocation(
            allocation_ref=row["allocation_ref"],
            purchase_ref=purchase["purchase_ref"],
            tender_kind=TenderKind(row["tender_kind"]),
            allocated_minor=row["allocated_minor"],
            line_ref=row["source_line_reference"],
        )
        for row in rows
    ]


async def _resolve_matching_exceptions(
    db,
    *,
    user: dict,
    purchase: dict,
    now: str,
) -> None:
    rows = await (
        await db.execute(
            """
            SELECT id FROM finance_purchase_exceptions
            WHERE purchase_id = ? AND space_id = ? AND status = 'OPEN'
              AND exception_kind IN ('AMBIGUOUS_MATCH', 'UNMATCHED_PURCHASE')
              AND deleted_at IS NULL
            """,
            (purchase["id"], purchase["space_id"]),
        )
    ).fetchall()
    for row in rows:
        await save_history(
            db,
            "finance_purchase_exceptions",
            row["id"],
            user["id"],
            family_id=user["family_id"],
        )
    if rows:
        await db.execute(
            """
            UPDATE finance_purchase_exceptions
            SET status = 'RESOLVED', updated_at = ?
            WHERE purchase_id = ? AND space_id = ? AND status = 'OPEN'
              AND exception_kind IN ('AMBIGUOUS_MATCH', 'UNMATCHED_PURCHASE')
              AND deleted_at IS NULL
            """,
            (now, purchase["id"], purchase["space_id"]),
        )


async def review_purchase_match(
    db,
    *,
    user: dict,
    purchase_id: str,
    body: FinancePurchaseMatchReview,
) -> FinancePurchaseDetailResponse:
    """Replace bank allocations with one explicit, exact reviewed match."""
    require_finance_access(user)
    async with serialized_create(db):
        purchase = await _authorised_purchase(
            db,
            user=user,
            purchase_id=purchase_id,
        )
        if purchase["superseded_by_id"] is not None:
            raise FinancePurchaseConflictError(
                "A superseded purchase cannot be matched"
            )
        draft = await _stored_purchase_draft(db, purchase)
        transaction_ids = [item.transaction_id for item in body.allocations]
        transaction_rows = await _review_payment_rows(
            db,
            purchase=purchase,
            transaction_ids=transaction_ids,
        )
        line_rows = await (
            await db.execute(
                """
                SELECT id, source_line_reference FROM finance_purchase_lines
                WHERE purchase_id = ? AND space_id = ? AND deleted_at IS NULL
                """,
                (purchase_id, purchase["space_id"]),
            )
        ).fetchall()
        line_refs = {row["id"]: row["source_line_reference"] for row in line_rows}
        for allocation in body.allocations:
            if allocation.line_id is not None and allocation.line_id not in line_refs:
                raise FinancePurchaseNotFoundError("Finance purchase line not found")

        ordered = sorted(
            body.allocations,
            key=lambda item: (
                item.transaction_id,
                item.line_id or "",
                item.allocated_minor,
            ),
        )
        payments: list[CanonicalPayment] = []
        reviewed_allocations: list[PaymentAllocation] = []
        requested_rows: list[tuple[str, str | None, int, str]] = []
        for index, allocation in enumerate(ordered, start=1):
            transaction = transaction_rows[allocation.transaction_id]
            available = abs(transaction["amount_minor"]) - transaction["allocated_elsewhere"]
            if available <= 0:
                raise FinancePurchaseError(
                    "Canonical transaction has no unallocated amount"
                )
            tender_kind = (
                TenderKind.CARD
                if transaction["account_type"] == "CREDIT_CARD"
                else TenderKind.BANK
            )
            payments.append(
                CanonicalPayment(
                    payment_id=transaction["id"],
                    merchant=(
                        transaction["merchant_text"] or transaction["description"]
                    ),
                    booked_on=date.fromisoformat(transaction["canonical_date"]),
                    amount_minor=(
                        -available if transaction["amount_minor"] < 0 else available
                    ),
                    currency=transaction["currency"],
                    description=transaction["description"],
                    card_suffix=(
                        transaction["last_four"]
                        if transaction["account_type"] == "CREDIT_CARD"
                        else None
                    ),
                )
            )
            reviewed_allocations.append(
                PaymentAllocation(
                    allocation_ref=f"reviewed:{index}:{transaction['id']}",
                    purchase_ref=purchase["purchase_ref"],
                    tender_kind=tender_kind,
                    allocated_minor=allocation.allocated_minor,
                    payment_id=transaction["id"],
                    line_ref=(
                        line_refs[allocation.line_id]
                        if allocation.line_id is not None
                        else None
                    ),
                )
            )
            requested_rows.append(
                (
                    transaction["id"],
                    allocation.line_id,
                    allocation.allocated_minor,
                    tender_kind.value,
                )
            )

        nonbank = await _nonbank_allocations(db, purchase=purchase)
        reconciliation = reconcile_allocations(
            [draft],
            payments,
            [*nonbank, *reviewed_allocations],
        )
        if reconciliation.quarantined:
            codes = ", ".join(issue.code for issue in reconciliation.issues)
            raise FinancePurchaseError(
                f"Reviewed allocations do not reconcile: {codes}"
            )
        remainder = reconciliation.purchase_remainders[0]
        if remainder.unallocated_purchase_minor or remainder.unallocated_refund_minor:
            raise FinancePurchaseError(
                "Reviewed allocations must exactly cover the purchase and refunds"
            )

        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_purchase_payments
                WHERE purchase_id = ? AND space_id = ?
                  AND transaction_id IS NOT NULL AND deleted_at IS NULL
                ORDER BY transaction_id, COALESCE(line_id, ''), allocated_minor
                """,
                (purchase_id, purchase["space_id"]),
            )
        ).fetchall()
        existing_rows = [
            (
                row["transaction_id"],
                row["line_id"],
                row["allocated_minor"],
                row["tender_kind"],
            )
            for row in existing
        ]
        is_retry = (
            existing_rows == requested_rows
            and all(
                row["match_method"] == "REVIEWED" and row["status"] == "CONFIRMED"
                for row in existing
            )
        )
        now = _now()
        if not is_retry:
            for row in existing:
                await save_history(
                    db,
                    "finance_purchase_payments",
                    row["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
            if existing:
                await db.execute(
                    """
                    UPDATE finance_purchase_payments
                    SET deleted_at = ?, updated_at = ?
                    WHERE purchase_id = ? AND space_id = ?
                      AND transaction_id IS NOT NULL AND deleted_at IS NULL
                    """,
                    (now, now, purchase_id, purchase["space_id"]),
                )
            for allocation, requested in zip(reviewed_allocations, ordered, strict=True):
                await db.execute(
                    """
                    INSERT INTO finance_purchase_payments
                        (id, space_id, purchase_id, transaction_id, line_id,
                         allocation_ref, tender_kind, allocated_minor,
                         match_method, status, family_id, created_at, updated_at,
                         created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'REVIEWED', 'CONFIRMED',
                            ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        purchase["space_id"],
                        purchase_id,
                        allocation.payment_id,
                        requested.line_id,
                        allocation.allocation_ref,
                        allocation.tender_kind.value,
                        allocation.allocated_minor,
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
        await _resolve_matching_exceptions(
            db,
            user=user,
            purchase=purchase,
            now=now,
        )
    return await read_purchase(db, user=user, purchase_id=purchase_id)


async def rematch_unmatched_purchases(
    db,
    *,
    user: dict,
    space_id: str,
    limit: int = 50,
) -> int:
    """Apply only new unique exact bank matches to older unmatched purchases."""
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            "SELECT DISTINCT purchase.* FROM finance_purchase_records purchase "
            "JOIN finance_purchase_exceptions exception "
            "ON exception.purchase_id = purchase.id AND exception.space_id = purchase.space_id "
            "AND exception.family_id = purchase.family_id "
            "WHERE purchase.space_id = ? AND purchase.family_id = ? "
            "AND purchase.superseded_by_id IS NULL AND purchase.deleted_at IS NULL "
            "AND exception.exception_kind IN ('UNMATCHED_PURCHASE', 'AMBIGUOUS_MATCH') "
            "AND exception.status = 'OPEN' AND exception.deleted_at IS NULL "
            "ORDER BY purchase.purchased_on, purchase.id LIMIT ?",
            (space_id, user["family_id"], limit),
        )
    ).fetchall()
    matched_count = 0
    for source in rows:
        purchase = dict(source)
        try:
            draft = await _stored_purchase_draft(db, purchase)
            candidates = await _candidate_payments(
                db, user=user, space_id=space_id, draft=draft
            )
            suggested, _, ambiguous = _matched_allocations(draft, candidates)
            if ambiguous:
                continue
            new_bank = [item for item in suggested if item.payment_id is not None]
            if not new_bank:
                continue
            existing = await (
                await db.execute(
                    "SELECT transaction_id, line_id, allocated_minor "
                    "FROM finance_purchase_payments WHERE purchase_id = ? "
                    "AND space_id = ? AND transaction_id IS NOT NULL "
                    "AND status = 'CONFIRMED' AND deleted_at IS NULL "
                    "ORDER BY transaction_id, COALESCE(line_id, '')",
                    (purchase["id"], space_id),
                )
            ).fetchall()
            allocations = [
                FinancePurchaseMatchAllocation(
                    transaction_id=row["transaction_id"],
                    line_id=row["line_id"],
                    allocated_minor=row["allocated_minor"],
                )
                for row in existing
            ]
            allocations.extend(
                FinancePurchaseMatchAllocation(
                    transaction_id=item.payment_id,
                    allocated_minor=item.allocated_minor,
                )
                for item in new_bank
                if item.payment_id is not None
            )
            await review_purchase_match(
                db,
                user=user,
                purchase_id=purchase["id"],
                body=FinancePurchaseMatchReview(reviewed=True, allocations=allocations),
            )
        except FinancePurchaseError:
            continue
        matched_count += 1
    return matched_count


def _exception_response(row: dict) -> FinancePurchaseExceptionResponse:
    return FinancePurchaseExceptionResponse(
        id=row["id"],
        space_id=row["space_id"],
        source_id=row["source_id"],
        purchase_id=row["purchase_id"],
        exception_kind=row["exception_kind"],
        title=row["title"],
        detail=row["detail"],
        amount_minor=row["amount_minor"],
        currency=row["currency"],
        status=row["status"],
        priority=row["priority"],
        created_at=row["created_at"],
    )


async def read_purchase_exception(
    db, *, user: dict, exception_id: str
) -> FinancePurchaseExceptionResponse:
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT exception.* FROM finance_purchase_exceptions exception
            JOIN finance_spaces space
              ON space.id = exception.space_id
             AND space.family_id = exception.family_id
             AND space.deleted_at IS NULL
            WHERE exception.id = ? AND exception.family_id = ?
              AND exception.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            """,
            (exception_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinancePurchaseNotFoundError("Finance purchase exception not found")
    return _exception_response(dict(row))


async def list_purchase_inbox(
    db,
    *,
    user: dict,
    space_id: str,
    offset: int,
    limit: int,
    exclude_own_shared_copies: bool = False,
) -> list[FinancePurchaseExceptionResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    own_copy_clause = ""
    parameters: list[object] = [space_id, user["family_id"]]
    if exclude_own_shared_copies:
        own_copy_clause = """
              AND NOT EXISTS (
                  SELECT 1 FROM finance_share_copy_links copy
                  JOIN finance_share_actions share
                    ON share.id = copy.share_action_id AND share.deleted_at IS NULL
                  WHERE copy.household_record_type = 'purchase'
                    AND copy.household_record_id = finance_purchase_exceptions.purchase_id
                    AND copy.household_space_id = finance_purchase_exceptions.space_id
                    AND copy.family_id = finance_purchase_exceptions.family_id
                    AND copy.deleted_at IS NULL AND share.owner_user_id = ?
              )
        """
        parameters.append(user["id"])
    parameters.extend((limit, offset))
    rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_purchase_exceptions
            WHERE space_id = ? AND family_id = ? AND status = 'OPEN'
              AND deleted_at IS NULL
              {own_copy_clause}
            ORDER BY priority DESC, created_at DESC, id
            LIMIT ? OFFSET ?
            """,
            parameters,
        )
    ).fetchall()
    return [_exception_response(dict(row)) for row in rows]

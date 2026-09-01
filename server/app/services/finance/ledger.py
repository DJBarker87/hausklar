"""Canonical cash-ledger behaviour, independent of provider wording."""

import hashlib
import re
import unicodedata
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from difflib import SequenceMatcher

from app.models.finance import (
    FinanceAccountCreate,
    FinanceAccountResponse,
    FinanceBalanceResponse,
    FinanceCurrencySummary,
    FinanceImportResult,
    FinanceLedgerSummaryResponse,
    FinanceRelationResponse,
    FinanceSplitInput,
    FinanceSplitResponse,
    FinanceTransactionResponse,
    NormalisedSourceTransaction,
)
from app.services.finance.foundation import (
    require_finance_access,
    require_finance_space,
    resolve_finance_scope_spaces,
)
from app.services.finance.categorisation import (
    apply_rule_category_to_existing,
    classify_transaction,
    ensure_default_categories,
    record_new_transaction_categories,
)
from app.services.finance.money import normalise_currency
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

_WHITESPACE = re.compile(r"\s+")
_NON_WORD = re.compile(r"[^A-Z0-9]+")
_REFUND_WORDS = ("REFUND", "RETURN", "REVERSAL")
_REIMBURSEMENT_WORDS = ("REIMBURSE", "EXPENSE PAYMENT", "EXPENSES PAYMENT")
_NEUTRAL_RELATIONS = {"INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT", "FX_LEG"}

_INSERT_SOURCE_TRANSACTION = """
    INSERT INTO finance_source_transactions
        (id, space_id, account_id, source_kind, source_batch_id,
         source_transaction_id, source_statement_id,
         replaces_source_transaction_id, source_group_id,
         source_fingerprint, booking_date, value_date, pending_status,
         transaction_kind, amount_minor, currency, source_description,
         cleaned_description, merchant_text, merchant_category_code,
         bank_code, bank_sub_code, observed_at, family_id,
         created_at, updated_at, created_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""
_INSERT_CANONICAL_TRANSACTION = """
    INSERT INTO finance_transactions
        (id, space_id, account_id, canonical_date, amount_minor, currency,
         state, transaction_kind, source_kind, source_group_id, description,
         cleaned_description, merchant_text, merchant_id, primary_category_id,
         data_through_at,
         family_id, created_at, updated_at, created_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""
_INSERT_TRANSACTION_SOURCE = """
    INSERT INTO finance_transaction_sources
        (id, space_id, transaction_id, source_transaction_id, is_primary,
         family_id, created_at, updated_at, created_by)
    VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?)
"""


class FinanceLedgerError(ValueError):
    """Base class for safe Finance ledger failures."""


class FinanceRecordNotFoundError(FinanceLedgerError):
    """A caller-visible Finance record was not found."""


class FinanceImportConflictError(FinanceLedgerError):
    """A strong source identifier was reused for different normalized data."""


def clean_description(value: str) -> str:
    """Return the stable comparison form without discarding stored source text."""
    normalised = unicodedata.normalize("NFKC", value).upper().strip()
    return _WHITESPACE.sub(" ", _NON_WORD.sub(" ", normalised)).strip()


def source_fingerprint(account_id: str, source: NormalisedSourceTransaction) -> str:
    """Hash only normalized identity fields used for overlap idempotency."""
    identity = "\x1f".join(
        (
            account_id,
            source.pending_status,
            source.booking_date.isoformat(),
            source.value_date.isoformat() if source.value_date else "",
            str(source.amount_minor),
            source.currency,
            clean_description(source.description),
        )
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


async def create_finance_account(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceAccountCreate,
) -> FinanceAccountResponse:
    """Create normalized account metadata inside a caller-authorized space."""
    await require_finance_space(db, user=user, space_id=space_id)
    if body.connection_id:
        connection = await (
            await db.execute(
                """
                SELECT 1 FROM finance_connections
                WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (body.connection_id, space_id, user["family_id"]),
            )
        ).fetchone()
        if connection is None:
            raise FinanceRecordNotFoundError("Finance connection not found")

    account_id = body.id or str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    async with serialized_create(db):
        existing = await (
            await db.execute("SELECT * FROM finance_accounts WHERE id = ?", (account_id,))
        ).fetchone()
        if existing is not None:
            if (
                existing["space_id"] != space_id
                or existing["family_id"] != user["family_id"]
                or existing["deleted_at"] is not None
            ):
                raise FinanceImportConflictError("Finance account ID is already in use")
            return _account_response(dict(existing), None)
        await db.execute(
            """
            INSERT INTO finance_accounts
                (id, space_id, connection_id, provider_account_id, label, institution,
                 account_type, purpose, currency, last_four, include_in_cashflow,
                 include_in_net_worth, primary_spending_account, minimum_balance_minor,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                account_id,
                space_id,
                body.connection_id,
                body.provider_account_id,
                body.label,
                body.institution,
                body.account_type,
                _default_account_purpose(body.account_type),
                body.currency,
                body.last_four,
                int(body.include_in_cashflow),
                int(body.include_in_net_worth),
                0,
                body.minimum_balance_minor,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    row = await (
        await db.execute("SELECT * FROM finance_accounts WHERE id = ?", (account_id,))
    ).fetchone()
    return _account_response(dict(row), None)


async def record_balance_snapshot(
    db,
    *,
    user: dict,
    space_id: str,
    account_id: str,
    booked_minor: int,
    available_minor: int | None,
    credit_limit_minor: int | None,
    currency: str,
    observed_at: datetime,
    provider_at: datetime | None = None,
) -> str:
    """Append one normalized balance observation; earlier snapshots remain immutable."""
    account = await _authorised_account(db, user=user, space_id=space_id, account_id=account_id)
    currency = normalise_currency(currency)
    if currency != account["currency"]:
        raise FinanceLedgerError("Balance currency does not match the account")
    if observed_at.tzinfo is None or observed_at.utcoffset() is None:
        raise FinanceLedgerError("Balance observed_at must include a timezone")
    snapshot_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    observed_text = _utc_text(observed_at)
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_balance_snapshots
                (id, space_id, account_id, booked_minor, available_minor,
                 credit_limit_minor, currency, provider_at, observed_at, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                snapshot_id,
                space_id,
                account_id,
                booked_minor,
                available_minor,
                credit_limit_minor,
                currency,
                _utc_text(provider_at) if provider_at else None,
                observed_text,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        await save_history(
            db,
            "finance_accounts",
            account_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_accounts
            SET data_through_at = CASE
                    WHEN data_through_at IS NULL OR data_through_at < ? THEN ?
                    ELSE data_through_at END,
                updated_at = ?
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (observed_text, observed_text, now, account_id, space_id, user["family_id"]),
        )
        # A deliberately shared account keeps future balance history visible;
        # standalone transaction shares never expose a source balance.
        from app.services.finance.sharing import apply_balance_share_rules

        await apply_balance_share_rules(db, user=user, balance_id=snapshot_id)
    return snapshot_id


async def _authorised_account(
    db,
    *,
    user: dict,
    space_id: str,
    account_id: str,
) -> dict:
    await require_finance_space(db, user=user, space_id=space_id)
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_accounts
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (account_id, space_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceRecordNotFoundError("Finance account not found")
    return dict(row)


def _account_response(row: dict, balance: dict | None) -> FinanceAccountResponse:
    return FinanceAccountResponse(
        id=row["id"],
        space_id=row["space_id"],
        label=row["label"],
        institution=row["institution"],
        account_type=row["account_type"],
        purpose=row["purpose"],
        currency=row["currency"],
        last_four=row["last_four"],
        include_in_cashflow=bool(row["include_in_cashflow"]),
        include_in_net_worth=bool(row["include_in_net_worth"]),
        primary_spending_account=bool(row["primary_spending_account"]),
        minimum_balance_minor=row["minimum_balance_minor"],
        card_paid_in_full=bool(row["card_paid_in_full"]),
        card_settlement_account_id=row["card_settlement_account_id"],
        card_statement_close_day=row["card_statement_close_day"],
        card_repayment_day=row["card_repayment_day"],
        fresh_through_date=row["fresh_through_date"],
        data_through_at=row["data_through_at"],
        provider_presence_status=row.get("provider_presence_status", "ACTIVE"),
        balance=(
            FinanceBalanceResponse(
                booked_minor=balance["booked_minor"],
                available_minor=balance["available_minor"],
                credit_limit_minor=balance["credit_limit_minor"],
                provider_at=balance["provider_at"],
                observed_at=balance["observed_at"],
            )
            if balance
            else None
        ),
    )


def _default_account_purpose(account_type: str) -> str:
    if account_type == "SAVINGS":
        return "SAVINGS"
    if account_type == "CREDIT_CARD":
        return "CREDIT_CARD"
    if account_type in {"INVESTMENT", "CRYPTO"}:
        return "INVESTMENT_LIKE"
    return "OPERATING_CURRENT"


async def list_finance_accounts(
    db,
    *,
    user: dict,
    space_id: str,
    exclude_own_shared_copies: bool = False,
) -> list[FinanceAccountResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    own_copy_clause = ""
    parameters: list[object] = [space_id, user["family_id"]]
    if exclude_own_shared_copies:
        own_copy_clause = """
            AND NOT EXISTS (
                SELECT 1 FROM finance_share_copy_links copy
                JOIN finance_share_actions share
                  ON share.id = copy.share_action_id AND share.deleted_at IS NULL
                WHERE copy.household_record_type = 'account'
                  AND copy.household_record_id = a.id
                  AND copy.household_space_id = a.space_id
                  AND copy.family_id = a.family_id AND copy.deleted_at IS NULL
                  AND share.owner_user_id = ?
            )
        """
        parameters.append(user["id"])
    rows = await (
        await db.execute(
            f"""
            SELECT a.*, b.booked_minor, b.available_minor, b.credit_limit_minor,
                   b.provider_at, b.observed_at AS balance_observed_at
            FROM finance_accounts a
            LEFT JOIN finance_balance_snapshots b
              ON b.id = (
                  SELECT latest.id FROM finance_balance_snapshots latest
                  WHERE latest.account_id = a.id AND latest.space_id = a.space_id
                    AND latest.deleted_at IS NULL
                  ORDER BY latest.observed_at DESC, latest.id DESC LIMIT 1
              )
            WHERE a.space_id = ? AND a.family_id = ? AND a.deleted_at IS NULL
              {own_copy_clause}
            ORDER BY a.label, a.id
            """,
            parameters,
        )
    ).fetchall()
    responses = []
    for source in rows:
        row = dict(source)
        balance = None
        if row["balance_observed_at"] is not None:
            balance = {
                "booked_minor": row["booked_minor"],
                "available_minor": row["available_minor"],
                "credit_limit_minor": row["credit_limit_minor"],
                "provider_at": row["provider_at"],
                "observed_at": row["balance_observed_at"],
            }
        responses.append(_account_response(row, balance))
    return responses


_IMPORT_LOOKUP_CHUNK = 400


def _chunks(values: list[str], size: int = _IMPORT_LOOKUP_CHUNK):
    for index in range(0, len(values), size):
        yield values[index : index + size]


async def _source_import_cache(
    db,
    *,
    account_id: str,
    prepared: list[tuple[NormalisedSourceTransaction, str, str]],
) -> tuple[
    dict[tuple[str, str], dict],
    dict[tuple[str, str], dict],
    dict[str, dict],
    dict[str, dict],
]:
    """Bulk-load every active source identity this import can reference."""
    source_rows: dict[str, dict] = {}
    lookup_values = (
        (
            "source_transaction_id",
            sorted(
                {
                    source.source_transaction_id
                    for source, _, _ in prepared
                    if source.source_transaction_id
                }
            ),
        ),
        (
            "source_statement_id",
            sorted(
                {
                    source.source_statement_id
                    for source, _, _ in prepared
                    if source.source_statement_id
                }
            ),
        ),
        ("source_fingerprint", sorted({fingerprint for _, _, fingerprint in prepared})),
    )
    for column, values in lookup_values:
        for batch in _chunks(values):
            placeholders = ",".join("?" for _ in batch)
            rows = await (
                await db.execute(
                    f"""
                    SELECT * FROM finance_source_transactions
                    WHERE account_id = ? AND {column} IN ({placeholders})
                      AND deleted_at IS NULL
                    """,
                    [account_id, *batch],
                )
            ).fetchall()
            source_rows.update((row["id"], dict(row)) for row in rows)

    canonical_by_source: dict[str, dict] = {}
    for batch in _chunks(sorted(source_rows)):
        placeholders = ",".join("?" for _ in batch)
        rows = await (
            await db.execute(
                f"""
                SELECT link.source_transaction_id AS source_id,
                       canonical.id AS transaction_id,
                       canonical.primary_category_id
                FROM finance_transaction_sources link
                JOIN finance_transactions canonical
                  ON canonical.id = link.transaction_id
                 AND canonical.deleted_at IS NULL
                WHERE link.source_transaction_id IN ({placeholders})
                  AND link.deleted_at IS NULL
                """,
                batch,
            )
        ).fetchall()
        canonical_by_source.update(
            (
                row["source_id"],
                {
                    "id": row["transaction_id"],
                    "primary_category_id": row["primary_category_id"],
                },
            )
            for row in rows
        )

    provider_sources: dict[tuple[str, str], dict] = {}
    statement_sources: dict[tuple[str, str], dict] = {}
    fingerprint_sources: dict[str, dict] = {}
    for row in source_rows.values():
        if row["source_transaction_id"]:
            provider_sources[(row["source_transaction_id"], row["pending_status"])] = row
        if row["source_statement_id"]:
            statement_sources[(row["source_statement_id"], row["pending_status"])] = row
        fingerprint_sources[row["source_fingerprint"]] = row
    return provider_sources, statement_sources, fingerprint_sources, canonical_by_source


def _cached_source(
    *,
    source: NormalisedSourceTransaction,
    fingerprint: str,
    provider_sources: dict[tuple[str, str], dict],
    statement_sources: dict[tuple[str, str], dict],
    fingerprint_sources: dict[str, dict],
) -> dict | None:
    if source.source_transaction_id:
        row = provider_sources.get((source.source_transaction_id, source.pending_status))
        if row is not None:
            return row
    if source.source_statement_id:
        row = statement_sources.get((source.source_statement_id, source.pending_status))
        if row is not None:
            return row
    return fingerprint_sources.get(fingerprint)


async def _merchant_alias_cache(db, *, space_id: str, aliases: set[str]) -> dict[str, dict]:
    rows_by_alias: dict[str, dict] = {}
    for batch in _chunks(sorted(aliases)):
        placeholders = ",".join("?" for _ in batch)
        rows = await (
            await db.execute(
                f"""
                SELECT id, merchant_id, normalised_alias
                FROM finance_merchant_aliases
                WHERE space_id = ? AND normalised_alias IN ({placeholders})
                  AND deleted_at IS NULL
                """,
                [space_id, *batch],
            )
        ).fetchall()
        rows_by_alias.update((row["normalised_alias"], dict(row)) for row in rows)
    return rows_by_alias


def _cached_merchant(
    aliases: dict[str, dict], *, cleaned: str, merchant_text: str | None
) -> dict | None:
    keys = {cleaned}
    if merchant_text:
        keys.add(clean_description(merchant_text))
    candidates = [aliases[key] for key in keys if key in aliases]
    return min(candidates, key=lambda row: row["id"]) if candidates else None


async def _pending_match_state(
    db, *, account_id: str
) -> tuple[dict[str, dict], dict[str, list[tuple[str, str]]]]:
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_transactions
            WHERE account_id = ? AND state = 'PENDING'
              AND deleted_at IS NULL AND superseded_by_id IS NULL
            """,
            (account_id,),
        )
    ).fetchall()
    candidates = {row["id"]: dict(row) for row in rows}
    source_rows = await (
        await db.execute(
            """
            SELECT source.source_transaction_id, source.observed_at,
                   canonical.id AS transaction_id
            FROM finance_source_transactions source
            JOIN finance_transaction_sources link
              ON link.source_transaction_id = source.id AND link.deleted_at IS NULL
            JOIN finance_transactions canonical
              ON canonical.id = link.transaction_id
             AND canonical.deleted_at IS NULL
            WHERE source.account_id = ? AND source.pending_status = 'PENDING'
              AND source.source_transaction_id IS NOT NULL
              AND canonical.state = 'PENDING'
            """,
            (account_id,),
        )
    ).fetchall()
    source_matches: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for row in source_rows:
        source_matches[row["source_transaction_id"]].append(
            (row["observed_at"], row["transaction_id"])
        )
    return candidates, source_matches


def _matching_pending_from_state(
    *,
    source: NormalisedSourceTransaction,
    cleaned: str,
    candidates: dict[str, dict],
    source_matches: dict[str, list[tuple[str, str]]],
) -> dict | None:
    if source.replaces_source_transaction_id:
        matches = [
            (observed_at, transaction_id)
            for observed_at, transaction_id in source_matches.get(
                source.replaces_source_transaction_id, []
            )
            if transaction_id in candidates
        ]
        if not matches:
            return None
        return candidates[max(matches)[1]]

    scored = []
    for candidate in candidates.values():
        if candidate["currency"] != source.currency:
            continue
        date_gap = abs((source.booking_date - date.fromisoformat(candidate["canonical_date"])).days)
        amount_gap = abs(source.amount_minor - candidate["amount_minor"])
        amount_limit = max(50, abs(source.amount_minor) // 50)
        similarity = SequenceMatcher(None, cleaned, candidate["cleaned_description"]).ratio()
        if date_gap <= 7 and amount_gap <= amount_limit and similarity >= 0.9:
            scored.append((amount_gap, date_gap, -similarity, candidate["id"], candidate))
    return min(scored)[-1] if scored else None


async def import_source_transactions(
    db,
    *,
    user: dict,
    space_id: str,
    account_id: str,
    observations: list[NormalisedSourceTransaction],
) -> FinanceImportResult:
    """Append normalized observations and create one stable canonical history."""
    account = await _authorised_account(db, user=user, space_id=space_id, account_id=account_id)
    if not observations:
        return FinanceImportResult(
            source_created=0,
            canonical_created=0,
            duplicates=0,
            pending_superseded=0,
            transaction_ids=[],
            relation_suggestion_ids=[],
        )

    source_created = canonical_created = duplicates = pending_superseded = 0
    transaction_ids: list[str] = []
    new_transaction_ids: list[str] = []
    new_category_assignments: list[tuple[str, str, int]] = []
    latest_observed: str | None = None
    latest_booking: str | None = None
    prepared = [
        (source, clean_description(source.description), source_fingerprint(account_id, source))
        for source in observations
    ]
    merchant_aliases = {
        alias
        for source, cleaned, _ in prepared
        for alias in (
            cleaned,
            clean_description(source.merchant_text) if source.merchant_text else cleaned,
        )
    }

    async with serialized_create(db):
        (
            provider_sources,
            statement_sources,
            fingerprint_sources,
            canonical_by_source,
        ) = await _source_import_cache(db, account_id=account_id, prepared=prepared)
        aliases = await _merchant_alias_cache(
            db, space_id=space_id, aliases=merchant_aliases
        )
        category_ids = (
            await ensure_default_categories(
                db,
                space_id=space_id,
                family_id=user["family_id"],
                actor_id=user["id"],
            )
            if any(source.amount_minor < 0 for source, _, _ in prepared)
            else {}
        )
        pending_candidates, pending_source_matches = await _pending_match_state(
            db, account_id=account_id
        )
        bulk_core_inserts = not pending_candidates and all(
            source.pending_status == "POSTED" for source, _, _ in prepared
        )
        source_insert_rows: list[tuple] = []
        transaction_insert_rows: list[tuple] = []
        transaction_source_rows: list[tuple] = []
        active_share_actions = await (
            await db.execute(
                """
                SELECT 1 FROM finance_share_actions
                WHERE owner_user_id = ? AND source_space_id = ? AND family_id = ?
                  AND status = 'ACTIVE' AND share_kind IN ('ACCOUNT', 'RULE')
                  AND deleted_at IS NULL
                LIMIT 1
                """,
                (user["id"], space_id, user["family_id"]),
            )
        ).fetchone()

        for source, cleaned, fingerprint in prepared:
            if source.currency != account["currency"]:
                raise FinanceLedgerError("Transaction currency does not match the account")
            if source.amount_minor == 0:
                raise FinanceLedgerError("Zero-value source transactions are not supported")
            category_match = classify_transaction(
                amount_minor=source.amount_minor,
                description=source.description,
                merchant_text=source.merchant_text,
                transaction_kind=source.transaction_kind,
                provider_category=source.bank_code,
                provider_classification=source.bank_sub_code,
                merchant_category_code=source.merchant_category_code,
            )
            category_id = (
                category_ids[category_match.key] if category_match is not None else None
            )
            existing = _cached_source(
                source=source,
                fingerprint=fingerprint,
                provider_sources=provider_sources,
                statement_sources=statement_sources,
                fingerprint_sources=fingerprint_sources,
            )
            if existing is not None:
                if existing["source_fingerprint"] != fingerprint:
                    raise FinanceImportConflictError(
                        "A source transaction identifier was reused for different data"
                    )
                canonical = canonical_by_source.get(existing["id"])
                if canonical is None:
                    raise RuntimeError("Source observation has no canonical transaction")
                if (
                    category_id is not None
                    and category_match is not None
                    and canonical.get("primary_category_id") != category_id
                ):
                    await apply_rule_category_to_existing(
                        db,
                        transaction_id=canonical["id"],
                        space_id=space_id,
                        category_id=category_id,
                        confidence_bps=category_match.confidence_bps,
                        family_id=user["family_id"],
                        actor_id=user["id"],
                    )
                duplicates += 1
                if canonical["id"] not in transaction_ids:
                    transaction_ids.append(canonical["id"])
                continue

            source_id = str(uuid.uuid4())
            transaction_id = str(uuid.uuid4())
            observed_text = _utc_text(source.observed_at)
            now = datetime.now(timezone.utc).isoformat()
            source_parameters = (
                source_id,
                space_id,
                account_id,
                source.source_kind,
                source.source_batch_id,
                source.source_transaction_id,
                source.source_statement_id,
                source.replaces_source_transaction_id,
                source.source_group_id,
                fingerprint,
                source.booking_date.isoformat(),
                source.value_date.isoformat() if source.value_date else None,
                source.pending_status,
                source.transaction_kind,
                source.amount_minor,
                source.currency,
                source.description,
                cleaned,
                source.merchant_text,
                source.merchant_category_code,
                source.bank_code,
                source.bank_sub_code,
                observed_text,
                user["family_id"],
                now,
                now,
                user["id"],
            )
            if bulk_core_inserts:
                source_insert_rows.append(source_parameters)
            else:
                await db.execute(_INSERT_SOURCE_TRANSACTION, source_parameters)
            source_created += 1

            pending = None
            if source.pending_status == "POSTED":
                pending = _matching_pending_from_state(
                    source=source,
                    cleaned=cleaned,
                    candidates=pending_candidates,
                    source_matches=pending_source_matches,
                )
            merchant = _cached_merchant(
                aliases,
                cleaned=cleaned,
                merchant_text=source.merchant_text,
            )
            transaction_parameters = (
                transaction_id,
                space_id,
                account_id,
                source.booking_date.isoformat(),
                source.amount_minor,
                source.currency,
                source.pending_status,
                source.transaction_kind,
                source.source_kind,
                source.source_group_id,
                source.description,
                cleaned,
                source.merchant_text,
                merchant["merchant_id"] if merchant else None,
                category_id,
                observed_text,
                user["family_id"],
                now,
                now,
                user["id"],
            )
            transaction_source_parameters = (
                str(uuid.uuid4()),
                space_id,
                transaction_id,
                source_id,
                user["family_id"],
                now,
                now,
                user["id"],
            )
            if bulk_core_inserts:
                transaction_insert_rows.append(transaction_parameters)
                transaction_source_rows.append(transaction_source_parameters)
            else:
                await db.execute(_INSERT_CANONICAL_TRANSACTION, transaction_parameters)
                await db.execute(_INSERT_TRANSACTION_SOURCE, transaction_source_parameters)
            cached_source = {
                "id": source_id,
                "source_transaction_id": source.source_transaction_id,
                "source_statement_id": source.source_statement_id,
                "pending_status": source.pending_status,
                "source_fingerprint": fingerprint,
            }
            if source.source_transaction_id:
                provider_sources[(source.source_transaction_id, source.pending_status)] = (
                    cached_source
                )
            if source.source_statement_id:
                statement_sources[(source.source_statement_id, source.pending_status)] = (
                    cached_source
                )
            fingerprint_sources[fingerprint] = cached_source
            canonical_by_source[source_id] = {
                "id": transaction_id,
                "primary_category_id": category_id,
            }
            if category_id is not None and category_match is not None:
                new_category_assignments.append(
                    (transaction_id, category_id, category_match.confidence_bps)
                )
            if pending is not None:
                await save_history(
                    db,
                    "finance_transactions",
                    pending["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    """
                    UPDATE finance_transactions
                    SET state = 'SUPERSEDED', superseded_by_id = ?, updated_at = ?
                    WHERE id = ? AND space_id = ? AND state = 'PENDING' AND deleted_at IS NULL
                    """,
                    (transaction_id, now, pending["id"], space_id),
                )
                pending_superseded += 1
                pending_candidates.pop(pending["id"], None)
            elif source.pending_status == "PENDING":
                pending_candidates[transaction_id] = {
                    "id": transaction_id,
                    "canonical_date": source.booking_date.isoformat(),
                    "amount_minor": source.amount_minor,
                    "currency": source.currency,
                    "cleaned_description": cleaned,
                }
                if source.source_transaction_id:
                    pending_source_matches[source.source_transaction_id].append(
                        (observed_text, transaction_id)
                    )
            canonical_created += 1
            transaction_ids.append(transaction_id)
            new_transaction_ids.append(transaction_id)
            latest_observed = max(latest_observed or observed_text, observed_text)
            booking_text = source.booking_date.isoformat()
            latest_booking = max(latest_booking or booking_text, booking_text)

        if source_insert_rows:
            await db.executemany(_INSERT_SOURCE_TRANSACTION, source_insert_rows)
            await db.executemany(_INSERT_CANONICAL_TRANSACTION, transaction_insert_rows)
            await db.executemany(_INSERT_TRANSACTION_SOURCE, transaction_source_rows)

        await record_new_transaction_categories(
            db,
            space_id=space_id,
            assignments=new_category_assignments,
            family_id=user["family_id"],
            actor_id=user["id"],
        )

        if latest_observed is not None:
            await save_history(
                db,
                "finance_accounts",
                account_id,
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_accounts
                SET data_through_at = CASE
                        WHEN data_through_at IS NULL OR data_through_at < ? THEN ?
                        ELSE data_through_at END,
                    fresh_through_date = CASE
                        WHEN fresh_through_date IS NULL OR fresh_through_date < ? THEN ?
                        ELSE fresh_through_date END,
                    updated_at = ?
                WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (
                    latest_observed,
                    latest_observed,
                    latest_booking,
                    latest_booking,
                    datetime.now(timezone.utc).isoformat(),
                    account_id,
                    space_id,
                    user["family_id"],
                ),
            )

        relation_ids = await _suggest_relations(
            db,
            user=user,
            space_id=space_id,
            transaction_ids=new_transaction_ids,
        )
        if new_transaction_ids and active_share_actions is not None:
            from app.services.finance.sharing import apply_transaction_share_rules

            for transaction_id in new_transaction_ids:
                await apply_transaction_share_rules(
                    db, user=user, transaction_id=transaction_id
                )

    return FinanceImportResult(
        source_created=source_created,
        canonical_created=canonical_created,
        duplicates=duplicates,
        pending_superseded=pending_superseded,
        transaction_ids=transaction_ids,
        relation_suggestion_ids=relation_ids,
    )


async def _insert_relation_suggestion(
    db,
    *,
    user: dict,
    space_id: str,
    from_id: str,
    to_id: str,
    relation_type: str,
    method: str,
    confidence_bps: int,
) -> str | None:
    existing = await (
        await db.execute(
            """
            SELECT id FROM finance_transaction_relations
            WHERE from_transaction_id = ? AND to_transaction_id = ?
              AND relation_type = ? AND deleted_at IS NULL
            """,
            (from_id, to_id, relation_type),
        )
    ).fetchone()
    if existing is not None:
        return None
    relation_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO finance_transaction_relations
            (id, space_id, from_transaction_id, to_transaction_id, relation_type,
             status, method, confidence_bps, family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, 'SUGGESTED', ?, ?, ?, ?, ?, ?)
        """,
        (
            relation_id,
            space_id,
            from_id,
            to_id,
            relation_type,
            method,
            confidence_bps,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    return relation_id


async def _suggest_relations(
    db,
    *,
    user: dict,
    space_id: str,
    transaction_ids: list[str],
) -> list[str]:
    suggestions: list[str] = []
    transactions_by_id: dict[str, dict] = {}
    for batch in _chunks(transaction_ids):
        placeholders = ",".join("?" for _ in batch)
        rows = await (
            await db.execute(
                f"""
                SELECT t.*, a.account_type FROM finance_transactions t
                JOIN finance_accounts a ON a.id = t.account_id AND a.deleted_at IS NULL
                WHERE t.id IN ({placeholders}) AND t.space_id = ?
                  AND t.state = 'POSTED' AND t.deleted_at IS NULL
                """,
                [*batch, space_id],
            )
        ).fetchall()
        transactions_by_id.update((row["id"], dict(row)) for row in rows)
    for transaction_id in transaction_ids:
        transaction = transactions_by_id.get(transaction_id)
        if transaction is None or transaction["transaction_kind"] == "FEE":
            continue
        transaction_day = date.fromisoformat(transaction["canonical_date"])
        cleaned = transaction["cleaned_description"]

        positive_kind = None
        if transaction["amount_minor"] > 0:
            if any(word in cleaned for word in _REFUND_WORDS):
                positive_kind = "REFUND"
            elif any(word in cleaned for word in _REIMBURSEMENT_WORDS):
                positive_kind = "REIMBURSEMENT"
        if positive_kind:
            candidates = await (
                await db.execute(
                    """
                    SELECT * FROM finance_transactions
                    WHERE space_id = ? AND currency = ? AND amount_minor < 0
                      AND state = 'POSTED' AND canonical_date BETWEEN ? AND ?
                      AND deleted_at IS NULL
                    ORDER BY canonical_date DESC, id
                    """,
                    (
                        space_id,
                        transaction["currency"],
                        (transaction_day - timedelta(days=120)).isoformat(),
                        transaction["canonical_date"],
                    ),
                )
            ).fetchall()
            eligible = [
                candidate
                for candidate in candidates
                if abs(transaction_day - date.fromisoformat(candidate["canonical_date"])).days
                <= 120
                and transaction["amount_minor"] <= abs(candidate["amount_minor"])
            ]
            if eligible:
                original = min(
                    eligible,
                    key=lambda row: (
                        abs(abs(row["amount_minor"]) - transaction["amount_minor"]),
                        abs(transaction_day - date.fromisoformat(row["canonical_date"])).days,
                        row["id"],
                    ),
                )
                relation_id = await _insert_relation_suggestion(
                    db,
                    user=user,
                    space_id=space_id,
                    from_id=original["id"],
                    to_id=transaction_id,
                    relation_type=positive_kind,
                    method="description_amount_date",
                    confidence_bps=9000,
                )
                if relation_id:
                    suggestions.append(relation_id)
                continue

        if transaction["source_group_id"]:
            fx_candidate = await (
                await db.execute(
                    """
                    SELECT t.*, a.account_type FROM finance_transactions t
                    JOIN finance_accounts a ON a.id = t.account_id AND a.deleted_at IS NULL
                    WHERE t.space_id = ? AND t.id <> ? AND t.state = 'POSTED'
                      AND t.source_group_id = ? AND t.currency <> ?
                      AND t.transaction_kind <> 'FEE'
                      AND ((t.amount_minor < 0 AND ? > 0) OR (t.amount_minor > 0 AND ? < 0))
                      AND t.deleted_at IS NULL
                    ORDER BY t.canonical_date DESC, t.id LIMIT 1
                    """,
                    (
                        space_id,
                        transaction_id,
                        transaction["source_group_id"],
                        transaction["currency"],
                        transaction["amount_minor"],
                        transaction["amount_minor"],
                    ),
                )
            ).fetchone()
            if fx_candidate:
                negative, positive = (
                    (transaction, fx_candidate)
                    if transaction["amount_minor"] < 0
                    else (fx_candidate, transaction)
                )
                relation_id = await _insert_relation_suggestion(
                    db,
                    user=user,
                    space_id=space_id,
                    from_id=negative["id"],
                    to_id=positive["id"],
                    relation_type="FX_LEG",
                    method="provider_group",
                    confidence_bps=9500,
                )
                if relation_id:
                    suggestions.append(relation_id)
                continue

        opposite = await (
            await db.execute(
                """
                SELECT t.*, a.account_type FROM finance_transactions t
                JOIN finance_accounts a ON a.id = t.account_id AND a.deleted_at IS NULL
                WHERE t.space_id = ? AND t.id <> ? AND t.account_id <> ?
                  AND t.state = 'POSTED' AND t.currency = ? AND t.amount_minor = ?
                  AND t.canonical_date BETWEEN ? AND ?
                  AND t.transaction_kind <> 'FEE' AND t.deleted_at IS NULL
                ORDER BY t.canonical_date DESC, t.id
                """,
                (
                    space_id,
                    transaction_id,
                    transaction["account_id"],
                    transaction["currency"],
                    -transaction["amount_minor"],
                    (transaction_day - timedelta(days=3)).isoformat(),
                    (transaction_day + timedelta(days=3)).isoformat(),
                ),
            )
        ).fetchall()
        eligible = [
            candidate
            for candidate in opposite
            if abs(transaction_day - date.fromisoformat(candidate["canonical_date"])).days <= 3
        ]
        if not eligible:
            continue
        candidate = min(
            eligible,
            key=lambda row: (
                abs(transaction_day - date.fromisoformat(row["canonical_date"])).days,
                row["id"],
            ),
        )
        negative, positive = (
            (transaction, candidate)
            if transaction["amount_minor"] < 0
            else (candidate, transaction)
        )
        is_card_repayment = (
            positive["account_type"] == "CREDIT_CARD" and negative["account_type"] != "CREDIT_CARD"
        )
        relation_id = await _insert_relation_suggestion(
            db,
            user=user,
            space_id=space_id,
            from_id=negative["id"],
            to_id=positive["id"],
            relation_type=("CREDIT_CARD_REPAYMENT" if is_card_repayment else "INTERNAL_TRANSFER"),
            method="opposite_owned_accounts",
            confidence_bps=9300 if is_card_repayment else 9000,
        )
        if relation_id:
            suggestions.append(relation_id)
    return suggestions


async def review_transaction_relation(
    db,
    *,
    user: dict,
    relation_id: str,
    status: str,
) -> FinanceRelationResponse:
    if status not in {"CONFIRMED", "REJECTED"}:
        raise FinanceLedgerError("Relation review status is invalid")
    require_finance_access(user)
    relation = await (
        await db.execute(
            """
            SELECT relation.* FROM finance_transaction_relations relation
            JOIN finance_spaces space
              ON space.id = relation.space_id
             AND space.family_id = relation.family_id
             AND space.deleted_at IS NULL
            WHERE relation.id = ? AND relation.family_id = ?
              AND relation.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            """,
            (relation_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if relation is None:
        raise FinanceRecordNotFoundError("Finance relation not found")
    now = datetime.now(timezone.utc).isoformat()
    async with serialized_create(db):
        if status == "CONFIRMED":
            await _validate_relation_confirmation(db, dict(relation))
        await save_history(
            db,
            "finance_transaction_relations",
            relation_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_transaction_relations
            SET status = ?, updated_at = ?
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (status, now, relation_id, relation["space_id"], user["family_id"]),
        )
        from app.services.finance.sharing import sync_shared_relation_review

        await sync_shared_relation_review(db, user=user, relation_id=relation_id)
    updated = dict(relation)
    updated["status"] = status
    return _relation_response(updated)


async def _validate_relation_confirmation(db, relation: dict) -> None:
    if relation["relation_type"] in _NEUTRAL_RELATIONS:
        existing_neutral = await (
            await db.execute(
                """
                SELECT 1 FROM finance_transaction_relations
                WHERE id <> ? AND space_id = ? AND status = 'CONFIRMED'
                  AND relation_type IN (
                      'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                  )
                  AND deleted_at IS NULL
                  AND (
                      from_transaction_id IN (?, ?)
                      OR to_transaction_id IN (?, ?)
                  )
                LIMIT 1
                """,
                (
                    relation["id"],
                    relation["space_id"],
                    relation["from_transaction_id"],
                    relation["to_transaction_id"],
                    relation["from_transaction_id"],
                    relation["to_transaction_id"],
                ),
            )
        ).fetchone()
        if existing_neutral is not None:
            raise FinanceLedgerError(
                "A transaction cannot belong to more than one confirmed transfer relation"
            )

    rows = await (
        await db.execute(
            """
            SELECT t.*, a.account_type FROM finance_transactions t
            JOIN finance_accounts a ON a.id = t.account_id AND a.deleted_at IS NULL
            WHERE t.id IN (?, ?) AND t.space_id = ? AND t.state = 'POSTED'
              AND t.deleted_at IS NULL
            """,
            (
                relation["from_transaction_id"],
                relation["to_transaction_id"],
                relation["space_id"],
            ),
        )
    ).fetchall()
    by_id = {row["id"]: row for row in rows}
    if len(by_id) != 2:
        raise FinanceLedgerError("Both relation transactions must be posted and visible")
    source = by_id[relation["from_transaction_id"]]
    target = by_id[relation["to_transaction_id"]]
    relation_type = relation["relation_type"]
    opposite_sign = source["amount_minor"] < 0 < target["amount_minor"]
    if relation_type in {"INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT"}:
        if (
            not opposite_sign
            or source["currency"] != target["currency"]
            or source["amount_minor"] + target["amount_minor"] != 0
            or source["account_id"] == target["account_id"]
        ):
            raise FinanceLedgerError("Transfer relation amounts do not reconcile")
        if relation_type == "CREDIT_CARD_REPAYMENT" and not (
            source["account_type"] != "CREDIT_CARD" and target["account_type"] == "CREDIT_CARD"
        ):
            raise FinanceLedgerError("Card repayment must enter a credit-card account")
    elif relation_type == "FX_LEG":
        if (
            not opposite_sign
            or source["currency"] == target["currency"]
            or "FEE" in {source["transaction_kind"], target["transaction_kind"]}
        ):
            raise FinanceLedgerError("FX relation must contain two principal currency legs")
    elif relation_type in {"REFUND", "REIMBURSEMENT"}:
        if (
            not opposite_sign
            or source["currency"] != target["currency"]
            or target["amount_minor"] > abs(source["amount_minor"])
        ):
            raise FinanceLedgerError("Refund or reimbursement does not reconcile")


def _relation_response(row: dict) -> FinanceRelationResponse:
    return FinanceRelationResponse(
        id=row["id"],
        from_transaction_id=row["from_transaction_id"],
        to_transaction_id=row["to_transaction_id"],
        relation_type=row["relation_type"],
        status=row["status"],
        method=row["method"],
        confidence_bps=row["confidence_bps"],
    )


def _split_response(row: dict) -> FinanceSplitResponse:
    category_name = row.get("category_name")
    spending_type = row.get("category_spending_type")
    return FinanceSplitResponse(
        id=row["id"],
        transaction_id=row["transaction_id"],
        amount_minor=row["amount_minor"],
        category_id=row["category_id"],
        category_name=category_name or "Uncategorised",
        spending_type=spending_type or "UNCATEGORISED",
        label=row["label"],
        created_at=row["created_at"],
    )


async def replace_transaction_splits(
    db,
    *,
    user: dict,
    transaction_id: str,
    splits: list[FinanceSplitInput],
) -> list[FinanceSplitResponse]:
    require_finance_access(user)
    transaction = await (
        await db.execute(
            """
            SELECT tx.* FROM finance_transactions tx
            JOIN finance_spaces space
              ON space.id = tx.space_id
             AND space.family_id = tx.family_id
             AND space.deleted_at IS NULL
            WHERE tx.id = ? AND tx.family_id = ?
              AND tx.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            """,
            (transaction_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if transaction is None:
        raise FinanceRecordNotFoundError("Finance transaction not found")
    if transaction["state"] in {"SUPERSEDED", "VOID"}:
        raise FinanceLedgerError("Superseded or void transactions cannot be split")
    if not splits or sum(item.amount_minor for item in splits) != transaction["amount_minor"]:
        raise FinanceLedgerError("Transaction splits must sum exactly to the transaction")
    if transaction["amount_minor"] > 0:
        invalid_sign = any(item.amount_minor <= 0 for item in splits)
    else:
        invalid_sign = any(item.amount_minor >= 0 for item in splits)
    if invalid_sign:
        raise FinanceLedgerError("Transaction splits must use the parent transaction sign")

    category_ids = {item.category_id for item in splits if item.category_id}
    categories: dict[str, dict] = {}
    if category_ids:
        placeholders = ",".join("?" for _ in category_ids)
        rows = await (
            await db.execute(
                f"""
                SELECT id, name, spending_type FROM finance_categories
                WHERE id IN ({placeholders}) AND space_id = ? AND family_id = ?
                  AND deleted_at IS NULL
                """,
                [*sorted(category_ids), transaction["space_id"], user["family_id"]],
            )
        ).fetchall()
        if {row["id"] for row in rows} != category_ids:
            raise FinanceRecordNotFoundError("Finance category not found")
        categories = {row["id"]: dict(row) for row in rows}

    now = datetime.now(timezone.utc).isoformat()
    created_rows = []
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT id FROM finance_transaction_splits
                WHERE transaction_id = ? AND space_id = ? AND deleted_at IS NULL
                """,
                (transaction_id, transaction["space_id"]),
            )
        ).fetchall()
        for row in existing:
            await save_history(
                db,
                "finance_transaction_splits",
                row["id"],
                user["id"],
                family_id=user["family_id"],
            )
        if existing:
            await db.execute(
                """
                UPDATE finance_transaction_splits
                SET deleted_at = ?, updated_at = ?
                WHERE transaction_id = ? AND space_id = ? AND family_id = ?
                  AND deleted_at IS NULL
                """,
                (
                    now,
                    now,
                    transaction_id,
                    transaction["space_id"],
                    user["family_id"],
                ),
            )
        for item in splits:
            row = {
                "id": str(uuid.uuid4()),
                "transaction_id": transaction_id,
                "amount_minor": item.amount_minor,
                "category_id": item.category_id,
                "category_name": (
                    categories[item.category_id]["name"] if item.category_id else None
                ),
                "category_spending_type": (
                    categories[item.category_id]["spending_type"]
                    if item.category_id
                    else None
                ),
                "label": item.label.strip() if item.label else None,
                "created_at": now,
            }
            await db.execute(
                """
                INSERT INTO finance_transaction_splits
                    (id, space_id, transaction_id, amount_minor, category_id, label,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    row["id"],
                    transaction["space_id"],
                    transaction_id,
                    row["amount_minor"],
                    row["category_id"],
                    row["label"],
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
            created_rows.append(row)
    return [_split_response(row) for row in created_rows]


async def list_finance_transactions(
    db,
    *,
    user: dict,
    space_id: str,
    offset: int,
    limit: int,
    account_id: str | None = None,
    search: str | None = None,
    include_superseded: bool = False,
    exclude_own_shared_copies: bool = False,
) -> list[FinanceTransactionResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    where = ["space_id = ?", "family_id = ?", "deleted_at IS NULL"]
    parameters: list[object] = [space_id, user["family_id"]]
    if not include_superseded:
        where.append("state IN ('PENDING', 'POSTED')")
    if account_id:
        where.append("account_id = ?")
        parameters.append(account_id)
    if search and clean_description(search):
        where.append("(cleaned_description LIKE ? OR upper(COALESCE(merchant_text, '')) LIKE ?)")
        term = f"%{clean_description(search)}%"
        parameters.extend((term, term))
    if exclude_own_shared_copies:
        where.append(
            """
            NOT EXISTS (
                SELECT 1 FROM finance_share_copy_links copy
                JOIN finance_share_actions share
                  ON share.id = copy.share_action_id AND share.deleted_at IS NULL
                WHERE copy.household_record_type = 'transaction'
                  AND copy.household_record_id = finance_transactions.id
                  AND copy.household_space_id = finance_transactions.space_id
                  AND copy.family_id = finance_transactions.family_id
                  AND copy.deleted_at IS NULL AND share.owner_user_id = ?
            )
            """
        )
        parameters.append(user["id"])
    parameters.extend((limit, offset))
    rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_transactions
            WHERE {" AND ".join(where)}
            ORDER BY canonical_date DESC, created_at DESC, id DESC
            LIMIT ? OFFSET ?
            """,
            parameters,
        )
    ).fetchall()
    return await _transaction_responses(db, rows, space_id=space_id)


async def _transaction_responses(db, rows, *, space_id: str) -> list[FinanceTransactionResponse]:
    if not rows:
        return []
    ids = [row["id"] for row in rows]
    placeholders = ",".join("?" for _ in ids)
    relation_rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_transaction_relations
            WHERE space_id = ? AND deleted_at IS NULL
              AND (from_transaction_id IN ({placeholders}) OR to_transaction_id IN ({placeholders}))
            ORDER BY created_at, id
            """,
            [space_id, *ids, *ids],
        )
    ).fetchall()
    relations_by_transaction: dict[str, list[FinanceRelationResponse]] = defaultdict(list)
    for relation in relation_rows:
        response = _relation_response(dict(relation))
        relations_by_transaction[relation["from_transaction_id"]].append(response)
        relations_by_transaction[relation["to_transaction_id"]].append(response)
    split_rows = await (
        await db.execute(
            f"""
            SELECT split.*, category.name AS category_name,
                   category.spending_type AS category_spending_type
            FROM finance_transaction_splits split
            LEFT JOIN finance_categories category
              ON category.id = split.category_id
             AND category.space_id = split.space_id
             AND category.family_id = split.family_id
             AND category.deleted_at IS NULL
            WHERE split.space_id = ?
              AND split.transaction_id IN ({placeholders})
              AND split.deleted_at IS NULL
            ORDER BY split.created_at, split.id
            """,
            [space_id, *ids],
        )
    ).fetchall()
    splits_by_transaction: dict[str, list[FinanceSplitResponse]] = defaultdict(list)
    for split in split_rows:
        splits_by_transaction[split["transaction_id"]].append(_split_response(dict(split)))
    category_ids = sorted(
        {row["primary_category_id"] for row in rows if row["primary_category_id"]}
    )
    categories: dict[str, dict] = {}
    if category_ids:
        category_placeholders = ",".join("?" for _ in category_ids)
        category_rows = await (
            await db.execute(
                f"""
                SELECT id, name, spending_type FROM finance_categories
                WHERE id IN ({category_placeholders}) AND space_id = ?
                  AND deleted_at IS NULL
                """,
                [*category_ids, space_id],
            )
        ).fetchall()
        categories = {row["id"]: dict(row) for row in category_rows}

    responses: list[FinanceTransactionResponse] = []
    for row in rows:
        category = categories.get(row["primary_category_id"])
        responses.append(FinanceTransactionResponse(
            id=row["id"],
            space_id=row["space_id"],
            account_id=row["account_id"],
            canonical_date=row["canonical_date"],
            amount_minor=row["amount_minor"],
            currency=row["currency"],
            state=row["state"],
            transaction_kind=row["transaction_kind"],
            source_kind=row["source_kind"],
            description=row["description"],
            merchant_text=row["merchant_text"],
            merchant_id=row["merchant_id"],
            primary_category_id=row["primary_category_id"],
            primary_category_name=category["name"] if category else "Uncategorised",
            primary_spending_type=(
                category["spending_type"] if category else "UNCATEGORISED"
            ),
            superseded_by_id=row["superseded_by_id"],
            data_through_at=row["data_through_at"],
            relations=relations_by_transaction[row["id"]],
            splits=splits_by_transaction[row["id"]],
        ))
    return responses


async def finance_ledger_summary(
    db,
    *,
    user: dict,
    space_id: str,
    scope: str | None = None,
    exclude_own_shared_copies: bool = False,
) -> FinanceLedgerSummaryResponse:
    if scope is None:
        await require_finance_space(db, user=user, space_id=space_id)
        space_ids = (space_id,)
        response_scope = "space"
    else:
        space_ids = await resolve_finance_scope_spaces(
            db,
            user=user,
            scope=scope,
            selected_space_id=space_id,
        )
        response_scope = scope
    scope_values = ", ".join("(?, ?)" for _ in space_ids)
    own_copy_clause = ""
    parameters: list[object] = [
        value
        for visible_space_id in space_ids
        for value in (visible_space_id, user["family_id"])
    ]
    if exclude_own_shared_copies or len(space_ids) > 1:
        own_copy_clause = """
              AND NOT EXISTS (
                  SELECT 1 FROM finance_share_copy_links copy
                  JOIN finance_share_actions share
                    ON share.id = copy.share_action_id AND share.deleted_at IS NULL
                  WHERE copy.household_record_type = 'transaction'
                    AND copy.household_record_id = tx.id
                    AND copy.household_space_id = tx.space_id
                    AND copy.family_id = tx.family_id
                    AND copy.deleted_at IS NULL AND share.owner_user_id = ?
              )
        """
        parameters.append(user["id"])
    rows = await (
        await db.execute(
            f"""
            WITH scope(space_id, family_id) AS (VALUES {scope_values}),
            relation_marks AS (
                SELECT relation.from_transaction_id AS transaction_id,
                       1 AS is_neutral, 0 AS is_refund, 0 AS is_reimbursement
                FROM finance_transaction_relations relation, scope
                WHERE relation.space_id = scope.space_id
                  AND relation.family_id = scope.family_id
                  AND relation.status = 'CONFIRMED'
                  AND relation.relation_type IN (
                      'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                  )
                  AND relation.deleted_at IS NULL
                UNION ALL
                SELECT relation.to_transaction_id AS transaction_id,
                       CASE WHEN relation.relation_type IN (
                           'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                       ) THEN 1 ELSE 0 END AS is_neutral,
                       CASE WHEN relation.relation_type = 'REFUND' THEN 1 ELSE 0 END,
                       CASE WHEN relation.relation_type = 'REIMBURSEMENT' THEN 1 ELSE 0 END
                FROM finance_transaction_relations relation, scope
                WHERE relation.space_id = scope.space_id
                  AND relation.family_id = scope.family_id
                  AND relation.status = 'CONFIRMED'
                  AND relation.relation_type IN (
                      'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG',
                      'REFUND', 'REIMBURSEMENT'
                  )
                  AND relation.deleted_at IS NULL
            ),
            relation_treatments AS (
                SELECT transaction_id,
                       MAX(is_neutral) AS is_neutral,
                       MAX(is_refund) AS is_refund,
                       MAX(is_reimbursement) AS is_reimbursement
                FROM relation_marks
                GROUP BY transaction_id
            ),
            shared_treatments AS (
                SELECT copy.household_record_id AS transaction_id,
                       MAX(copy.accounting_treatment = 'NEUTRAL_TRANSFER') AS is_neutral,
                       MAX(copy.accounting_treatment = 'REFUND') AS is_refund,
                       MAX(copy.accounting_treatment = 'REIMBURSEMENT') AS is_reimbursement
                FROM finance_share_copy_links copy, scope
                WHERE copy.household_space_id = scope.space_id
                  AND copy.family_id = scope.family_id
                  AND copy.household_record_type = 'transaction'
                  AND copy.accounting_treatment <> 'CASEY'
                  AND copy.deleted_at IS NULL
                GROUP BY copy.household_record_id
            ),
            classified AS (
                SELECT tx.currency, tx.amount_minor, tx.transaction_kind,
                       tx.data_through_at,
                       (COALESCE(relation_treatments.is_neutral, 0)
                        OR COALESCE(shared_treatments.is_neutral, 0)) AS is_neutral,
                       (COALESCE(relation_treatments.is_refund, 0)
                        OR COALESCE(shared_treatments.is_refund, 0)) AS is_refund,
                       (COALESCE(relation_treatments.is_reimbursement, 0)
                        OR COALESCE(shared_treatments.is_reimbursement, 0))
                           AS is_reimbursement
                FROM finance_transactions tx
                JOIN scope
                  ON scope.space_id = tx.space_id AND scope.family_id = tx.family_id
                LEFT JOIN relation_treatments
                  ON relation_treatments.transaction_id = tx.id
                LEFT JOIN shared_treatments
                  ON shared_treatments.transaction_id = tx.id
                WHERE tx.state = 'POSTED' AND tx.deleted_at IS NULL
                  {own_copy_clause}
            )
            SELECT currency,
                   SUM(amount_minor) AS movement,
                   SUM(CASE WHEN NOT is_neutral AND amount_minor > 0
                                  AND NOT is_refund AND NOT is_reimbursement
                            THEN amount_minor ELSE 0 END) AS income,
                   SUM(CASE WHEN NOT is_neutral AND amount_minor < 0
                            THEN -amount_minor ELSE 0 END) AS spending,
                   SUM(CASE WHEN NOT is_neutral AND amount_minor > 0 AND is_refund
                            THEN amount_minor ELSE 0 END) AS refunds,
                   SUM(CASE WHEN NOT is_neutral AND amount_minor > 0
                                  AND NOT is_refund AND is_reimbursement
                            THEN amount_minor ELSE 0 END) AS reimbursements,
                   SUM(CASE WHEN NOT is_neutral AND amount_minor < 0
                                  AND transaction_kind = 'FEE'
                            THEN -amount_minor ELSE 0 END) AS fees,
                   MAX(data_through_at) AS data_through_at
            FROM classified
            GROUP BY currency
            ORDER BY currency
            """,
            parameters,
        )
    ).fetchall()

    data_through = max(
        (row["data_through_at"] for row in rows if row["data_through_at"] is not None),
        default=None,
    )

    currencies = [
        FinanceCurrencySummary(
            currency=row["currency"],
            account_movement_minor=row["movement"],
            income_minor=row["income"],
            gross_spending_minor=row["spending"],
            refunds_minor=row["refunds"],
            reimbursements_minor=row["reimbursements"],
            fees_minor=row["fees"],
            net_household_cost_minor=(
                row["spending"] - row["refunds"] - row["reimbursements"]
            ),
        )
        for row in rows
    ]
    return FinanceLedgerSummaryResponse(
        space_id=space_id,
        scope=response_scope,
        space_ids=list(space_ids),
        data_through_at=data_through,
        currencies=currencies,
    )

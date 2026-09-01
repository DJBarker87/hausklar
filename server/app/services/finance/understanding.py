"""Editable purchase understanding and exact analysis of authorised saved records."""

import json
import uuid
from datetime import date, datetime, timedelta, timezone
from fractions import Fraction
from urllib.parse import quote

from app.models.finance_understanding import (
    FinanceAnalysisCoverageResponse,
    FinanceAnalysisEvidenceResponse,
    FinanceAnalysisFilters,
    FinanceAnalysisGroupResponse,
    FinanceAnalysisRequest,
    FinanceAnalysisResponse,
    FinanceEvidenceHandleResponse,
    FinanceExactValue,
    FinancePurchaseLineAssessmentResponse,
    FinancePurchaseLineAssessmentConfirm,
    FinancePurchaseLineAssessmentUpdate,
    FinancePurchaseReviewItemResponse,
    FinanceSavedAnalysisViewResponse,
)
from app.services.finance.analytics import (
    AnalysisFilters,
    AnalysisSpec,
    PurchaseLineRecord,
    TransactionRecord,
    analyse_finance,
)
from app.services.finance.foundation import (
    require_finance_access,
    require_finance_space,
    resolve_finance_scope_spaces,
)
from app.services.finance.ledger import clean_description
from app.services.finance.money import Money
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

_ASSESSMENT_FIELDS = (
    "beneficiary",
    "purpose",
    "plannedness",
    "utility",
    "decision_quality",
    "value_for_money",
    "outcome_state",
)
_NEUTRAL_RELATIONS = {"INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT", "FX_LEG"}
_RETAIL_MERCHANT_KINDS = {"BROAD_RETAILER", "MARKETPLACE", "BROAD_OR_UNKNOWN"}
_RETAIL_CATEGORY_TERMS = (
    "retail",
    "shopping",
    "grocer",
    "clothing",
    "household goods",
    "electronics",
    "marketplace",
)


class FinanceUnderstandingError(ValueError):
    """A typed understanding request is invalid for the saved records."""


class FinanceUnderstandingNotFoundError(FinanceUnderstandingError):
    """An authorised record was not found."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _identity_key(value: str) -> str:
    key = clean_description(value).casefold()
    if not key:
        raise FinanceUnderstandingError("A normalized item needs a meaningful name")
    return key


def _deep_link(kind: str, record_id: str) -> str:
    safe_id = quote(record_id, safe="")
    if kind == "transaction":
        return f"/?view=finance&section=explore&transaction={safe_id}"
    return f"/?view=finance&section=activity&line={safe_id}"


def _exact(value: Fraction) -> FinanceExactValue:
    return FinanceExactValue(numerator=value.numerator, denominator=value.denominator)


def _query_bounds(body: FinanceAnalysisRequest) -> tuple[date, date]:
    """Include comparison rows in the load; the pure engine separates periods."""
    if body.comparison == "NONE":
        return body.start_date, body.end_date
    if body.comparison == "PREVIOUS_PERIOD":
        days = (body.end_date - body.start_date).days + 1
        comparison_end = body.start_date - timedelta(days=1)
        return comparison_end - timedelta(days=days - 1), body.end_date

    def prior_year(day: date) -> date:
        try:
            return day.replace(year=day.year - 1)
        except ValueError:
            return day.replace(year=day.year - 1, day=28)

    return min(prior_year(body.start_date), body.start_date), body.end_date


def _scope_query_parts(space_ids: tuple[str, ...]) -> tuple[str, dict[str, str]]:
    if not space_ids:
        raise FinanceUnderstandingError("Finance analysis scope is empty")
    parameters = {f"space_{index}": value for index, value in enumerate(space_ids)}
    return ",".join(f":space_{index}" for index in range(len(space_ids))), parameters


def _exclude_own_household_copy(
    *, alias: str, record_type: str, multiple_spaces: bool
) -> str:
    if not multiple_spaces:
        return ""
    return f"""
        AND NOT EXISTS (
            SELECT 1 FROM finance_share_copy_links copy
            JOIN finance_share_actions share
              ON share.id = copy.share_action_id AND share.deleted_at IS NULL
            WHERE copy.household_record_type = '{record_type}'
              AND copy.household_record_id = {alias}.id
              AND copy.household_space_id = {alias}.space_id
              AND copy.family_id = {alias}.family_id
              AND copy.deleted_at IS NULL
              AND share.owner_user_id = :owner_user_id
        )
    """


async def _confirmed_relations_for_ids(
    db,
    *,
    user: dict,
    space_ids: tuple[str, ...],
    identifiers: set[str],
):
    """Read exact linked relations in one query regardless of analysis row count."""
    if not identifiers:
        return []
    space_placeholders = ",".join("?" for _ in space_ids)
    return await (
        await db.execute(
            f"""
            WITH requested(id) AS (
                SELECT value FROM json_each(?)
            )
            SELECT DISTINCT relation.id, relation.from_transaction_id,
                            relation.to_transaction_id, relation.relation_type
            FROM finance_transaction_relations relation
            JOIN requested
              ON requested.id = relation.from_transaction_id
              OR requested.id = relation.to_transaction_id
            WHERE relation.space_id IN ({space_placeholders})
              AND relation.family_id = ? AND relation.status = 'CONFIRMED'
              AND relation.deleted_at IS NULL
            """,
            (json.dumps(sorted(identifiers)), *space_ids, user["family_id"]),
        )
    ).fetchall()


async def _authorised_line(db, *, user: dict, line_id: str) -> dict:
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT line.*, purchase.purchased_on, purchase.merchant_name,
                   purchase.currency, purchase.superseded_by_id,
                   source.source_kind
            FROM finance_purchase_lines line
            JOIN finance_purchase_records purchase
              ON purchase.id = line.purchase_id AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id AND purchase.deleted_at IS NULL
            JOIN finance_purchase_sources source
              ON source.id = purchase.source_id AND source.space_id = purchase.space_id
             AND source.family_id = purchase.family_id AND source.deleted_at IS NULL
            JOIN finance_spaces space
              ON space.id = line.space_id AND space.family_id = line.family_id
             AND space.deleted_at IS NULL
            WHERE line.id = ? AND line.family_id = ? AND line.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            """,
            (line_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceUnderstandingNotFoundError("Finance purchase line not found")
    return dict(row)


async def _normalized_item(
    db, *, user: dict, space_id: str, display_name: str, item_kind: str
) -> tuple[str, str]:
    identity_key = _identity_key(display_name)
    row = await (
        await db.execute(
            """
            SELECT id, display_name FROM finance_normalized_purchase_items
            WHERE space_id = ? AND identity_key = ? AND family_id = ?
              AND deleted_at IS NULL
            """,
            (space_id, identity_key, user["family_id"]),
        )
    ).fetchone()
    if row is not None:
        return row["id"], row["display_name"]
    identifier = str(uuid.uuid4())
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_normalized_purchase_items
            (id, space_id, identity_key, display_name, item_kind, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            identifier,
            space_id,
            identity_key,
            display_name.strip(),
            item_kind if item_kind in {"product", "service"} else "unknown",
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    return identifier, display_name.strip()


async def _assessment_response(
    db, *, line: dict, assessment_id: str, feedback_recorded: int = 0
) -> FinancePurchaseLineAssessmentResponse:
    row = await (
        await db.execute(
            """
            SELECT assessment.*, item.display_name AS normalized_item_name
            FROM finance_purchase_line_assessments assessment
            LEFT JOIN finance_normalized_purchase_items item
              ON item.id = assessment.normalized_item_id AND item.deleted_at IS NULL
            WHERE assessment.id = ? AND assessment.deleted_at IS NULL
            """,
            (assessment_id,),
        )
    ).fetchone()
    if row is None:
        raise FinanceUnderstandingNotFoundError("Finance line assessment not found")
    return FinancePurchaseLineAssessmentResponse(
        id=row["id"],
        line_id=line["id"],
        purchase_id=line["purchase_id"],
        space_id=line["space_id"],
        source_description=line["raw_description"],
        normalized_item_id=row["normalized_item_id"],
        normalized_item_name=row["normalized_item_name"],
        beneficiary=row["beneficiary"],
        purpose=row["purpose"],
        plannedness=row["plannedness"],
        utility=row["utility"],
        decision_quality=row["decision_quality"],
        value_for_money=row["value_for_money"],
        outcome_state=row["outcome_state"],
        classification_source=row["classification_source"],
        confidence_bps=row["confidence_bps"],
        review_status=row["review_status"],
        feedback_recorded=feedback_recorded,
        updated_at=row["updated_at"],
    )


async def update_purchase_line_assessment(
    db,
    *,
    user: dict,
    line_id: str,
    body: FinancePurchaseLineAssessmentUpdate,
) -> FinancePurchaseLineAssessmentResponse:
    """Save user judgment separately and append examples for future matching lines."""
    line = await _authorised_line(db, user=user, line_id=line_id)
    if line["superseded_by_id"] is not None:
        raise FinanceUnderstandingError("A superseded purchase cannot be reassessed")
    async with serialized_create(db):
        current_row = await (
            await db.execute(
                """
                SELECT assessment.*, item.display_name AS normalized_item_name
                FROM finance_purchase_line_assessments assessment
                LEFT JOIN finance_normalized_purchase_items item
                  ON item.id = assessment.normalized_item_id AND item.deleted_at IS NULL
                WHERE assessment.line_id = ? AND assessment.space_id = ?
                  AND assessment.deleted_at IS NULL
                """,
                (line_id, line["space_id"]),
            )
        ).fetchone()
        current = dict(current_row) if current_row else {}
        values = body.model_dump(exclude_unset=True)
        values.pop("correction_reason", None)
        normalized_item_id = current.get("normalized_item_id")
        normalized_item_name = current.get("normalized_item_name")
        if "normalized_item_name" in values:
            normalized_item_name = values.pop("normalized_item_name")
            normalized_item_id = None
            if normalized_item_name is not None:
                normalized_item_id, normalized_item_name = await _normalized_item(
                    db,
                    user=user,
                    space_id=line["space_id"],
                    display_name=normalized_item_name,
                    item_kind=line["line_kind"],
                )
        proposed = {
            field: values.get(field, current.get(field)) for field in _ASSESSMENT_FIELDS
        }
        material_before = (
            current.get("normalized_item_id"),
            *(current.get(field) for field in _ASSESSMENT_FIELDS),
        )
        material_after = (
            normalized_item_id,
            *(proposed[field] for field in _ASSESSMENT_FIELDS),
        )
        if all(value is None for value in material_after):
            raise FinanceUnderstandingError(
                "At least one non-blank assessment field is required"
            )
        if material_after == material_before:
            raise FinanceUnderstandingError("The assessment does not contain a change")
        complete_count = sum(value is not None for value in material_after)
        assessment_complete = complete_count == len(material_after)
        confidence_bps = (
            10_000
            if assessment_complete
            else max(1_000, complete_count * 10_000 // len(material_after))
        )
        review_status = "CONFIRMED" if assessment_complete else "NEEDS_REVIEW"
        now = _now()
        assessment_id = current.get("id") or str(uuid.uuid4())
        if current:
            await save_history(
                db,
                "finance_purchase_line_assessments",
                assessment_id,
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_purchase_line_assessments
                SET normalized_item_id = ?, beneficiary = ?, purpose = ?,
                    plannedness = ?, utility = ?, decision_quality = ?,
                    value_for_money = ?, outcome_state = ?,
                    classification_source = 'USER', confidence_bps = ?,
                    review_status = ?, updated_at = ?
                WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (
                    normalized_item_id,
                    *(proposed[field] for field in _ASSESSMENT_FIELDS),
                    confidence_bps,
                    review_status,
                    now,
                    assessment_id,
                    line["space_id"],
                    user["family_id"],
                ),
            )
        else:
            await db.execute(
                """
                INSERT INTO finance_purchase_line_assessments
                    (id, space_id, line_id, normalized_item_id, beneficiary, purpose,
                     plannedness, utility, decision_quality, value_for_money,
                     outcome_state, classification_source, confidence_bps, review_status,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'USER', ?,
                        ?, ?, ?, ?, ?)
                """,
                (
                    assessment_id,
                    line["space_id"],
                    line_id,
                    normalized_item_id,
                    *(proposed[field] for field in _ASSESSMENT_FIELDS),
                    confidence_bps,
                    review_status,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )

        identity_key = _identity_key(line["raw_description"])
        feedback: list[tuple[str, str | None, str | None]] = []
        if "normalized_item_name" in body.model_fields_set:
            feedback.append(
                ("normalized_item", current.get("normalized_item_name"), normalized_item_name)
            )
        for field in _ASSESSMENT_FIELDS:
            if field in body.model_fields_set:
                feedback.append((field, current.get(field), proposed[field]))
        for field, previous, corrected in feedback:
            await db.execute(
                """
                INSERT INTO finance_purchase_classification_feedback
                    (id, space_id, line_id, identity_key, field_name, previous_value,
                     corrected_value, correction_reason, family_id, created_at,
                     updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    line["space_id"],
                    line_id,
                    identity_key,
                    field,
                    previous,
                    corrected,
                    body.correction_reason,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
    return await _assessment_response(
        db, line=line, assessment_id=assessment_id, feedback_recorded=len(feedback)
    )


async def confirm_purchase_line_assessment(
    db,
    *,
    user: dict,
    line_id: str,
    body: FinancePurchaseLineAssessmentConfirm,
) -> FinancePurchaseLineAssessmentResponse:
    """Record an explicit human check without inventing missing classifications."""
    line = await _authorised_line(db, user=user, line_id=line_id)
    if line["superseded_by_id"] is not None:
        raise FinanceUnderstandingError("A superseded purchase cannot be reviewed")
    async with serialized_create(db):
        current_row = await (
            await db.execute(
                """
                SELECT id FROM finance_purchase_line_assessments
                WHERE line_id = ? AND space_id = ? AND family_id = ?
                  AND deleted_at IS NULL
                """,
                (line_id, line["space_id"], user["family_id"]),
            )
        ).fetchone()
        now = _now()
        assessment_id = current_row["id"] if current_row else str(uuid.uuid4())
        if current_row:
            await save_history(
                db,
                "finance_purchase_line_assessments",
                assessment_id,
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_purchase_line_assessments
                SET classification_source = 'USER', confidence_bps = 10000,
                    review_status = 'CONFIRMED', updated_at = ?
                WHERE id = ? AND space_id = ? AND family_id = ?
                  AND deleted_at IS NULL
                """,
                (now, assessment_id, line["space_id"], user["family_id"]),
            )
        else:
            await db.execute(
                """
                INSERT INTO finance_purchase_line_assessments
                    (id, space_id, line_id, classification_source, confidence_bps,
                     review_status, family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, 'USER', 10000, 'CONFIRMED', ?, ?, ?, ?)
                """,
                (
                    assessment_id,
                    line["space_id"],
                    line_id,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
        await db.execute(
            """
            INSERT INTO finance_purchase_classification_feedback
                (id, space_id, line_id, identity_key, field_name, previous_value,
                 corrected_value, correction_reason, family_id, created_at,
                 updated_at, created_by)
            VALUES (?, ?, ?, ?, 'review_disposition', NULL, ?, NULL, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                line["space_id"],
                line_id,
                _identity_key(line["raw_description"]),
                body.disposition,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    return await _assessment_response(
        db, line=line, assessment_id=assessment_id, feedback_recorded=1
    )


async def read_purchase_line_assessment(
    db, *, user: dict, line_id: str
) -> FinancePurchaseLineAssessmentResponse:
    line = await _authorised_line(db, user=user, line_id=line_id)
    row = await (
        await db.execute(
            """
            SELECT id FROM finance_purchase_line_assessments
            WHERE line_id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (line_id, line["space_id"], user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceUnderstandingNotFoundError("Finance line assessment not found")
    return await _assessment_response(db, line=line, assessment_id=row["id"])


async def apply_learned_purchase_line_assessment(
    db, *, user: dict, line_id: str, space_id: str, raw_description: str, line_kind: str
) -> None:
    """Apply the latest same-space user corrections to a newly ingested matching line."""
    identity_key = _identity_key(raw_description)
    rows = await (
        await db.execute(
            """
            SELECT feedback.field_name, feedback.corrected_value
            FROM finance_purchase_classification_feedback feedback
            WHERE feedback.space_id = ? AND feedback.family_id = ?
              AND feedback.identity_key = ? AND feedback.deleted_at IS NULL
              AND feedback.id = (
                  SELECT latest.id FROM finance_purchase_classification_feedback latest
                  WHERE latest.space_id = feedback.space_id
                    AND latest.family_id = feedback.family_id
                    AND latest.identity_key = feedback.identity_key
                    AND latest.field_name = feedback.field_name
                    AND latest.deleted_at IS NULL
                  ORDER BY latest.created_at DESC, latest.id DESC LIMIT 1
              )
            """,
            (space_id, user["family_id"], identity_key),
        )
    ).fetchall()
    learned = {row["field_name"]: row["corrected_value"] for row in rows}
    if not learned:
        return
    normalized_item_id = None
    if learned.get("normalized_item"):
        normalized_item_id, _ = await _normalized_item(
            db,
            user=user,
            space_id=space_id,
            display_name=learned["normalized_item"],
            item_kind=line_kind,
        )
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_purchase_line_assessments
            (id, space_id, line_id, normalized_item_id, beneficiary, purpose,
             plannedness, utility, decision_quality, value_for_money, outcome_state,
             classification_source, confidence_bps, review_status, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'LEARNED', 8000,
                'NEEDS_REVIEW', ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            space_id,
            line_id,
            normalized_item_id,
            *(learned.get(field) for field in _ASSESSMENT_FIELDS),
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )


async def list_high_impact_purchase_review(
    db, *, user: dict, space_id: str, minimum_impact_minor: int, limit: int
) -> list[FinancePurchaseReviewItemResponse]:
    """Return only materially large lines whose separate assessment is uncertain."""
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            WITH eligible_purchases AS MATERIALIZED (
                SELECT * FROM finance_purchase_records
                WHERE space_id = :space_id AND family_id = :family_id
                  AND superseded_by_id IS NULL AND deleted_at IS NULL
            ),
            eligible_lines AS MATERIALIZED (
                SELECT line.*
                FROM finance_purchase_lines line
                JOIN eligible_purchases purchase
                  ON purchase.id = line.purchase_id
                 AND purchase.space_id = line.space_id
                 AND purchase.family_id = line.family_id
                WHERE line.space_id = :space_id AND line.family_id = :family_id
                  AND line.deleted_at IS NULL
            ),
            refund AS MATERIALIZED (
                SELECT refund.line_id, SUM(refund.amount_minor) AS refunded_minor
                FROM finance_line_refunds refund
                JOIN eligible_lines line
                  ON line.id = refund.line_id AND line.space_id = refund.space_id
                 AND line.family_id = refund.family_id
                WHERE refund.deleted_at IS NULL
                GROUP BY refund.line_id
            ),
            payment AS MATERIALIZED (
                SELECT payment.purchase_id, payment.space_id,
                       SUM(CASE WHEN payment.allocated_minor > 0
                                THEN payment.allocated_minor ELSE 0 END) AS funded_minor,
                       SUM(CASE WHEN payment.allocated_minor < 0
                                THEN -payment.allocated_minor ELSE 0 END) AS refunded_minor
                FROM finance_purchase_payments payment
                JOIN eligible_purchases purchase
                  ON purchase.id = payment.purchase_id
                 AND purchase.space_id = payment.space_id
                 AND purchase.family_id = payment.family_id
                WHERE payment.status = 'CONFIRMED' AND payment.deleted_at IS NULL
                GROUP BY payment.purchase_id, payment.space_id
            )
            SELECT line.id, line.purchase_id, line.space_id, line.raw_description,
                   COALESCE(line.line_net_minor, 0) - COALESCE(refund.refunded_minor, 0)
                       AS amount_minor,
                   purchase.purchased_on, purchase.merchant_name, purchase.currency,
                   purchase.source_id,
                   CASE
                     WHEN MAX(0, purchase.final_total_minor - COALESCE(payment.funded_minor, 0)) = 0
                      AND MAX(0, purchase.refunded_minor - COALESCE(payment.refunded_minor, 0)) = 0
                       THEN 'MATCHED'
                     WHEN COALESCE(payment.funded_minor, 0) > 0
                       OR COALESCE(payment.refunded_minor, 0) > 0
                       THEN 'PARTIAL'
                     ELSE 'UNMATCHED'
                   END AS match_status,
                   (SELECT file.id FROM finance_purchase_source_files file
                    WHERE file.source_id = purchase.source_id
                      AND file.space_id = purchase.space_id
                      AND file.family_id = purchase.family_id
                      AND file.storage_status = 'STORED'
                      AND file.deleted_at IS NULL
                    ORDER BY CASE file.file_role WHEN 'ATTACHMENT' THEN 0 ELSE 1 END,
                             file.created_at, file.id LIMIT 1) AS receipt_file_id,
                   assessment.confidence_bps, assessment.review_status,
                   assessment.normalized_item_id, assessment.beneficiary,
                   assessment.purpose, assessment.plannedness, assessment.utility,
                   assessment.decision_quality, assessment.value_for_money,
                   assessment.outcome_state
            FROM eligible_lines line
            JOIN eligible_purchases purchase
              ON purchase.id = line.purchase_id AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id
            LEFT JOIN finance_purchase_line_assessments assessment
              ON assessment.line_id = line.id AND assessment.space_id = line.space_id
             AND assessment.family_id = line.family_id AND assessment.deleted_at IS NULL
            LEFT JOIN refund ON refund.line_id = line.id
            LEFT JOIN payment ON payment.purchase_id = purchase.id
                     AND payment.space_id = purchase.space_id
            WHERE ABS(COALESCE(line.line_net_minor, 0)
                      - COALESCE(refund.refunded_minor, 0)) >= :minimum_impact_minor
              AND (assessment.id IS NULL OR assessment.review_status <> 'CONFIRMED')
            ORDER BY ABS(amount_minor) DESC, purchase.purchased_on DESC, line.id
            LIMIT :limit
            """,
            {
                "space_id": space_id,
                "family_id": user["family_id"],
                "minimum_impact_minor": minimum_impact_minor,
                "limit": limit,
            },
        )
    ).fetchall()
    result = []
    for row in rows:
        uncertain = []
        for field in ("normalized_item_id", *_ASSESSMENT_FIELDS):
            if row[field] is None:
                uncertain.append("normalized_item" if field == "normalized_item_id" else field)
        if row["confidence_bps"] is not None and row["confidence_bps"] < 8500:
            uncertain.append("confidence")
        result.append(
            FinancePurchaseReviewItemResponse(
                line_id=row["id"],
                purchase_id=row["purchase_id"],
                space_id=row["space_id"],
                purchased_on=row["purchased_on"],
                merchant=row["merchant_name"],
                source_description=row["raw_description"],
                amount_minor=row["amount_minor"],
                currency=row["currency"],
                confidence_bps=row["confidence_bps"] or 0,
                uncertain_fields=uncertain,
                evidence_handle=f"purchase-line:{row['id']}",
                deep_link=_deep_link("purchase-line", row["id"]),
                source_id=row["source_id"],
                match_status=row["match_status"],
                receipt_file_id=row["receipt_file_id"],
            )
        )
    return result


def _analysis_filters(filters: FinanceAnalysisFilters) -> AnalysisFilters:
    return AnalysisFilters(
        account_ids=tuple(filters.account_ids),
        merchants=tuple(filters.merchants),
        categories=tuple(filters.categories),
        transaction_types=tuple(filters.transaction_types),
        line_kinds=tuple(filters.line_kinds),
        normalized_items=tuple(filters.normalized_items),
        purposes=tuple(filters.purposes),
        recipients=tuple(filters.beneficiaries),
        plannedness=tuple(filters.plannedness),
        utilities=tuple(filters.utilities),
        decision_qualities=tuple(filters.decision_qualities),
        value_for_money=tuple(filters.value_for_money),
        outcomes=tuple(filters.outcomes),
        itemisation=tuple(filters.itemisation),
    )


async def _transaction_records(
    db,
    *,
    user: dict,
    body: FinanceAnalysisRequest,
    space_ids: tuple[str, ...],
):
    states = ("POSTED", "PENDING") if body.pending_policy == "INCLUDE" else ("POSTED",)
    state_placeholders = ",".join(f":state_{index}" for index in range(len(states)))
    space_placeholders, parameters = _scope_query_parts(space_ids)
    parameters.update(
        {
            "family_id": user["family_id"],
            "currency": body.currency,
            "owner_user_id": user["id"],
            **{f"state_{index}": state for index, state in enumerate(states)},
        }
    )
    query_start, query_end = _query_bounds(body)
    parameters["query_start"] = query_start.isoformat()
    parameters["query_end"] = query_end.isoformat()
    copy_clause = _exclude_own_household_copy(
        alias="tx", record_type="transaction", multiple_spaces=len(space_ids) > 1
    )
    rows = await (
        await db.execute(
            f"""
            SELECT tx.*, category.name AS category_name
            FROM finance_transactions tx
            LEFT JOIN finance_categories category
              ON category.id = tx.primary_category_id AND category.deleted_at IS NULL
            WHERE tx.space_id IN ({space_placeholders}) AND tx.family_id = :family_id
              AND tx.state IN ({state_placeholders}) AND tx.deleted_at IS NULL
              AND tx.canonical_date BETWEEN :query_start AND :query_end
              AND tx.currency = :currency
              {copy_clause}
            ORDER BY tx.canonical_date, tx.id
            """,
            parameters,
        )
    ).fetchall()
    ids = {row["id"] for row in rows}
    relation_types: dict[str, set[str]] = {identifier: set() for identifier in ids}
    if ids:
        relations = await _confirmed_relations_for_ids(
            db,
            user=user,
            space_ids=space_ids,
            identifiers=ids,
        )
        for relation in relations:
            for identifier in (relation["from_transaction_id"], relation["to_transaction_id"]):
                if identifier in relation_types:
                    relation_types[identifier].add(relation["relation_type"])
    records = []
    for row in rows:
        relations = relation_types[row["id"]]
        if body.transfer_policy == "EXCLUDE" and relations & _NEUTRAL_RELATIONS:
            continue
        is_refund = (
            row["amount_minor"] > 0
            and ("REFUND" in relations or "REIMBURSEMENT" in relations)
        )
        if is_refund and body.refund_policy == "EXCLUDE":
            continue
        typed_relations = (
            relations
            if is_refund
            else relations - {"REFUND", "REIMBURSEMENT"}
        )
        transaction_type = (
            sorted(typed_relations)[0].casefold()
            if typed_relations
            else row["transaction_kind"].casefold()
        )
        records.append(
            TransactionRecord(
                id=row["id"],
                space_id=row["space_id"],
                day=date.fromisoformat(row["canonical_date"]),
                amount=Money(row["amount_minor"], row["currency"]),
                account_id=row["account_id"],
                merchant=row["merchant_text"],
                category=row["category_name"],
                transaction_type=transaction_type,
                evidence_ids=(f"transaction:{row['id']}",),
                is_refund=is_refund,
            )
        )
    data_through = max(
        (
            record.day
            for record in records
            if body.start_date <= record.day <= body.end_date
        ),
        default=None,
    )
    return records, data_through


async def _visible_cash_spend_minor(
    db,
    *,
    user: dict,
    body: FinanceAnalysisRequest,
    space_ids: tuple[str, ...],
) -> int:
    """Conservative coverage denominator including unitemised canonical spend."""
    space_placeholders, parameters = _scope_query_parts(space_ids)
    parameters.update(
        {
            "family_id": user["family_id"],
            "currency": body.currency,
            "start_date": body.start_date.isoformat(),
            "end_date": body.end_date.isoformat(),
            "owner_user_id": user["id"],
        }
    )
    copy_clause = _exclude_own_household_copy(
        alias="tx", record_type="transaction", multiple_spaces=len(space_ids) > 1
    )
    rows = await (
        await db.execute(
            f"""
            SELECT tx.id, tx.amount_minor, merchant.merchant_kind,
                   category.name AS category_name,
                   EXISTS (
                       SELECT 1 FROM finance_purchase_payments payment
                       WHERE payment.transaction_id = tx.id
                         AND payment.status = 'CONFIRMED' AND payment.deleted_at IS NULL
                   ) AS has_purchase_match
            FROM finance_transactions tx
            LEFT JOIN finance_merchants merchant
              ON merchant.id = tx.merchant_id AND merchant.space_id = tx.space_id
             AND merchant.family_id = tx.family_id AND merchant.deleted_at IS NULL
            LEFT JOIN finance_categories category
              ON category.id = tx.primary_category_id AND category.space_id = tx.space_id
             AND category.family_id = tx.family_id AND category.deleted_at IS NULL
            WHERE tx.space_id IN ({space_placeholders})
              AND tx.family_id = :family_id AND tx.state = 'POSTED'
              AND tx.deleted_at IS NULL AND tx.currency = :currency
              AND tx.canonical_date BETWEEN :start_date AND :end_date
              {copy_clause}
            ORDER BY tx.canonical_date, tx.id
            """,
            parameters,
        )
    ).fetchall()
    by_id = {row["id"]: row for row in rows}
    retail_ids = {
        row["id"]
        for row in rows
        if bool(row["has_purchase_match"])
        or row["merchant_kind"] in _RETAIL_MERCHANT_KINDS
        or any(
            term in (row["category_name"] or "").casefold()
            for term in _RETAIL_CATEGORY_TERMS
        )
    }
    relation_types: dict[str, set[str]] = {identifier: set() for identifier in by_id}
    linked_retail_refunds: set[str] = set()
    if by_id:
        relations = await _confirmed_relations_for_ids(
            db,
            user=user,
            space_ids=space_ids,
            identifiers=set(by_id),
        )
        for relation in relations:
            linked = (relation["from_transaction_id"], relation["to_transaction_id"])
            for identifier in linked:
                if identifier in relation_types:
                    relation_types[identifier].add(relation["relation_type"])
            if relation["relation_type"] in {"REFUND", "REIMBURSEMENT"}:
                if any(identifier in retail_ids for identifier in linked):
                    linked_retail_refunds.update(
                        identifier
                        for identifier in linked
                        if identifier in by_id and by_id[identifier]["amount_minor"] > 0
                    )
    gross = sum(
        -row["amount_minor"]
        for row in rows
        if row["id"] in retail_ids
        and row["amount_minor"] < 0
        and not (relation_types[row["id"]] & _NEUTRAL_RELATIONS)
    )
    refunds = sum(
        by_id[identifier]["amount_minor"] for identifier in linked_retail_refunds
    )
    return max(0, gross - refunds)


async def _purchase_line_records(
    db,
    *,
    user: dict,
    body: FinanceAnalysisRequest,
    space_ids: tuple[str, ...],
):
    reconciled = body.basis == "RECONCILED_PURCHASE_LINES"
    query_start, query_end = _query_bounds(body)
    space_placeholders, parameters = _scope_query_parts(space_ids)
    parameters.update(
        {
            "family_id": user["family_id"],
            "query_start": query_start.isoformat(),
            "query_end": query_end.isoformat(),
            "currency": body.currency,
            "owner_user_id": user["id"],
        }
    )
    copy_clause = _exclude_own_household_copy(
        alias="line", record_type="purchase_line", multiple_spaces=len(space_ids) > 1
    )
    rows = await (
        await db.execute(
            f"""
            WITH eligible_purchases AS MATERIALIZED (
                SELECT * FROM finance_purchase_records
                WHERE space_id IN ({space_placeholders}) AND family_id = :family_id
                  AND purchased_on BETWEEN :query_start AND :query_end
                  AND currency = :currency AND superseded_by_id IS NULL
                  AND deleted_at IS NULL
            ),
            eligible_lines AS MATERIALIZED (
                SELECT line.*
                FROM finance_purchase_lines line
                JOIN eligible_purchases purchase
                  ON purchase.id = line.purchase_id
                 AND purchase.space_id = line.space_id
                 AND purchase.family_id = line.family_id
                WHERE line.space_id IN ({space_placeholders})
                  AND line.family_id = :family_id
                  AND line.deleted_at IS NULL
                  {copy_clause}
            ),
            ranked_assignments AS MATERIALIZED (
                SELECT assignment.*,
                       ROW_NUMBER() OVER (
                           PARTITION BY assignment.target_type,
                                        assignment.target_id,
                                        assignment.assignment_type
                           ORDER BY CASE assignment.source WHEN 'USER' THEN 0 ELSE 1 END,
                                    assignment.created_at DESC,
                                    assignment.id DESC
                       ) AS assignment_rank
                FROM finance_assignments assignment
                WHERE assignment.space_id IN ({space_placeholders})
                  AND assignment.family_id = :family_id
                  AND assignment.status = 'CONFIRMED'
                  AND assignment.deleted_at IS NULL
                  AND (
                      (
                          assignment.target_type = 'PURCHASE'
                          AND EXISTS (
                              SELECT 1 FROM eligible_purchases purchase
                              WHERE purchase.id = assignment.target_id
                          )
                      )
                      OR (
                          assignment.target_type = 'PURCHASE_LINE'
                          AND EXISTS (
                              SELECT 1 FROM eligible_lines line
                              WHERE line.id = assignment.target_id
                          )
                      )
                  )
            ),
            refund AS MATERIALIZED (
                SELECT refund.line_id, refund.space_id, refund.family_id,
                       SUM(refund.amount_minor) AS refunded_minor
                FROM finance_line_refunds refund
                JOIN eligible_purchases purchase
                  ON purchase.id = refund.purchase_id
                 AND purchase.space_id = refund.space_id
                 AND purchase.family_id = refund.family_id
                WHERE refund.deleted_at IS NULL
                GROUP BY refund.line_id, refund.space_id, refund.family_id
            ),
            purchase_refund AS MATERIALIZED (
                SELECT refund.purchase_id, refund.space_id, refund.family_id,
                       SUM(refund.amount_minor) AS refunded_minor
                FROM finance_line_refunds refund
                JOIN eligible_purchases purchase
                  ON purchase.id = refund.purchase_id
                 AND purchase.space_id = refund.space_id
                 AND purchase.family_id = refund.family_id
                WHERE refund.deleted_at IS NULL
                GROUP BY refund.purchase_id, refund.space_id, refund.family_id
            ),
            payment AS MATERIALIZED (
                SELECT payment.purchase_id, payment.space_id, payment.family_id,
                       SUM(CASE WHEN payment.status = 'CONFIRMED'
                                     AND payment.allocated_minor > 0
                                THEN payment.allocated_minor ELSE 0 END) AS funded_minor,
                       SUM(CASE WHEN payment.status = 'CONFIRMED'
                                     AND payment.allocated_minor < 0
                                THEN -payment.allocated_minor ELSE 0 END)
                           AS allocated_refund_minor,
                       SUM(CASE WHEN payment.status = 'PROPOSED' THEN 1 ELSE 0 END)
                           AS unresolved_count,
                       SUM(CASE WHEN payment.status = 'CONFIRMED' THEN 1 ELSE 0 END)
                           AS confirmed_count
                FROM finance_purchase_payments payment
                JOIN eligible_purchases purchase
                  ON purchase.id = payment.purchase_id
                 AND purchase.space_id = payment.space_id
                 AND purchase.family_id = payment.family_id
                WHERE payment.deleted_at IS NULL
                GROUP BY payment.purchase_id, payment.space_id, payment.family_id
            )
            SELECT line.*, purchase.purchased_on,
                   COALESCE(assigned_merchant.name, purchase.merchant_name) AS merchant_name,
                   assigned_category.name AS category_name,
                   purchase.currency, purchase.final_total_minor,
                   purchase.refunded_minor AS purchase_refunded_minor,
                   item.display_name AS normalized_item_name,
                   assessment.beneficiary, assessment.purpose,
                   assessment.plannedness, assessment.utility,
                   assessment.decision_quality, assessment.value_for_money,
                   assessment.outcome_state,
                   COALESCE(refund.refunded_minor, 0) AS refunded_minor,
                   COALESCE(purchase_refund.refunded_minor, 0) AS line_refunded_minor,
                   COALESCE(payment.funded_minor, 0) AS funded_minor,
                   COALESCE(payment.allocated_refund_minor, 0) AS allocated_refund_minor,
                   COALESCE(payment.unresolved_count, 0) AS unresolved_count,
                   COALESCE(payment.confirmed_count, 0) AS confirmed_count
            FROM eligible_lines line
            JOIN eligible_purchases purchase
              ON purchase.id = line.purchase_id AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id
            LEFT JOIN ranked_assignments line_merchant_assignment
              ON line_merchant_assignment.target_type = 'PURCHASE_LINE'
             AND line_merchant_assignment.target_id = line.id
             AND line_merchant_assignment.assignment_type = 'MERCHANT'
             AND line_merchant_assignment.assignment_rank = 1
            LEFT JOIN ranked_assignments purchase_merchant_assignment
              ON purchase_merchant_assignment.target_type = 'PURCHASE'
             AND purchase_merchant_assignment.target_id = purchase.id
             AND purchase_merchant_assignment.assignment_type = 'MERCHANT'
             AND purchase_merchant_assignment.assignment_rank = 1
            LEFT JOIN finance_merchants assigned_merchant
              ON assigned_merchant.id = COALESCE(
                  line_merchant_assignment.assigned_value_id,
                  purchase_merchant_assignment.assigned_value_id
              )
             AND assigned_merchant.space_id = line.space_id
             AND assigned_merchant.family_id = line.family_id
             AND assigned_merchant.deleted_at IS NULL
            LEFT JOIN ranked_assignments line_category_assignment
              ON line_category_assignment.target_type = 'PURCHASE_LINE'
             AND line_category_assignment.target_id = line.id
             AND line_category_assignment.assignment_type = 'CATEGORY'
             AND line_category_assignment.assignment_rank = 1
            LEFT JOIN ranked_assignments purchase_category_assignment
              ON purchase_category_assignment.target_type = 'PURCHASE'
             AND purchase_category_assignment.target_id = purchase.id
             AND purchase_category_assignment.assignment_type = 'CATEGORY'
             AND purchase_category_assignment.assignment_rank = 1
            LEFT JOIN finance_categories assigned_category
              ON assigned_category.id = COALESCE(
                  line_category_assignment.assigned_value_id,
                  purchase_category_assignment.assigned_value_id
              )
             AND assigned_category.space_id = line.space_id
             AND assigned_category.family_id = line.family_id
             AND assigned_category.deleted_at IS NULL
            LEFT JOIN finance_purchase_line_assessments assessment
              ON assessment.line_id = line.id AND assessment.space_id = line.space_id
             AND assessment.family_id = line.family_id AND assessment.deleted_at IS NULL
            LEFT JOIN finance_normalized_purchase_items item
              ON item.id = assessment.normalized_item_id AND item.space_id = line.space_id
             AND item.family_id = line.family_id AND item.deleted_at IS NULL
            LEFT JOIN refund ON refund.line_id = line.id AND refund.space_id = line.space_id
                    AND refund.family_id = line.family_id
            LEFT JOIN purchase_refund ON purchase_refund.purchase_id = purchase.id
                    AND purchase_refund.space_id = purchase.space_id
                    AND purchase_refund.family_id = purchase.family_id
            LEFT JOIN payment ON payment.purchase_id = purchase.id
                     AND payment.space_id = purchase.space_id
                     AND payment.family_id = purchase.family_id
            ORDER BY purchase.purchased_on, purchase.id, line.line_position, line.id
            """,
            parameters,
        )
    ).fetchall()
    records = []
    for row in rows:
        if reconciled:
            exact_reconciliation = (
                row["confirmed_count"] > 0
                and row["unresolved_count"] == 0
                and row["funded_minor"] == row["final_total_minor"]
                and row["allocated_refund_minor"] == row["purchase_refunded_minor"]
                and row["line_refunded_minor"] == row["purchase_refunded_minor"]
            )
            if not exact_reconciliation:
                continue
        net_minor = row["line_net_minor"] or 0
        if body.refund_policy == "NET":
            net_minor -= row["refunded_minor"]
        records.append(
            PurchaseLineRecord(
                id=row["id"],
                space_id=row["space_id"],
                day=date.fromisoformat(row["purchased_on"]),
                net_amount=Money(net_minor, row["currency"]),
                merchant=row["merchant_name"],
                category=row["category_name"],
                line_kind=row["line_kind"],
                normalized_item=row["normalized_item_name"],
                purpose=row["purpose"],
                recipient=row["beneficiary"],
                plannedness=row["plannedness"],
                utility=row["utility"],
                decision_quality=row["decision_quality"],
                value_for_money=row["value_for_money"],
                outcome=(
                    row["outcome_state"]
                    or ("returned" if row["refunded_minor"] > 0 else None)
                ),
                itemisation=(
                    "UNITEMISED" if row["evidence_status"] == "unitemised" else "ITEMISED"
                ),
                unit_price_minor=row["unit_price_minor"],
                evidence_ids=(f"purchase-line:{row['id']}",),
            )
        )
    current_records = [
        record for record in records if body.start_date <= record.day <= body.end_date
    ]
    purchase_eligible = sum(
        max(0, record.net_amount.minor_units) for record in current_records
    )
    itemised = sum(
        max(0, record.net_amount.minor_units)
        for record in current_records
        if record.itemisation == "ITEMISED"
    )
    visible_cash_spend = await _visible_cash_spend_minor(
        db, user=user, body=body, space_ids=space_ids
    )
    eligible = max(purchase_eligible, visible_cash_spend)
    coverage = FinanceAnalysisCoverageResponse(
        eligible_minor=eligible,
        itemised_minor=itemised,
        coverage_bps=min(10000, (itemised * 10000 // eligible) if eligible else 0),
    )
    data_through = max((record.day for record in current_records), default=None)
    return records, data_through, coverage


async def purchase_itemisation_coverage(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    start_date: date,
    end_date: date,
) -> FinanceAnalysisCoverageResponse:
    """Return the shared conservative retail-only itemisation denominator."""
    body = FinanceAnalysisRequest(
        space_id=space_id,
        basis="PURCHASE_LINES",
        start_date=start_date,
        end_date=end_date,
        currency=currency,
    )
    totals = await (
        await db.execute(
            """
            WITH eligible_purchases AS MATERIALIZED (
                SELECT id, space_id, family_id
                FROM finance_purchase_records
                WHERE space_id = :space_id AND family_id = :family_id
                  AND purchased_on BETWEEN :start_date AND :end_date
                  AND currency = :currency AND superseded_by_id IS NULL
                  AND deleted_at IS NULL
            ),
            refunds AS MATERIALIZED (
                SELECT refund.line_id, refund.space_id, refund.family_id,
                       SUM(refund.amount_minor) AS refunded_minor
                FROM finance_line_refunds refund
                JOIN eligible_purchases purchase
                  ON purchase.id = refund.purchase_id
                 AND purchase.space_id = refund.space_id
                 AND purchase.family_id = refund.family_id
                WHERE refund.deleted_at IS NULL
                GROUP BY refund.line_id, refund.space_id, refund.family_id
            )
            SELECT
                COALESCE(SUM(MAX(
                    0,
                    COALESCE(line.line_net_minor, 0)
                    - COALESCE(refund.refunded_minor, 0)
                )), 0) AS eligible_minor,
                COALESCE(SUM(CASE
                    WHEN line.evidence_status <> 'unitemised' THEN MAX(
                        0,
                        COALESCE(line.line_net_minor, 0)
                        - COALESCE(refund.refunded_minor, 0)
                    )
                    ELSE 0
                END), 0) AS itemised_minor
            FROM finance_purchase_lines line
            JOIN eligible_purchases purchase
              ON purchase.id = line.purchase_id
             AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id
            LEFT JOIN refunds refund
              ON refund.line_id = line.id AND refund.space_id = line.space_id
             AND refund.family_id = line.family_id
            WHERE line.space_id = :space_id AND line.family_id = :family_id
              AND line.deleted_at IS NULL
            """,
            {
                "space_id": space_id,
                "family_id": user["family_id"],
                "start_date": start_date.isoformat(),
                "end_date": end_date.isoformat(),
                "currency": currency,
            },
        )
    ).fetchone()
    purchase_eligible = int(totals["eligible_minor"])
    itemised = int(totals["itemised_minor"])
    visible_cash_spend = await _visible_cash_spend_minor(
        db, user=user, body=body, space_ids=(space_id,)
    )
    eligible = max(purchase_eligible, visible_cash_spend)
    return FinanceAnalysisCoverageResponse(
        eligible_minor=eligible,
        itemised_minor=itemised,
        coverage_bps=min(10000, (itemised * 10000 // eligible) if eligible else 0),
    )


async def _save_view(
    db, *, user: dict, body: FinanceAnalysisRequest
) -> FinanceSavedAnalysisViewResponse:
    identifier = str(uuid.uuid4())
    now = _now()
    stored = body.model_copy(update={"save_as": None})
    await db.execute(
        """
        INSERT INTO finance_analysis_views
            (id, space_id, owner_user_id, name, specification_json, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            identifier,
            body.space_id,
            user["id"],
            body.save_as,
            json.dumps(stored.model_dump(mode="json"), sort_keys=True, separators=(",", ":")),
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    return FinanceSavedAnalysisViewResponse(
        id=identifier,
        space_id=body.space_id,
        name=body.save_as,
        request=stored,
        deep_link=f"/?view=finance&section=explore&analysis={quote(identifier, safe='')}",
        created_at=now,
        updated_at=now,
    )


async def run_saved_finance_analysis(
    db, *, user: dict, body: FinanceAnalysisRequest
) -> FinanceAnalysisResponse:
    """Run one typed basis after binding the requested view to caller-visible spaces."""
    if body.scope is None:
        await require_finance_space(db, user=user, space_id=body.space_id)
        space_ids = (body.space_id,)
    else:
        space_ids = await resolve_finance_scope_spaces(
            db,
            user=user,
            scope=body.scope,
            selected_space_id=body.space_id,
        )
    transactions = []
    purchase_lines = []
    coverage = None
    if body.basis == "TRANSACTIONS":
        transactions, data_through = await _transaction_records(
            db, user=user, body=body, space_ids=space_ids
        )
    else:
        purchase_lines, data_through, coverage = await _purchase_line_records(
            db, user=user, body=body, space_ids=space_ids
        )
    spec = AnalysisSpec(
        basis=body.basis,
        start_date=body.start_date,
        end_date=body.end_date,
        currency=body.currency,
        allowed_space_ids=space_ids,
        grouping=body.grouping,
        measure=body.measure,
        comparison=body.comparison,
        filters=_analysis_filters(body.filters),
    )
    result = analyse_finance(
        spec, transactions=transactions, purchase_lines=purchase_lines
    )
    evidence_handles = tuple(
        sorted(
            set(result.evidence_ids)
            | {
                handle
                for group in result.comparison_groups
                for handle in group.evidence_ids
            }
        )
    )
    evidence = []
    for handle in evidence_handles:
        kind, record_id = handle.split(":", 1)
        evidence.append(
            FinanceAnalysisEvidenceResponse(
                handle=handle,
                kind=kind,
                record_id=record_id,
                deep_link=_deep_link(kind, record_id),
            )
        )
    saved_view = None
    if body.save_as:
        async with serialized_create(db):
            saved_view = await _save_view(db, user=user, body=body)
    return FinanceAnalysisResponse(
        basis=body.basis,
        currency=body.currency,
        total=_exact(result.total),
        groups=[
            FinanceAnalysisGroupResponse(
                key=group.key,
                value=_exact(group.value),
                record_count=group.record_count,
                evidence_handles=list(group.evidence_ids),
            )
            for group in result.groups
        ],
        comparison_groups=[
            FinanceAnalysisGroupResponse(
                key=group.key,
                value=_exact(group.value),
                record_count=group.record_count,
                evidence_handles=list(group.evidence_ids),
            )
            for group in result.comparison_groups
        ],
        comparison_total=(
            _exact(result.comparison_total) if result.comparison_total is not None else None
        ),
        comparison_start_date=result.comparison_start_date,
        comparison_end_date=result.comparison_end_date,
        data_through=data_through,
        itemisation_coverage=coverage,
        evidence=evidence,
        saved_view=saved_view,
    )


async def list_saved_analysis_views(
    db, *, user: dict, space_id: str
) -> list[FinanceSavedAnalysisViewResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_analysis_views
            WHERE space_id = ? AND owner_user_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY updated_at DESC, id DESC
            """,
            (space_id, user["id"], user["family_id"]),
        )
    ).fetchall()
    return [
        FinanceSavedAnalysisViewResponse(
            id=row["id"],
            space_id=row["space_id"],
            name=row["name"],
            request=FinanceAnalysisRequest.model_validate_json(row["specification_json"]),
            deep_link=f"/?view=finance&section=explore&analysis={quote(row['id'], safe='')}",
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )
        for row in rows
    ]


async def read_analysis_evidence(
    db, *, user: dict, kind: str, record_id: str
) -> FinanceEvidenceHandleResponse:
    """Resolve a typed evidence handle only after record-level ownership checks."""
    require_finance_access(user)
    if kind == "purchase-line":
        row = await _authorised_line(db, user=user, line_id=record_id)
        return FinanceEvidenceHandleResponse(
            handle=f"purchase-line:{record_id}",
            kind="purchase-line",
            record_id=record_id,
            space_id=row["space_id"],
            deep_link=_deep_link(kind, record_id),
            source_evidence_id=row["source_id"],
            source_description=row["raw_description"],
            amount_minor=row["line_net_minor"] or 0,
            currency=row["currency"],
            occurred_on=row["purchased_on"],
            source_kind=row["source_kind"],
            line_kind=row["line_kind"],
        )
    if kind != "transaction":
        raise FinanceUnderstandingNotFoundError("Finance analysis evidence not found")
    row = await (
        await db.execute(
            """
            SELECT tx.*, source.source_transaction_id
            FROM finance_transactions tx
            JOIN finance_spaces space
              ON space.id = tx.space_id AND space.family_id = tx.family_id
             AND space.deleted_at IS NULL
            LEFT JOIN finance_transaction_sources link
              ON link.transaction_id = tx.id AND link.is_primary = 1
             AND link.deleted_at IS NULL
            LEFT JOIN finance_source_transactions source
              ON source.id = link.source_transaction_id AND source.deleted_at IS NULL
            WHERE tx.id = ? AND tx.family_id = ? AND tx.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            LIMIT 1
            """,
            (record_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceUnderstandingNotFoundError("Finance analysis evidence not found")
    return FinanceEvidenceHandleResponse(
        handle=f"transaction:{record_id}",
        kind="transaction",
        record_id=record_id,
        space_id=row["space_id"],
        deep_link=_deep_link(kind, record_id),
        source_evidence_id=row["source_transaction_id"] or record_id,
        source_description=row["description"],
        amount_minor=row["amount_minor"],
        currency=row["currency"],
        occurred_on=row["canonical_date"],
        source_kind=None,
        line_kind=None,
    )

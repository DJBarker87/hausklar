"""Finance spaces, explicit AI consent, and read-only coach queries."""

import json
import uuid
from collections import defaultdict
from collections.abc import Mapping, Sequence
from datetime import date, datetime, timezone

from app.config import settings
from app.models.finance import (
    FinanceAIConsentResponse,
)
from app.services.finance.ai import (
    FinanceQueryOperation,
    FinanceReasoningError,
    HermesFinanceReasoningAdapter,
    OpenAIFinanceReasoningAdapter,
)
from app.services.finance.foundation import (
    accessible_finance_spaces,
    require_finance_access,
    require_finance_space,
    resolve_finance_scope_spaces,
)
from app.services.finance.analytics import (
    AnalysisFilters,
    AnalysisSpec,
    PurchaseLineRecord,
    TransactionRecord,
    analyse_finance,
)
from app.services.finance.dates import household_zone
from app.services.finance.ledger import clean_description
from app.services.finance.money import Money
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

FINANCE_AI_DISCLOSURE_VERSION = "finance-ai-disclosure-v3"
_NEUTRAL_RELATIONS = {"INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT", "FX_LEG"}
_SUPPORTED_COACH_READS = {
    "get_financial_overview",
    "search_transactions",
    "get_account_freshness",
    "analyse_finance",
    "search_purchase_lines",
    "aggregate_purchase_lines",
    "get_purchase_and_line_evidence",
}
_MAX_COACH_ANALYSIS_RECORDS = 5_000


class FinanceCoachError(RuntimeError):
    """Base class for safe Finance coach failures."""


class FinanceCoachForbiddenError(FinanceCoachError):
    """The caller cannot administer Finance for this family."""


class FinanceCoachNotFoundError(FinanceCoachError):
    """A same-family Finance record was not found."""


class FinanceCoachConflictError(FinanceCoachError):
    """The displayed disclosure no longer matches deployment configuration."""


class FinanceAIConsentRequiredError(FinanceCoachError):
    """Current explicit Finance-AI consent is incomplete."""


class FinanceCoachUnavailableError(FinanceCoachError):
    """The configured Finance reasoning provider is unavailable."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def finance_ai_identity() -> tuple[str, str]:
    provider = settings.finance_ai_provider
    if provider == "openai":
        return provider, settings.finance_openai_model.strip()
    if provider == "hermes":
        return provider, settings.finance_hermes_model.strip()
    return "off", "none"


def finance_ai_consent_version() -> str:
    provider, model = finance_ai_identity()
    return f"{FINANCE_AI_DISCLOSURE_VERSION}/{provider}/{model}"


def _disclosure() -> str:
    provider, _ = finance_ai_identity()
    if provider == "off":
        return (
            "The Finance Coach is turned off. HausKlar will ask for permission "
            "before any future sharing. Bank credentials are never shared. "
            "HausKlar does not store Finance Coach chats or send Finance data in "
            "the background."
        )

    if provider == "openai":
        service = "OpenAI"
    else:
        service = (
            "the private Hermes Finance service, which currently uses OpenAI "
            "to produce the answer"
        )
    storage_note = (
        " OpenAI is also asked not to store the request."
        if provider == "openai"
        else ""
    )
    return (
        f"Only after you press Send, HausKlar may share the Finance details you "
        f"selected with {service}: account names and update times, transaction "
        "dates, descriptions, merchants, amounts and currencies, reviewed purchase "
        "details, and calculated totals. Bank credentials are never shared. "
        "HausKlar does not store Finance Coach chats, and nothing is sent in the "
        f"background.{storage_note}"
    )


async def _current_consent_row(db, *, user_id: str, space_id: str):
    provider, model = finance_ai_identity()
    if provider == "off":
        return None
    return await (
        await db.execute(
            """
            SELECT * FROM finance_ai_consents
            WHERE user_id = ? AND space_id = ? AND disclosure_version = ?
              AND consent_version = ? AND provider = ? AND model = ?
              AND store_response = 0 AND background_processing = 0
              AND revoked_at IS NULL AND deleted_at IS NULL
            ORDER BY accepted_at DESC, id DESC LIMIT 1
            """,
            (
                user_id,
                space_id,
                FINANCE_AI_DISCLOSURE_VERSION,
                finance_ai_consent_version(),
                provider,
                model,
            ),
        )
    ).fetchone()


async def finance_ai_consent_allows_space(
    db, *, user: dict, space_id: str
) -> bool:
    """Check the current consent needed before sharing one Finance space."""

    space = await require_finance_space(db, user=user, space_id=space_id)
    if space["kind"] == "personal":
        return (
            await _current_consent_row(
                db,
                user_id=user["id"],
                space_id=space_id,
            )
            is not None
        )

    family_accounts = await (
        await db.execute(
            """
            SELECT id FROM users
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY id
            """,
            (user["family_id"],),
        )
    ).fetchall()
    for account in family_accounts:
        if await _current_consent_row(
            db,
            user_id=account["id"],
            space_id=space_id,
        ) is None:
            return False
    return True


def _consent_response(
    *, space_id: str, space_kind: str, consented_at: str | None
) -> FinanceAIConsentResponse:
    provider, model = finance_ai_identity()
    return FinanceAIConsentResponse(
        space_id=space_id,
        space_kind=space_kind,
        consented=consented_at is not None,
        consent_version=finance_ai_consent_version(),
        consented_at=consented_at,
        provider=provider,
        model=model,
        store=False,
        background_processing=False,
        disclosure=_disclosure(),
    )


async def list_finance_ai_consents(
    db, *, user: dict
) -> list[FinanceAIConsentResponse]:
    spaces = await accessible_finance_spaces(db, user=user)
    responses = []
    for space in spaces:
        consent = await _current_consent_row(
            db, user_id=user["id"], space_id=space.id
        )
        responses.append(
            _consent_response(
                space_id=space.id,
                space_kind=space.kind,
                consented_at=consent["accepted_at"] if consent else None,
            )
        )
    return responses


async def accept_finance_ai_consent(
    db, *, user: dict, space_id: str, consent_version: str
) -> FinanceAIConsentResponse:
    space = await require_finance_space(db, user=user, space_id=space_id)
    provider, model = finance_ai_identity()
    if provider == "off":
        raise FinanceCoachUnavailableError("The Finance coach is disabled")
    if consent_version != finance_ai_consent_version():
        raise FinanceCoachConflictError(
            "The Finance AI notice has changed. Review the current disclosure."
        )
    identifier = str(uuid.uuid4())
    now = _now()
    accepted_at = now
    async with serialized_create(db):
        existing = await _current_consent_row(
            db, user_id=user["id"], space_id=space_id
        )
        if existing is not None:
            accepted_at = existing["accepted_at"]
            active = []
        else:
            active = await (
                await db.execute(
                    """
                    SELECT id FROM finance_ai_consents
                    WHERE user_id = ? AND space_id = ? AND revoked_at IS NULL
                      AND deleted_at IS NULL
                    """,
                    (user["id"], space_id),
                )
            ).fetchall()
        for row in active:
            await save_history(
                db,
                "finance_ai_consents",
                row["id"],
                user["id"],
                family_id=user["family_id"],
            )
        if active:
            await db.execute(
                """
                UPDATE finance_ai_consents SET revoked_at = ?, updated_at = ?
                WHERE user_id = ? AND space_id = ? AND revoked_at IS NULL
                  AND deleted_at IS NULL
                """,
                (now, now, user["id"], space_id),
            )
        if existing is None:
            await db.execute(
                """
                INSERT INTO finance_ai_consents
                    (id, space_id, user_id, disclosure_version, consent_version,
                     provider, model, store_response, background_processing,
                     accepted_at, family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?)
                """,
                (
                    identifier,
                    space_id,
                    user["id"],
                    FINANCE_AI_DISCLOSURE_VERSION,
                    consent_version,
                    provider,
                    model,
                    now,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
    return _consent_response(
        space_id=space_id, space_kind=space["kind"], consented_at=accepted_at
    )


async def revoke_finance_ai_consent(
    db, *, user: dict, space_id: str
) -> FinanceAIConsentResponse:
    space = await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT id FROM finance_ai_consents
            WHERE user_id = ? AND space_id = ? AND revoked_at IS NULL
              AND deleted_at IS NULL
            """,
            (user["id"], space_id),
        )
    ).fetchall()
    if rows:
        now = _now()
        async with serialized_create(db):
            for row in rows:
                await save_history(
                    db,
                    "finance_ai_consents",
                    row["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
            await db.execute(
                """
                UPDATE finance_ai_consents SET revoked_at = ?, updated_at = ?
                WHERE user_id = ? AND space_id = ? AND revoked_at IS NULL
                  AND deleted_at IS NULL
                """,
                (now, now, user["id"], space_id),
            )
    return _consent_response(
        space_id=space_id, space_kind=space["kind"], consented_at=None
    )


async def resolve_coach_spaces(
    db, *, user: dict, scope: str, space_id: str
) -> tuple[str, ...]:
    try:
        resolved = await resolve_finance_scope_spaces(
            db,
            user=user,
            scope=scope,
            selected_space_id=space_id,
        )
    except ValueError as exc:
        raise FinanceCoachError(str(exc)) from exc

    family_adults = await (
        await db.execute(
            """
            SELECT id FROM users
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY id
            """,
            (user["family_id"],),
        )
    ).fetchall()
    personal_id = resolved[0] if scope == "mine" else None
    household_id = resolved[-1]
    missing: list[str] = []
    if personal_id is not None and await _current_consent_row(
        db, user_id=user["id"], space_id=personal_id
    ) is None:
        missing.append(user["id"])
    for adult in family_adults:
        if await _current_consent_row(
            db, user_id=adult["id"], space_id=household_id
        ) is None:
            missing.append(adult["id"])
    if missing:
        detail = (
            "Every adult must accept the current Household Finance Coach consent"
            if any(user_id != user["id"] for user_id in missing)
            else "Current explicit Finance AI consent is required for this scope"
        )
        raise FinanceAIConsentRequiredError(
            detail
        )
    return resolved


def build_finance_reasoning_adapter():
    provider, model = finance_ai_identity()
    if provider == "off":
        raise FinanceCoachUnavailableError("The Finance coach is disabled")
    if not model:
        raise FinanceCoachUnavailableError(
            "The Finance reasoning provider is not configured"
        )
    if provider == "openai":
        if not settings.finance_openai_api_key.strip():
            raise FinanceCoachUnavailableError(
                "The Finance reasoning provider is not configured"
            )
        return OpenAIFinanceReasoningAdapter(
            api_key=settings.finance_openai_api_key,
            model=settings.finance_openai_model,
            timeout_seconds=settings.finance_ai_timeout_seconds,
        )
    if provider == "hermes":
        if not settings.hermes_bridge_url.strip() or len(
            settings.hermes_bridge_token.strip()
        ) < 32:
            raise FinanceCoachUnavailableError(
                "The Finance reasoning provider is not configured"
            )
        return HermesFinanceReasoningAdapter(
            bridge_url=settings.hermes_bridge_url,
            bridge_token=settings.hermes_bridge_token,
            timeout_seconds=(
                settings.hermes_timeout_seconds
                + settings.hermes_queue_wait_seconds
                + 5.0
            ),
        )
    raise FinanceCoachUnavailableError(
        "The configured Finance reasoning provider is not available"
    )


def _validated_period(arguments: Mapping[str, object], key: str) -> str | None:
    value = arguments.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise FinanceReasoningError("Finance query date is invalid")
    try:
        return date.fromisoformat(value).isoformat()
    except ValueError as exc:
        raise FinanceReasoningError("Finance query date is invalid") from exc


class FinanceLedgerQueryExecutor:
    """Execute only bounded deterministic reads exposed to the coach."""

    def __init__(self, db) -> None:
        self._db = db

    @staticmethod
    def _own_copy_clause(
        *, alias: str, record_type: str, space_ids: tuple[str, ...]
    ) -> str:
        if len(space_ids) < 2:
            return ""
        return f"""
            NOT EXISTS (
                SELECT 1 FROM finance_share_copy_links copy
                JOIN finance_share_actions share
                  ON share.id = copy.share_action_id AND share.deleted_at IS NULL
                WHERE copy.household_record_type = '{record_type}'
                  AND copy.household_record_id = {alias}.id
                  AND copy.household_space_id = {alias}.space_id
                  AND copy.family_id = {alias}.family_id
                  AND copy.deleted_at IS NULL AND share.owner_user_id = ?
            )
        """

    async def _household_today(self, *, family_id: str) -> date:
        row = await (
            await self._db.execute(
                "SELECT household_timezone FROM finance_settings "
                "WHERE family_id = ? AND deleted_at IS NULL LIMIT 1",
                (family_id,),
            )
        ).fetchone()
        if row is None:
            raise FinanceReasoningError("Finance settings are not available")
        return datetime.now(timezone.utc).astimezone(
            household_zone(row["household_timezone"])
        ).date()

    async def execute(
        self,
        *,
        operation: FinanceQueryOperation,
        arguments: Mapping[str, object],
        principal: Mapping[str, object],
        space_ids: Sequence[str],
    ) -> Mapping[str, object]:
        if operation not in _SUPPORTED_COACH_READS:
            raise FinanceReasoningError(
                "This Finance coach operation is not available in read-only mode"
            )
        user = dict(principal)
        require_finance_access(user)
        bound = tuple(dict.fromkeys(space_ids))
        if not bound:
            raise FinanceReasoningError("Finance query scope is empty")
        space_kinds: list[str] = []
        for space_id in bound:
            space = await require_finance_space(self._db, user=user, space_id=space_id)
            space_kinds.append(space["kind"])
        if operation == "get_financial_overview":
            result = await self._overview(
                user=user, space_ids=bound, arguments=arguments
            )
        elif operation == "search_transactions":
            result = await self._search(
                user=user, space_ids=bound, arguments=arguments
            )
        elif operation == "get_account_freshness":
            result = await self._freshness(user=user, space_ids=bound)
        elif operation == "analyse_finance":
            result = await self._analyse(
                user=user, space_ids=bound, arguments=arguments
            )
        elif operation == "search_purchase_lines":
            result = await self._purchase_lines(
                user=user, space_ids=bound, arguments=arguments, aggregate=False
            )
        elif operation == "aggregate_purchase_lines":
            result = await self._purchase_lines(
                user=user, space_ids=bound, arguments=arguments, aggregate=True
            )
        else:
            result = await self._purchase_evidence(
                user=user, space_ids=bound, arguments=arguments
            )
        view_scope = (
            "personal_and_household"
            if set(space_kinds) == {"personal", "household"}
            else space_kinds[0]
        )
        return {"view_scope": view_scope, **result}

    async def _overview(
        self,
        *,
        user: dict,
        space_ids: tuple[str, ...],
        arguments: Mapping[str, object],
    ) -> Mapping[str, object]:
        start = _validated_period(arguments, "period_start")
        end = _validated_period(arguments, "period_end")
        if start and end and start > end:
            raise FinanceReasoningError("Finance query period is invalid")
        placeholders = ",".join("?" for _ in space_ids)
        where = [
            f"space_id IN ({placeholders})",
            "family_id = ?",
            "state = 'POSTED'",
            "deleted_at IS NULL",
        ]
        parameters: list[object] = [*space_ids, user["family_id"]]
        own_copy_clause = self._own_copy_clause(
            alias="finance_transactions",
            record_type="transaction",
            space_ids=space_ids,
        )
        if own_copy_clause:
            where.append(own_copy_clause)
            parameters.append(user["id"])
        if start:
            where.append("canonical_date >= ?")
            parameters.append(start)
        if end:
            where.append("canonical_date <= ?")
            parameters.append(end)
        transactions = await (
            await self._db.execute(
                f"SELECT * FROM finance_transactions WHERE {' AND '.join(where)}",
                parameters,
            )
        ).fetchall()
        relations = await (
            await self._db.execute(
                f"""
                SELECT * FROM finance_transaction_relations
                WHERE space_id IN ({placeholders}) AND family_id = ?
                  AND status = 'CONFIRMED' AND deleted_at IS NULL
                """,
                [*space_ids, user["family_id"]],
            )
        ).fetchall()
        included_ids = {row["id"] for row in transactions}
        neutral_ids: set[str] = set()
        refund_ids: set[str] = set()
        reimbursement_ids: set[str] = set()
        for relation in relations:
            linked = {
                relation["from_transaction_id"],
                relation["to_transaction_id"],
            } & included_ids
            if relation["relation_type"] in _NEUTRAL_RELATIONS:
                neutral_ids.update(linked)
            elif relation["relation_type"] == "REFUND":
                refund_ids.add(relation["to_transaction_id"])
            elif relation["relation_type"] == "REIMBURSEMENT":
                reimbursement_ids.add(relation["to_transaction_id"])
        shared_treatment_rows = await (
            await self._db.execute(
                f"""
                SELECT DISTINCT household_record_id, accounting_treatment
                FROM finance_share_copy_links
                WHERE household_space_id IN ({placeholders}) AND family_id = ?
                  AND household_record_type = 'transaction'
                  AND accounting_treatment <> 'CASEY'
                  AND deleted_at IS NULL
                """,
                [*space_ids, user["family_id"]],
            )
        ).fetchall()
        for row in shared_treatment_rows:
            if row["accounting_treatment"] == "NEUTRAL_TRANSFER":
                neutral_ids.add(row["household_record_id"])
            elif row["accounting_treatment"] == "REFUND":
                refund_ids.add(row["household_record_id"])
            elif row["accounting_treatment"] == "REIMBURSEMENT":
                reimbursement_ids.add(row["household_record_id"])
        totals: dict[str, dict[str, int]] = defaultdict(
            lambda: {
                "account_movement_minor": 0,
                "income_minor": 0,
                "gross_spending_minor": 0,
                "refunds_minor": 0,
                "reimbursements_minor": 0,
                "fees_minor": 0,
            }
        )
        data_through: str | None = None
        for row in transactions:
            values = totals[row["currency"]]
            amount = row["amount_minor"]
            values["account_movement_minor"] += amount
            data_through = max(data_through or row["data_through_at"], row["data_through_at"])
            if row["id"] in neutral_ids:
                continue
            if amount < 0:
                values["gross_spending_minor"] += abs(amount)
                if row["transaction_kind"] == "FEE":
                    values["fees_minor"] += abs(amount)
            elif row["id"] in refund_ids:
                values["refunds_minor"] += amount
            elif row["id"] in reimbursement_ids:
                values["reimbursements_minor"] += amount
            else:
                values["income_minor"] += amount
        currencies = []
        for currency, values in sorted(totals.items()):
            currencies.append(
                {
                    "currency": currency,
                    **values,
                    "net_household_cost_minor": (
                        values["gross_spending_minor"]
                        - values["refunds_minor"]
                        - values["reimbursements_minor"]
                    ),
                }
            )
        return {
            "evidence_id": "ledger-overview:bounded",
            "period_start": start,
            "period_end": end,
            "data_through_at": data_through,
            "currencies": currencies,
        }

    async def _search(
        self,
        *,
        user: dict,
        space_ids: tuple[str, ...],
        arguments: Mapping[str, object],
    ) -> Mapping[str, object]:
        search_text = arguments.get("search_text")
        if not isinstance(search_text, str) or not clean_description(search_text):
            raise FinanceReasoningError("Finance transaction search is invalid")
        limit = arguments.get("limit", 20)
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
            raise FinanceReasoningError("Finance transaction search limit is invalid")
        start = _validated_period(arguments, "period_start")
        end = _validated_period(arguments, "period_end")
        if start and end and start > end:
            raise FinanceReasoningError("Finance query period is invalid")
        placeholders = ",".join("?" for _ in space_ids)
        where = [
            f"space_id IN ({placeholders})",
            "family_id = ?",
            "state IN ('PENDING', 'POSTED')",
            "deleted_at IS NULL",
            "(cleaned_description LIKE ? OR upper(COALESCE(merchant_text, '')) LIKE ?)",
        ]
        term = f"%{clean_description(search_text)}%"
        parameters: list[object] = [*space_ids, user["family_id"], term, term]
        own_copy_clause = self._own_copy_clause(
            alias="finance_transactions",
            record_type="transaction",
            space_ids=space_ids,
        )
        if own_copy_clause:
            where.append(own_copy_clause)
            parameters.append(user["id"])
        if start:
            where.append("canonical_date >= ?")
            parameters.append(start)
        if end:
            where.append("canonical_date <= ?")
            parameters.append(end)
        parameters.append(limit)
        rows = await (
            await self._db.execute(
                f"""
                SELECT id, canonical_date, amount_minor, currency, state,
                       description, merchant_text, data_through_at
                FROM finance_transactions
                WHERE {' AND '.join(where)}
                ORDER BY canonical_date DESC, created_at DESC, id DESC LIMIT ?
                """,
                parameters,
            )
        ).fetchall()
        return {
            "evidence_id": "ledger-search:bounded",
            "search_text": search_text,
            "transactions": [
                {
                    "evidence_id": f"transaction:{row['id']}",
                    "transaction_id": row["id"],
                    "date": row["canonical_date"],
                    "amount_minor": row["amount_minor"],
                    "currency": row["currency"],
                    "state": row["state"],
                    "description": row["description"],
                    "merchant": row["merchant_text"],
                    "data_through_at": row["data_through_at"],
                }
                for row in rows
            ],
        }

    @staticmethod
    def _bounded_limit(arguments: Mapping[str, object], default: int = 20) -> int:
        limit = arguments.get("limit", default)
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
            raise FinanceReasoningError("Finance query limit is invalid")
        return limit

    @staticmethod
    def _exact(value) -> dict[str, int]:
        return {"numerator": value.numerator, "denominator": value.denominator}

    async def _analyse(
        self,
        *,
        user: dict,
        space_ids: tuple[str, ...],
        arguments: Mapping[str, object],
    ) -> Mapping[str, object]:
        """Run the pure typed engine over posted canonical transactions only."""
        requested_end = _validated_period(arguments, "period_end")
        end_day = (
            date.fromisoformat(requested_end)
            if requested_end
            else await self._household_today(family_id=user["family_id"])
        )
        requested_start = _validated_period(arguments, "period_start")
        start_day = (
            date.fromisoformat(requested_start)
            if requested_start
            else date.fromordinal(end_day.toordinal() - 365)
        )
        start, end = start_day.isoformat(), end_day.isoformat()
        if start > end:
            raise FinanceReasoningError("Finance query period is invalid")
        if (end_day - start_day).days > 3_660:
            raise FinanceReasoningError("Finance query period is too large")
        grouping = str(arguments.get("group_by") or "total").upper()
        if grouping not in {"TOTAL", "DAY", "WEEK", "MONTH", "ACCOUNT", "MERCHANT", "CATEGORY"}:
            raise FinanceReasoningError("Finance analysis grouping is invalid")
        limit = self._bounded_limit(arguments, 50)
        placeholders = ",".join("?" for _ in space_ids)
        own_copy_clause = self._own_copy_clause(
            alias="tx", record_type="transaction", space_ids=space_ids
        )
        own_copy_sql = f"AND {own_copy_clause}" if own_copy_clause else ""
        parameters: list[object] = [*space_ids, user["family_id"]]
        if own_copy_clause:
            parameters.append(user["id"])
        parameters.extend((start, end, _MAX_COACH_ANALYSIS_RECORDS + 1))
        rows = await (
            await self._db.execute(
                f"""
                SELECT tx.*, category.name AS category_name
                FROM finance_transactions tx
                LEFT JOIN finance_categories category
                  ON category.id = tx.primary_category_id AND category.deleted_at IS NULL
                WHERE tx.space_id IN ({placeholders}) AND tx.family_id = ?
                  AND tx.state = 'POSTED' AND tx.deleted_at IS NULL
                  {own_copy_sql}
                  AND tx.canonical_date BETWEEN ? AND ?
                ORDER BY tx.canonical_date, tx.id LIMIT ?
                """,
                parameters,
            )
        ).fetchall()
        if len(rows) > _MAX_COACH_ANALYSIS_RECORDS:
            raise FinanceReasoningError(
                "Finance analysis matched too many records; narrow the period"
            )
        by_currency: dict[str, list[TransactionRecord]] = defaultdict(list)
        for row in rows:
            by_currency[row["currency"]].append(
                TransactionRecord(
                    id=row["id"],
                    space_id=row["space_id"],
                    day=date.fromisoformat(row["canonical_date"]),
                    amount=Money(row["amount_minor"], row["currency"]),
                    account_id=row["account_id"],
                    merchant=row["merchant_text"],
                    category=row["category_name"],
                    transaction_type=row["transaction_kind"].casefold(),
                    evidence_ids=(f"transaction:{row['id']}",),
                )
            )
        analyses = []
        for currency, records in sorted(by_currency.items()):
            result = analyse_finance(
                AnalysisSpec(
                    basis="TRANSACTIONS",
                    start_date=date.fromisoformat(start),
                    end_date=date.fromisoformat(end),
                    currency=currency,
                    allowed_space_ids=space_ids,
                    grouping=grouping,
                    measure="SPEND",
                    filters=AnalysisFilters(),
                ),
                transactions=records,
            )
            analyses.append(
                {
                    "currency": currency,
                    "total": self._exact(result.total),
                    "groups": [
                        {
                            "key": group.key,
                            "value": self._exact(group.value),
                            "record_count": group.record_count,
                            "evidence_ids": list(group.evidence_ids[:100]),
                        }
                        for group in result.groups[:limit]
                    ],
                    "evidence_ids": list(result.evidence_ids[:100]),
                }
            )
        return {
            "evidence_id": "analysis:transactions:bounded",
            "basis": "TRANSACTIONS",
            "period_start": start,
            "period_end": end,
            "analyses": analyses,
        }

    async def _purchase_lines(
        self,
        *,
        user: dict,
        space_ids: tuple[str, ...],
        arguments: Mapping[str, object],
        aggregate: bool,
    ) -> Mapping[str, object]:
        requested_end = _validated_period(arguments, "period_end")
        end_day = (
            date.fromisoformat(requested_end)
            if requested_end
            else await self._household_today(family_id=user["family_id"])
        )
        requested_start = _validated_period(arguments, "period_start")
        start_day = (
            date.fromisoformat(requested_start)
            if requested_start
            else date.fromordinal(end_day.toordinal() - 365)
        )
        start, end = start_day.isoformat(), end_day.isoformat()
        if start > end:
            raise FinanceReasoningError("Finance query period is invalid")
        if (end_day - start_day).days > 3_660:
            raise FinanceReasoningError("Finance query period is too large")
        limit = self._bounded_limit(arguments, 20)
        search_text = arguments.get("search_text")
        if not aggregate and (
            not isinstance(search_text, str) or not clean_description(search_text)
        ):
            raise FinanceReasoningError("Finance purchase-line search is invalid")
        if search_text is not None and (
            not isinstance(search_text, str) or not clean_description(search_text)
        ):
            raise FinanceReasoningError("Finance purchase-line search is invalid")
        placeholders = ",".join("?" for _ in space_ids)
        where = [
            f"line.space_id IN ({placeholders})",
            "line.family_id = ?",
            "line.deleted_at IS NULL",
            "purchase.deleted_at IS NULL",
            "purchase.superseded_by_id IS NULL",
            "purchase.purchased_on BETWEEN ? AND ?",
        ]
        parameters: list[object] = [*space_ids, user["family_id"], start, end]
        own_copy_clause = self._own_copy_clause(
            alias="line", record_type="purchase_line", space_ids=space_ids
        )
        if own_copy_clause:
            where.append(own_copy_clause)
            parameters.append(user["id"])
        if search_text is not None:
            term = f"%{clean_description(search_text)}%"
            where.append(
                "(upper(line.raw_description) LIKE ? OR upper(COALESCE(item.display_name, '')) LIKE ?)"
            )
            parameters.extend((term, term))
        rows = await (
            await self._db.execute(
                f"""
                SELECT line.*, purchase.purchased_on, purchase.merchant_name,
                       purchase.currency, item.display_name AS normalized_item_name,
                       assessment.beneficiary, assessment.purpose,
                       assessment.plannedness, assessment.utility,
                       assessment.decision_quality, assessment.value_for_money,
                       assessment.outcome_state,
                       COALESCE(refund.refunded_minor, 0) AS refunded_minor
                FROM finance_purchase_lines line
                JOIN finance_purchase_records purchase ON purchase.id = line.purchase_id
                LEFT JOIN finance_purchase_line_assessments assessment
                  ON assessment.line_id = line.id AND assessment.deleted_at IS NULL
                LEFT JOIN finance_normalized_purchase_items item
                  ON item.id = assessment.normalized_item_id AND item.deleted_at IS NULL
                LEFT JOIN (
                    SELECT line_id, SUM(amount_minor) AS refunded_minor
                    FROM finance_line_refunds WHERE deleted_at IS NULL GROUP BY line_id
                ) refund ON refund.line_id = line.id
                WHERE {' AND '.join(where)}
                ORDER BY purchase.purchased_on DESC, line.id DESC
                LIMIT ?
                """,
                (*parameters, limit if not aggregate else 101),
            )
        ).fetchall()
        if aggregate and len(rows) > 100:
            raise FinanceReasoningError(
                "Finance purchase analysis matched too many lines; narrow the period or search"
            )
        records = [
            PurchaseLineRecord(
                id=row["id"],
                space_id=row["space_id"],
                day=date.fromisoformat(row["purchased_on"]),
                net_amount=Money(
                    (row["line_net_minor"] or 0) - row["refunded_minor"],
                    row["currency"],
                ),
                merchant=row["merchant_name"],
                line_kind=row["line_kind"],
                normalized_item=row["normalized_item_name"],
                purpose=row["purpose"],
                recipient=row["beneficiary"],
                plannedness=row["plannedness"],
                utility=row["utility"],
                decision_quality=row["decision_quality"],
                value_for_money=row["value_for_money"],
                outcome=row["outcome_state"],
                unit_price_minor=row["unit_price_minor"],
                evidence_ids=(f"purchase-line:{row['id']}",),
            )
            for row in rows
        ]
        if not aggregate:
            return {
                "evidence_id": "purchase-line-search:bounded",
                "search_text": search_text,
                "purchase_lines": [
                    {
                        "evidence_id": record.evidence_ids[0],
                        "line_id": record.id,
                        "date": record.day.isoformat(),
                        "amount_minor": record.net_amount.minor_units,
                        "currency": record.net_amount.currency,
                        "merchant": record.merchant,
                        "source_description": row["raw_description"],
                        "normalized_item": record.normalized_item,
                        "purpose": record.purpose,
                        "beneficiary": record.recipient,
                    }
                    for record, row in zip(records, rows, strict=True)
                ],
            }
        grouping = str(arguments.get("group_by") or "item").upper()
        if grouping not in {"TOTAL", "DAY", "WEEK", "MONTH", "MERCHANT", "ITEM"}:
            raise FinanceReasoningError("Finance purchase-line grouping is invalid")
        analyses = []
        for currency in sorted({record.net_amount.currency for record in records}):
            currency_records = [
                record for record in records if record.net_amount.currency == currency
            ]
            result = analyse_finance(
                AnalysisSpec(
                    basis="PURCHASE_LINES",
                    start_date=date.fromisoformat(start),
                    end_date=date.fromisoformat(end),
                    currency=currency,
                    allowed_space_ids=space_ids,
                    grouping=grouping,
                    measure="SPEND",
                ),
                purchase_lines=currency_records,
            )
            analyses.append(
                {
                    "currency": currency,
                    "total": self._exact(result.total),
                    "groups": [
                        {
                            "key": group.key,
                            "value": self._exact(group.value),
                            "record_count": group.record_count,
                            "evidence_ids": list(group.evidence_ids[:100]),
                        }
                        for group in result.groups[:limit]
                    ],
                }
            )
        return {
            "evidence_id": "analysis:purchase-lines:bounded",
            "basis": "PURCHASE_LINES",
            "period_start": start,
            "period_end": end,
            "analyses": analyses,
        }

    async def _purchase_evidence(
        self,
        *,
        user: dict,
        space_ids: tuple[str, ...],
        arguments: Mapping[str, object],
    ) -> Mapping[str, object]:
        entity_ref = arguments.get("entity_ref")
        if not isinstance(entity_ref, str) or not entity_ref.startswith("purchase-line:"):
            raise FinanceReasoningError("Finance purchase evidence reference is invalid")
        line_id = entity_ref.removeprefix("purchase-line:")
        placeholders = ",".join("?" for _ in space_ids)
        own_copy_clause = self._own_copy_clause(
            alias="line", record_type="purchase_line", space_ids=space_ids
        )
        own_copy_sql = f"AND {own_copy_clause}" if own_copy_clause else ""
        parameters: list[object] = [line_id, *space_ids, user["family_id"]]
        if own_copy_clause:
            parameters.append(user["id"])
        row = await (
            await self._db.execute(
                f"""
                SELECT line.id, line.raw_description, line.line_net_minor,
                       line.evidence_status, line.source_refs_json,
                       purchase.id AS purchase_id, purchase.purchased_on,
                       purchase.merchant_name, purchase.currency, purchase.source_id,
                       item.display_name AS normalized_item_name,
                       assessment.beneficiary, assessment.purpose,
                       assessment.plannedness, assessment.utility,
                       assessment.decision_quality, assessment.value_for_money,
                       assessment.outcome_state, assessment.classification_source,
                       assessment.confidence_bps
                FROM finance_purchase_lines line
                JOIN finance_purchase_records purchase ON purchase.id = line.purchase_id
                LEFT JOIN finance_purchase_line_assessments assessment
                  ON assessment.line_id = line.id AND assessment.deleted_at IS NULL
                LEFT JOIN finance_normalized_purchase_items item
                  ON item.id = assessment.normalized_item_id AND item.deleted_at IS NULL
                WHERE line.id = ? AND line.space_id IN ({placeholders})
                  AND line.family_id = ? AND line.deleted_at IS NULL
                  AND purchase.deleted_at IS NULL
                  {own_copy_sql}
                """,
                parameters,
            )
        ).fetchone()
        if row is None:
            raise FinanceReasoningError("Finance purchase evidence was not found")
        return {
            "evidence_id": entity_ref,
            "line_id": row["id"],
            "purchase_id": row["purchase_id"],
            "source_evidence_id": row["source_id"],
            "date": row["purchased_on"],
            "merchant": row["merchant_name"],
            "amount_minor": row["line_net_minor"],
            "currency": row["currency"],
            "source_description": row["raw_description"],
            "source_refs": json.loads(row["source_refs_json"]),
            "evidence_status": row["evidence_status"],
            "assessment": {
                "normalized_item": row["normalized_item_name"],
                "beneficiary": row["beneficiary"],
                "purpose": row["purpose"],
                "plannedness": row["plannedness"],
                "utility": row["utility"],
                "decision_quality": row["decision_quality"],
                "value_for_money": row["value_for_money"],
                "outcome_state": row["outcome_state"],
                "source": row["classification_source"],
                "confidence_bps": row["confidence_bps"],
            },
        }

    async def _freshness(
        self, *, user: dict, space_ids: tuple[str, ...]
    ) -> Mapping[str, object]:
        placeholders = ",".join("?" for _ in space_ids)
        own_copy_clause = self._own_copy_clause(
            alias="account", record_type="account", space_ids=space_ids
        )
        own_copy_sql = f"AND {own_copy_clause}" if own_copy_clause else ""
        parameters: list[object] = [*space_ids, user["family_id"]]
        if own_copy_clause:
            parameters.append(user["id"])
        rows = await (
            await self._db.execute(
                f"""
                SELECT account.id, account.label, account.currency,
                       account.fresh_through_date, account.data_through_at,
                       balance.observed_at AS balance_observed_at
                FROM finance_accounts account
                LEFT JOIN finance_balance_snapshots balance
                  ON balance.id = (
                    SELECT latest.id FROM finance_balance_snapshots latest
                    WHERE latest.account_id = account.id
                      AND latest.space_id = account.space_id
                      AND latest.deleted_at IS NULL
                    ORDER BY latest.observed_at DESC, latest.id DESC LIMIT 1
                  )
                WHERE account.space_id IN ({placeholders})
                  AND account.family_id = ? AND account.deleted_at IS NULL
                  {own_copy_sql}
                ORDER BY account.label, account.id
                """,
                parameters,
            )
        ).fetchall()
        return {
            "evidence_id": "account-freshness:bounded",
            "accounts": [
                {
                    "evidence_id": f"account-freshness:{row['id']}",
                    "account_id": row["id"],
                    "label": row["label"],
                    "currency": row["currency"],
                    "fresh_through_date": row["fresh_through_date"],
                    "data_through_at": row["data_through_at"],
                    "balance_observed_at": row["balance_observed_at"],
                }
                for row in rows
            ],
        }

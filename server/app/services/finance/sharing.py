"""Explicit personal-to-household Finance sharing.

Household rows are real copies in the household space.  Private source IDs live
only in the internal provenance tables and are never returned by this module.
"""

import hashlib
import json
import uuid
from datetime import datetime, timezone

from app.models.finance_sharing import (
    FinanceContributionCreate,
    FinanceContributionResponse,
    FinancePurchaseShareCreate,
    FinanceSharePreviewRequest,
    FinanceSharePreviewResponse,
    FinanceShareResponse,
    FinanceShareRuleCreate,
)
from app.services.finance.foundation import get_finance_settings, require_finance_access
from app.services.finance.ledger import clean_description
from app.services.idempotency import serialized_create
from app.services.record_history import save_history


class FinanceSharingError(ValueError):
    """A requested visibility change is invalid."""


class FinanceSharingNotFoundError(FinanceSharingError):
    """A source record or owner-only share action was not found."""


class FinanceSharingConflictError(FinanceSharingError):
    """A record cannot be safely copied with the requested visibility."""


_SOURCE_TABLES = {
    "account": "finance_accounts",
    "transaction": "finance_transactions",
    "purchase": "finance_purchase_records",
    "commitment": "finance_commitments",
    "goal": "finance_goals",
}
_FUTURE_KINDS = {"ACCOUNT", "RULE"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


async def own_household_copy_ids(
    db,
    *,
    user: dict,
    household_space_id: str,
    record_type: str,
) -> set[str]:
    """Return household copy IDs that duplicate this caller's personal roots.

    This is an internal de-duplication primitive for the combined `mine` view;
    the identifiers are never serialized to a client.
    """
    require_finance_access(user)
    household = await (
        await db.execute(
            """
            SELECT id FROM finance_spaces
            WHERE id = ? AND family_id = ? AND kind = 'household'
              AND owner_user_id IS NULL AND deleted_at IS NULL
            """,
            (household_space_id, user["family_id"]),
        )
    ).fetchone()
    if household is None:
        return set()
    rows = await (
        await db.execute(
            """
            SELECT DISTINCT link.household_record_id
            FROM finance_share_copy_links link
            JOIN finance_share_actions share
              ON share.id = link.share_action_id AND share.deleted_at IS NULL
            WHERE share.owner_user_id = ? AND share.family_id = ?
              AND link.household_space_id = ?
              AND link.household_record_type = ? AND link.deleted_at IS NULL
            """,
            (user["id"], user["family_id"], household_space_id, record_type),
        )
    ).fetchall()
    return {row["household_record_id"] for row in rows}


async def _space_ids(db, *, user: dict) -> tuple[str, str]:
    require_finance_access(user)
    settings = await get_finance_settings(db, user=user)
    return settings.personal_space_id, settings.household_space_id


async def _owned_source(db, *, user: dict, record_type: str, record_id: str) -> dict:
    table = _SOURCE_TABLES[record_type]
    row = await (
        await db.execute(
            f"""
            SELECT record.* FROM {table} record
            JOIN finance_spaces space
              ON space.id = record.space_id
             AND space.family_id = record.family_id
             AND space.deleted_at IS NULL
            WHERE record.id = ? AND record.family_id = ?
              AND record.deleted_at IS NULL
              AND space.kind = 'personal' AND space.owner_user_id = ?
            """,
            (record_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceSharingNotFoundError(f"Finance {record_type} not found")
    result = dict(row)
    if record_type == "purchase" and result["superseded_by_id"] is not None:
        raise FinanceSharingConflictError("Only the current purchase version can be shared")
    return result


def _selection(line_ids: list[str]) -> tuple[str, str]:
    selection_json = json.dumps(sorted(line_ids), separators=(",", ":"))
    digest = hashlib.sha256(selection_json.encode("utf-8")).hexdigest()
    return selection_json, digest


async def _share_display(db, *, row: dict, user: dict) -> dict:
    kind = row["share_kind"]
    automatic = kind in _FUTURE_KINDS
    label = "Shared Finance record"
    included: list[str] = []
    source_updated_at: str | None = None
    source = None
    record_type = row.get("source_record_type")
    record_id = row.get("source_record_id")
    if kind == "RULE":
        target = "purchases" if row.get("rule_target") == "PURCHASE" else "payments"
        label = f"{row.get('rule_match_value') or 'Merchant'} {target}"
        included = ["Matching future records"]
        source_updated_at = row.get("updated_at")
    elif kind == "CONTRIBUTION":
        try:
            values = json.loads(row.get("selection_json") or "{}")
        except (TypeError, json.JSONDecodeError):
            values = {}
        amount = values.get("amount_minor")
        currency = values.get("currency") or "GBP"
        day = values.get("contribution_date")
        label = "Household contribution"
        included = [
            value for value in (
                f"{currency} {int(amount) / 100:.2f}" if isinstance(amount, int) else None,
                f"Due {day}" if isinstance(day, str) else None,
            ) if value
        ]
        source_updated_at = row.get("updated_at")
    elif record_type in _SOURCE_TABLES and record_id:
        table = _SOURCE_TABLES[record_type]
        source_row = await (
            await db.execute(
                f"""
                SELECT record.* FROM {table} record
                JOIN finance_spaces space ON space.id = record.space_id
                  AND space.family_id = record.family_id
                WHERE record.id = ? AND record.family_id = ?
                  AND space.kind = 'personal' AND space.owner_user_id = ?
                """,
                (record_id, user["family_id"], user["id"]),
            )
        ).fetchone()
        source = dict(source_row) if source_row else None
        if source:
            source_updated_at = source.get("updated_at")
            if record_type == "account":
                label = source["label"]
                included = ["Account details, balances and future payments"]
            elif record_type == "transaction":
                label = source["description"] or "Payment"
                included = [source["canonical_date"], f"{source['currency']} {abs(source['amount_minor']) / 100:.2f}"]
            elif record_type == "purchase":
                label = source["merchant_name"] or "Purchase"
                selected_ids = json.loads(row.get("selection_json") or "[]")
                if selected_ids:
                    marks = ",".join("?" for _ in selected_ids)
                    lines = await (
                        await db.execute(
                            f"""
                            SELECT raw_description, line_net_minor
                            FROM finance_purchase_lines
                            WHERE purchase_id = ? AND space_id = ? AND family_id = ?
                              AND id IN ({marks}) AND deleted_at IS NULL
                            ORDER BY line_position, id
                            """,
                            (source["id"], source["space_id"], user["family_id"], *selected_ids),
                        )
                    ).fetchall()
                    included = [
                        f"{line['raw_description']} · {source['currency']} {(line['line_net_minor'] or 0) / 100:.2f}"
                        for line in lines
                    ]
                else:
                    count = await (
                        await db.execute(
                            "SELECT COUNT(*) AS count FROM finance_purchase_lines "
                            "WHERE purchase_id = ? AND space_id = ? AND family_id = ? "
                            "AND deleted_at IS NULL",
                            (source["id"], source["space_id"], user["family_id"]),
                        )
                    ).fetchone()
                    included = [f"Whole purchase · {count['count']} items", f"Purchased {source['purchased_on']}"]
            elif record_type == "commitment":
                label = source["name"]
                included = ["Amount, reviewed due dates and priority"]
                if source.get("show_in_calendar"):
                    included.append("Shown in the family calendar")
                if source.get("show_in_tasks"):
                    included.append("Creates a family task")
            elif record_type == "goal":
                label = source["name"]
                included = ["Target, deadline and saved progress"]

    shared_copy_updated_at: str | None = None
    target_type = row.get("household_record_type")
    target_id = row.get("household_record_id")
    target_tables = {**_SOURCE_TABLES, "contribution": "finance_declared_contributions"}
    if target_type in target_tables and target_id:
        target = await (
            await db.execute(
                f"SELECT updated_at FROM {target_tables[target_type]} "
                "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                (target_id, user["family_id"]),
            )
        ).fetchone()
        shared_copy_updated_at = target["updated_at"] if target else None
    stale = bool(
        not automatic
        and source_updated_at
        and shared_copy_updated_at
        and source_updated_at > shared_copy_updated_at
    )
    version_state = "PAST" if row["status"] == "STOPPED" or stale else "CURRENT"
    return {
        "label": label,
        "included": included,
        "sharing_mode": "AUTOMATIC" if automatic else "ONCE",
        "source_updated_at": source_updated_at,
        "shared_copy_updated_at": shared_copy_updated_at,
        "stale": stale,
        "version_state": version_state,
    }


async def _share_response(db, row: dict, *, user: dict) -> FinanceShareResponse:
    display = await _share_display(db, row=row, user=user)
    return FinanceShareResponse(
        id=row["id"],
        kind=row["share_kind"],
        status=row["status"],
        applies_to_future=(row["share_kind"] in _FUTURE_KINDS and row["status"] == "ACTIVE"),
        shared_record_type=row["household_record_type"],
        shared_record_id=row["household_record_id"],
        rule_target=row["rule_target"],
        rule_match_kind=row["rule_match_kind"],
        rule_match_value=row["rule_match_value"],
        created_at=row["created_at"],
        stopped_at=row["stopped_at"],
        **display,
    )


async def _action_by_id(db, action_id: str) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM finance_share_actions WHERE id = ? AND deleted_at IS NULL",
            (action_id,),
        )
    ).fetchone()
    if row is None:
        raise RuntimeError("Finance share action was not persisted")
    return dict(row)


async def _ensure_direct_action(
    db,
    *,
    user: dict,
    personal_space_id: str,
    household_space_id: str,
    share_kind: str,
    source_record_type: str | None,
    source_record_id: str | None,
    selection_json: str = "[]",
    selection_digest: str = "",
    active: bool = False,
) -> dict:
    existing = await (
        await db.execute(
            """
            SELECT * FROM finance_share_actions
            WHERE source_space_id = ? AND share_kind = ?
              AND source_record_id IS ? AND selection_digest = ?
              AND family_id = ? AND deleted_at IS NULL
            """,
            (
                personal_space_id,
                share_kind,
                source_record_id,
                selection_digest,
                user["family_id"],
            ),
        )
    ).fetchone()
    if existing is not None:
        result = dict(existing)
        if active and result["status"] == "STOPPED":
            now = _now()
            await save_history(
                db,
                "finance_share_actions",
                result["id"],
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_share_actions
                SET status = 'ACTIVE', stopped_at = NULL, updated_at = ?
                WHERE id = ? AND owner_user_id = ? AND family_id = ?
                """,
                (now, result["id"], user["id"], user["family_id"]),
            )
            result.update(status="ACTIVE", stopped_at=None, updated_at=now)
        return result

    action_id = str(uuid.uuid4())
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_share_actions
            (id, owner_user_id, source_space_id, household_space_id, share_kind,
             source_record_type, source_record_id, selection_json,
             selection_digest, status, family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            action_id,
            user["id"],
            personal_space_id,
            household_space_id,
            share_kind,
            source_record_type,
            source_record_id,
            selection_json,
            selection_digest,
            "ACTIVE" if active else "COMPLETED",
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    return await _action_by_id(db, action_id)


async def _set_action_household_record(
    db,
    *,
    action: dict,
    record_type: str,
    record_id: str,
) -> None:
    await save_history(
        db,
        "finance_share_actions",
        action["id"],
        action["owner_user_id"],
        family_id=action["family_id"],
    )
    await db.execute(
        """
        UPDATE finance_share_actions
        SET household_record_type = ?, household_record_id = ?, updated_at = ?
        WHERE id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (record_type, record_id, _now(), action["id"], action["family_id"]),
    )
    action["household_record_type"] = record_type
    action["household_record_id"] = record_id


async def _copy_link(
    db,
    *,
    action: dict,
    source_type: str,
    source_id: str,
    household_type: str,
    household_id: str,
    accounting_treatment: str = "CASEY",
) -> None:
    existing = await (
        await db.execute(
            """
            SELECT id, accounting_treatment FROM finance_share_copy_links
            WHERE share_action_id = ? AND source_record_type = ?
              AND source_record_id = ? AND household_record_type = ?
              AND deleted_at IS NULL
            """,
            (action["id"], source_type, source_id, household_type),
        )
    ).fetchone()
    if existing is not None:
        if existing["accounting_treatment"] != accounting_treatment:
            await save_history(
                db,
                "finance_share_copy_links",
                existing["id"],
                action["owner_user_id"],
                family_id=action["family_id"],
            )
            await db.execute(
                "UPDATE finance_share_copy_links SET accounting_treatment = ?, "
                "updated_at = ? WHERE id = ?",
                (accounting_treatment, _now(), existing["id"]),
            )
        return
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_share_copy_links
            (id, share_action_id, source_space_id, source_record_type,
             source_record_id, household_space_id, household_record_type,
             household_record_id, accounting_treatment, family_id, created_at,
             updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            action["id"],
            action["source_space_id"],
            source_type,
            source_id,
            action["household_space_id"],
            household_type,
            household_id,
            accounting_treatment,
            action["family_id"],
            now,
            now,
            action["owner_user_id"],
        ),
    )


async def _any_household_copy(
    db,
    *,
    action: dict,
    source_type: str,
    source_id: str,
    household_type: str,
) -> str | None:
    row = await (
        await db.execute(
            """
            SELECT link.household_record_id
            FROM finance_share_copy_links link
            JOIN finance_share_actions share
              ON share.id = link.share_action_id AND share.deleted_at IS NULL
            WHERE link.source_space_id = ? AND link.source_record_type = ?
              AND link.source_record_id = ? AND link.household_space_id = ?
              AND link.household_record_type = ? AND link.family_id = ?
              AND link.deleted_at IS NULL
            ORDER BY link.created_at, link.id LIMIT 1
            """,
            (
                action["source_space_id"],
                source_type,
                source_id,
                action["household_space_id"],
                household_type,
                action["family_id"],
            ),
        )
    ).fetchone()
    return row["household_record_id"] if row is not None else None


async def _copy_account_row(db, *, action: dict, source: dict) -> str:
    target_id = action.get("household_record_id")
    if target_id:
        existing = await (
            await db.execute(
                "SELECT id FROM finance_accounts WHERE id = ? AND deleted_at IS NULL",
                (target_id,),
            )
        ).fetchone()
        if existing is not None:
            await _update_shared_account_metadata(db, action=action, source=source)
            return target_id
    target_id = str(uuid.uuid4())
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_accounts
            (id, space_id, label, institution, account_type, purpose, currency,
             last_four, include_in_cashflow, include_in_net_worth,
             primary_spending_account, minimum_balance_minor, card_paid_in_full,
             fresh_through_date, data_through_at, family_id, created_at,
             updated_at, created_by, client_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 0, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            target_id,
            action["household_space_id"],
            source["label"],
            source["institution"],
            source["account_type"],
            source["purpose"],
            source["currency"],
            source["last_four"],
            source["include_in_cashflow"],
            source["include_in_net_worth"],
            source["minimum_balance_minor"],
            source["fresh_through_date"],
            source["data_through_at"],
            action["family_id"],
            now,
            now,
            action["owner_user_id"],
            "finance-shared-account",
        ),
    )
    await _set_action_household_record(
        db, action=action, record_type="account", record_id=target_id
    )
    await _copy_link(
        db,
        action=action,
        source_type="account",
        source_id=source["id"],
        household_type="account",
        household_id=target_id,
    )
    return target_id


async def _update_shared_account_metadata(db, *, action: dict, source: dict) -> None:
    target_id = action["household_record_id"]
    await save_history(
        db,
        "finance_accounts",
        target_id,
        action["owner_user_id"],
        family_id=action["family_id"],
    )
    await db.execute(
        """
        UPDATE finance_accounts
        SET label = ?, institution = ?, account_type = ?, purpose = ?, currency = ?,
            last_four = ?, include_in_cashflow = ?, include_in_net_worth = ?,
            minimum_balance_minor = ?, card_paid_in_full = 0,
            card_settlement_account_id = NULL, card_statement_close_day = NULL,
            card_repayment_day = NULL, fresh_through_date = ?, data_through_at = ?,
            updated_at = ?
        WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (
            source["label"],
            source["institution"],
            source["account_type"],
            source["purpose"],
            source["currency"],
            source["last_four"],
            source["include_in_cashflow"],
            source["include_in_net_worth"],
            source["minimum_balance_minor"],
            source["fresh_through_date"],
            source["data_through_at"],
            _now(),
            target_id,
            action["household_space_id"],
            action["family_id"],
        ),
    )


async def _shared_envelope_account(db, *, action: dict, currency: str) -> str:
    row = await (
        await db.execute(
            """
            SELECT id FROM finance_accounts
            WHERE space_id = ? AND family_id = ? AND currency = ?
              AND client_id = 'finance-sharing-envelope' AND deleted_at IS NULL
            ORDER BY created_at, id LIMIT 1
            """,
            (action["household_space_id"], action["family_id"], currency),
        )
    ).fetchone()
    if row is not None:
        return row["id"]
    account_id = str(uuid.uuid4())
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_accounts
            (id, space_id, label, account_type, purpose, currency,
             include_in_cashflow, include_in_net_worth, primary_spending_account,
             minimum_balance_minor, family_id, created_at, updated_at, created_by,
             client_id)
        VALUES (?, ?, 'Shared transaction envelopes', 'CURRENT', 'IGNORED', ?,
                0, 0, 0, 0, ?, ?, ?, ?, 'finance-sharing-envelope')
        """,
        (
            account_id,
            action["household_space_id"],
            currency,
            action["family_id"],
            now,
            now,
            action["owner_user_id"],
        ),
    )
    return account_id


async def _source_accounting_treatment(
    db, *, family_id: str, source: dict
) -> str:
    semantic_relations = await (
        await db.execute(
            """
            SELECT relation_type, from_transaction_id, to_transaction_id
            FROM finance_transaction_relations
            WHERE space_id = ? AND family_id = ? AND status = 'CONFIRMED'
              AND relation_type IN (
                  'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG',
                  'REFUND', 'REIMBURSEMENT'
              )
              AND (from_transaction_id = ? OR to_transaction_id = ?)
              AND deleted_at IS NULL
            """,
            (
                source["space_id"],
                family_id,
                source["id"],
                source["id"],
            ),
        )
    ).fetchall()
    accounting_treatment = "CASEY"
    for relation in semantic_relations:
        if relation["relation_type"] in {
            "INTERNAL_TRANSFER",
            "CREDIT_CARD_REPAYMENT",
            "FX_LEG",
        }:
            accounting_treatment = "NEUTRAL_TRANSFER"
            break
        if relation["to_transaction_id"] == source["id"]:
            accounting_treatment = relation["relation_type"]
    return accounting_treatment


async def _copy_transaction(
    db,
    *,
    action: dict,
    source: dict,
    target_account_id: str | None = None,
    force_new: bool = False,
) -> str:
    accounting_treatment = await _source_accounting_treatment(
        db, family_id=action["family_id"], source=source
    )
    existing_id = None if force_new else await _any_household_copy(
        db,
        action=action,
        source_type="transaction",
        source_id=source["id"],
        household_type="transaction",
    )
    if existing_id is not None:
        if target_account_id is not None:
            existing = await (
                await db.execute(
                    "SELECT account_id FROM finance_transactions WHERE id = ? AND deleted_at IS NULL",
                    (existing_id,),
                )
            ).fetchone()
            if existing is not None and existing["account_id"] != target_account_id:
                await save_history(
                    db,
                    "finance_transactions",
                    existing_id,
                    action["owner_user_id"],
                    family_id=action["family_id"],
                )
                await db.execute(
                    "UPDATE finance_transactions SET account_id = ?, updated_at = ? "
                    "WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL",
                    (
                        target_account_id,
                        _now(),
                        existing_id,
                        action["household_space_id"],
                        action["family_id"],
                    ),
                )
        await _copy_link(
            db,
            action=action,
            source_type="transaction",
            source_id=source["id"],
            household_type="transaction",
            household_id=existing_id,
            accounting_treatment=accounting_treatment,
        )
        return existing_id

    account_id = target_account_id or await _shared_envelope_account(
        db, action=action, currency=source["currency"]
    )
    target_id = str(uuid.uuid4())
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_transactions
            (id, space_id, account_id, canonical_date, amount_minor, currency,
             state, transaction_kind, source_kind, source_group_id, description,
             cleaned_description, merchant_text, data_through_at, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'SHARED', ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            target_id,
            action["household_space_id"],
            account_id,
            source["canonical_date"],
            source["amount_minor"],
            source["currency"],
            source["state"],
            source["transaction_kind"],
            action["id"],
            source["description"],
            source["cleaned_description"],
            source["merchant_text"],
            source["data_through_at"],
            action["family_id"],
            now,
            now,
            action["owner_user_id"],
        ),
    )
    await _copy_link(
        db,
        action=action,
        source_type="transaction",
        source_id=source["id"],
        household_type="transaction",
        household_id=target_id,
        accounting_treatment=accounting_treatment,
    )

    if source["superseded_by_id"]:
        replacement_id = await _any_household_copy(
            db,
            action=action,
            source_type="transaction",
            source_id=source["superseded_by_id"],
            household_type="transaction",
        )
        if replacement_id:
            await db.execute(
                "UPDATE finance_transactions SET state = 'SUPERSEDED', "
                "superseded_by_id = ?, updated_at = ? WHERE id = ?",
                (replacement_id, now, target_id),
            )
    pending_rows = await (
        await db.execute(
            """
            SELECT id FROM finance_transactions
            WHERE space_id = ? AND superseded_by_id = ? AND deleted_at IS NULL
            """,
            (source["space_id"], source["id"]),
        )
    ).fetchall()
    for pending in pending_rows:
        shared_pending = await _any_household_copy(
            db,
            action=action,
            source_type="transaction",
            source_id=pending["id"],
            household_type="transaction",
        )
        if shared_pending:
            await save_history(
                db,
                "finance_transactions",
                shared_pending,
                action["owner_user_id"],
                family_id=action["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_transactions
                SET state = 'SUPERSEDED', superseded_by_id = ?, updated_at = ?
                WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (
                    target_id,
                    now,
                    shared_pending,
                    action["household_space_id"],
                    action["family_id"],
                ),
            )
    return target_id


async def _copy_neutral_relations_for_transaction(
    db, *, action: dict, source_transaction_id: str
) -> None:
    relations = await (
        await db.execute(
            """
            SELECT * FROM finance_transaction_relations
            WHERE space_id = ? AND family_id = ? AND status = 'CONFIRMED'
              AND relation_type IN (
                  'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG',
                  'REFUND', 'REIMBURSEMENT'
              )
              AND (from_transaction_id = ? OR to_transaction_id = ?)
              AND deleted_at IS NULL
            ORDER BY created_at, id
            """,
            (
                action["source_space_id"],
                action["family_id"],
                source_transaction_id,
                source_transaction_id,
            ),
        )
    ).fetchall()
    for relation_row in relations:
        relation = dict(relation_row)
        source_from = await _any_household_copy(
            db,
            action=action,
            source_type="transaction",
            source_id=relation["from_transaction_id"],
            household_type="transaction",
        )
        source_to = await _any_household_copy(
            db,
            action=action,
            source_type="transaction",
            source_id=relation["to_transaction_id"],
            household_type="transaction",
        )
        if source_from is None or source_to is None or source_from == source_to:
            continue
        existing = await (
            await db.execute(
                """
                SELECT id FROM finance_transaction_relations
                WHERE from_transaction_id = ? AND to_transaction_id = ?
                  AND relation_type = ? AND deleted_at IS NULL
                """,
                (source_from, source_to, relation["relation_type"]),
            )
        ).fetchone()
        if existing is None:
            target_relation_id = str(uuid.uuid4())
            now = _now()
            await db.execute(
                """
                INSERT INTO finance_transaction_relations
                    (id, space_id, from_transaction_id, to_transaction_id,
                     relation_type, status, method, confidence_bps, note,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, 'CONFIRMED', 'shared_confirmed', ?, NULL,
                        ?, ?, ?, ?)
                """,
                (
                    target_relation_id,
                    action["household_space_id"],
                    source_from,
                    source_to,
                    relation["relation_type"],
                    relation["confidence_bps"],
                    action["family_id"],
                    now,
                    now,
                    action["owner_user_id"],
                ),
            )
        else:
            target_relation_id = existing["id"]
            await save_history(
                db,
                "finance_transaction_relations",
                target_relation_id,
                action["owner_user_id"],
                family_id=action["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_transaction_relations
                SET status = 'CONFIRMED', method = 'shared_confirmed', updated_at = ?
                WHERE id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (_now(), target_relation_id, action["family_id"]),
            )
        await _copy_link(
            db,
            action=action,
            source_type="transaction_relation",
            source_id=relation["id"],
            household_type="transaction_relation",
            household_id=target_relation_id,
            accounting_treatment=(
                "NEUTRAL_TRANSFER"
                if relation["relation_type"]
                in {"INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT", "FX_LEG"}
                else relation["relation_type"]
            ),
        )


async def sync_shared_relation_review(
    db, *, user: dict, relation_id: str
) -> None:
    """Mirror reviewed accounting semantics onto existing household envelopes."""
    relation_row = await (
        await db.execute(
            """
            SELECT relation.* FROM finance_transaction_relations relation
            JOIN finance_spaces space
              ON space.id = relation.space_id
             AND space.family_id = relation.family_id
             AND space.deleted_at IS NULL
            WHERE relation.id = ? AND relation.family_id = ?
              AND relation.deleted_at IS NULL AND space.kind = 'personal'
              AND space.owner_user_id = ?
            """,
            (relation_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if relation_row is None:
        return
    relation = dict(relation_row)
    source_ids = (relation["from_transaction_id"], relation["to_transaction_id"])
    for source_id in source_ids:
        source_row = await (
            await db.execute(
                "SELECT * FROM finance_transactions WHERE id = ? AND space_id = ? "
                "AND family_id = ? AND deleted_at IS NULL",
                (source_id, relation["space_id"], user["family_id"]),
            )
        ).fetchone()
        if source_row is None:
            continue
        treatment = await _source_accounting_treatment(
            db, family_id=user["family_id"], source=dict(source_row)
        )
        links = await (
            await db.execute(
                """
                SELECT copy.id, copy.accounting_treatment
                FROM finance_share_copy_links copy
                JOIN finance_share_actions share
                  ON share.id = copy.share_action_id AND share.deleted_at IS NULL
                WHERE share.owner_user_id = ? AND copy.family_id = ?
                  AND copy.source_space_id = ?
                  AND copy.source_record_type = 'transaction'
                  AND copy.source_record_id = ? AND copy.deleted_at IS NULL
                """,
                (user["id"], user["family_id"], relation["space_id"], source_id),
            )
        ).fetchall()
        for link in links:
            if link["accounting_treatment"] == treatment:
                continue
            await save_history(
                db,
                "finance_share_copy_links",
                link["id"],
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                "UPDATE finance_share_copy_links SET accounting_treatment = ?, "
                "updated_at = ? WHERE id = ? AND family_id = ?",
                (treatment, _now(), link["id"], user["family_id"]),
            )

    actions = await (
        await db.execute(
            """
            SELECT DISTINCT share.* FROM finance_share_actions share
            JOIN finance_share_copy_links copy ON copy.share_action_id = share.id
            WHERE share.owner_user_id = ? AND share.family_id = ?
              AND copy.source_space_id = ?
              AND copy.source_record_type = 'transaction'
              AND copy.source_record_id IN (?, ?)
              AND share.deleted_at IS NULL AND copy.deleted_at IS NULL
            ORDER BY share.created_at, share.id
            """,
            (
                user["id"],
                user["family_id"],
                relation["space_id"],
                *source_ids,
            ),
        )
    ).fetchall()
    if relation["status"] == "CONFIRMED":
        for action in actions:
            await _copy_neutral_relations_for_transaction(
                db,
                action=dict(action),
                source_transaction_id=relation["from_transaction_id"],
            )
        return

    copied_relations = await (
        await db.execute(
            """
            SELECT DISTINCT copy.household_record_id
            FROM finance_share_copy_links copy
            JOIN finance_share_actions share
              ON share.id = copy.share_action_id AND share.deleted_at IS NULL
            WHERE share.owner_user_id = ? AND copy.family_id = ?
              AND copy.source_record_type = 'transaction_relation'
              AND copy.source_record_id = ? AND copy.deleted_at IS NULL
            """,
            (user["id"], user["family_id"], relation_id),
        )
    ).fetchall()
    for copied in copied_relations:
        await save_history(
            db,
            "finance_transaction_relations",
            copied["household_record_id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_transaction_relations
            SET status = 'REJECTED', updated_at = ?
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (_now(), copied["household_record_id"], user["family_id"]),
        )


async def _copy_balance(db, *, action: dict, source: dict, target_account_id: str) -> str:
    existing_id = await _any_household_copy(
        db,
        action=action,
        source_type="balance_snapshot",
        source_id=source["id"],
        household_type="balance_snapshot",
    )
    if existing_id is not None:
        return existing_id
    target_id = str(uuid.uuid4())
    now = _now()
    await db.execute(
        """
        INSERT INTO finance_balance_snapshots
            (id, space_id, account_id, booked_minor, available_minor,
             credit_limit_minor, currency, provider_at, observed_at, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            target_id,
            action["household_space_id"],
            target_account_id,
            source["booked_minor"],
            source["available_minor"],
            source["credit_limit_minor"],
            source["currency"],
            source["provider_at"],
            source["observed_at"],
            action["family_id"],
            now,
            now,
            action["owner_user_id"],
        ),
    )
    await _copy_link(
        db,
        action=action,
        source_type="balance_snapshot",
        source_id=source["id"],
        household_type="balance_snapshot",
        household_id=target_id,
    )
    return target_id


async def share_account(db, *, user: dict, account_id: str) -> FinanceShareResponse:
    personal_id, household_id = await _space_ids(db, user=user)
    source = await _owned_source(db, user=user, record_type="account", record_id=account_id)
    if source["space_id"] != personal_id:
        raise FinanceSharingNotFoundError("Finance account not found")
    async with serialized_create(db):
        action = await _ensure_direct_action(
            db,
            user=user,
            personal_space_id=personal_id,
            household_space_id=household_id,
            share_kind="ACCOUNT",
            source_record_type="account",
            source_record_id=account_id,
            active=True,
        )
        target_account_id = await _copy_account_row(db, action=action, source=source)
        transactions = await (
            await db.execute(
                """
                SELECT * FROM finance_transactions
                WHERE account_id = ? AND space_id = ? AND family_id = ?
                  AND deleted_at IS NULL ORDER BY canonical_date, created_at, id
                """,
                (account_id, personal_id, user["family_id"]),
            )
        ).fetchall()
        for transaction in transactions:
            await _copy_transaction(
                db,
                action=action,
                source=dict(transaction),
                target_account_id=target_account_id,
            )
        for transaction in transactions:
            await _copy_neutral_relations_for_transaction(
                db, action=action, source_transaction_id=transaction["id"]
            )
        balances = await (
            await db.execute(
                """
                SELECT * FROM finance_balance_snapshots
                WHERE account_id = ? AND space_id = ? AND family_id = ?
                  AND deleted_at IS NULL ORDER BY observed_at, created_at, id
                """,
                (account_id, personal_id, user["family_id"]),
            )
        ).fetchall()
        for balance in balances:
            await _copy_balance(
                db,
                action=action,
                source=dict(balance),
                target_account_id=target_account_id,
            )
    return await _share_response(db, await _action_by_id(db, action["id"]), user=user)


async def share_transaction(
    db, *, user: dict, transaction_id: str
) -> FinanceShareResponse:
    personal_id, household_id = await _space_ids(db, user=user)
    source = await _owned_source(
        db, user=user, record_type="transaction", record_id=transaction_id
    )
    if source["space_id"] != personal_id:
        raise FinanceSharingNotFoundError("Finance transaction not found")
    async with serialized_create(db):
        action = await _ensure_direct_action(
            db,
            user=user,
            personal_space_id=personal_id,
            household_space_id=household_id,
            share_kind="TRANSACTION",
            source_record_type="transaction",
            source_record_id=transaction_id,
        )
        target_id = action.get("household_record_id") or await _copy_transaction(
            db, action=action, source=source
        )
        await _copy_neutral_relations_for_transaction(
            db, action=action, source_transaction_id=source["id"]
        )
        if action.get("household_record_id") is None:
            await _set_action_household_record(
                db, action=action, record_type="transaction", record_id=target_id
            )
    return await _share_response(db, await _action_by_id(db, action["id"]), user=user)


async def _copy_purchase(
    db,
    *,
    action: dict,
    source: dict,
    selected_line_ids: list[str] | None,
    force_new: bool = False,
) -> str:
    if not force_new and action["share_kind"] != "RULE" and action.get("household_record_id"):
        return action["household_record_id"]
    if selected_line_ids is None and not force_new:
        existing_id = await _full_purchase_copy_id(
            db, action=action, source_purchase_id=source["id"]
        )
        if existing_id is not None:
            await _copy_link(
                db,
                action=action,
                source_type="purchase",
                source_id=source["id"],
                household_type="purchase",
                household_id=existing_id,
            )
            if action["share_kind"] != "RULE":
                await _set_action_household_record(
                    db, action=action, record_type="purchase", record_id=existing_id
                )
            return existing_id
    all_lines = await (
        await db.execute(
            """
            SELECT * FROM finance_purchase_lines
            WHERE purchase_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL ORDER BY line_position, id
            """,
            (source["id"], source["space_id"], action["family_id"]),
        )
    ).fetchall()
    lines = [dict(row) for row in all_lines]
    is_partial = selected_line_ids is not None
    if is_partial:
        selected = set(selected_line_ids)
        lines = [line for line in lines if line["id"] in selected]
        if {line["id"] for line in lines} != selected:
            raise FinanceSharingNotFoundError("One or more purchase lines were not found")
        if any(line["line_net_minor"] is None for line in lines):
            raise FinanceSharingConflictError(
                "Selected lines need exact amounts before they can be shared safely"
            )
    if not lines:
        raise FinanceSharingConflictError("A shared purchase must contain at least one line")

    source_id = str(uuid.uuid4())
    purchase_id = str(uuid.uuid4())
    now = _now()
    line_total = sum(int(line["line_net_minor"] or 0) for line in lines)
    if is_partial and line_total <= 0:
        raise FinanceSharingConflictError("Selected lines must have a positive shared total")
    source_payload = {
        "merchant": source["merchant_name"],
        "purchased_on": source["purchased_on"],
        "currency": source["currency"],
        "final_total_minor": line_total if is_partial else source["final_total_minor"],
        "lines": [
            {
                "description": line["raw_description"],
                "quantity": line["quantity_decimal"],
                "net_minor": line["line_net_minor"],
            }
            for line in lines
        ],
    }
    await db.execute(
        """
        INSERT INTO finance_purchase_sources
            (id, space_id, external_source_id, source_kind, parser_version,
             extraction_status, confidence_bps, raw_payload_json, issues_json,
             received_at, parsed_at, family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, 'natural_language', 'finance-sharing-v1', 'PARSED',
                10000, ?, '[]', ?, ?, ?, ?, ?, ?)
        """,
        (
            source_id,
            action["household_space_id"],
            f"share:{purchase_id}",
            json.dumps(source_payload, separators=(",", ":"), ensure_ascii=False),
            now,
            now,
            action["family_id"],
            now,
            now,
            action["owner_user_id"],
        ),
    )
    refund_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_line_refunds
            WHERE purchase_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            """,
            (source["id"], source["space_id"], action["family_id"]),
        )
    ).fetchall()
    refunds_by_line: dict[str, list[dict]] = {}
    for refund in refund_rows:
        refunds_by_line.setdefault(refund["line_id"], []).append(dict(refund))
    refunded = sum(
        refund["amount_minor"]
        for line in lines
        for refund in refunds_by_line.get(line["id"], [])
    )
    final_total = line_total if is_partial else source["final_total_minor"]
    if is_partial and refunded > final_total:
        raise FinanceSharingConflictError(
            "Selected-line refunds exceed the self-contained shared total"
        )
    if is_partial:
        shared_status = (
            "refunded"
            if refunded == final_total and refunded > 0
            else "partly_refunded"
            if refunded > 0
            else "fulfilled"
        )
    else:
        shared_status = source["status"]
    await db.execute(
        """
        INSERT INTO finance_purchase_records
            (id, space_id, source_id, purchase_ref, merchant_name,
             external_order_reference, purchased_on, currency,
             lines_subtotal_minor, shipping_minor, vat_included_minor,
             order_discount_minor, final_total_minor, refunded_minor, status,
             source_kind, extraction_confidence_bps, family_id, created_at,
             updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                'natural_language', 10000, ?, ?, ?, ?)
        """,
        (
            purchase_id,
            action["household_space_id"],
            source_id,
            f"share:{purchase_id}",
            source["merchant_name"],
            None if is_partial else source["external_order_reference"],
            source["purchased_on"],
            source["currency"],
            line_total if is_partial else source["lines_subtotal_minor"],
            0 if is_partial else source["shipping_minor"],
            0 if is_partial else source["vat_included_minor"],
            0 if is_partial else source["order_discount_minor"],
            final_total,
            refunded,
            shared_status,
            action["family_id"],
            now,
            now,
            action["owner_user_id"],
        ),
    )
    for position, line in enumerate(lines):
        target_line_id = str(uuid.uuid4())
        line_ref = f"shared-line-{position + 1}"
        await db.execute(
            """
            INSERT INTO finance_purchase_lines
                (id, space_id, source_id, purchase_id, source_line_reference,
                 line_position, line_kind, raw_description, quantity_decimal,
                 unit_description, unit_price_minor, line_gross_minor,
                 line_discount_minor, line_net_minor, evidence_status,
                 source_refs_json, seller, product_reference,
                 replaces_description, shipment_reference, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'user_confirmed',
                    '[]', ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                target_line_id,
                action["household_space_id"],
                source_id,
                purchase_id,
                line_ref,
                position,
                line["line_kind"],
                line["raw_description"],
                line["quantity_decimal"],
                line["unit_description"],
                line["unit_price_minor"],
                line["line_gross_minor"],
                line["line_discount_minor"],
                line["line_net_minor"],
                line["seller"],
                line["product_reference"],
                line["replaces_description"],
                # Parcel references remain private source evidence even when the
                # adult deliberately shares the observed purchase line.
                None,
                action["family_id"],
                now,
                now,
                action["owner_user_id"],
            ),
        )
        await _copy_link(
            db,
            action=action,
            source_type="purchase_line",
            source_id=line["id"],
            household_type="purchase_line",
            household_id=target_line_id,
        )
        for refund in refunds_by_line.get(line["id"], []):
            await db.execute(
                """
                INSERT INTO finance_line_refunds
                    (id, space_id, source_id, purchase_id, line_id, refund_ref,
                     amount_minor, quantity_decimal, source_refs_json, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, '[]', ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    action["household_space_id"],
                    source_id,
                    purchase_id,
                    target_line_id,
                    f"shared-refund-{uuid.uuid4()}",
                    refund["amount_minor"],
                    refund["quantity_decimal"],
                    action["family_id"],
                    now,
                    now,
                    action["owner_user_id"],
                ),
            )
    await _copy_link(
        db,
        action=action,
        source_type="purchase",
        source_id=source["id"],
        household_type="purchase",
        household_id=purchase_id,
    )
    if action["share_kind"] != "RULE":
        await _set_action_household_record(
            db, action=action, record_type="purchase", record_id=purchase_id
        )

    if source["supersedes_purchase_id"]:
        previous_id = await _full_purchase_copy_id(
            db,
            action=action,
            source_purchase_id=source["supersedes_purchase_id"],
        )
        if previous_id:
            await save_history(
                db,
                "finance_purchase_records",
                previous_id,
                action["owner_user_id"],
                family_id=action["family_id"],
            )
            await db.execute(
                "UPDATE finance_purchase_records SET superseded_by_id = ?, updated_at = ? "
                "WHERE id = ? AND family_id = ?",
                (purchase_id, now, previous_id, action["family_id"]),
            )
            await db.execute(
                "UPDATE finance_purchase_records SET supersedes_purchase_id = ?, updated_at = ? "
                "WHERE id = ? AND family_id = ?",
                (previous_id, now, purchase_id, action["family_id"]),
            )
    return purchase_id


async def _full_purchase_copy_id(
    db, *, action: dict, source_purchase_id: str
) -> str | None:
    """Find only a prior full-purchase copy, never a selected-line copy."""
    row = await (
        await db.execute(
            """
            SELECT link.household_record_id
            FROM finance_share_copy_links link
            JOIN finance_share_actions share
              ON share.id = link.share_action_id AND share.deleted_at IS NULL
            JOIN finance_purchase_records purchase
              ON purchase.id = link.household_record_id AND purchase.deleted_at IS NULL
            WHERE link.source_space_id = ? AND link.source_record_type = 'purchase'
              AND link.source_record_id = ? AND link.household_space_id = ?
              AND link.household_record_type = 'purchase'
              AND share.share_kind IN ('PURCHASE', 'RULE')
              AND share.selection_json = '[]' AND link.family_id = ?
              AND link.deleted_at IS NULL
            ORDER BY link.created_at, link.id LIMIT 1
            """,
            (
                action["source_space_id"],
                source_purchase_id,
                action["household_space_id"],
                action["family_id"],
            ),
        )
    ).fetchone()
    return row["household_record_id"] if row is not None else None


async def share_purchase(
    db,
    *,
    user: dict,
    purchase_id: str,
    body: FinancePurchaseShareCreate,
) -> FinanceShareResponse:
    personal_id, household_id = await _space_ids(db, user=user)
    source = await _owned_source(db, user=user, record_type="purchase", record_id=purchase_id)
    if source["space_id"] != personal_id:
        raise FinanceSharingNotFoundError("Finance purchase not found")
    selected = body.line_ids if body.mode == "SELECTED_LINES" else []
    selection_json, digest = _selection(selected)
    share_kind = "PURCHASE_LINES" if selected else "PURCHASE"
    async with serialized_create(db):
        action = await _ensure_direct_action(
            db,
            user=user,
            personal_space_id=personal_id,
            household_space_id=household_id,
            share_kind=share_kind,
            source_record_type="purchase",
            source_record_id=purchase_id,
            selection_json=selection_json,
            selection_digest=digest,
        )
        await _copy_purchase(
            db,
            action=action,
            source=source,
            selected_line_ids=selected if selected else None,
        )
    return await _share_response(db, await _action_by_id(db, action["id"]), user=user)


async def _copy_planning_record(
    db,
    *,
    action: dict,
    source: dict,
    record_type: str,
    force_new: bool = False,
) -> str:
    if action.get("household_record_id") and not force_new:
        return action["household_record_id"]
    target_id = str(uuid.uuid4())
    now = _now()
    if record_type == "commitment":
        responsible_user_id = source.get("responsible_user_id")
        if responsible_user_id is not None:
            responsible = await (
                await db.execute(
                    "SELECT id FROM users WHERE id = ? AND family_id = ? "
                    "AND deleted_at IS NULL",
                    (responsible_user_id, action["family_id"]),
                )
            ).fetchone()
            if responsible is None:
                raise FinanceSharingConflictError(
                    "The responsible family member is no longer available"
                )
        if source.get("show_in_tasks") and responsible_user_id is None:
            raise FinanceSharingConflictError(
                "A shared commitment task needs a responsible family member"
            )
        await db.execute(
            """
            INSERT INTO finance_commitments
                (id, space_id, name, amount_mode, exact_minor, expected_minor,
                 low_minor, high_minor, currency, recurrence, reviewed_dates_json,
                 priority, funding_account_id, already_reserved_minor, status,
                 payment_handling, show_in_calendar, show_in_tasks,
                 responsible_user_id, notes, family_id, created_at, updated_at,
                 created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                target_id,
                action["household_space_id"],
                source["name"],
                source["amount_mode"],
                source["exact_minor"],
                source["expected_minor"],
                source["low_minor"],
                source["high_minor"],
                source["currency"],
                source["recurrence"],
                source["reviewed_dates_json"],
                source["priority"],
                source["status"],
                source.get("payment_handling") or "UNSPECIFIED",
                int(bool(source.get("show_in_calendar"))),
                int(bool(source.get("show_in_tasks"))),
                responsible_user_id,
                source["notes"],
                action["family_id"],
                now,
                now,
                action["owner_user_id"],
            ),
        )
    else:
        await db.execute(
            """
            INSERT INTO finance_goals
                (id, space_id, name, target_minor, deadline,
                 currently_allocated_minor, currency, priority,
                 allowed_funding_sources_json, emergency_buffer_minor, status,
                 notes, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?, '[]', ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                target_id,
                action["household_space_id"],
                source["name"],
                source["target_minor"],
                source["deadline"],
                source["currency"],
                source["priority"],
                source["emergency_buffer_minor"],
                source["status"],
                source["notes"],
                action["family_id"],
                now,
                now,
                action["owner_user_id"],
            ),
        )
    await _copy_link(
        db,
        action=action,
        source_type=record_type,
        source_id=source["id"],
        household_type=record_type,
        household_id=target_id,
    )
    await _set_action_household_record(
        db, action=action, record_type=record_type, record_id=target_id
    )
    return target_id


async def share_planning_record(
    db, *, user: dict, record_type: str, record_id: str
) -> FinanceShareResponse:
    personal_id, household_id = await _space_ids(db, user=user)
    source = await _owned_source(
        db, user=user, record_type=record_type, record_id=record_id
    )
    if source["space_id"] != personal_id:
        raise FinanceSharingNotFoundError(f"Finance {record_type} not found")
    share_kind = record_type.upper()
    async with serialized_create(db):
        action = await _ensure_direct_action(
            db,
            user=user,
            personal_space_id=personal_id,
            household_space_id=household_id,
            share_kind=share_kind,
            source_record_type=record_type,
            source_record_id=record_id,
        )
        await _copy_planning_record(
            db, action=action, source=source, record_type=record_type
        )
    return await _share_response(db, await _action_by_id(db, action["id"]), user=user)


async def declare_contribution(
    db, *, user: dict, body: FinanceContributionCreate
) -> FinanceShareResponse:
    personal_id, household_id = await _space_ids(db, user=user)
    contribution_id = str(body.id)
    now = _now()
    async with serialized_create(db):
        action = await _ensure_direct_action(
            db,
            user=user,
            personal_space_id=personal_id,
            household_space_id=household_id,
            share_kind="CONTRIBUTION",
            source_record_type="contribution_request",
            source_record_id=contribution_id,
            selection_json=json.dumps(
                {
                    "amount_minor": body.amount_minor,
                    "contribution_date": body.contribution_date.isoformat(),
                    "currency": body.currency,
                },
                sort_keys=True,
                separators=(",", ":"),
            ),
            selection_digest="",
        )
        if action.get("household_record_id"):
            persisted = await (
                await db.execute(
                    """
                    SELECT amount_minor, currency, contribution_date
                    FROM finance_declared_contributions
                    WHERE id = ? AND space_id = ? AND family_id = ?
                      AND deleted_at IS NULL
                    """,
                    (contribution_id, household_id, user["family_id"]),
                )
            ).fetchone()
            if persisted is None:
                raise FinanceSharingConflictError(
                    "Contribution replay is missing its household record"
                )
            if (
                persisted["amount_minor"] != body.amount_minor
                or persisted["currency"] != body.currency
                or persisted["contribution_date"]
                != body.contribution_date.isoformat()
            ):
                raise FinanceSharingConflictError(
                    "Contribution ID was reused for different values"
                )
            return await _share_response(db, action, user=user)
        existing = await (
            await db.execute(
                "SELECT id FROM finance_declared_contributions WHERE id = ?",
                (contribution_id,),
            )
        ).fetchone()
        if existing is not None:
            raise FinanceSharingConflictError("Contribution ID is already in use")
        await db.execute(
            """
            INSERT INTO finance_declared_contributions
                (id, space_id, amount_minor, currency, contribution_date,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                contribution_id,
                household_id,
                body.amount_minor,
                body.currency,
                body.contribution_date.isoformat(),
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        await _set_action_household_record(
            db, action=action, record_type="contribution", record_id=contribution_id
        )
    return await _share_response(db, await _action_by_id(db, action["id"]), user=user)


async def list_contributions(
    db, *, user: dict, space_id: str
) -> list[FinanceContributionResponse]:
    _, household_id = await _space_ids(db, user=user)
    if space_id != household_id:
        raise FinanceSharingNotFoundError("Household contributions are not available in this space")
    rows = await (
        await db.execute(
            """
            SELECT id, space_id, amount_minor, currency, contribution_date,
                   label, status, created_at
            FROM finance_declared_contributions
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY contribution_date DESC, created_at DESC, id
            """,
            (household_id, user["family_id"]),
        )
    ).fetchall()
    return [FinanceContributionResponse(**dict(row)) for row in rows]


async def create_share_rule(
    db, *, user: dict, body: FinanceShareRuleCreate
) -> FinanceShareResponse:
    personal_id, household_id = await _space_ids(db, user=user)
    match_value = clean_description(body.merchant)
    if not match_value:
        raise FinanceSharingConflictError("Merchant rule must contain letters or numbers")
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_share_actions
                WHERE owner_user_id = ? AND source_space_id = ?
                  AND share_kind = 'RULE' AND rule_target = ?
                  AND rule_match_kind = 'MERCHANT' AND rule_match_value = ?
                  AND family_id = ? AND deleted_at IS NULL
                """,
                (
                    user["id"],
                    personal_id,
                    body.target,
                    match_value,
                    user["family_id"],
                ),
            )
        ).fetchone()
        if existing is not None:
            action = dict(existing)
            if action["status"] == "STOPPED":
                now = _now()
                await save_history(
                    db,
                    "finance_share_actions",
                    action["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    "UPDATE finance_share_actions SET status = 'ACTIVE', stopped_at = NULL, "
                    "updated_at = ? WHERE id = ? AND owner_user_id = ?",
                    (now, action["id"], user["id"]),
                )
        else:
            action_id = str(uuid.uuid4())
            now = _now()
            await db.execute(
                """
                INSERT INTO finance_share_actions
                    (id, owner_user_id, source_space_id, household_space_id,
                     share_kind, selection_json, selection_digest, rule_target,
                     rule_match_kind, rule_match_value, status, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, 'RULE', '[]', '', ?, 'MERCHANT', ?,
                        'ACTIVE', ?, ?, ?, ?)
                """,
                (
                    action_id,
                    user["id"],
                    personal_id,
                    household_id,
                    body.target,
                    match_value,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
            action = await _action_by_id(db, action_id)
    return await _share_response(db, await _action_by_id(db, action["id"]), user=user)


async def preview_share(
    db, *, user: dict, body: FinanceSharePreviewRequest
) -> FinanceSharePreviewResponse:
    """Describe exactly what the caller would share, without returning its private ID."""
    personal_id, household_id = await _space_ids(db, user=user)
    record_type = body.kind.lower()
    source = await _owned_source(
        db, user=user, record_type=record_type, record_id=body.source_record_id
    )
    if source["space_id"] != personal_id:
        raise FinanceSharingNotFoundError("Finance record not found")
    selected = body.purchase.line_ids if body.purchase and body.purchase.mode == "SELECTED_LINES" else []
    selection_json, digest = _selection(selected)
    share_kind = "PURCHASE_LINES" if body.kind == "PURCHASE" and selected else body.kind
    pseudo = {
        "id": "",
        "share_kind": share_kind,
        "status": "COMPLETED" if share_kind not in _FUTURE_KINDS else "ACTIVE",
        "source_record_type": record_type,
        "source_record_id": body.source_record_id,
        "selection_json": selection_json,
        "selection_digest": digest,
        "rule_target": None,
        "rule_match_kind": None,
        "rule_match_value": None,
        "household_record_type": None,
        "household_record_id": None,
        "created_at": _now(),
        "updated_at": source["updated_at"],
        "stopped_at": None,
    }
    display = await _share_display(db, row=pseudo, user=user)
    existing = await (
        await db.execute(
            """
            SELECT * FROM finance_share_actions
            WHERE owner_user_id = ? AND source_space_id = ? AND household_space_id = ?
              AND share_kind = ? AND source_record_id = ? AND selection_digest = ?
              AND family_id = ? AND deleted_at IS NULL
            """,
            (
                user["id"], personal_id, household_id, share_kind,
                body.source_record_id, digest, user["family_id"],
            ),
        )
    ).fetchone()
    return FinanceSharePreviewResponse(
        kind=share_kind,
        label=display["label"],
        included=display["included"],
        sharing_mode=display["sharing_mode"],
        applies_to_future=share_kind in _FUTURE_KINDS,
        source_updated_at=display["source_updated_at"],
        existing_share=(
            await _share_response(db, dict(existing), user=user) if existing else None
        ),
    )


async def _soft_delete_rows(
    db, *, table: str, ids: list[str], action: dict, now: str
) -> None:
    for record_id in ids:
        await save_history(
            db, table, record_id, action["owner_user_id"], family_id=action["family_id"]
        )
        await db.execute(
            f"UPDATE {table} SET deleted_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (now, now, record_id, action["family_id"]),
        )


async def _retire_shared_version(db, *, action: dict) -> None:
    """Soft-delete only this action's old household copy before replacing it."""
    target_id = action.get("household_record_id")
    target_type = action.get("household_record_type")
    if not target_id or target_type not in _SOURCE_TABLES:
        raise FinanceSharingConflictError("The shared version cannot be replaced")
    now = _now()
    if target_type == "transaction":
        split_rows = await (
            await db.execute(
                "SELECT id FROM finance_transaction_splits WHERE transaction_id = ? AND family_id = ? "
                "AND deleted_at IS NULL",
                (target_id, action["family_id"]),
            )
        ).fetchall()
        relation_rows = await (
            await db.execute(
                "SELECT id FROM finance_transaction_relations WHERE family_id = ? "
                "AND (from_transaction_id = ? OR to_transaction_id = ?) "
                "AND deleted_at IS NULL",
                (action["family_id"], target_id, target_id),
            )
        ).fetchall()
        await _soft_delete_rows(db, table="finance_transaction_splits", ids=[row["id"] for row in split_rows], action=action, now=now)
        await _soft_delete_rows(db, table="finance_transaction_relations", ids=[row["id"] for row in relation_rows], action=action, now=now)
    elif target_type == "purchase":
        purchase = await (
            await db.execute(
                "SELECT source_id FROM finance_purchase_records WHERE id = ? "
                "AND family_id = ? AND space_id = ? AND deleted_at IS NULL",
                (target_id, action["family_id"], action["household_space_id"]),
            )
        ).fetchone()
        line_rows = await (
            await db.execute(
                "SELECT id FROM finance_purchase_lines WHERE purchase_id = ? "
                "AND family_id = ? AND deleted_at IS NULL",
                (target_id, action["family_id"]),
            )
        ).fetchall()
        line_ids = [row["id"] for row in line_rows]
        refund_rows = []
        if line_ids:
            marks = ",".join("?" for _ in line_ids)
            refund_rows = await (
                await db.execute(
                    f"SELECT id FROM finance_line_refunds WHERE line_id IN ({marks}) "
                    "AND family_id = ? AND deleted_at IS NULL",
                    (*line_ids, action["family_id"]),
                )
            ).fetchall()
        await _soft_delete_rows(db, table="finance_line_refunds", ids=[row["id"] for row in refund_rows], action=action, now=now)
        await _soft_delete_rows(db, table="finance_purchase_lines", ids=line_ids, action=action, now=now)
        if purchase and purchase["source_id"]:
            await _soft_delete_rows(db, table="finance_purchase_sources", ids=[purchase["source_id"]], action=action, now=now)
    await _soft_delete_rows(
        db, table=_SOURCE_TABLES[target_type], ids=[target_id], action=action, now=now
    )
    link_rows = await (
        await db.execute(
            "SELECT id FROM finance_share_copy_links WHERE share_action_id = ? "
            "AND family_id = ? AND deleted_at IS NULL",
            (action["id"], action["family_id"]),
        )
    ).fetchall()
    await _soft_delete_rows(db, table="finance_share_copy_links", ids=[row["id"] for row in link_rows], action=action, now=now)
    await save_history(
        db,
        "finance_share_actions",
        action["id"],
        action["owner_user_id"],
        family_id=action["family_id"],
    )
    await db.execute(
        "UPDATE finance_share_actions SET household_record_type = NULL, "
        "household_record_id = NULL, updated_at = ? WHERE id = ? "
        "AND owner_user_id = ? AND family_id = ? AND deleted_at IS NULL",
        (now, action["id"], action["owner_user_id"], action["family_id"]),
    )
    action["household_record_type"] = None
    action["household_record_id"] = None


async def replace_shared_version(
    db, *, user: dict, share_id: str
) -> FinanceShareResponse:
    """Replace a stale one-off household copy with the current private values."""
    require_finance_access(user)
    async with serialized_create(db):
        row = await (
            await db.execute(
                """
                SELECT * FROM finance_share_actions
                WHERE id = ? AND owner_user_id = ? AND family_id = ?
                  AND deleted_at IS NULL
                """,
                (share_id, user["id"], user["family_id"]),
            )
        ).fetchone()
        if row is None:
            raise FinanceSharingNotFoundError("Finance share action not found")
        action = dict(row)
        if action["share_kind"] not in {"TRANSACTION", "PURCHASE", "PURCHASE_LINES", "COMMITMENT", "GOAL"}:
            raise FinanceSharingConflictError("Only a one-off shared copy can be replaced")
        record_type = action["source_record_type"]
        source = await _owned_source(
            db,
            user=user,
            record_type=record_type,
            record_id=action["source_record_id"],
        )
        await _retire_shared_version(db, action=action)
        if action["share_kind"] == "TRANSACTION":
            target_id = await _copy_transaction(db, action=action, source=source, force_new=True)
            await _set_action_household_record(db, action=action, record_type="transaction", record_id=target_id)
            await _copy_neutral_relations_for_transaction(db, action=action, source_transaction_id=source["id"])
        elif action["share_kind"] in {"PURCHASE", "PURCHASE_LINES"}:
            selected = json.loads(action["selection_json"] or "[]")
            await _copy_purchase(
                db,
                action=action,
                source=source,
                selected_line_ids=selected if action["share_kind"] == "PURCHASE_LINES" else None,
                force_new=True,
            )
        else:
            await _copy_planning_record(
                db,
                action=action,
                source=source,
                record_type=record_type,
                force_new=True,
            )
    return await _share_response(db, await _action_by_id(db, share_id), user=user)


async def list_share_actions(db, *, user: dict) -> list[FinanceShareResponse]:
    require_finance_access(user)
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_share_actions
            WHERE owner_user_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY created_at DESC, id DESC
            """,
            (user["id"], user["family_id"]),
        )
    ).fetchall()
    return [await _share_response(db, dict(row), user=user) for row in rows]


async def stop_share_action(
    db, *, user: dict, share_id: str
) -> FinanceShareResponse:
    require_finance_access(user)
    async with serialized_create(db):
        row = await (
            await db.execute(
                """
                SELECT * FROM finance_share_actions
                WHERE id = ? AND owner_user_id = ? AND family_id = ?
                  AND deleted_at IS NULL
                """,
                (share_id, user["id"], user["family_id"]),
            )
        ).fetchone()
        if row is None:
            raise FinanceSharingNotFoundError("Finance share action not found")
        action = dict(row)
        if action["share_kind"] not in _FUTURE_KINDS:
            raise FinanceSharingConflictError(
                "This share has no future updates to stop; its household copy is historical"
            )
        if action["status"] == "ACTIVE":
            now = _now()
            await save_history(
                db,
                "finance_share_actions",
                share_id,
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_share_actions
                SET status = 'STOPPED', stopped_at = ?, updated_at = ?
                WHERE id = ? AND owner_user_id = ? AND family_id = ?
                """,
                (now, now, share_id, user["id"], user["family_id"]),
            )
    return await _share_response(db, await _action_by_id(db, share_id), user=user)


def _merchant_matches(rule_value: str, merchant: str | None, description: str) -> bool:
    candidate = clean_description(merchant or description)
    # A saved rule is an exact normalized merchant label, not a substring
    # classifier.  `Tesco` must not silently broaden to Tesco Mobile/Insurance.
    return bool(candidate and candidate == rule_value)


async def apply_transaction_share_rules(
    db, *, user: dict, transaction_id: str
) -> None:
    """Copy one newly-created personal transaction for active account/rule shares."""
    require_finance_access(user)
    row = await (
        await db.execute(
            "SELECT * FROM finance_transactions WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (transaction_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        return
    source = dict(row)
    actions = await (
        await db.execute(
            """
            SELECT * FROM finance_share_actions
            WHERE owner_user_id = ? AND source_space_id = ? AND family_id = ?
              AND status = 'ACTIVE' AND share_kind IN ('ACCOUNT', 'RULE')
              AND updated_at <= ? AND deleted_at IS NULL
            ORDER BY created_at, id
            """,
            (user["id"], source["space_id"], user["family_id"], source["created_at"]),
        )
    ).fetchall()
    async with serialized_create(db):
        for raw_action in actions:
            action = dict(raw_action)
            target_account_id = None
            if action["share_kind"] == "ACCOUNT":
                if action["source_record_id"] != source["account_id"]:
                    continue
                target_account_id = action["household_record_id"]
                source_account = await (
                    await db.execute(
                        "SELECT * FROM finance_accounts WHERE id = ? AND space_id = ? "
                        "AND family_id = ? AND deleted_at IS NULL",
                        (
                            source["account_id"],
                            source["space_id"],
                            user["family_id"],
                        ),
                    )
                ).fetchone()
                if source_account is not None:
                    await _update_shared_account_metadata(
                        db, action=action, source=dict(source_account)
                    )
            elif action["rule_target"] != "TRANSACTION" or not _merchant_matches(
                action["rule_match_value"], source["merchant_text"], source["description"]
            ):
                continue
            await _copy_transaction(
                db,
                action=action,
                source=source,
                target_account_id=target_account_id,
            )
            await _copy_neutral_relations_for_transaction(
                db, action=action, source_transaction_id=source["id"]
            )


async def apply_balance_share_rules(db, *, user: dict, balance_id: str) -> None:
    require_finance_access(user)
    row = await (
        await db.execute(
            "SELECT * FROM finance_balance_snapshots WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (balance_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        return
    source = dict(row)
    actions = await (
        await db.execute(
            """
            SELECT * FROM finance_share_actions
            WHERE owner_user_id = ? AND source_space_id = ? AND family_id = ?
              AND share_kind = 'ACCOUNT' AND source_record_id = ?
              AND status = 'ACTIVE' AND updated_at <= ? AND deleted_at IS NULL
            """,
            (
                user["id"],
                source["space_id"],
                user["family_id"],
                source["account_id"],
                source["created_at"],
            ),
        )
    ).fetchall()
    async with serialized_create(db):
        for raw_action in actions:
            action = dict(raw_action)
            source_account = await (
                await db.execute(
                    "SELECT * FROM finance_accounts WHERE id = ? AND space_id = ? "
                    "AND family_id = ? AND deleted_at IS NULL",
                    (
                        source["account_id"],
                        source["space_id"],
                        user["family_id"],
                    ),
                )
            ).fetchone()
            if source_account is not None:
                await _update_shared_account_metadata(
                    db, action=action, source=dict(source_account)
                )
            await _copy_balance(
                db,
                action=action,
                source=source,
                target_account_id=action["household_record_id"],
            )


async def apply_account_metadata_share(db, *, user: dict, account_id: str) -> None:
    require_finance_access(user)
    row = await (
        await db.execute(
            "SELECT * FROM finance_accounts WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (account_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        return
    source = dict(row)
    actions = await (
        await db.execute(
            """
            SELECT * FROM finance_share_actions
            WHERE owner_user_id = ? AND source_space_id = ? AND family_id = ?
              AND share_kind = 'ACCOUNT' AND source_record_id = ?
              AND status = 'ACTIVE' AND deleted_at IS NULL
            """,
            (user["id"], source["space_id"], user["family_id"], account_id),
        )
    ).fetchall()
    async with serialized_create(db):
        for raw_action in actions:
            await _update_shared_account_metadata(
                db, action=dict(raw_action), source=source
            )


async def apply_purchase_share_rules(db, *, user: dict, purchase_id: str) -> None:
    """Copy one newly-created personal purchase for active merchant rules."""
    require_finance_access(user)
    row = await (
        await db.execute(
            "SELECT * FROM finance_purchase_records WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (purchase_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        return
    source = dict(row)
    actions = await (
        await db.execute(
            """
            SELECT * FROM finance_share_actions
            WHERE owner_user_id = ? AND source_space_id = ? AND family_id = ?
              AND share_kind = 'RULE' AND rule_target = 'PURCHASE'
              AND status = 'ACTIVE' AND updated_at <= ? AND deleted_at IS NULL
            ORDER BY created_at, id
            """,
            (user["id"], source["space_id"], user["family_id"], source["created_at"]),
        )
    ).fetchall()
    async with serialized_create(db):
        for raw_action in actions:
            action = dict(raw_action)
            if _merchant_matches(
                action["rule_match_value"], source["merchant_name"], source["merchant_name"]
            ):
                await _copy_purchase(
                    db, action=action, source=source, selected_line_ids=None
                )

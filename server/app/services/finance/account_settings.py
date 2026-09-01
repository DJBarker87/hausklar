"""Authorised account-purpose and direct-spend settings."""

from datetime import datetime, timezone

from app.models.finance import FinanceAccountResponse
from app.models.finance_account_settings import FinanceAccountSettingsUpdate
from app.services.finance.foundation import require_finance_space
from app.services.finance.ledger import list_finance_accounts
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

_DIRECT_SPEND_ACCOUNT_TYPES = {"CURRENT", "SAVINGS", "CASH"}
_DIRECT_SPEND_PURPOSES = {"OPERATING_CURRENT", "SAVINGS", "GOAL"}
_PURPOSES_BY_ACCOUNT_TYPE = {
    "CURRENT": {"OPERATING_CURRENT", "SAVINGS", "GOAL", "IGNORED"},
    "SAVINGS": {"OPERATING_CURRENT", "SAVINGS", "GOAL", "IGNORED"},
    "CASH": {"OPERATING_CURRENT", "SAVINGS", "GOAL", "IGNORED"},
    "CREDIT_CARD": {"CREDIT_CARD", "IGNORED"},
    "INVESTMENT": {"INVESTMENT_LIKE", "IGNORED"},
    "CRYPTO": {"INVESTMENT_LIKE", "IGNORED"},
}


class FinanceAccountSettingsError(ValueError):
    """An account settings update would violate Finance invariants."""


class FinanceAccountSettingsNotFoundError(FinanceAccountSettingsError):
    """The account is not visible in the selected space."""


async def update_finance_account_settings(
    db,
    *,
    user: dict,
    space_id: str,
    account_id: str,
    body: FinanceAccountSettingsUpdate,
) -> FinanceAccountResponse:
    """Update user-owned settings without changing provider account facts."""
    await require_finance_space(db, user=user, space_id=space_id)
    async with serialized_create(db):
        row = await (
            await db.execute(
                """
                SELECT account.*, connection.status AS connection_status
                FROM finance_accounts account
                LEFT JOIN finance_connections connection
                  ON connection.id = account.connection_id
                 AND connection.family_id = account.family_id
                 AND connection.deleted_at IS NULL
                WHERE account.id = ? AND account.space_id = ?
                  AND account.family_id = ? AND account.deleted_at IS NULL
                """,
                (account_id, space_id, user["family_id"]),
            )
        ).fetchone()
        if row is None:
            raise FinanceAccountSettingsNotFoundError("Finance account not found")
        account = dict(row)
        if account.get("provider_presence_status") == "OMITTED":
            raise FinanceAccountSettingsError(
                "This provider account is disconnected from the latest complete account list"
            )
        values = body.model_dump(exclude_unset=True)
        proposed_purpose = values.get("purpose", account["purpose"])
        proposed_default = values.get(
            "primary_spending_account",
            bool(account["primary_spending_account"]),
        )
        proposed_include_in_cashflow = values.get(
            "include_in_cashflow", bool(account["include_in_cashflow"])
        )
        if proposed_purpose not in _PURPOSES_BY_ACCOUNT_TYPE[account["account_type"]]:
            raise FinanceAccountSettingsError(
                "Account purpose is incompatible with the account type"
            )
        explicitly_preserves_default = values.get("primary_spending_account") is True
        if proposed_default and not proposed_include_in_cashflow:
            if explicitly_preserves_default:
                raise FinanceAccountSettingsError(
                    "Default direct-spend account must remain included in cashflow"
                )
            proposed_default = False
            values["primary_spending_account"] = False
        if (
            proposed_default
            and proposed_purpose not in _DIRECT_SPEND_PURPOSES
            and not explicitly_preserves_default
        ):
            proposed_default = False
            values["primary_spending_account"] = False
        if proposed_default and not _eligible_for_direct_spend(
            account,
            purpose=proposed_purpose,
            include_in_cashflow=proposed_include_in_cashflow,
        ):
            raise FinanceAccountSettingsError(
                "Default direct-spend account must be an active cash account"
            )

        proposed = {
            "label": values.get("label", account["label"]),
            "purpose": proposed_purpose,
            "include_in_cashflow": proposed_include_in_cashflow,
            "include_in_net_worth": values.get(
                "include_in_net_worth", bool(account["include_in_net_worth"])
            ),
            "primary_spending_account": proposed_default,
            "minimum_balance_minor": values.get(
                "minimum_balance_minor", account["minimum_balance_minor"]
            ),
            "card_paid_in_full": values.get(
                "card_paid_in_full", bool(account["card_paid_in_full"])
            ),
            "card_settlement_account_id": values.get(
                "card_settlement_account_id", account["card_settlement_account_id"]
            ),
            "card_statement_close_day": values.get(
                "card_statement_close_day", account["card_statement_close_day"]
            ),
            "card_repayment_day": values.get("card_repayment_day", account["card_repayment_day"]),
        }
        card_fields = {
            "card_paid_in_full",
            "card_settlement_account_id",
            "card_statement_close_day",
            "card_repayment_day",
        }
        if card_fields & values.keys() and account["account_type"] != "CREDIT_CARD":
            raise FinanceAccountSettingsError(
                "Card repayment settings can only be saved on a credit-card account"
            )
        if account["account_type"] == "CREDIT_CARD":
            if not proposed["card_paid_in_full"]:
                proposed.update(
                    card_settlement_account_id=None,
                    card_statement_close_day=None,
                    card_repayment_day=None,
                )
            else:
                if any(
                    proposed[field] is None
                    for field in (
                        "card_settlement_account_id",
                        "card_statement_close_day",
                        "card_repayment_day",
                    )
                ):
                    raise FinanceAccountSettingsError(
                        "Full card repayment needs a settlement account, statement close day, and repayment day"
                    )
                settlement = await (
                    await db.execute(
                        """
                        SELECT id FROM finance_accounts
                        WHERE id = ? AND id != ? AND space_id = ? AND family_id = ?
                          AND currency = ? AND include_in_cashflow = 1
                          AND account_type IN ('CURRENT', 'SAVINGS', 'CASH')
                          AND purpose IN ('OPERATING_CURRENT', 'SAVINGS', 'GOAL')
                          AND deleted_at IS NULL
                        """,
                        (
                            proposed["card_settlement_account_id"],
                            account_id,
                            space_id,
                            user["family_id"],
                            account["currency"],
                        ),
                    )
                ).fetchone()
                if settlement is None:
                    raise FinanceAccountSettingsError(
                        "Card settlement account must be an included cash account in the same space and currency"
                    )
        current = {
            "label": account["label"],
            "purpose": account["purpose"],
            "include_in_cashflow": bool(account["include_in_cashflow"]),
            "include_in_net_worth": bool(account["include_in_net_worth"]),
            "primary_spending_account": bool(account["primary_spending_account"]),
            "minimum_balance_minor": account["minimum_balance_minor"],
            "card_paid_in_full": bool(account["card_paid_in_full"]),
            "card_settlement_account_id": account["card_settlement_account_id"],
            "card_statement_close_day": account["card_statement_close_day"],
            "card_repayment_day": account["card_repayment_day"],
        }
        if proposed == current:
            return await _read_account(db, user=user, space_id=space_id, account_id=account_id)

        now = datetime.now(timezone.utc).isoformat()
        if proposed_default:
            previous_defaults = await (
                await db.execute(
                    """
                    SELECT id FROM finance_accounts
                    WHERE space_id = ? AND currency = ? AND id != ?
                      AND family_id = ? AND primary_spending_account = 1
                      AND deleted_at IS NULL
                    """,
                    (space_id, account["currency"], account_id, user["family_id"]),
                )
            ).fetchall()
            for previous in previous_defaults:
                await save_history(
                    db,
                    "finance_accounts",
                    previous["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
            if previous_defaults:
                await db.execute(
                    """
                    UPDATE finance_accounts
                    SET primary_spending_account = 0, updated_at = ?
                    WHERE space_id = ? AND currency = ? AND id != ?
                      AND family_id = ? AND primary_spending_account = 1
                      AND deleted_at IS NULL
                    """,
                    (now, space_id, account["currency"], account_id, user["family_id"]),
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
            SET label = ?, purpose = ?, include_in_cashflow = ?,
                include_in_net_worth = ?, primary_spending_account = ?,
                minimum_balance_minor = ?, card_paid_in_full = ?,
                card_settlement_account_id = ?, card_statement_close_day = ?,
                card_repayment_day = ?, updated_at = ?
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                proposed["label"],
                proposed["purpose"],
                int(proposed["include_in_cashflow"]),
                int(proposed["include_in_net_worth"]),
                int(proposed["primary_spending_account"]),
                proposed["minimum_balance_minor"],
                int(proposed["card_paid_in_full"]),
                proposed["card_settlement_account_id"],
                proposed["card_statement_close_day"],
                proposed["card_repayment_day"],
                now,
                account_id,
                space_id,
                user["family_id"],
            ),
        )
        from app.services.finance.sharing import apply_account_metadata_share

        await apply_account_metadata_share(db, user=user, account_id=account_id)
    return await _read_account(db, user=user, space_id=space_id, account_id=account_id)


def _eligible_for_direct_spend(account: dict, *, purpose: str, include_in_cashflow: bool) -> bool:
    connection_is_active = account["connection_id"] is None or account["connection_status"] not in {
        None,
        "DISCONNECTED",
        "EXPIRED",
    }
    return (
        connection_is_active
        and account.get("provider_presence_status", "ACTIVE") == "ACTIVE"
        and include_in_cashflow
        and account["account_type"] in _DIRECT_SPEND_ACCOUNT_TYPES
        and purpose in _DIRECT_SPEND_PURPOSES
    )


async def _read_account(
    db,
    *,
    user: dict,
    space_id: str,
    account_id: str,
) -> FinanceAccountResponse:
    accounts = await list_finance_accounts(db, user=user, space_id=space_id)
    account = next((item for item in accounts if item.id == account_id), None)
    if account is None:
        raise FinanceAccountSettingsNotFoundError("Finance account not found")
    return account

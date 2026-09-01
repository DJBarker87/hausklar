import aiosqlite
import pytest
from pydantic import ValidationError

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate
from app.services.finance.ledger import create_finance_account



def _enabled(user: dict) -> dict:
    return user


async def _spaces(client, headers: dict) -> dict[str, str]:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200
    return {item["kind"]: item["id"] for item in response.json()}


async def _account(
    db_path: str,
    *,
    user: dict,
    space_id: str,
    label: str,
    account_type: str,
    currency: str = "GBP",
):
    async with standalone_db(db_path) as db:
        return await create_finance_account(
            db,
            user=_enabled(user),
            space_id=space_id,
            body=FinanceAccountCreate(
                label=label,
                institution="Fixture Bank",
                account_type=account_type,
                currency=currency,
            ),
        )


@pytest.mark.asyncio
async def test_account_purpose_defaults_uniqueness_space_and_privacy(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    with pytest.raises(ValidationError):
        FinanceAccountCreate(
            label="Credit bypass",
            account_type="CREDIT_CARD",
            currency="GBP",
            primary_spending_account=True,
        )

    adult_a_spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    current = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["personal"],
        label="Current one",
        account_type="CURRENT",
    )
    savings = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["personal"],
        label="Savings one",
        account_type="SAVINGS",
    )
    euro_goal = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["personal"],
        label="Euro savings",
        account_type="SAVINGS",
        currency="EUR",
    )
    credit_card = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["personal"],
        label="Credit card",
        account_type="CREDIT_CARD",
    )
    household = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["household"],
        label="Household current",
        account_type="CURRENT",
    )

    configured = await client.patch(
        f"/api/finance/accounts/{current.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={
            "label": "Daily spending",
            "purpose": "OPERATING_CURRENT",
            "include_in_cashflow": True,
            "include_in_net_worth": True,
            "primary_spending_account": True,
            "minimum_balance_minor": 25_000,
        },
        headers=adult_a_headers,
    )
    assert configured.status_code == 200, configured.text
    assert configured.json()["label"] == "Daily spending"
    assert configured.json()["purpose"] == "OPERATING_CURRENT"
    assert configured.json()["account_type"] == "CURRENT"
    assert configured.json()["primary_spending_account"] is True
    assert configured.json()["minimum_balance_minor"] == 25_000

    rejected_excluded_default = await client.patch(
        f"/api/finance/accounts/{current.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={"include_in_cashflow": False, "primary_spending_account": True},
        headers=adult_a_headers,
    )
    assert rejected_excluded_default.status_code == 422
    excluded_default = await client.patch(
        f"/api/finance/accounts/{current.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={"include_in_cashflow": False},
        headers=adult_a_headers,
    )
    assert excluded_default.status_code == 200
    assert excluded_default.json()["include_in_cashflow"] is False
    assert excluded_default.json()["primary_spending_account"] is False

    replacement_default = await client.patch(
        f"/api/finance/accounts/{savings.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={"purpose": "SAVINGS", "primary_spending_account": True},
        headers=adult_a_headers,
    )
    assert replacement_default.status_code == 200
    assert replacement_default.json()["account_type"] == "SAVINGS"
    assert replacement_default.json()["primary_spending_account"] is True

    other_currency_default = await client.patch(
        f"/api/finance/accounts/{euro_goal.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={"purpose": "GOAL", "primary_spending_account": True},
        headers=adult_a_headers,
    )
    assert other_currency_default.status_code == 200
    assert other_currency_default.json()["purpose"] == "GOAL"

    accounts = await client.get(
        "/api/finance/accounts",
        params={"space_id": adult_a_spaces["personal"]},
        headers=adult_a_headers,
    )
    assert accounts.status_code == 200
    by_id = {item["id"]: item for item in accounts.json()}
    assert by_id[current.id]["primary_spending_account"] is False
    assert by_id[savings.id]["primary_spending_account"] is True
    assert by_id[euro_goal.id]["primary_spending_account"] is True
    assert by_id[savings.id]["currency"] == "GBP"
    assert by_id[euro_goal.id]["currency"] == "EUR"

    for ineligible_purpose in ("IGNORED", "INVESTMENT_LIKE", "CREDIT_CARD"):
        rejected_default = await client.patch(
            f"/api/finance/accounts/{current.id}",
            params={"space_id": adult_a_spaces["personal"]},
            json={
                "purpose": ineligible_purpose,
                "primary_spending_account": True,
            },
            headers=adult_a_headers,
        )
        assert rejected_default.status_code == 422

    rejected_credit_default = await client.patch(
        f"/api/finance/accounts/{credit_card.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={"purpose": "OPERATING_CURRENT", "primary_spending_account": True},
        headers=adult_a_headers,
    )
    assert rejected_credit_default.status_code == 422

    incompatible_included_purpose = await client.patch(
        f"/api/finance/accounts/{credit_card.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={"purpose": "SAVINGS", "include_in_cashflow": True},
        headers=adult_a_headers,
    )
    assert incompatible_included_purpose.status_code == 422

    ignored = await client.patch(
        f"/api/finance/accounts/{current.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={
            "purpose": "IGNORED",
            "include_in_cashflow": False,
            "include_in_net_worth": False,
        },
        headers=adult_a_headers,
    )
    assert ignored.status_code == 200
    assert ignored.json()["purpose"] == "IGNORED"
    assert ignored.json()["include_in_cashflow"] is False
    assert ignored.json()["include_in_net_worth"] is False
    assert ignored.json()["account_type"] == "CURRENT"

    wrong_space = await client.patch(
        f"/api/finance/accounts/{household.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={"label": "Must not move spaces"},
        headers=adult_a_headers,
    )
    assert wrong_space.status_code == 404

    private_attempt = await client.patch(
        f"/api/finance/accounts/{savings.id}",
        params={"space_id": adult_a_spaces["personal"]},
        json={"label": "Must remain private"},
        headers=adult_b_headers,
    )
    assert private_attempt.status_code == 404
    assert savings.id not in private_attempt.text

    async with aiosqlite.connect(initialized_db) as db:
        defaults = await (
            await db.execute(
                """
                SELECT currency, COUNT(*)
                FROM finance_accounts
                WHERE space_id = ? AND primary_spending_account = 1
                  AND deleted_at IS NULL
                GROUP BY currency ORDER BY currency
                """,
                (adult_a_spaces["personal"],),
            )
        ).fetchall()
        history_count = (
            await (
                await db.execute(
                    """
                    SELECT COUNT(*) FROM record_history
                    WHERE table_name = 'finance_accounts'
                      AND record_id IN (?, ?)
                    """,
                    (current.id, savings.id),
                )
            ).fetchone()
        )[0]
    assert defaults == [("EUR", 1), ("GBP", 1)]
    assert history_count >= 4

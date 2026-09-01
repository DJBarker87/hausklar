from datetime import date, datetime, timezone

import aiosqlite
import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.ledger import (
    create_finance_account,
    import_source_transactions,
    record_balance_snapshot,
)



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
    account_type: str = "CURRENT",
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


def _source(
    identifier: str | None,
    *,
    amount: int,
    description: str,
    day: date = date(2026, 7, 20),
    status: str = "POSTED",
    currency: str = "GBP",
    batch: str = "fixture-1",
    replaces: str | None = None,
    group: str | None = None,
    kind: str = "CASEY",
) -> NormalisedSourceTransaction:
    return NormalisedSourceTransaction(
        source_kind="PROVIDER",
        source_batch_id=batch,
        source_transaction_id=identifier,
        replaces_source_transaction_id=replaces,
        source_group_id=group,
        booking_date=day,
        pending_status=status,
        transaction_kind=kind,
        amount_minor=amount,
        currency=currency,
        description=description,
        observed_at=datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc),
    )


async def _import(db_path, *, user, space_id, account_id, sources):
    async with standalone_db(db_path) as db:
        return await import_source_transactions(
            db,
            user=_enabled(user),
            space_id=space_id,
            account_id=account_id,
            observations=sources,
        )


@pytest.mark.asyncio
async def test_personal_ledger_is_not_discoverable_from_partner_requests(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    account = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["personal"],
        label="Alex private",
    )
    imported = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["personal"],
        account_id=account.id,
        sources=[_source("private-ai", amount=-2499, description="Private AI subscription")],
    )

    for path in ("accounts", "transactions", "summary"):
        response = await client.get(
            f"/api/finance/{path}",
            params={"space_id": adult_a_spaces["personal"]},
            headers=adult_b_headers,
        )
        assert response.status_code == 404
        assert "subscription" not in response.text.lower()
    guessed_split = await client.put(
        f"/api/finance/transactions/{imported.transaction_ids[0]}/splits",
        json={"splits": [{"amount_minor": -2499, "label": "AI"}]},
        headers=adult_b_headers,
    )
    assert guessed_split.status_code == 404


@pytest.mark.asyncio
async def test_overlapping_imports_are_idempotent_and_list_data_through(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    account = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="Current"
    )
    source = _source("bank-1", amount=-1234, description="Tesco Stores")

    first = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=account.id,
        sources=[source],
    )
    repeated = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=account.id,
        sources=[source],
    )
    overlap_without_provider_id = source.model_copy(
        update={"source_transaction_id": None, "source_batch_id": "overlap-window"}
    )
    overlap = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=account.id,
        sources=[overlap_without_provider_id],
    )

    assert first.canonical_created == 1
    assert repeated.duplicates == 1
    assert overlap.duplicates == 1
    response = await client.get(
        "/api/finance/transactions",
        params={"space_id": space_id, "limit": 1},
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    assert len(response.json()) == 1
    assert response.json()[0]["amount_minor"] == -1234
    assert response.json()[0]["data_through_at"] == "2026-07-20T12:00:00+00:00"

    async with aiosqlite.connect(initialized_db) as db:
        source_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM finance_source_transactions WHERE account_id = ?",
                    (account.id,),
                )
            ).fetchone()
        )[0]
        canonical_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM finance_transactions WHERE account_id = ?",
                    (account.id,),
                )
            ).fetchone()
        )[0]
    assert (source_count, canonical_count) == (1, 1)


@pytest.mark.asyncio
async def test_pending_source_is_preserved_when_posted_transaction_supersedes_it(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    account = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="Current"
    )
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=account.id,
        sources=[
            _source(
                "pending-1",
                amount=-4599,
                description="AMAZON PENDING",
                status="PENDING",
            )
        ],
    )
    posted = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=account.id,
        sources=[
            _source(
                "posted-1",
                amount=-4599,
                description="AMAZON PENDING",
                replaces="pending-1",
            )
        ],
    )
    assert posted.pending_superseded == 1

    visible = await client.get(
        "/api/finance/transactions",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert [row["state"] for row in visible.json()] == ["POSTED"]
    all_rows = await client.get(
        "/api/finance/transactions",
        params={"space_id": space_id, "include_superseded": True},
        headers=adult_a_headers,
    )
    assert {row["state"] for row in all_rows.json()} == {"POSTED", "SUPERSEDED"}
    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT pending_status, source_transaction_id FROM finance_source_transactions"
            )
        ).fetchall()
    assert set(rows) == {("PENDING", "pending-1"), ("POSTED", "posted-1")}


@pytest.mark.asyncio
async def test_confirmed_transfer_and_card_repayment_have_zero_consumption_effect(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["household"]
    current = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="Current"
    )
    savings = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        label="Savings",
        account_type="SAVINGS",
    )
    card = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        label="Card",
        account_type="CREDIT_CARD",
    )
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=current.id,
        sources=[_source("save-out", amount=-10000, description="Savings transfer")],
    )
    transfer = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=savings.id,
        sources=[_source("save-in", amount=10000, description="Savings transfer")],
    )
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=current.id,
        sources=[_source("card-out", amount=-25000, description="Card repayment")],
    )
    repayment = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=card.id,
        sources=[_source("card-in", amount=25000, description="Card repayment")],
    )
    relation_ids = transfer.relation_suggestion_ids + repayment.relation_suggestion_ids
    assert len(relation_ids) == 2
    for relation_id in relation_ids:
        reviewed = await client.post(
            f"/api/finance/relations/{relation_id}/review",
            json={"status": "CONFIRMED"},
            headers=adult_a_headers,
        )
        assert reviewed.status_code == 200

    summary = await client.get(
        "/api/finance/summary",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    gbp = summary.json()["currencies"][0]
    assert gbp["account_movement_minor"] == 0
    assert gbp["gross_spending_minor"] == 0
    assert gbp["income_minor"] == 0
    assert gbp["net_household_cost_minor"] == 0


@pytest.mark.asyncio
async def test_one_transaction_cannot_confirm_two_neutral_relations(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["household"]
    source_account = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="Source"
    )
    first_destination = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        label="First destination",
        account_type="SAVINGS",
    )
    second_destination = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        label="Second destination",
        account_type="SAVINGS",
    )
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=source_account.id,
        sources=[_source("one-out", amount=-10000, description="Transfer")],
    )
    first = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=first_destination.id,
        sources=[_source("first-in", amount=10000, description="Transfer")],
    )
    second = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=second_destination.id,
        sources=[_source("second-in", amount=10000, description="Transfer")],
    )
    assert len(first.relation_suggestion_ids) == 1
    assert len(second.relation_suggestion_ids) == 1

    accepted = await client.post(
        f"/api/finance/relations/{first.relation_suggestion_ids[0]}/review",
        json={"status": "CONFIRMED"},
        headers=adult_a_headers,
    )
    assert accepted.status_code == 200
    rejected = await client.post(
        f"/api/finance/relations/{second.relation_suggestion_ids[0]}/review",
        json={"status": "CONFIRMED"},
        headers=adult_a_headers,
    )
    assert rejected.status_code == 422

    summary = (
        await client.get(
            "/api/finance/summary",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
    ).json()["currencies"][0]
    assert summary["account_movement_minor"] == 10000
    assert summary["income_minor"] == 10000
    assert summary["gross_spending_minor"] == 0


@pytest.mark.asyncio
async def test_fx_principal_is_neutral_but_explicit_fee_remains_spending(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    gbp_account = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="GBP", currency="GBP"
    )
    eur_account = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="EUR", currency="EUR"
    )
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=gbp_account.id,
        sources=[
            _source("fx-out", amount=-10000, description="FX exchange", group="fx-1"),
            _source(
                "fx-fee",
                amount=-150,
                description="FX fee",
                group="fx-1",
                kind="FEE",
            ),
        ],
    )
    incoming = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=eur_account.id,
        sources=[
            _source(
                "fx-in",
                amount=11500,
                description="FX exchange",
                currency="EUR",
                group="fx-1",
            )
        ],
    )
    assert len(incoming.relation_suggestion_ids) == 1
    reviewed = await client.post(
        f"/api/finance/relations/{incoming.relation_suggestion_ids[0]}/review",
        json={"status": "CONFIRMED"},
        headers=adult_a_headers,
    )
    assert reviewed.json()["relation_type"] == "FX_LEG"

    summary = (
        await client.get(
            "/api/finance/summary",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
    ).json()
    by_currency = {row["currency"]: row for row in summary["currencies"]}
    assert by_currency["GBP"]["gross_spending_minor"] == 150
    assert by_currency["GBP"]["fees_minor"] == 150
    assert by_currency["EUR"]["income_minor"] == 0


@pytest.mark.asyncio
async def test_refunds_and_reimbursements_remain_visible_in_gross_and_net_totals(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    account = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="Current"
    )
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=account.id,
        sources=[
            _source("shop", amount=-5000, description="Shoe shop"),
            _source("work", amount=-3000, description="Train to work"),
        ],
    )
    credits = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=account.id,
        sources=[
            _source("refund", amount=2000, description="Shoe shop refund"),
            _source("reimburse", amount=3000, description="Work expenses payment"),
        ],
    )
    assert len(credits.relation_suggestion_ids) == 2
    for relation_id in credits.relation_suggestion_ids:
        reviewed = await client.post(
            f"/api/finance/relations/{relation_id}/review",
            json={"status": "CONFIRMED"},
            headers=adult_a_headers,
        )
        assert reviewed.status_code == 200

    transactions = (
        await client.get(
            "/api/finance/transactions",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
    ).json()
    relation_types = {
        relation["relation_type"]
        for transaction in transactions
        for relation in transaction["relations"]
    }
    assert {"REFUND", "REIMBURSEMENT"} <= relation_types
    summary = (
        await client.get(
            "/api/finance/summary",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
    ).json()["currencies"][0]
    assert summary["gross_spending_minor"] == 8000
    assert summary["refunds_minor"] == 2000
    assert summary["reimbursements_minor"] == 3000
    assert summary["net_household_cost_minor"] == 3000


@pytest.mark.asyncio
async def test_transaction_splits_must_reconcile_exactly(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    account = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="Current"
    )
    imported = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        account_id=account.id,
        sources=[_source("mixed", amount=-1000, description="Mixed purchase")],
    )
    transaction_id = imported.transaction_ids[0]

    invalid = await client.put(
        f"/api/finance/transactions/{transaction_id}/splits",
        json={
            "splits": [
                {"amount_minor": -600, "label": "Household"},
                {"amount_minor": -300, "label": "Personal"},
            ]
        },
        headers=adult_a_headers,
    )
    assert invalid.status_code == 422
    valid = await client.put(
        f"/api/finance/transactions/{transaction_id}/splits",
        json={
            "splits": [
                {"amount_minor": -600, "label": "Household"},
                {"amount_minor": -400, "label": "Personal"},
            ]
        },
        headers=adult_a_headers,
    )
    assert valid.status_code == 200
    assert sum(row["amount_minor"] for row in valid.json()) == -1000


@pytest.mark.asyncio
async def test_account_listing_uses_latest_append_only_balance(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    account = await _account(
        initialized_db, user=adult_a_user, space_id=space_id, label="Current"
    )
    async with standalone_db(initialized_db) as db:
        await record_balance_snapshot(
            db,
            user=_enabled(adult_a_user),
            space_id=space_id,
            account_id=account.id,
            booked_minor=123456,
            available_minor=120000,
            credit_limit_minor=None,
            currency="GBP",
            observed_at=datetime(2026, 7, 20, 11, 0, tzinfo=timezone.utc),
        )
        await record_balance_snapshot(
            db,
            user=_enabled(adult_a_user),
            space_id=space_id,
            account_id=account.id,
            booked_minor=125000,
            available_minor=121000,
            credit_limit_minor=None,
            currency="GBP",
            observed_at=datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc),
        )
    response = await client.get(
        "/api/finance/accounts",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    assert response.json()[0]["balance"] == {
        "booked_minor": 125000,
        "available_minor": 121000,
        "credit_limit_minor": None,
        "provider_at": None,
        "observed_at": "2026-07-20T12:00:00+00:00",
    }

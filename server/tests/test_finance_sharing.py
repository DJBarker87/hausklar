from datetime import date, datetime, timedelta, timezone
import uuid

import aiosqlite
import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, FinanceForecastGenerate, NormalisedSourceTransaction
from app.services.finance.ledger import create_finance_account, import_source_transactions, record_balance_snapshot
from app.services.finance.planning import generate_forecast


def _enabled(user: dict) -> dict:
    return user



async def _spaces(client, headers: dict) -> dict[str, str]:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200
    return {row["kind"]: row["id"] for row in response.json()}


async def _account(db_path: str, *, user: dict, space_id: str, label: str):
    async with standalone_db(db_path) as db:
        return await create_finance_account(
            db,
            user=_enabled(user),
            space_id=space_id,
            body=FinanceAccountCreate(
                label=label,
                institution="Fixture Bank",
                account_type="CURRENT",
                currency="GBP",
            ),
        )


async def _import(
    db_path: str,
    *,
    user: dict,
    space_id: str,
    account_id: str,
    source_id: str,
    merchant: str,
    amount: int,
    day: date,
):
    async with standalone_db(db_path) as db:
        return await import_source_transactions(
            db,
            user=_enabled(user),
            space_id=space_id,
            account_id=account_id,
            observations=[
                NormalisedSourceTransaction(
                    source_kind="MANUAL",
                    source_batch_id=f"batch-{source_id}",
                    source_transaction_id=source_id,
                    booking_date=day,
                    pending_status="POSTED",
                    amount_minor=amount,
                    currency="GBP",
                    description=merchant,
                    merchant_text=merchant,
                    observed_at=datetime.combine(
                        day, datetime.min.time(), tzinfo=timezone.utc
                    ),
                )
            ],
        )


@pytest.mark.asyncio
async def test_account_share_history_future_stop_and_mine_deduplication(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    account = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        label="Private current",
    )
    first = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=account.id,
        source_id="share-first",
        merchant="Grocer",
        amount=-1_000,
        day=date(2026, 8, 2),
    )

    shared = await client.post(
        f"/api/finance/shares/accounts/{account.id}", headers=adult_a_headers
    )
    assert shared.status_code == 200, shared.text
    action = shared.json()
    assert action["kind"] == "ACCOUNT"
    assert action["status"] == "ACTIVE"
    assert action["applies_to_future"] is True
    assert not ({"source_space_id", "source_record_id", "owner_user_id"} & action.keys())

    household = await client.get(
        "/api/finance/summary",
        params={"space_id": spaces["household"]},
        headers=adult_b_headers,
    )
    assert household.status_code == 200
    assert household.json()["currencies"][0]["gross_spending_minor"] == 1_000
    mine_household_leg = await client.get(
        "/api/finance/summary",
        params={
            "space_id": spaces["household"],
            "exclude_own_shared_copies": "true",
        },
        headers=adult_a_headers,
    )
    assert mine_household_leg.status_code == 200
    assert mine_household_leg.json()["currencies"] == []

    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=account.id,
        source_id="share-second",
        merchant="Bakery",
        amount=-500,
        day=date(2026, 8, 3),
    )
    before_stop = await client.get(
        "/api/finance/transactions",
        params={"space_id": spaces["household"], "limit": 200},
        headers=adult_b_headers,
    )
    assert before_stop.status_code == 200
    assert {row["description"] for row in before_stop.json()} == {"Grocer", "Bakery"}

    stopped = await client.post(
        f"/api/finance/shares/{action['id']}/stop", headers=adult_a_headers
    )
    assert stopped.status_code == 200
    assert stopped.json()["status"] == "STOPPED"
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=account.id,
        source_id="share-third",
        merchant="Private after stop",
        amount=-700,
        day=date(2026, 8, 4),
    )
    after_stop = await client.get(
        "/api/finance/transactions",
        params={"space_id": spaces["household"], "limit": 200},
        headers=adult_b_headers,
    )
    assert {row["description"] for row in after_stop.json()} == {"Grocer", "Bakery"}
    assert first.transaction_ids


@pytest.mark.asyncio
async def test_selected_purchase_share_is_self_contained_and_rule_is_exact(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    intake = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": spaces["personal"]},
        headers=adult_a_headers,
        json={
            "external_source_id": "private-order-source",
            "adapter": "e_receipt",
            "reviewed": True,
            "payload": {
                "source_id": "private-order-source",
                "purchase_reference": "private-order-reference",
                "merchant": "Example Shop",
                "purchased_at": "2026-08-02",
                "currency": "GBP",
                "lines": [
                    {
                        "line_reference": "school-shoes",
                        "description": "School shoes",
                        "net_minor": 4_500,
                        "shipment_reference": "PRIVATE-PARCEL-REFERENCE",
                    },
                    {
                        "line_reference": "private-item",
                        "description": "Private item",
                        "net_minor": 9_000,
                    },
                ],
                "shipping_minor": 500,
                "final_total_minor": 14_000,
            },
        },
    )
    assert intake.status_code == 201, intake.text
    private_purchase = intake.json()["purchase"]
    selected_line = private_purchase["lines"][0]
    assert selected_line["shipment_reference"] == "PRIVATE-PARCEL-REFERENCE"
    share = await client.post(
        f"/api/finance/shares/purchases/{private_purchase['id']}",
        headers=adult_a_headers,
        json={"mode": "SELECTED_LINES", "line_ids": [selected_line["id"]]},
    )
    assert share.status_code == 200, share.text
    shared_purchase_id = share.json()["shared_record_id"]
    household_purchase = await client.get(
        f"/api/finance/purchases/{shared_purchase_id}", headers=adult_b_headers
    )
    assert household_purchase.status_code == 200, household_purchase.text
    body = household_purchase.json()
    assert body["final_total_minor"] == 4_500
    assert body["lines_subtotal_minor"] == 4_500
    assert body["shipping_minor"] == 0
    assert body["order_discount_minor"] == 0
    assert body["order_reference"] is None
    assert [line["raw_description"] for line in body["lines"]] == ["School shoes"]
    assert body["lines"][0]["source_refs"] == []
    assert body["lines"][0]["shipment_reference"] is None
    serialized = household_purchase.text
    assert "Private item" not in serialized
    assert "14000" not in serialized
    assert "private-order" not in serialized
    assert "PRIVATE-PARCEL-REFERENCE" not in serialized

    mine_household = await client.get(
        "/api/finance/purchases",
        params={
            "space_id": spaces["household"],
            "exclude_own_shared_copies": "true",
        },
        headers=adult_a_headers,
    )
    assert mine_household.status_code == 200
    assert mine_household.json() == []

    account = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        label="Rule current",
    )
    rule = await client.post(
        "/api/finance/share-rules",
        headers=adult_a_headers,
        json={"target": "TRANSACTION", "merchant": "Tesco"},
    )
    assert rule.status_code == 200
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=account.id,
        source_id="tesco-exact",
        merchant="Tesco",
        amount=-2_000,
        day=date(2026, 8, 5),
    )
    await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=account.id,
        source_id="tesco-mobile",
        merchant="Tesco Mobile",
        amount=-3_000,
        day=date(2026, 8, 6),
    )
    household_transactions = await client.get(
        "/api/finance/transactions",
        params={"space_id": spaces["household"], "limit": 200},
        headers=adult_b_headers,
    )
    descriptions = {row["description"] for row in household_transactions.json()}
    assert "Tesco" in descriptions
    assert "Tesco Mobile" not in descriptions


@pytest.mark.asyncio
async def test_share_preview_history_and_replace_use_safe_owner_only_labels(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    goal = await client.post(
        "/api/finance/goals",
        params={"space_id": spaces["personal"]},
        headers=adult_a_headers,
        json={
            "name": "Family holiday",
            "target_minor": 300_000,
            "deadline": "2027-08-01",
            "currency": "GBP",
        },
    )
    assert goal.status_code == 201, goal.text
    private_goal_id = goal.json()["id"]
    preview = await client.post(
        "/api/finance/shares/preview",
        headers=adult_a_headers,
        json={"kind": "GOAL", "source_record_id": private_goal_id},
    )
    assert preview.status_code == 200, preview.text
    assert preview.json()["label"] == "Family holiday"
    assert private_goal_id not in preview.text

    shared = await client.post(
        f"/api/finance/shares/goals/{private_goal_id}", headers=adult_a_headers
    )
    assert shared.status_code == 200, shared.text
    action_id = shared.json()["id"]
    old_household_id = shared.json()["shared_record_id"]
    revised = await client.patch(
        f"/api/finance/goals/{private_goal_id}",
        headers=adult_a_headers,
        json={"name": "Family holiday 2027"},
    )
    assert revised.status_code == 200, revised.text

    history = await client.get("/api/finance/shares", headers=adult_a_headers)
    assert history.status_code == 200, history.text
    entry = next(item for item in history.json() if item["id"] == action_id)
    assert entry["label"] == "Family holiday 2027"
    assert entry["sharing_mode"] == "ONCE"
    assert entry["stale"] is True
    assert entry["version_state"] == "PAST"
    assert private_goal_id not in history.text

    replaced = await client.post(
        f"/api/finance/shares/{action_id}/replace", headers=adult_a_headers
    )
    assert replaced.status_code == 200, replaced.text
    assert replaced.json()["stale"] is False
    assert replaced.json()["shared_record_id"] != old_household_id
    household_goals = await client.get(
        "/api/finance/goals",
        params={"space_id": spaces["household"]},
        headers=adult_b_headers,
    )
    assert household_goals.status_code == 200
    assert [item["name"] for item in household_goals.json()] == ["Family holiday 2027"]


@pytest.mark.asyncio
async def test_contribution_has_neutral_public_shape_and_enters_future_forecast_once(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    account = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["household"],
        label="Household current",
    )
    observed = datetime.now(timezone.utc) - timedelta(days=1)
    async with standalone_db(initialized_db) as db:
        await record_balance_snapshot(
            db,
            user=_enabled(adult_a_user),
            space_id=spaces["household"],
            account_id=account.id,
            booked_minor=10_000,
            available_minor=10_000,
            credit_limit_minor=None,
            currency="GBP",
            observed_at=observed,
        )
    contribution_day = date.today() + timedelta(days=2)
    declared = await client.post(
        "/api/finance/shares/contributions",
        headers=adult_a_headers,
        json={
            "id": str(uuid.uuid4()),
            "amount_minor": 2_500,
            "currency": "GBP",
            "contribution_date": contribution_day.isoformat(),
        },
    )
    assert declared.status_code == 200, declared.text
    listed = await client.get(
        "/api/finance/contributions",
        params={"space_id": spaces["household"]},
        headers=adult_b_headers,
    )
    assert listed.status_code == 200
    assert listed.json() == [
        {
            "id": declared.json()["shared_record_id"],
            "space_id": spaces["household"],
            "amount_minor": 2_500,
            "currency": "GBP",
            "contribution_date": contribution_day.isoformat(),
            "label": "Contribution from a personal space",
            "status": "ACTIVE",
            "created_at": listed.json()[0]["created_at"],
        }
    ]
    assert "Alex" not in listed.text
    assert "source" not in listed.text.lower()

    async with standalone_db(initialized_db) as db:
        forecast = await generate_forecast(
            db,
            user=_enabled(adult_a_user),
            space_id=spaces["household"],
            body=FinanceForecastGenerate(
                end_date=contribution_day + timedelta(days=1),
                currency="GBP",
                household_buffer_minor=0,
            ),
        )
    contribution_events = [
        event for event in forecast.events if event.provenance == "declared-contribution"
    ]
    assert len(contribution_events) == 1
    assert contribution_events[0].amount_minor == 2_500
    assert contribution_events[0].kind == "planned"


@pytest.mark.asyncio
async def test_shared_transfer_and_refund_keep_accounting_meaning_without_counterleg_leak(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    left = await _account(
        initialized_db, user=adult_a_user, space_id=spaces["personal"], label="Left"
    )
    right = await _account(
        initialized_db, user=adult_a_user, space_id=spaces["personal"], label="Right"
    )
    outgoing = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=left.id,
        source_id="transfer-out",
        merchant="Own transfer",
        amount=-2_000,
        day=date(2026, 8, 7),
    )
    incoming = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=right.id,
        source_id="transfer-in",
        merchant="Own transfer",
        amount=2_000,
        day=date(2026, 8, 7),
    )
    purchase = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=left.id,
        source_id="refund-original",
        merchant="Shop",
        amount=-1_000,
        day=date(2026, 8, 8),
    )
    refund = await _import(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["personal"],
        account_id=left.id,
        source_id="refund-return",
        merchant="Shop refund",
        amount=500,
        day=date(2026, 8, 9),
    )
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        fixtures = [
            (
                outgoing.transaction_ids[0],
                incoming.transaction_ids[0],
                "INTERNAL_TRANSFER",
            ),
            (purchase.transaction_ids[0], refund.transaction_ids[0], "REFUND"),
        ]
        for from_id, to_id, relation_type in fixtures:
            updated = await db.execute(
                """
                UPDATE finance_transaction_relations
                SET status = 'CONFIRMED', confidence_bps = 10000, updated_at = ?
                WHERE from_transaction_id = ? AND to_transaction_id = ?
                  AND relation_type = ? AND deleted_at IS NULL
                """,
                (now, from_id, to_id, relation_type),
            )
            if updated.rowcount == 0:
                await db.execute(
                    """
                    INSERT INTO finance_transaction_relations
                        (id, space_id, from_transaction_id, to_transaction_id,
                         relation_type, status, method, confidence_bps, family_id,
                         created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, 'CONFIRMED', 'fixture', 10000, ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        spaces["personal"],
                        from_id,
                        to_id,
                        relation_type,
                        adult_a_user["family_id"],
                        now,
                        now,
                        adult_a_user["id"],
                    ),
                )
        await db.commit()

    # Sharing only one side retains its neutral/refund treatment but creates no
    # relation that could expose the private counter-leg.
    for transaction_id in (outgoing.transaction_ids[0], refund.transaction_ids[0]):
        response = await client.post(
            f"/api/finance/shares/transactions/{transaction_id}", headers=adult_a_headers
        )
        assert response.status_code == 200, response.text
    one_sided = await client.get(
        "/api/finance/transactions",
        params={"space_id": spaces["household"], "limit": 200},
        headers=adult_b_headers,
    )
    assert all(row["relations"] == [] for row in one_sided.json())
    summary = await client.get(
        "/api/finance/summary",
        params={"space_id": spaces["household"]},
        headers=adult_b_headers,
    )
    totals = summary.json()["currencies"][0]
    assert totals["gross_spending_minor"] == 0
    assert totals["income_minor"] == 0
    assert totals["refunds_minor"] == 500

    # Once both explicitly shared envelopes exist, the confirmed meaning is
    # represented in Household without any private source IDs.
    for transaction_id in (incoming.transaction_ids[0], purchase.transaction_ids[0]):
        response = await client.post(
            f"/api/finance/shares/transactions/{transaction_id}", headers=adult_a_headers
        )
        assert response.status_code == 200, response.text
    both_sides = await client.get(
        "/api/finance/transactions",
        params={"space_id": spaces["household"], "limit": 200},
        headers=adult_b_headers,
    )
    relation_types = {
        relation["relation_type"]
        for row in both_sides.json()
        for relation in row["relations"]
    }
    assert {"INTERNAL_TRANSFER", "REFUND"} <= relation_types
    assert "source_record_id" not in both_sides.text

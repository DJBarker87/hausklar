import json
from datetime import date, datetime, timezone

import aiosqlite

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.capture import expire_finance_capture_drafts
from app.services.finance.ledger import create_finance_account, import_source_transactions


async def test_finance_capture_is_reviewed_private_single_use_and_retry_safe(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    space_id = next(item["id"] for item in spaces if item["kind"] == "personal")
    await client.get("/api/finance/spaces", headers=adult_b_headers)
    enabled_dom = adult_a_user
    async with standalone_db(initialized_db) as db:
        current = await create_finance_account(
            db,
            user=enabled_dom,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Everyday current",
                institution="Fixture Bank",
                account_type="CURRENT",
                currency="GBP",
            ),
        )
        await import_source_transactions(
            db,
            user=enabled_dom,
            space_id=space_id,
            account_id=current.id,
            observations=[NormalisedSourceTransaction(
                source_kind="MANUAL",
                source_batch_id="capture-fixture",
                source_transaction_id="tesco-party",
                booking_date=date(2026, 8, 1),
                pending_status="POSTED",
                amount_minor=-14_200,
                currency="GBP",
                description="Tesco shop",
                merchant_text="Tesco",
                observed_at=datetime(2026, 8, 1, 8, tzinfo=timezone.utc),
            )],
        )

    examples = {
        "Car insurance is due in May and will probably be about £900.": "COMMITMENT",
        "We want a £4,000 holiday next August.": "GOAL",
        "Do not cut the children's activities.": "PREFERENCE",
        "I spent £52 cash at the zoo: £34 tickets and about £18 food.": "CASH_SPEND",
        (
            "That £86 Amazon payment contained £32 school shoes for Alex, "
            "£16 dog bags, an £18 birthday present and a £20 phone stand I regret."
        ): "PURCHASE_DETAILS",
        (
            "The £142 Tesco shop included £26 of party food; treat that as a "
            "birthday cost rather than normal groceries."
        ): "TRANSACTION_CORRECTION",
        (
            "For optional online household items over £40, remind me to wait "
            "until tomorrow before buying."
        ): "HABIT",
        "Can we buy this £1,400 pergola in October?": "PURCHASE_PLAN",
    }
    review_cards = {}
    for text, expected_kind in examples.items():
        response = await client.post(
            "/api/finance/capture/interpret",
            json={"space_id": space_id, "text": text},
            headers=adult_a_headers,
        )
        assert response.status_code == 200, response.text
        assert response.json()["mode"] == "REVIEW"
        assert response.json()["drafts"][0]["content"]["kind"] == expected_kind
        review_cards[expected_kind] = response.json()["drafts"][0]

    tesco = review_cards["TRANSACTION_CORRECTION"]
    assert "Food shopping" in tesco["category_options"]
    assert "Other" in tesco["category_options"]
    assert [line["category_name"] for line in tesco["content"]["splits"]] == [
        None,
        "Food shopping",
    ]
    assert tesco["target_options"][0]["label"] == "Tesco"
    tesco_confirmed = await client.post(
        f"/api/finance/capture/{tesco['id']}/confirm",
        json={
            "content": tesco["content"],
            "selected_target_id": tesco["target_options"][0]["id"],
        },
        headers=adult_a_headers,
    )
    assert tesco_confirmed.status_code == 200, tesco_confirmed.text

    cash = review_cards["CASH_SPEND"]
    assert cash["target_options"] == [{
        "id": "cash-spend:purchase-only",
        "kind": "PURCHASE_ONLY",
        "label": "Save purchase only (cash tender; no cashflow entry)",
        "date": None,
        "amount_minor": None,
        "currency": "GBP",
    }]
    cash_content = {**cash["content"], "account_hint": current.id}
    cash_confirmed = await client.post(
        f"/api/finance/capture/{cash['id']}/confirm",
        json={
            "content": cash_content,
            "selected_target_id": "cash-spend:purchase-only",
        },
        headers=adult_a_headers,
    )
    assert cash_confirmed.status_code == 200, cash_confirmed.text
    assert cash_confirmed.json()["action_kind"] == "CASH_SPEND_PURCHASE_ONLY"
    assert cash_confirmed.json()["result"]["posting_mode"] == "PURCHASE_ONLY"
    assert cash_confirmed.json()["result"]["cashflow_posted"] is False
    assert cash_confirmed.json()["result"]["transaction_id"] is None
    purchase_id = cash_confirmed.json()["result"]["purchase_id"]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        # The arbitrary account_hint remains descriptive only: no bank movement
        # is fabricated, while the reviewed itemisation is purchase evidence.
        transaction_count = (
            await (await db.execute("SELECT COUNT(*) FROM finance_transactions")).fetchone()
        )[0]
        line_total = (
            await (await db.execute(
                "SELECT SUM(line_net_minor) FROM finance_purchase_lines "
                "WHERE purchase_id = ? AND deleted_at IS NULL",
                (purchase_id,),
            )).fetchone()
        )[0]
        allocation = await (
            await db.execute(
                "SELECT transaction_id, tender_kind, allocated_minor, match_method "
                "FROM finance_purchase_payments WHERE purchase_id = ? AND deleted_at IS NULL",
                (purchase_id,),
            )
        ).fetchone()
    assert transaction_count == 1
    assert line_total == 5_200
    assert dict(allocation) == {
        "transaction_id": None,
        "tender_kind": "cash",
        "allocated_minor": 5_200,
        "match_method": "EVIDENCED_NON_BANK",
    }

    async with standalone_db(initialized_db) as db:
        cash_wallet = await create_finance_account(
            db,
            user=enabled_dom,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Cash wallet",
                institution="Household",
                account_type="CASH",
                currency="GBP",
            ),
        )
    wallet_review = await client.post(
        "/api/finance/capture/interpret",
        json={
            "space_id": space_id,
            "text": "I spent £52 cash at the zoo: £34 tickets and about £18 food.",
        },
        headers=adult_a_headers,
    )
    wallet_cash = wallet_review.json()["drafts"][0]
    assert [option["id"] for option in wallet_cash["target_options"]] == [cash_wallet.id]
    wallet_confirmed = await client.post(
        f"/api/finance/capture/{wallet_cash['id']}/confirm",
        json={
            "content": wallet_cash["content"],
            "selected_account_id": cash_wallet.id,
        },
        headers=adult_a_headers,
    )
    assert wallet_confirmed.status_code == 200, wallet_confirmed.text
    assert wallet_confirmed.json()["result"]["posting_mode"] == "CASH_ACCOUNT_TRANSACTION"
    assert wallet_confirmed.json()["result"]["account_id"] == cash_wallet.id
    assert wallet_confirmed.json()["result"]["cashflow_posted"] is True

    fact = await client.post(
        "/api/finance/capture/interpret",
        json={
            "space_id": space_id,
            "text": "From September nursery should drop by roughly £800 a month.",
            "conversation": [
                {"role": "user", "text": "temporary-context-marker-7391"},
                {"role": "assistant", "text": "I will use that only on this screen."},
            ],
        },
        headers=adult_a_headers,
    )
    assert fact.status_code == 200, fact.text
    draft = fact.json()["drafts"][0]
    assert draft["content"]["kind"] == "FACT"
    async with aiosqlite.connect(initialized_db) as db:
        assert (await (await db.execute("SELECT COUNT(*) FROM finance_facts")).fetchone())[0] == 0
        stored = await (
            await db.execute(
                "SELECT payload_json,target_options_json FROM finance_capture_drafts WHERE id = ?",
                (draft["id"],),
            )
        ).fetchone()
        assert "temporary-context-marker-7391" not in json.dumps(stored)

    partner_attempt = await client.post(
        f"/api/finance/capture/{draft['id']}/confirm",
        json={"content": draft["content"]},
        headers=adult_b_headers,
    )
    assert partner_attempt.status_code == 404
    confirmed = await client.post(
        f"/api/finance/capture/{draft['id']}/confirm",
        json={"content": draft["content"]},
        headers=adult_a_headers,
    )
    replay = await client.post(
        f"/api/finance/capture/{draft['id']}/confirm",
        json={"content": draft["content"]},
        headers=adult_a_headers,
    )
    assert confirmed.status_code == replay.status_code == 200
    assert confirmed.json() == replay.json()
    async with standalone_db(initialized_db) as db:
        await db.execute(
            "UPDATE finance_capture_drafts SET expires_at = '2020-01-01T00:00:00+00:00' "
            "WHERE id = ?",
            (draft["id"],),
        )
        await db.commit()
        await expire_finance_capture_drafts(
            db, now=datetime(2026, 8, 1, 12, tzinfo=timezone.utc)
        )
    late_replay = await client.post(
        f"/api/finance/capture/{draft['id']}/confirm",
        json={"content": draft["content"]},
        headers=adult_a_headers,
    )
    assert late_replay.status_code == 200
    assert late_replay.json() == confirmed.json()
    changed = {**draft["content"], "statement": "Nursery will increase instead."}
    conflicting_replay = await client.post(
        f"/api/finance/capture/{draft['id']}/confirm",
        json={"content": changed},
        headers=adult_a_headers,
    )
    assert conflicting_replay.status_code == 409
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        saved = await (
            await db.execute(
                "SELECT status,statement FROM finance_facts WHERE id = ?",
                (confirmed.json()["action_id"],),
            )
        ).fetchone()
        capture = await (
            await db.execute(
                "SELECT status,payload_json,target_options_json FROM finance_capture_drafts "
                "WHERE id = ?",
                (draft["id"],),
            )
        ).fetchone()
    assert saved["status"] == "CONFIRMED"
    assert saved["statement"] == draft["content"]["statement"]
    assert dict(capture) == {
        "status": "CONFIRMED",
        "payload_json": "{}",
        "target_options_json": "[]",
    }

    question = await client.post(
        "/api/finance/capture/interpret",
        json={"space_id": space_id, "text": "Why are we not saving?"},
        headers=adult_a_headers,
    )
    assert question.status_code == 200, question.text
    assert question.json()["mode"] == "ANSWER"
    assert question.json()["drafts"] == []
    assert question.json()["conversation_persisted"] is False


async def test_household_commitment_capture_keeps_the_reviewed_date_useful(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    personal_id = next(item["id"] for item in spaces if item["kind"] == "personal")
    household_id = next(item["id"] for item in spaces if item["kind"] == "household")

    personal = await client.post(
        "/api/finance/capture/interpret",
        json={
            "space_id": personal_id,
            "text": "Car insurance is due in May and will probably be about £900.",
        },
        headers=adult_a_headers,
    )
    assert personal.status_code == 200
    personal_draft = personal.json()["drafts"][0]
    assert personal_draft["content"]["show_in_calendar"] is False
    assert personal_draft["content"]["show_in_tasks"] is False
    assert personal_draft["target_options"] == []

    household = await client.post(
        "/api/finance/capture/interpret",
        json={
            "space_id": household_id,
            "text": "Car insurance is due in May and will probably be about £900.",
        },
        headers=adult_a_headers,
    )
    assert household.status_code == 200, household.text
    draft = household.json()["drafts"][0]
    assert draft["content"]["show_in_calendar"] is True
    assert draft["content"]["show_in_tasks"] is False
    assert draft["content"]["responsible_user_id"] is None
    assert {option["id"] for option in draft["target_options"]} == {
        adult_a_user["id"], adult_b_user["id"]
    }

    reviewed = {
        **draft["content"],
        "payment_handling": "RENEWAL",
        "show_in_tasks": True,
        "responsible_user_id": adult_b_user["id"],
    }
    confirmed = await client.post(
        f"/api/finance/capture/{draft['id']}/confirm",
        json={"content": reviewed},
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()["result"]["payment_handling"] == "RENEWAL"
    assert confirmed.json()["result"]["show_in_calendar"] is True
    assert confirmed.json()["result"]["show_in_tasks"] is True
    assert confirmed.json()["result"]["responsible_user_id"] == adult_b_user["id"]

    due = reviewed["reviewed_date"]
    calendar = await client.get(
        "/api/calendar/",
        params={"start": due, "end": due, "limit": 20},
        headers=adult_a_headers,
    )
    assert calendar.status_code == 200
    assert [item["title"] for item in calendar.json()] == ["Car insurance renewal due"]
    tasks = await client.get("/api/tasks/", headers=adult_a_headers)
    assert tasks.status_code == 200
    reminder = next(item for item in tasks.json() if item["title"] == "Review or renew Car insurance")
    assert reminder["assigned_to"] == adult_b_user["id"]

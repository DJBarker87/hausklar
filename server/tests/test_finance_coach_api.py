import json
from datetime import date, datetime, timezone

import aiosqlite
import pytest

import app.routers.finance as finance_router
from app.config import settings
from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.ai import FinanceAnswer, FinanceReasoningTurn
from app.services.finance.ledger import (
    create_finance_account,
    import_source_transactions,
)


class MockFinanceAdapter:
    def __init__(self) -> None:
        self.contexts = []

    async def next_turn(self, *, question, query_results, conversation=()):
        self.contexts.append((question, tuple(query_results), tuple(conversation)))
        if not query_results:
            operation = (
                "get_financial_overview"
                if "overview" in question.lower()
                else (
                    "get_account_freshness"
                    if "fresh" in question.lower()
                    else "search_transactions"
                )
            )
            return FinanceReasoningTurn(
                kind="query",
                operation=operation,
                search_text="private" if operation == "search_transactions" else None,
                period_start=None,
                period_end=None,
                entity_ref=None,
                group_by=None,
                limit=20 if operation == "search_transactions" else None,
                answer=None,
            )
        result = query_results[-1]["result"]
        if "transactions" in result and result["transactions"]:
            evidence_id = result["transactions"][0]["evidence_id"]
            answer_text = result["transactions"][0]["description"]
            data_through = result["transactions"][0]["data_through_at"]
        else:
            evidence_id = result["evidence_id"]
            answer_text = "The deterministic Finance view is ready."
            data_through = result.get("data_through_at") or "2026-07-20T12:00:00+00:00"
        return FinanceReasoningTurn(
            kind="final",
            operation=None,
            search_text=None,
            period_start=None,
            period_end=None,
            entity_ref=None,
            group_by=None,
            limit=None,
            answer=FinanceAnswer(
                kind="answer",
                headline="Checked Finance answer",
                answer=answer_text,
                answer_mode="DATED_EXACT",
                data_through=data_through,
                claims=[{"text": answer_text, "evidence_ids": [evidence_id]}],
                estimates=[],
                suggested_actions=[],
                analysis_view_id=None,
                questions=[],
            ),
        )


async def _add_transaction(
    db_path: str,
    *,
    user: dict,
    space_id: str,
    label: str,
    identifier: str,
    description: str,
) -> None:
    enabled_user = user
    async with standalone_db(db_path) as db:
        account = await create_finance_account(
            db,
            user=enabled_user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label=label,
                institution="Fixture Bank",
                account_type="CURRENT",
                currency="GBP",
            ),
        )
        await import_source_transactions(
            db,
            user=enabled_user,
            space_id=space_id,
            account_id=account.id,
            observations=[
                NormalisedSourceTransaction(
                    source_kind="MANUAL",
                    source_batch_id="coach-fixture",
                    source_transaction_id=identifier,
                    booking_date=date(2026, 7, 20),
                    pending_status="POSTED",
                    amount_minor=-2500,
                    currency="GBP",
                    description=description,
                    observed_at=datetime(2026, 7, 20, 12, tzinfo=timezone.utc),
                )
            ],
        )


async def _accept(client, headers, consent: dict) -> None:
    response = await client.put(
        "/api/finance/ai-consent",
        json={
            "space_id": consent["space_id"],
            "accepted": True,
            "consent_version": consent["consent_version"],
        },
        headers=headers,
    )
    assert response.status_code == 200
    assert response.json()["consented"] is True


@pytest.mark.asyncio
async def test_finance_consent_and_bounded_read_only_coach(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
):
    monkeypatch.setattr(settings, "finance_ai_provider", "off")
    monkeypatch.setattr(settings, "finance_openai_model", "coach-test-model")

    assert (await client.get("/api/finance/members", headers=adult_a_headers)).status_code == 404
    assert (
        await client.patch(
            f"/api/finance/members/{adult_b_user['id']}",
            json={"enabled": False},
            headers=adult_a_headers,
        )
    ).status_code == 404

    adult_a_spaces_response = await client.get("/api/finance/spaces", headers=adult_a_headers)
    adult_b_spaces_response = await client.get("/api/finance/spaces", headers=adult_b_headers)
    assert adult_a_spaces_response.status_code == 200
    assert adult_b_spaces_response.status_code == 200
    adult_a_spaces = {row["kind"]: row["id"] for row in adult_a_spaces_response.json()}
    adult_b_spaces = {row["kind"]: row["id"] for row in adult_b_spaces_response.json()}

    await _add_transaction(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["personal"],
        label="Alex private",
        identifier="dom-private",
        description="Alex private tutoring",
    )
    await _add_transaction(
        initialized_db,
        user=adult_b_user,
        space_id=adult_b_spaces["personal"],
        label="Morgan private",
        identifier="kat-private",
        description="Morgan private gift",
    )
    await _add_transaction(
        initialized_db,
        user=adult_a_user,
        space_id=adult_a_spaces["household"],
        label="Household",
        identifier="household-nursery",
        description="Household nursery",
    )

    provider_off = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "Give an overview",
            "scope": "mine",
            "space_id": adult_a_spaces["personal"],
        },
        headers=adult_a_headers,
    )
    assert provider_off.status_code == 503
    assert provider_off.json()["detail"] == (
        "Finance couldn't answer just now. Your overview and transactions are still "
        "available."
    )
    off_consents = await client.get("/api/finance/ai-consent", headers=adult_a_headers)
    assert all(
        "Finance Coach is turned off" in item["disclosure"]
        and "ask for permission" in item["disclosure"]
        and "provider off" not in item["disclosure"]
        and "model none" not in item["disclosure"]
        for item in off_consents.json()
    )

    monkeypatch.setattr(settings, "finance_ai_provider", "openai")
    adapter = MockFinanceAdapter()
    monkeypatch.setattr(
        finance_router, "build_finance_reasoning_adapter", lambda: adapter
    )
    general_consent_does_not_count = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "Find my private costs",
            "scope": "mine",
            "space_id": adult_a_spaces["personal"],
        },
        headers=adult_a_headers,
    )
    assert general_consent_does_not_count.status_code == 428

    adult_a_consents = await client.get("/api/finance/ai-consent", headers=adult_a_headers)
    assert adult_a_consents.status_code == 200
    assert len(adult_a_consents.json()) == 2
    assert all(item["provider"] == "openai" for item in adult_a_consents.json())
    assert all(item["model"] == "coach-test-model" for item in adult_a_consents.json())
    assert all(item["store"] is False for item in adult_a_consents.json())
    assert all(item["background_processing"] is False for item in adult_a_consents.json())
    assert all("Only after you press Send" in item["disclosure"] for item in adult_a_consents.json())
    assert all("with OpenAI" in item["disclosure"] for item in adult_a_consents.json())
    assert all("account names and update times" in item["disclosure"] for item in adult_a_consents.json())
    assert all("transaction dates, descriptions, merchants" in item["disclosure"] for item in adult_a_consents.json())
    assert all("calculated totals" in item["disclosure"] for item in adult_a_consents.json())
    assert all("Bank credentials are never shared" in item["disclosure"] for item in adult_a_consents.json())
    assert all("asked not to store the request" in item["disclosure"] for item in adult_a_consents.json())
    for consent in adult_a_consents.json():
        await _accept(client, adult_a_headers, consent)

    oversized = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "x" * 4_001,
            "scope": "mine",
            "space_id": adult_a_spaces["personal"],
        },
        headers=adult_a_headers,
    )
    assert oversized.status_code == 422
    private_without_partner_consent = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "Find my private costs",
            "scope": "mine",
            "space_id": adult_a_spaces["personal"],
        },
        headers=adult_a_headers,
    )
    # My finances contains personal plus household data, so the household part
    # still needs every adult's current provider consent.
    assert private_without_partner_consent.status_code == 428
    assert "Every adult" in private_without_partner_consent.json()["detail"]

    mismatched_scope = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "Find my private costs",
            "scope": "mine",
            "space_id": adult_a_spaces["household"],
        },
        headers=adult_a_headers,
    )
    assert mismatched_scope.status_code == 422

    household_missing_partner = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "Give a household overview",
            "scope": "household",
            "space_id": adult_a_spaces["household"],
        },
        headers=adult_a_headers,
    )
    assert household_missing_partner.status_code == 428
    adult_b_consents = (
        await client.get("/api/finance/ai-consent", headers=adult_b_headers)
    ).json()
    adult_b_household = next(row for row in adult_b_consents if row["space_kind"] == "household")
    await _accept(client, adult_b_headers, adult_b_household)
    mine = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "And what was that tutoring payment?",
            "scope": "mine",
            "space_id": adult_a_spaces["personal"],
            "conversation": [
                {"role": "user", "text": "Find my private costs"},
                {
                    "role": "assistant",
                    "text": "I found a private tutoring payment in the checked data.",
                },
            ],
        },
        headers=adult_a_headers,
    )
    assert mine.status_code == 200
    assert mine.json()["answer"] == "Alex private tutoring"
    mine_context = json.dumps(adapter.contexts)
    assert all(
        context[2][0]["text"] == "Find my private costs"
        for context in adapter.contexts[-2:]
    )
    assert "Alex private tutoring" in mine_context
    assert "Morgan private gift" not in mine_context
    assert "Household nursery" not in mine_context
    mine_overview = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "Give my overview",
            "scope": "mine",
            "space_id": adult_a_spaces["personal"],
        },
        headers=adult_a_headers,
    )
    assert mine_overview.status_code == 200
    overview_result = adapter.contexts[-1][1][-1]["result"]
    assert overview_result["view_scope"] == "personal_and_household"
    assert overview_result["currencies"][0]["gross_spending_minor"] == 5_000
    assert "Morgan private gift" not in json.dumps(adapter.contexts[-2:])
    freshness = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "How fresh are my accounts?",
            "scope": "mine",
            "space_id": adult_a_spaces["personal"],
        },
        headers=adult_a_headers,
    )
    assert freshness.status_code == 200
    household = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "Give a household overview",
            "scope": "household",
            "space_id": adult_a_spaces["household"],
        },
        headers=adult_a_headers,
    )
    assert household.status_code == 200

    changed_model = settings.finance_openai_model
    monkeypatch.setattr(settings, "finance_openai_model", "new-model-version")
    invalidated = await client.post(
        "/api/finance/coach/ask",
        json={
            "question": "Give an overview",
            "scope": "mine",
            "space_id": adult_a_spaces["personal"],
        },
        headers=adult_a_headers,
    )
    assert invalidated.status_code == 428
    monkeypatch.setattr(settings, "finance_openai_model", changed_model)

    revoked = await client.delete(
        "/api/finance/ai-consent",
        params={"space_id": adult_b_spaces["household"]},
        headers=adult_b_headers,
    )
    assert revoked.status_code == 200
    assert revoked.json()["consented"] is False
    assert (
        await client.post(
            "/api/finance/coach/ask",
            json={
                "question": "Give a household overview",
                "scope": "household",
                "space_id": adult_a_spaces["household"],
            },
            headers=adult_a_headers,
        )
    ).status_code == 428

    async with aiosqlite.connect(initialized_db) as db:
        transcript_tables = await (
            await db.execute(
                """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND (
                    lower(name) LIKE 'finance%chat%'
                    OR lower(name) LIKE 'finance%conversation%'
                    OR lower(name) LIKE 'finance%transcript%'
                )
                """
            )
        ).fetchall()
    assert transcript_tables == []

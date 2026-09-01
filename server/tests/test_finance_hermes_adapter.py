import json

import aiosqlite
import httpx
import pytest

import app.routers.finance as finance_router
import app.services.finance.capture as finance_capture
from app.config import settings
from app.services.finance.ai import (
    FinanceAnswer,
    FinanceReasoningError,
    HermesFinanceReasoningAdapter,
)
from app.services.finance.coach import (
    FinanceCoachUnavailableError,
    build_finance_reasoning_adapter,
)


_BRIDGE_TOKEN = "test-hermes-bridge-token-0123456789"  # gitleaks:allow


def _query_turn(**overrides) -> dict:
    value = {
        "kind": "query",
        "operation": "search_transactions",
        "search_text": "nursery",
        "period_start": "2026-01-01",
        "period_end": "2026-08-03",
        "entity_ref": None,
        "group_by": None,
        "limit": 20,
        "answer": None,
    }
    value.update(overrides)
    return value


def _partial_turn(*, suggested_actions: list[str] | None = None) -> dict:
    return {
        "kind": "final",
        "operation": None,
        "search_text": None,
        "period_start": None,
        "period_end": None,
        "entity_ref": None,
        "group_by": None,
        "limit": None,
        "answer": {
            "kind": "partial",
            "headline": "One useful next step",
            "answer": "Review whether this goal still matters before changing it.",
            "answer_mode": "PARTIAL",
            "data_through": None,
            "claims": [],
            "estimates": [],
            "suggested_actions": suggested_actions or [],
            "analysis_view_id": None,
            "questions": [],
        },
    }


def _bridge_response(turn: dict) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "turn": turn,
            "provider": "openai-codex",
            "model": "gpt-5.5",
        },
    )


def test_hermes_provider_selection_requires_the_private_bridge(monkeypatch):
    monkeypatch.setattr(settings, "finance_ai_provider", "hermes")
    monkeypatch.setattr(settings, "hermes_bridge_url", "http://192.0.2.91:9120")
    monkeypatch.setattr(settings, "hermes_bridge_token", _BRIDGE_TOKEN)

    adapter = build_finance_reasoning_adapter()

    assert isinstance(adapter, HermesFinanceReasoningAdapter)
    assert adapter._url == "http://192.0.2.91:9120/v1/finance"

    monkeypatch.setattr(settings, "hermes_bridge_url", "")
    monkeypatch.setattr(settings, "hermes_bridge_token", "")
    with pytest.raises(FinanceCoachUnavailableError):
        build_finance_reasoning_adapter()

    monkeypatch.setattr(settings, "hermes_bridge_url", "http://192.0.2.91:9120")
    monkeypatch.setattr(settings, "hermes_bridge_token", _BRIDGE_TOKEN)
    monkeypatch.setattr(settings, "finance_hermes_model", "   ")
    with pytest.raises(FinanceCoachUnavailableError):
        build_finance_reasoning_adapter()


@pytest.mark.asyncio
async def test_capture_question_closes_its_request_owned_reasoning_client(monkeypatch):
    class ClosingAdapter:
        closed = False

        async def aclose(self):
            self.closed = True

    adapter = ClosingAdapter()
    answer = FinanceAnswer(
        kind="partial",
        headline="Checked answer",
        answer="Nothing needs changing today.",
        answer_mode="PARTIAL",
        data_through=None,
        claims=[],
        estimates=[],
        suggested_actions=[],
        analysis_view_id=None,
        questions=[],
    )

    async def consent_allows_space(*args, **kwargs):
        del args, kwargs
        return True

    async def run_reasoning(**kwargs):
        assert kwargs["adapter"] is adapter
        return answer

    monkeypatch.setattr(
        finance_capture,
        "finance_ai_consent_allows_space",
        consent_allows_space,
    )
    monkeypatch.setattr(
        finance_capture, "build_finance_reasoning_adapter", lambda: adapter
    )
    monkeypatch.setattr(finance_capture, "run_finance_reasoning", run_reasoning)

    result = await finance_capture._answer_question(
        object(),
        user={"id": "adult-1", "family_id": "family-1"},
        space_id="personal-1",
        question="What changed?",
    )

    assert result == answer
    assert adapter.closed is True


@pytest.mark.asyncio
async def test_hermes_adapter_sends_only_bounded_temporary_finance_context():
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["authorization"] = request.headers["Authorization"]
        captured["payload"] = json.loads(request.content)
        return _bridge_response(_query_turn())

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = HermesFinanceReasoningAdapter(
            bridge_url="http://hermes.test:9120",
            bridge_token=_BRIDGE_TOKEN,
            timeout_seconds=10,
            client=client,
        )
        turn = await adapter.next_turn(
            question="How much did nursery cost?",
            query_results=[
                {
                    "operation": "get_financial_overview",
                    "result": {"evidence_id": "overview:1", "amount_minor": 250_000},
                }
            ],
            conversation=[
                {"role": "user", "text": "What changed this month?"},
                {"role": "assistant", "text": "I need to check nursery."},
            ],
        )

    assert turn.operation == "search_transactions"
    assert captured["url"] == "http://hermes.test:9120/v1/finance"
    assert captured["authorization"] == f"Bearer {_BRIDGE_TOKEN}"
    assert set(captured["payload"]) == {"message", "context"}
    assert set(captured["payload"]["context"]) == {
        "conversation",
        "query_results",
    }
    encoded = json.dumps(captured["payload"])
    assert "overview:1" in encoded
    assert "What changed this month?" in encoded
    assert all(
        forbidden not in encoded
        for forbidden in (
            '"tools"',
            '"model"',
            '"store"',
            '"user_id"',
            '"space_id"',
        )
    )


@pytest.mark.asyncio
async def test_hermes_adapter_rejects_oversized_context_before_contacting_bridge():
    adapter = HermesFinanceReasoningAdapter(
        bridge_url="http://hermes.test:9120",
        bridge_token=_BRIDGE_TOKEN,
        timeout_seconds=10,
    )
    with pytest.raises(FinanceReasoningError):
        await adapter.next_turn(question="x" * 4_001, query_results=[])
    with pytest.raises(FinanceReasoningError):
        await adapter.next_turn(
            question="Summarise this",
            query_results=[
                {
                    "operation": "get_financial_overview",
                    "result": {"data": "x" * 100_000},
                }
            ],
        )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "response",
    [
        _bridge_response(_query_turn(operation="run_sql")),
        httpx.Response(
            200,
            json={
                "turn": _query_turn(),
                "provider": "openai-codex",
                "model": "gpt-5.5",
                "unexpected": True,
            },
        ),
        httpx.Response(
            200,
            json={
                "turn": _query_turn(),
                "provider": "unapproved-provider",
                "model": "gpt-5.5",
            },
        ),
        _bridge_response(
            {
                **_partial_turn(),
                "answer": {
                    **_partial_turn()["answer"],
                    "action": {"kind": "create_goal", "amount_minor": 250_000},
                },
            }
        ),
    ],
)
async def test_hermes_adapter_rejects_invalid_or_executable_responses(response):
    async def handler(_: httpx.Request) -> httpx.Response:
        return response

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = HermesFinanceReasoningAdapter(
            bridge_url="http://hermes.test:9120",
            bridge_token=_BRIDGE_TOKEN,
            timeout_seconds=10,
            client=client,
        )
        with pytest.raises(FinanceReasoningError):
            await adapter.next_turn(question="Change my goal", query_results=[])


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", ["timeout", "unavailable", "bad_gateway"])
async def test_hermes_adapter_fails_cleanly_when_the_bridge_is_unavailable(failure):
    def handler(request: httpx.Request) -> httpx.Response:
        if failure == "timeout":
            raise httpx.ReadTimeout("private detail", request=request)
        if failure == "unavailable":
            raise httpx.ConnectError("private detail", request=request)
        return httpx.Response(504, json={"detail": "private bridge detail"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = HermesFinanceReasoningAdapter(
            bridge_url="http://hermes.test:9120",
            bridge_token=_BRIDGE_TOKEN,
            timeout_seconds=10,
            client=client,
        )
        with pytest.raises(FinanceReasoningError) as raised:
            await adapter.next_turn(question="What changed?", query_results=[])

    assert "private detail" not in str(raised.value)
    assert "private bridge detail" not in str(raised.value)


async def _accept_all_required_consents(client, adult_a_headers, adult_b_headers) -> str:
    adult_a_consents = (await client.get("/api/finance/ai-consent", headers=adult_a_headers)).json()
    adult_b_consents = (await client.get("/api/finance/ai-consent", headers=adult_b_headers)).json()
    assert all(
        "private Hermes Finance service" in consent["disclosure"]
        and "uses OpenAI to produce the answer" in consent["disclosure"]
        for consent in adult_a_consents
    )
    for consent in adult_a_consents:
        response = await client.put(
            "/api/finance/ai-consent",
            json={
                "space_id": consent["space_id"],
                "accepted": True,
                "consent_version": consent["consent_version"],
            },
            headers=adult_a_headers,
        )
        assert response.status_code == 200
    for consent in adult_b_consents:
        if consent["space_kind"] != "household":
            continue
        response = await client.put(
            "/api/finance/ai-consent",
            json={
                "space_id": consent["space_id"],
                "accepted": True,
                "consent_version": consent["consent_version"],
            },
            headers=adult_b_headers,
        )
        assert response.status_code == 200
    return next(
        consent["space_id"] for consent in adult_a_consents if consent["space_kind"] == "personal"
    )


async def _mutation_counts(db_path: str) -> tuple[int, ...]:
    tables = (
        "finance_goals",
        "finance_plans",
        "finance_commitments",
        "finance_habits",
        "finance_purchase_proposals",
        "finance_opportunity_actions",
    )
    async with aiosqlite.connect(db_path) as db:
        counts = []
        for table in tables:
            row = await (await db.execute(f"SELECT COUNT(*) FROM {table}")).fetchone()
            counts.append(row[0])
        return tuple(counts)


@pytest.mark.asyncio
async def test_hermes_receives_nothing_before_current_finance_consent(
    client,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    monkeypatch,
):
    del adult_a_user, adult_b_user
    monkeypatch.setattr(settings, "finance_ai_provider", "hermes")
    monkeypatch.setattr(settings, "finance_hermes_model", "hermes-finance-test")
    monkeypatch.setattr(settings, "hermes_bridge_url", "http://192.0.2.91:9120")
    monkeypatch.setattr(settings, "hermes_bridge_token", _BRIDGE_TOKEN)
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    personal_space_id = next(space["id"] for space in spaces if space["kind"] == "personal")
    bridge_calls = 0

    def handler(_: httpx.Request) -> httpx.Response:
        nonlocal bridge_calls
        bridge_calls += 1
        return _bridge_response(_partial_turn())

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as bridge:
        adapter = HermesFinanceReasoningAdapter(
            bridge_url=settings.hermes_bridge_url,
            bridge_token=settings.hermes_bridge_token,
            timeout_seconds=10,
            client=bridge,
        )
        adapter_closed = False
        original_close = adapter.aclose

        async def tracked_close():
            nonlocal adapter_closed
            adapter_closed = True
            await original_close()

        adapter.aclose = tracked_close
        monkeypatch.setattr(
            finance_router,
            "build_finance_reasoning_adapter",
            lambda: adapter,
        )
        response = await client.post(
            "/api/finance/coach/ask",
            json={
                "question": "What changed?",
                "scope": "mine",
                "space_id": personal_space_id,
            },
            headers=adult_a_headers,
        )

    assert response.status_code == 428
    assert bridge_calls == 0
    assert adapter_closed is True


@pytest.mark.asyncio
async def test_capture_does_not_share_household_finance_until_every_adult_consents(
    client,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
):
    del adult_a_user, adult_b_user
    monkeypatch.setattr(settings, "finance_ai_provider", "hermes")
    monkeypatch.setattr(settings, "finance_hermes_model", "hermes-finance-test")
    monkeypatch.setattr(settings, "hermes_bridge_url", "http://192.0.2.91:9120")
    monkeypatch.setattr(settings, "hermes_bridge_token", _BRIDGE_TOKEN)
    adult_a_consents = (
        await client.get("/api/finance/ai-consent", headers=adult_a_headers)
    ).json()
    household = next(item for item in adult_a_consents if item["space_kind"] == "household")
    accepted = await client.put(
        "/api/finance/ai-consent",
        json={
            "space_id": household["space_id"],
            "accepted": True,
            "consent_version": household["consent_version"],
        },
        headers=adult_a_headers,
    )
    assert accepted.status_code == 200
    bridge_calls = 0

    def handler(_: httpx.Request) -> httpx.Response:
        nonlocal bridge_calls
        bridge_calls += 1
        return _bridge_response(_partial_turn())

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as bridge:
        adapter = HermesFinanceReasoningAdapter(
            bridge_url=settings.hermes_bridge_url,
            bridge_token=settings.hermes_bridge_token,
            timeout_seconds=10,
            client=bridge,
        )
        monkeypatch.setattr(
            finance_capture,
            "build_finance_reasoning_adapter",
            lambda: adapter,
        )
        before_partner_consent = await client.post(
            "/api/finance/capture/interpret",
            json={
                "space_id": household["space_id"],
                "text": "Why are household costs higher?",
            },
            headers=adult_a_headers,
        )
        assert before_partner_consent.status_code == 200
        assert before_partner_consent.json()["mode"] == "ANSWER"
        assert bridge_calls == 0

        adult_b_consents = (
            await client.get("/api/finance/ai-consent", headers=adult_b_headers)
        ).json()
        adult_b_household = next(
            item for item in adult_b_consents if item["space_kind"] == "household"
        )
        partner_accepted = await client.put(
            "/api/finance/ai-consent",
            json={
                "space_id": adult_b_household["space_id"],
                "accepted": True,
                "consent_version": adult_b_household["consent_version"],
            },
            headers=adult_b_headers,
        )
        assert partner_accepted.status_code == 200
        after_partner_consent = await client.post(
            "/api/finance/capture/interpret",
            json={
                "space_id": household["space_id"],
                "text": "Why are household costs higher?",
            },
            headers=adult_a_headers,
        )

    assert after_partner_consent.status_code == 200
    assert after_partner_consent.json()["answer"]["headline"] == "One useful next step"
    assert bridge_calls == 1


@pytest.mark.asyncio
async def test_hermes_suggestion_does_not_change_finance_before_confirmation(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
):
    del adult_a_user, adult_b_user
    monkeypatch.setattr(settings, "finance_ai_provider", "hermes")
    monkeypatch.setattr(settings, "finance_hermes_model", "hermes-finance-test")
    monkeypatch.setattr(settings, "hermes_bridge_url", "http://192.0.2.91:9120")
    monkeypatch.setattr(settings, "hermes_bridge_token", _BRIDGE_TOKEN)
    personal_space_id = await _accept_all_required_consents(client, adult_a_headers, adult_b_headers)
    before = await _mutation_counts(initialized_db)

    def handler(_: httpx.Request) -> httpx.Response:
        return _bridge_response(
            _partial_turn(suggested_actions=["Review the holiday savings target"])
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as bridge:
        adapter = HermesFinanceReasoningAdapter(
            bridge_url=settings.hermes_bridge_url,
            bridge_token=settings.hermes_bridge_token,
            timeout_seconds=10,
            client=bridge,
        )
        adapter_closed = False
        original_close = adapter.aclose

        async def tracked_close():
            nonlocal adapter_closed
            adapter_closed = True
            await original_close()

        adapter.aclose = tracked_close
        monkeypatch.setattr(
            finance_router,
            "build_finance_reasoning_adapter",
            lambda: adapter,
        )
        response = await client.post(
            "/api/finance/coach/ask",
            json={
                "question": "Should I change the holiday savings target?",
                "scope": "mine",
                "space_id": personal_space_id,
            },
            headers=adult_a_headers,
        )

    assert response.status_code == 200
    assert response.json()["suggested_actions"] == [
        "Review the holiday savings target"
    ]
    assert adapter_closed is True
    assert await _mutation_counts(initialized_db) == before

from collections.abc import Mapping, Sequence

import pytest

from app.services.finance.ai import (
    FinanceAnswer,
    FinanceReasoningError,
    FinanceReasoningTurn,
    run_finance_reasoning,
)


def _query(operation="get_financial_overview", **values):
    payload = {
        "kind": "query",
        "operation": operation,
        "search_text": None,
        "period_start": None,
        "period_end": None,
        "entity_ref": None,
        "group_by": None,
        "limit": None,
        "answer": None,
    }
    payload.update(values)
    return FinanceReasoningTurn.model_validate(payload)


def _final(
    evidence_id: str | None = None,
    *,
    analysis_view_id: str | None = None,
):
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
            headline="Nursery is the largest fixed cost",
            answer="Nursery cost £2,500 through July.",
            answer_mode="DATED_EXACT",
            data_through="2026-07-31T23:00:00Z",
            claims=(
                []
                if evidence_id is None
                else [{"text": "Nursery cost £2,500.", "evidence_ids": [evidence_id]}]
            ),
            estimates=[],
            suggested_actions=[],
            analysis_view_id=analysis_view_id,
            questions=[],
        ),
    )


class SequenceAdapter:
    def __init__(self, turns: Sequence[FinanceReasoningTurn]):
        self.turns = iter(turns)
        self.contexts: list[Sequence[Mapping[str, object]]] = []

    async def next_turn(self, *, question, query_results):
        self.contexts.append(tuple(query_results))
        return next(self.turns)


class RecordingExecutor:
    def __init__(self):
        self.calls = []

    async def execute(self, **call):
        self.calls.append(call)
        return {
            "evidence_id": "analysis:overview:1",
            "amount_minor": 250_000,
            "currency": "GBP",
        }


@pytest.mark.asyncio
async def test_loop_binds_server_principal_and_space_and_checks_evidence():
    adapter = SequenceAdapter([_query(), _final("analysis:overview:1")])
    executor = RecordingExecutor()

    answer = await run_finance_reasoning(
        adapter=adapter,
        executor=executor,
        question="Why are we not saving?",
        principal={"id": "adult-1", "family_id": "family-1"},
        space_id="space-owned-by-server",
    )

    assert answer.answer_mode == "DATED_EXACT"
    assert executor.calls == [
        {
            "operation": "get_financial_overview",
            "arguments": {},
            "principal": {"id": "adult-1", "family_id": "family-1"},
            "space_id": "space-owned-by-server",
        }
    ]
    assert adapter.contexts[0] == ()
    assert adapter.contexts[1][0]["operation"] == "get_financial_overview"


@pytest.mark.asyncio
async def test_loop_rejects_missing_arguments_and_invented_evidence():
    executor = RecordingExecutor()
    with pytest.raises(FinanceReasoningError):
        await run_finance_reasoning(
            adapter=SequenceAdapter([_query("search_transactions")]),
            executor=executor,
            question="Find nursery",
            principal={"id": "adult-1"},
            space_id="space-1",
        )

    with pytest.raises(FinanceReasoningError):
        await run_finance_reasoning(
            adapter=SequenceAdapter(
                [_final("analysis:overview:1", analysis_view_id="analysis:invented")]
            ),
            executor=executor,
            question="Open the analysis",
            principal={"id": "adult-1"},
            space_id="space-1",
        )
    assert executor.calls == []

    with pytest.raises(FinanceReasoningError):
        await run_finance_reasoning(
            adapter=SequenceAdapter([_final("invented:evidence")]),
            executor=executor,
            question="How much?",
            principal={"id": "adult-1"},
            space_id="space-1",
        )


@pytest.mark.asyncio
async def test_loop_stops_once_at_query_cap_with_plain_partial_answer():
    adapter = SequenceAdapter([_query(), _query(), _query()])
    executor = RecordingExecutor()

    answer = await run_finance_reasoning(
        adapter=adapter,
        executor=executor,
        question="Investigate",
        principal={"id": "adult-1"},
        space_id="space-1",
        max_query_turns=2,
    )

    assert answer.kind == "partial"
    assert answer.answer_mode == "PARTIAL"
    assert len(executor.calls) == 2


@pytest.mark.asyncio
async def test_loop_rejects_oversized_deterministic_result():
    class OversizedExecutor(RecordingExecutor):
        async def execute(self, **call):
            return {"evidence_id": "large:1", "data": "x" * 70_000}

    with pytest.raises(FinanceReasoningError):
        await run_finance_reasoning(
            adapter=SequenceAdapter([_query()]),
            executor=OversizedExecutor(),
            question="Investigate",
            principal={"id": "adult-1"},
            space_id="space-1",
        )

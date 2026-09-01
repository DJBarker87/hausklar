"""Server-controlled loop for bounded, read-only Finance reasoning queries."""

import json
import inspect
from collections.abc import Mapping, Sequence
from typing import Protocol

from app.services.finance.ai.base import (
    FinanceAnswer,
    FinanceQueryOperation,
    FinanceReasoningAdapter,
    FinanceReasoningError,
    FinanceReasoningTurn,
)

_MAX_RESULT_BYTES = 64_000
_DEFAULT_MAX_QUERY_TURNS = 4
_MAX_CONVERSATION_TURNS = 8
_MAX_CONVERSATION_CHARS = 8_000
_MAX_CONVERSATION_BYTES = 16_000


class FinanceQueryExecutor(Protocol):
    async def execute(
        self,
        *,
        operation: FinanceQueryOperation,
        arguments: Mapping[str, object],
        principal: Mapping[str, object],
        space_ids: Sequence[str],
    ) -> Mapping[str, object]:
        """Execute one deterministic read with server-bound principal and spaces."""


_OPERATION_ARGUMENTS: dict[str, frozenset[str]] = {
    "get_financial_overview": frozenset({"period_start", "period_end"}),
    "search_transactions": frozenset(
        {"search_text", "period_start", "period_end", "limit"}
    ),
    "get_transaction_context": frozenset({"entity_ref"}),
    "analyse_finance": frozenset({"period_start", "period_end", "group_by", "limit"}),
    "compare_periods": frozenset({"period_start", "period_end", "group_by"}),
    "get_account_freshness": frozenset(),
    "get_recurring_series": frozenset({"period_start", "period_end", "limit"}),
    "get_unitemised_purchase_queue": frozenset({"limit"}),
    "search_purchase_lines": frozenset(
        {"search_text", "period_start", "period_end", "limit"}
    ),
    "aggregate_purchase_lines": frozenset(
        {"search_text", "period_start", "period_end", "group_by", "limit"}
    ),
    "get_purchase_and_line_evidence": frozenset({"entity_ref"}),
    "find_repeated_or_duplicate_items": frozenset({"period_start", "period_end", "limit"}),
    "get_product_purchase_history": frozenset({"entity_ref", "limit"}),
    "compare_item_prices": frozenset({"entity_ref", "period_start", "period_end", "limit"}),
    "get_finding_evidence": frozenset({"entity_ref"}),
}

_REQUIRED_ARGUMENTS: dict[str, frozenset[str]] = {
    "search_transactions": frozenset({"search_text"}),
    "get_transaction_context": frozenset({"entity_ref"}),
    "search_purchase_lines": frozenset({"search_text"}),
    "get_purchase_and_line_evidence": frozenset({"entity_ref"}),
    "get_product_purchase_history": frozenset({"entity_ref"}),
    "compare_item_prices": frozenset({"entity_ref"}),
    "get_finding_evidence": frozenset({"entity_ref"}),
}


def _arguments(turn: FinanceReasoningTurn) -> dict[str, object]:
    if turn.operation is None:
        raise FinanceReasoningError("Finance reasoning query omitted its operation")
    values = {
        "search_text": turn.search_text,
        "period_start": turn.period_start,
        "period_end": turn.period_end,
        "entity_ref": turn.entity_ref,
        "group_by": turn.group_by,
        "limit": turn.limit,
    }
    allowed = _OPERATION_ARGUMENTS[turn.operation]
    arguments = {key: value for key, value in values.items() if key in allowed and value is not None}
    missing = _REQUIRED_ARGUMENTS.get(turn.operation, frozenset()) - arguments.keys()
    if missing:
        raise FinanceReasoningError("Finance reasoning query omitted a required argument")
    return arguments


def _evidence_ids(value: object) -> set[str]:
    found: set[str] = set()
    if isinstance(value, Mapping):
        evidence_id = value.get("evidence_id")
        if isinstance(evidence_id, str):
            found.add(evidence_id)
        evidence_ids = value.get("evidence_ids")
        if isinstance(evidence_ids, list):
            found.update(item for item in evidence_ids if isinstance(item, str))
        for nested in value.values():
            found.update(_evidence_ids(nested))
    elif isinstance(value, list | tuple):
        for nested in value:
            found.update(_evidence_ids(nested))
    return found


def _validate_answer_evidence(answer: FinanceAnswer, available_ids: set[str]) -> None:
    for claim in answer.claims:
        if any(evidence_id not in available_ids for evidence_id in claim.evidence_ids):
            raise FinanceReasoningError("Finance answer referenced unavailable evidence")
    if (
        answer.analysis_view_id is not None
        and answer.analysis_view_id not in available_ids
    ):
        raise FinanceReasoningError("Finance answer referenced an unavailable analysis")


async def run_finance_reasoning(
    *,
    adapter: FinanceReasoningAdapter,
    executor: FinanceQueryExecutor,
    question: str,
    conversation: Sequence[Mapping[str, str]] = (),
    principal: Mapping[str, object],
    space_ids: Sequence[str] | None = None,
    space_id: str | None = None,
    max_query_turns: int = _DEFAULT_MAX_QUERY_TURNS,
) -> FinanceAnswer:
    """Run a small read-only loop without accepting model-selected identity or scope."""

    if not principal.get("id"):
        raise FinanceReasoningError("Finance reasoning requires a bound principal and space")
    if len(conversation) > _MAX_CONVERSATION_TURNS:
        raise FinanceReasoningError("Finance screen conversation is too long")
    temporary_conversation: tuple[dict[str, str], ...] = ()
    if conversation:
        checked = []
        total_chars = 0
        for turn in conversation:
            if set(turn) != {"role", "text"}:
                raise FinanceReasoningError("Finance screen conversation is invalid")
            role, text = turn.get("role"), turn.get("text")
            if role not in {"user", "assistant"} or not isinstance(text, str):
                raise FinanceReasoningError("Finance screen conversation is invalid")
            text = text.strip()
            if not text or len(text) > 1_500:
                raise FinanceReasoningError("Finance screen conversation is invalid")
            total_chars += len(text)
            checked.append({"role": role, "text": text})
        if total_chars > _MAX_CONVERSATION_CHARS:
            raise FinanceReasoningError("Finance screen conversation is too long")
        encoded = json.dumps(checked, ensure_ascii=False, separators=(",", ":"))
        if len(encoded.encode("utf-8")) > _MAX_CONVERSATION_BYTES:
            raise FinanceReasoningError("Finance screen conversation is too long")
        temporary_conversation = tuple(checked)
    if space_ids is not None:
        bound_space_ids = tuple(dict.fromkeys(space_ids))
        if not bound_space_ids or any(not value for value in bound_space_ids):
            raise FinanceReasoningError(
                "Finance reasoning requires a bound principal and space"
            )
        execution_scope = {"space_ids": bound_space_ids}
    elif space_id:
        # Compatibility for existing single-space callers while the Finance API
        # always uses the multi-space, server-resolved path below.
        execution_scope = {"space_id": space_id}
    else:
        raise FinanceReasoningError("Finance reasoning requires a bound principal and space")
    if not 1 <= max_query_turns <= 8:
        raise ValueError("Finance query-turn limit must be between 1 and 8")

    query_results: list[Mapping[str, object]] = []
    evidence_ids: set[str] = set()
    for _ in range(max_query_turns + 1):
        adapter_parameters = inspect.signature(adapter.next_turn).parameters
        if "conversation" in adapter_parameters:
            turn = await adapter.next_turn(
                question=question,
                query_results=query_results,
                conversation=temporary_conversation,
            )
        elif temporary_conversation:
            raise FinanceReasoningError(
                "The configured Finance reasoning adapter cannot receive follow-up context"
            )
        else:
            # Keep older in-process deterministic adapters valid while provider
            # adapters adopt the temporary-conversation argument.
            turn = await adapter.next_turn(question=question, query_results=query_results)
        if turn.kind == "final":
            assert turn.answer is not None
            _validate_answer_evidence(turn.answer, evidence_ids)
            return turn.answer
        if len(query_results) >= max_query_turns:
            return FinanceAnswer(
                kind="partial",
                headline="I could not finish this analysis safely",
                answer=(
                    "I reached the limit for checked Finance queries. "
                    "The deterministic Finance views remain available."
                ),
                answer_mode="PARTIAL",
                data_through=None,
                claims=[],
                estimates=[],
                suggested_actions=[],
                analysis_view_id=None,
                questions=[],
            )

        assert turn.operation is not None
        result = await executor.execute(
            operation=turn.operation,
            arguments=_arguments(turn),
            principal=principal,
            **execution_scope,
        )
        encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":"), default=str)
        if len(encoded.encode("utf-8")) > _MAX_RESULT_BYTES:
            raise FinanceReasoningError("A deterministic Finance query returned too much data")
        evidence_ids.update(_evidence_ids(result))
        query_results.append(
            {
                "operation": turn.operation,
                "result": result,
            }
        )

    raise AssertionError("Finance reasoning loop terminated unexpectedly")

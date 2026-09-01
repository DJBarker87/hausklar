"""Typed contract shared by Finance reasoning providers.

Adapters can ask HausKlar for one allowlisted deterministic query or publish an
answer. They never receive a database connection and cannot execute the query.
"""

import json
from collections.abc import Mapping, Sequence
from typing import Annotated, Literal, Protocol, TypeAlias

from pydantic import BaseModel, ConfigDict, Field, StrictInt, model_validator


class FinanceReasoningError(RuntimeError):
    """A reasoning provider was unavailable or returned an invalid turn."""


_MAX_QUESTION_CHARS = 4_000
_MAX_CONTEXT_BYTES = 96_000
_MAX_CONVERSATION_TURNS = 8
_MAX_CONVERSATION_CHARS = 8_000
_MAX_CONVERSATION_BYTES = 16_000
MAX_FINANCE_REASONING_TURN_BYTES = 64_000

_EvidenceID = Annotated[str, Field(min_length=1, max_length=200)]
_Assumption = Annotated[str, Field(min_length=1, max_length=1_000)]
_SuggestedAction = Annotated[str, Field(min_length=1, max_length=2_000)]
_Question = Annotated[str, Field(min_length=1, max_length=2_000)]
_FINANCE_QUERY_OPERATIONS = frozenset(
    {
        "get_financial_overview",
        "search_transactions",
        "get_transaction_context",
        "analyse_finance",
        "compare_periods",
        "get_account_freshness",
        "get_recurring_series",
        "get_unitemised_purchase_queue",
        "search_purchase_lines",
        "aggregate_purchase_lines",
        "get_purchase_and_line_evidence",
        "find_repeated_or_duplicate_items",
        "get_product_purchase_history",
        "compare_item_prices",
        "get_finding_evidence",
    }
)


def encode_finance_reasoning_input(
    *,
    question: str,
    query_results: Sequence[Mapping[str, object]],
    conversation: Sequence[Mapping[str, str]],
) -> tuple[str, str, str]:
    """Validate and encode the temporary context shared by every provider."""

    question = question.strip()
    if not question or len(question) > _MAX_QUESTION_CHARS:
        raise FinanceReasoningError("Finance question is empty or too long")
    if len(query_results) > 4:
        raise FinanceReasoningError("Finance query context has too many results")
    checked_results: list[dict[str, object]] = []
    for item in query_results:
        if set(item) != {"operation", "result"}:
            raise FinanceReasoningError("Finance query context is invalid")
        operation = item.get("operation")
        result = item.get("result")
        if (
            not isinstance(operation, str)
            or operation not in _FINANCE_QUERY_OPERATIONS
            or not isinstance(result, Mapping)
        ):
            raise FinanceReasoningError("Finance query context is invalid")
        checked_results.append({"operation": operation, "result": dict(result)})
    try:
        context_json = json.dumps(
            checked_results,
            ensure_ascii=False,
            separators=(",", ":"),
        )
    except (TypeError, ValueError) as exc:
        raise FinanceReasoningError("Finance query context is invalid") from exc
    if len(context_json.encode("utf-8")) > _MAX_CONTEXT_BYTES:
        raise FinanceReasoningError("Finance query context exceeds the provider boundary")
    if len(conversation) > _MAX_CONVERSATION_TURNS:
        raise FinanceReasoningError("Finance screen conversation exceeds the provider boundary")
    checked_conversation: list[dict[str, str]] = []
    total_chars = 0
    for turn in conversation:
        if set(turn) != {"role", "text"}:
            raise FinanceReasoningError("Finance screen conversation is invalid")
        role, text = turn.get("role"), turn.get("text")
        if (
            role not in {"user", "assistant"}
            or not isinstance(text, str)
            or not text.strip()
            or len(text) > 1_500
        ):
            raise FinanceReasoningError("Finance screen conversation is invalid")
        checked_conversation.append({"role": role, "text": text})
        total_chars += len(text)
    conversation_json = json.dumps(
        checked_conversation,
        ensure_ascii=False,
        separators=(",", ":"),
    )
    if (
        total_chars > _MAX_CONVERSATION_CHARS
        or len(conversation_json.encode("utf-8")) > _MAX_CONVERSATION_BYTES
    ):
        raise FinanceReasoningError("Finance screen conversation exceeds the provider boundary")
    return question, context_json, conversation_json


FinanceQueryOperation: TypeAlias = Literal[
    "get_financial_overview",
    "search_transactions",
    "get_transaction_context",
    "analyse_finance",
    "compare_periods",
    "get_account_freshness",
    "get_recurring_series",
    "get_unitemised_purchase_queue",
    "search_purchase_lines",
    "aggregate_purchase_lines",
    "get_purchase_and_line_evidence",
    "find_repeated_or_duplicate_items",
    "get_product_purchase_history",
    "compare_item_prices",
    "get_finding_evidence",
]


class FinanceAnswerClaim(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=1, max_length=2_000)
    evidence_ids: list[_EvidenceID] = Field(min_length=1, max_length=20)


class FinanceAnswerEstimate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=1, max_length=2_000)
    assumptions: list[_Assumption] = Field(min_length=1, max_length=20)
    low_minor: StrictInt | None
    high_minor: StrictInt | None
    currency: str | None

    @model_validator(mode="after")
    def validate_range(self):
        if (self.low_minor is None) != (self.high_minor is None):
            raise ValueError("Estimate ranges require both low and high values")
        if self.low_minor is not None and self.low_minor > self.high_minor:
            raise ValueError("Estimate low value cannot exceed high value")
        if self.currency is not None and (len(self.currency) != 3 or not self.currency.isalpha()):
            raise ValueError("Estimate currency must be a three-letter code")
        return self


class FinanceAnswer(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["analysis", "answer", "partial"]
    headline: str = Field(min_length=1, max_length=300)
    answer: str = Field(min_length=1, max_length=6_000)
    answer_mode: Literal["CURRENT_EXACT", "DATED_EXACT", "ESTIMATE", "PARTIAL"]
    data_through: str | None = Field(max_length=100)
    claims: list[FinanceAnswerClaim] = Field(max_length=30)
    estimates: list[FinanceAnswerEstimate] = Field(max_length=20)
    suggested_actions: list[_SuggestedAction] = Field(max_length=10)
    analysis_view_id: str | None = Field(min_length=1, max_length=200)
    questions: list[_Question] = Field(max_length=5)

    @model_validator(mode="after")
    def require_typed_support(self):
        if self.answer_mode in {"CURRENT_EXACT", "DATED_EXACT"} and not self.claims:
            raise ValueError("Exact Finance answers require evidence-backed claims")
        if self.answer_mode == "DATED_EXACT" and self.data_through is None:
            raise ValueError("Dated Finance answers require a data-through timestamp")
        if self.answer_mode == "ESTIMATE" and not self.estimates:
            raise ValueError("Estimated Finance answers require typed assumptions and ranges")
        return self


class FinanceReasoningTurn(BaseModel):
    """One strict model turn; query arguments exclude principal and space IDs."""

    model_config = ConfigDict(extra="forbid")

    kind: Literal["query", "final"]
    operation: FinanceQueryOperation | None
    search_text: str | None = Field(default=None, max_length=500)
    period_start: str | None = Field(default=None, max_length=10)
    period_end: str | None = Field(default=None, max_length=10)
    entity_ref: str | None = Field(default=None, max_length=200)
    group_by: Literal["day", "week", "month", "merchant", "category", "item"] | None
    limit: StrictInt | None = Field(default=None, ge=1, le=100)
    answer: FinanceAnswer | None

    @model_validator(mode="after")
    def validate_turn_shape(self):
        if self.kind == "query":
            if self.operation is None or self.answer is not None:
                raise ValueError("Query turns require an operation and cannot publish an answer")
        elif self.operation is not None or self.answer is None:
            raise ValueError("Final turns require an answer and cannot request an operation")
        encoded = json.dumps(
            self.model_dump(mode="json"),
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        if len(encoded) > MAX_FINANCE_REASONING_TURN_BYTES:
            raise ValueError("Finance reasoning turn is too large")
        return self


class FinanceReasoningAdapter(Protocol):
    async def next_turn(
        self,
        *,
        question: str,
        query_results: Sequence[Mapping[str, object]],
        conversation: Sequence[Mapping[str, str]] = (),
    ) -> FinanceReasoningTurn:
        """Request one turn from already-authorised, size-bounded context."""

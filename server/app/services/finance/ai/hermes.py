"""Private Hermes bridge adapter for Finance reasoning."""

import json
from collections.abc import Mapping, Sequence
from typing import Literal

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from app.services.finance.ai.base import (
    MAX_FINANCE_REASONING_TURN_BYTES,
    FinanceReasoningError,
    FinanceReasoningTurn,
    encode_finance_reasoning_input,
)


class _HermesFinanceResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    turn: FinanceReasoningTurn
    provider: Literal["openai-codex"]
    model: str = Field(min_length=1, max_length=200)


class HermesFinanceReasoningAdapter:
    """Ask the fixed, tool-disabled Finance profile for one typed turn."""

    def __init__(
        self,
        *,
        bridge_url: str,
        bridge_token: str,
        timeout_seconds: float,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        if not bridge_url.strip():
            raise ValueError("A Hermes bridge URL is required")
        if len(bridge_token.strip()) < 32:
            raise ValueError("A Hermes bridge token of at least 32 characters is required")
        self._url = f"{bridge_url.rstrip('/')}/v1/finance"
        self._token = bridge_token
        self._timeout_seconds = timeout_seconds
        self._client = client
        self._owns_client = client is None

    async def aclose(self) -> None:
        """Close the request-owned client after the complete reasoning loop."""
        if self._owns_client and self._client is not None:
            await self._client.aclose()
            self._client = None

    async def next_turn(
        self,
        *,
        question: str,
        query_results: Sequence[Mapping[str, object]],
        conversation: Sequence[Mapping[str, str]] = (),
    ) -> FinanceReasoningTurn:
        question, context_json, conversation_json = encode_finance_reasoning_input(
            question=question,
            query_results=query_results,
            conversation=conversation,
        )
        payload = {
            "message": question,
            "context": {
                "conversation": json.loads(conversation_json),
                "query_results": json.loads(context_json),
            },
        }
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=self._timeout_seconds)
        client = self._client
        try:
            response = await client.post(
                self._url,
                headers={
                    "Authorization": f"Bearer {self._token}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
            response.raise_for_status()
            if len(response.content) > MAX_FINANCE_REASONING_TURN_BYTES + 1_024:
                raise ValueError("Finance reasoning response is too large")
            return _HermesFinanceResponse.model_validate(response.json()).turn
        except (httpx.HTTPError, TypeError, ValueError, ValidationError) as exc:
            raise FinanceReasoningError(
                "Finance reasoning provider returned no valid turn"
            ) from exc

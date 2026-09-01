"""Narrow client for the private Hermes bridge running inside the NUC network."""

import json
import logging
from datetime import date

import httpx
from pydantic import BaseModel, ConfigDict, Field

from app.config import settings
from app.models.assistant import (
    AssistantHistoryMessage,
    HermesAssistantResponse,
)
from app.models.document import CaptureSuggestionCreate
from app.models.fitness_coach import (
    CoachHistoryTurn,
    CoachIntent,
    CoachMemoryCandidate,
)

logger = logging.getLogger(__name__)

# The bridge passes the composed prompt to the hermes CLI as a single argv
# string, which Linux caps at MAX_ARG_STRLEN (128 KiB). Keep the payload
# comfortably below that so the prompt wrapper still fits.
_MAX_PAYLOAD_BYTES = 120_000
# Bismarck's bridge adds a sizeable fixed instruction wrapper before invoking
# Hermes, so its JSON body needs extra headroom below Linux MAX_ARG_STRLEN.
_MAX_FAMILY_PAYLOAD_BYTES = 105_000


class HermesUsageLimitError(RuntimeError):
    """The bridge reported that the LLM provider's usage quota is exhausted."""


class HermesBusyError(RuntimeError):
    """The bridge is already handling its one allowed concurrent request."""


def _bridge_detail(response: httpx.Response) -> str:
    try:
        detail = response.json().get("detail", "")
    except ValueError:
        return ""
    return detail if isinstance(detail, str) else ""


def _raise_for_bridge_backpressure(response: httpx.Response) -> None:
    if response.status_code != 429:
        return
    detail = _bridge_detail(response).lower()
    if "usage limit" in detail:
        raise HermesUsageLimitError("Hermes provider usage limit reached")
    raise HermesBusyError("Hermes bridge is busy")


class _ExtractionResponse(BaseModel):
    suggestions: list[CaptureSuggestionCreate]


class FitnessHermesRecommendation(BaseModel):
    model_config = ConfigDict(extra="forbid")

    recommendation_type: str = Field(min_length=1, max_length=80)
    recommendation_text: str = Field(min_length=1, max_length=2_000)
    expected_effect: str | dict | None = None


class FitnessHermesProposal(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: str = Field(min_length=1, max_length=80)
    payload: dict


class FitnessHermesResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    answer: str = Field(min_length=1, max_length=10_000)
    evidence_ids: list[str] = Field(default_factory=list, max_length=20)
    recommendation: FitnessHermesRecommendation | None = None
    proposal: FitnessHermesProposal | None = None
    memory_candidates: list[CoachMemoryCandidate] = Field(
        default_factory=list, max_length=3
    )
    provider: str = Field(min_length=1, max_length=100)
    model: str = Field(min_length=1, max_length=200)


def hermes_is_configured() -> bool:
    return bool(settings.hermes_bridge_url.strip() and settings.hermes_bridge_token.strip())


def _bridge_request_timeout() -> float:
    """Include the bridge's bounded queue wait plus a small HTTP margin."""
    return (
        settings.hermes_timeout_seconds
        + settings.hermes_queue_wait_seconds
        + 5.0
    )


async def fitness_coach_bridge_status() -> dict | None:
    """Read provider metadata without sending any user or Fitness records."""
    if not hermes_is_configured():
        return None
    url = f"{settings.hermes_bridge_url.rstrip('/')}/v1/fitness/status"
    headers = {"Authorization": f"Bearer {settings.hermes_bridge_token}"}
    try:
        async with httpx.AsyncClient(timeout=min(settings.hermes_timeout_seconds, 10)) as client:
            response = await client.get(url, headers=headers)
            _raise_for_bridge_backpressure(response)
            response.raise_for_status()
        payload = response.json()
        provider = payload.get("provider")
        model = payload.get("model")
        if not isinstance(provider, str) or not provider.strip():
            return None
        if not isinstance(model, str) or not model.strip():
            return None
        return {"provider": provider[:100], "model": model[:200]}
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("Hermes Fitness status unavailable: %s", exc)
        return None


async def ask_fitness_coach(
    *,
    message: str,
    intent: CoachIntent,
    history: list[CoachHistoryTurn],
    memories: list[dict[str, str | None]],
    timezone_name: str,
    client_now: str | None,
    context: dict,
) -> FitnessHermesResponse | None:
    """Send one explicit, bounded Fitness request to the isolated profile."""
    if not hermes_is_configured() or not message.strip():
        return None
    payload = {
        "message": message[:2_000],
        "intent": intent,
        "history": [item.model_dump() for item in history[-8:]],
        "memories": memories[:5],
        "timezone": timezone_name[:100],
        "client_now": client_now[:100] if client_now else None,
        "context": context,
    }
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    if len(encoded) > _MAX_PAYLOAD_BYTES:
        logger.warning("Hermes Fitness context exceeded its bounded payload")
        return None
    url = f"{settings.hermes_bridge_url.rstrip('/')}/v1/fitness"
    headers = {
        "Authorization": f"Bearer {settings.hermes_bridge_token}",
        "Content-Type": "application/json",
    }
    try:
        async with httpx.AsyncClient(timeout=_bridge_request_timeout()) as client:
            response = await client.post(url, content=encoded, headers=headers)
            _raise_for_bridge_backpressure(response)
            response.raise_for_status()
        return FitnessHermesResponse.model_validate(response.json())
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("Hermes Fitness coach unavailable: %s", exc)
        return None


async def extract_capture_suggestions(
    *,
    title: str,
    text: str,
    people: list[dict[str, str]],
    reference_date: str | None = None,
) -> list[CaptureSuggestionCreate] | None:
    """Ask the tool-disabled Hermes profile for structured capture suggestions.

    Returning ``None`` means the bridge was unavailable or returned invalid data;
    callers must preserve device-generated suggestions in that case.
    """
    if not hermes_is_configured() or not text.strip():
        return None

    url = f"{settings.hermes_bridge_url.rstrip('/')}/v1/extract"
    payload = {
        "title": title,
        "text": text[:100_000],
        "people": people,
        "today": reference_date or date.today().isoformat(),
    }
    headers = {"Authorization": f"Bearer {settings.hermes_bridge_token}"}

    try:
        async with httpx.AsyncClient(timeout=_bridge_request_timeout()) as client:
            response = await client.post(url, json=payload, headers=headers)
            response.raise_for_status()
        parsed = _ExtractionResponse.model_validate(response.json())
        return parsed.suggestions[:50]
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("Hermes capture extraction unavailable: %s", exc)
        return None


async def ask_hermes(*, message: str, context: str = "") -> str | None:
    """Send a general, non-streaming request through the same private bridge."""
    if not hermes_is_configured():
        return None

    url = f"{settings.hermes_bridge_url.rstrip('/')}/v1/chat"
    headers = {"Authorization": f"Bearer {settings.hermes_bridge_token}"}
    try:
        async with httpx.AsyncClient(timeout=_bridge_request_timeout()) as client:
            response = await client.post(
                url,
                json={"message": message, "context": context[:100_000]},
                headers=headers,
            )
            response.raise_for_status()
        answer = response.json().get("answer")
        return answer.strip() if isinstance(answer, str) and answer.strip() else None
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("Hermes chat unavailable: %s", exc)
        return None


async def ask_family_assistant(
    *,
    message: str,
    history: list[AssistantHistoryMessage],
    context: dict,
) -> HermesAssistantResponse | None:
    """Request a grounded answer and non-executable, typed action proposals."""
    if not hermes_is_configured() or not message.strip():
        return None

    url = f"{settings.hermes_bridge_url.rstrip('/')}/v1/assistant"
    payload: dict = {
        "message": message[:5_000],
        "history": [item.model_dump() for item in history[-12:]],
        "context": context,
    }

    def compact_value(value, limit: int, string_limit: int, depth: int = 0):
        if depth > 8:
            return None
        if isinstance(value, str):
            return value[:string_limit]
        if isinstance(value, list):
            return [
                compact_value(item, limit, string_limit, depth + 1)
                for item in value[:limit]
            ]
        if isinstance(value, dict):
            return {
                key: compact_value(item, limit, string_limit, depth + 1)
                for key, item in value.items()
            }
        return value

    def compact_records(limit: int, string_limit: int) -> dict:
        records = context.get("family_records", {})
        if not isinstance(records, dict):
            return {}
        return {
            name: compact_value(values, limit, string_limit)
            for name, values in records.items()
        }

    encoded = json.dumps(payload, ensure_ascii=False).encode()
    if len(encoded) > _MAX_FAMILY_PAYLOAD_BYTES:
        compact_context = {
            **context,
            "calendar_events": context.get("calendar_events", [])[:100],
            "open_tasks": context.get("open_tasks", [])[:60],
            "term_dates": context.get("term_dates", [])[:150],
            "holiday_dates": context.get("holiday_dates", [])[:200],
            "home_assistant": {
                **context.get("home_assistant", {}),
                "entities": context.get("home_assistant", {}).get("entities", [])[:80],
            },
            "family_records": compact_records(30, 1_000),
        }
        payload = {
            "message": message[:5_000],
            "history": [
                {"role": item.role, "content": item.content[:2_000]}
                for item in history[-8:]
            ],
            "context": compact_context,
        }
        encoded = json.dumps(payload, ensure_ascii=False).encode()
    if len(encoded) > _MAX_FAMILY_PAYLOAD_BYTES:
        compact_context = {
            **context,
            "calendar_events": [
                {**item, "description": None}
                for item in context.get("calendar_events", [])[:50]
            ],
            "open_tasks": [
                {**item, "description": None}
                for item in context.get("open_tasks", [])[:30]
            ],
            "term_dates": context.get("term_dates", [])[:80],
            "holiday_dates": context.get("holiday_dates", [])[:100],
            "home_assistant": {
                **context.get("home_assistant", {}),
                "entities": context.get("home_assistant", {}).get("entities", [])[:40],
            },
            "family_records": compact_records(10, 400),
        }
        payload["context"] = compact_context
        payload["history"] = payload["history"][-6:]
        encoded = json.dumps(payload, ensure_ascii=False).encode()
    if len(encoded) > _MAX_FAMILY_PAYLOAD_BYTES:
        payload["context"] = {
            "now": context.get("now"),
            "timezone": context.get("timezone"),
            "people": context.get("people", []),
            "calendar_events": context.get("calendar_events", [])[:25],
            "open_tasks": context.get("open_tasks", [])[:20],
            "shared_time_off": context.get("shared_time_off", {}),
            "family_records": compact_records(5, 250),
            "home_assistant": {
                **context.get("home_assistant", {}),
                "entities": context.get("home_assistant", {}).get("entities", [])[:20],
            },
        }
        payload["history"] = payload["history"][-4:]
        encoded = json.dumps(payload, ensure_ascii=False).encode()
    if len(encoded) > _MAX_FAMILY_PAYLOAD_BYTES:
        logger.warning("Hermes family context exceeded its bounded payload")
        return None
    headers = {
        "Authorization": f"Bearer {settings.hermes_bridge_token}",
        "Content-Type": "application/json",
    }
    try:
        async with httpx.AsyncClient(timeout=_bridge_request_timeout()) as client:
            response = await client.post(url, content=encoded, headers=headers)
            _raise_for_bridge_backpressure(response)
            response.raise_for_status()
        return HermesAssistantResponse.model_validate(response.json())
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("Hermes family assistant unavailable: %s", exc)
        return None

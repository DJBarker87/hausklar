import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends

from app.auth import get_current_user
from app.database import database_lease
from app.models.capture import (
    UniversalCaptureProposal,
    UniversalCaptureRequest,
    UniversalCaptureResponse,
)
from app.models.document import CaptureSuggestionCreate
from app.services.capture import fallback_capture_suggestions, reference_in_timezone
from app.services.ai_consent import require_ai_consent
from app.services.hermes import extract_capture_suggestions

router = APIRouter()


async def _family_people(db, family_id: str) -> list[dict[str, str]]:
    cursor = await db.execute(
        """
        SELECT id, name, 'user' AS person_type
        FROM users
        WHERE family_id = ? AND deleted_at IS NULL
        UNION ALL
        SELECT id, name, 'child' AS person_type
        FROM children
        WHERE family_id = ? AND deleted_at IS NULL
        ORDER BY name
        """,
        (family_id, family_id),
    )
    return [
        {"id": row[0], "name": row[1], "person_type": row[2]} for row in await cursor.fetchall()
    ]


def _valid_temporal(value: str | None, reference: datetime) -> str | None:
    if not value:
        return None
    try:
        if len(value) == 10:
            datetime.fromisoformat(value)
            return value
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=reference.tzinfo or timezone.utc)
        return parsed.isoformat()
    except ValueError:
        return None


def _normalise_suggestions(
    suggestions: list[CaptureSuggestionCreate],
    people: list[dict[str, str]],
    reference: datetime,
) -> list[UniversalCaptureProposal]:
    people_by_id = {person["id"]: person["name"] for person in people}
    proposals: list[UniversalCaptureProposal] = []
    for suggestion in suggestions[:20]:
        start_time = _valid_temporal(suggestion.start_time, reference)
        if suggestion.kind == "event" and not start_time:
            continue
        assigned_to = suggestion.assigned_to
        if assigned_to not in people_by_id:
            assigned_to = None
        proposals.append(
            UniversalCaptureProposal(
                id=suggestion.id or str(uuid.uuid4()),
                kind=suggestion.kind,
                title=suggestion.title,
                details=suggestion.details,
                start_time=start_time,
                end_time=_valid_temporal(suggestion.end_time, reference),
                due_date=_valid_temporal(suggestion.due_date, reference),
                all_day=suggestion.all_day,
                assigned_to=assigned_to,
                assigned_to_name=people_by_id.get(assigned_to),
                confidence=suggestion.confidence,
                source_text=suggestion.source_text,
            )
        )
    return proposals


@router.post("/parse", response_model=UniversalCaptureResponse)
async def parse_capture(
    body: UniversalCaptureRequest,
    current_user: dict = Depends(get_current_user),
):
    """Turn free-form family input into reviewable drafts without writing records."""
    async with database_lease() as db:
        people = await _family_people(db, current_user["family_id"])
    reference = reference_in_timezone(body.client_now, body.timezone)
    suggestions: list[CaptureSuggestionCreate] = []
    processor = "fallback"
    warning = None

    if body.use_hermes:
        require_ai_consent(current_user)
        hermes_result = await extract_capture_suggestions(
            title="Family quick capture",
            text=body.text,
            people=people,
            reference_date=reference.date().isoformat(),
        )
        if hermes_result:
            suggestions = hermes_result
            processor = "hermes"
        else:
            warning = "Smart parsing was unavailable, so HausKlar used basic parsing."

    if not suggestions:
        suggestions = fallback_capture_suggestions(
            body.text,
            people=people,
            reference=reference,
        )

    return UniversalCaptureResponse(
        proposals=_normalise_suggestions(suggestions, people, reference),
        processor=processor,
        warning=warning,
    )

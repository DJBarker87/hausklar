"""Server-owned mappings from human goal choices to private Fitness goals."""

from app.models.fitness import GoalPayload
from app.models.fitness_goal_templates import GoalFromTemplateRequest
from app.services.fitness.common import FitnessConflictError
from app.services.fitness.planning import upsert_goal
from app.services.idempotency import serialized_create


TEMPLATES = (
    {
        "id": "run-faster-5k",
        "title": "Run a faster 5K",
        "description": "Follow your best comparable 5K time and work towards a time that matters to you.",
        "target_prompt": "What 5K time are you aiming for?",
        "input_kind": "duration_minutes_seconds",
        "unit_label": "5K time",
        "minimum_value": 12 * 60.0,
        "maximum_value": 120 * 60.0,
        "step": 5.0,
        "suggested_value": 25 * 60.0,
        "supports_target_date": True,
        "goal_type": "running",
        "metric_key": "running.5k_seconds",
        "unit_key": "s",
    },
    {
        "id": "run-consistently",
        "title": "Run regularly",
        "description": "Make running a dependable part of the week without prescribing distance or pace.",
        "target_prompt": "How many runs would feel realistic each week?",
        "input_kind": "sessions_per_week",
        "unit_label": "runs per week",
        "minimum_value": 1.0,
        "maximum_value": 7.0,
        "step": 1.0,
        "suggested_value": 3.0,
        "supports_target_date": True,
        "goal_type": "running",
        "metric_key": "running.sessions_per_week",
        "unit_key": "sessions per week",
    },
    {
        "id": "move-consistently",
        "title": "Move consistently",
        "description": "Build a repeatable weekly movement habit with any activities you enjoy.",
        "target_prompt": "How many sessions would feel realistic each week?",
        "input_kind": "sessions_per_week",
        "unit_label": "sessions per week",
        "minimum_value": 1.0,
        "maximum_value": 14.0,
        "step": 1.0,
        "suggested_value": 3.0,
        "supports_target_date": True,
        "goal_type": "fitness",
        "metric_key": "activity.sessions_per_week",
        "unit_key": "sessions per week",
    },
    {
        "id": "run-weekly-distance",
        "title": "Run further",
        "description": "Choose a weekly distance that gives your running a clear, flexible direction.",
        "target_prompt": "How many kilometres would you like to run each week?",
        "input_kind": "kilometres_per_week",
        "unit_label": "kilometres per week",
        "minimum_value": 0.5,
        "maximum_value": 300.0,
        "step": 0.5,
        "suggested_value": 15.0,
        "supports_target_date": True,
        "goal_type": "running",
        "metric_key": "running.distance_m",
        "unit_key": "m per week",
    },
    {
        "id": "strength-consistency",
        "title": "Build strength consistently",
        "description": "Make strength training a dependable part of your week.",
        "target_prompt": "How many strength sessions would you like each week?",
        "input_kind": "sessions_per_week",
        "unit_label": "strength sessions per week",
        "minimum_value": 1.0,
        "maximum_value": 7.0,
        "step": 1.0,
        "suggested_value": 2.0,
        "supports_target_date": True,
        "goal_type": "strength",
        "metric_key": "strength.sessions_per_week",
        "unit_key": "sessions per week",
    },
    {
        "id": "energy-and-wellbeing",
        "title": "Support energy and wellbeing",
        "description": "Aim for regular active days without prescribing a particular workout.",
        "target_prompt": "How many active days would support a good week?",
        "input_kind": "active_days_per_week",
        "unit_label": "active days per week",
        "minimum_value": 1.0,
        "maximum_value": 7.0,
        "step": 1.0,
        "suggested_value": 4.0,
        "supports_target_date": True,
        "goal_type": "wellbeing",
        "metric_key": "activity.active_days_per_week",
        "unit_key": "days per week",
    },
    {
        "id": "body-weight-support",
        "title": "Support a body-weight goal",
        "description": "Track gradual progress towards a weight that you have chosen for yourself.",
        "target_prompt": "What weight would you like to move towards?",
        "input_kind": "target_weight_kg",
        "unit_label": "kilograms",
        "minimum_value": 30.0,
        "maximum_value": 300.0,
        "step": 0.1,
        "suggested_value": 75.0,
        "supports_target_date": True,
        "goal_type": "body",
        "metric_key": "body.weight_kg",
        "unit_key": "kg",
    },
)
TEMPLATE_BY_ID = {template["id"]: template for template in TEMPLATES}
PUBLIC_TEMPLATE_FIELDS = (
    "id",
    "title",
    "description",
    "target_prompt",
    "input_kind",
    "unit_label",
    "minimum_value",
    "maximum_value",
    "step",
    "suggested_value",
    "supports_target_date",
)


def list_goal_templates() -> list[dict]:
    return [{field: template[field] for field in PUBLIC_TEMPLATE_FIELDS} for template in TEMPLATES]


def _display_number(value: float) -> str:
    return f"{value:g}"


def _target_text(template: dict, value: float) -> str:
    if template["id"] == "run-faster-5k":
        total = int(round(value))
        return f"Run 5K in {total // 60}:{total % 60:02d}"
    if template["id"] == "run-consistently":
        return f"{int(value)} runs each week"
    if template["id"] == "run-weekly-distance":
        return f"{_display_number(value)} km each week"
    if template["id"] == "body-weight-support":
        return f"Move towards {_display_number(value)} kg"
    if template["id"] == "energy-and-wellbeing":
        return f"{int(value)} active days each week"
    if template["id"] == "strength-consistency":
        return f"{int(value)} strength sessions each week"
    return f"{int(value)} sessions each week"


def _internal_target(template: dict, value: float) -> float:
    if template["id"] == "run-weekly-distance":
        return value * 1_000
    return value


def _goal_response(row, *, template: dict, requested_value: float) -> dict:
    return {
        "goal_id": row["id"],
        "template_id": template["id"],
        "title": row["name"],
        "target_text": _target_text(template, requested_value),
        "starts_on": row["starts_on"],
        "target_date": row["target_date"],
        "priority": row["priority"],
        "status": "active",
    }


def _same_create(
    row,
    *,
    user: dict,
    body: GoalFromTemplateRequest,
    template: dict,
    title: str,
    internal_target: float,
) -> bool:
    return (
        row["family_id"] == user["family_id"]
        and row["owner_user_id"] == user["id"]
        and row["deleted_at"] is None
        and row["goal_type"] == template["goal_type"]
        and row["metric_key"] == template["metric_key"]
        and row["name"] == title
        and row["target_value"] is not None
        and float(row["target_value"]) == internal_target
        and row["unit_key"] == template["unit_key"]
        and row["starts_on"] == body.starts_on.isoformat()
        and row["target_date"] == (body.target_date.isoformat() if body.target_date else None)
        and int(row["priority"]) == body.priority
        and row["status"] == "active"
        and row["client_id"] == body.client_id
        and row["client_timestamp"] == body.client_timestamp
    )


async def _latest_weight(db, *, user: dict, on_or_before: str) -> float | None:
    row = await (
        await db.execute(
            "SELECT value, unit_key FROM health_body_measurements "
            "WHERE family_id = ? AND owner_user_id = ? "
            "AND metric_key = 'body.weight_kg' AND canonical_state = 'canonical' "
            "AND deleted_at IS NULL AND substr(measured_at_utc,1,10) <= ? "
            "ORDER BY measured_at_utc DESC, created_at DESC LIMIT 1",
            (user["family_id"], user["id"], on_or_before),
        )
    ).fetchone()
    if row is None or row["unit_key"] != "kg":
        return None
    return float(row["value"])


async def _create_goal_from_template(
    db,
    *,
    user: dict,
    body: GoalFromTemplateRequest,
) -> dict:
    template = TEMPLATE_BY_ID[body.template_id]
    goal_id = str(body.id)
    title = body.title or (
        _target_text(template, body.target_value)
        if template["id"] == "run-faster-5k"
        else template["title"]
    )
    internal_target = _internal_target(template, body.target_value)
    existing = await (
        await db.execute("SELECT * FROM health_goals WHERE id = ?", (goal_id,))
    ).fetchone()
    if existing is not None:
        if not _same_create(
            existing,
            user=user,
            body=body,
            template=template,
            title=title,
            internal_target=internal_target,
        ):
            raise FitnessConflictError("That goal record ID was already used for a different goal")
        return _goal_response(
            existing,
            template=template,
            requested_value=body.target_value,
        )

    baseline = (
        await _latest_weight(
            db,
            user=user,
            on_or_before=body.starts_on.isoformat(),
        )
        if body.template_id == "body-weight-support"
        else None
    )
    await upsert_goal(
        db,
        user=user,
        record_id=goal_id,
        body=GoalPayload(
            id=body.id,
            goal_type=template["goal_type"],
            metric_key=template["metric_key"],
            name=title,
            baseline_value=baseline,
            current_value=baseline,
            target_value=internal_target,
            unit_key=template["unit_key"],
            starts_on=body.starts_on,
            target_date=body.target_date,
            priority=body.priority,
            status="active",
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        ),
    )
    created = await (
        await db.execute(
            "SELECT * FROM health_goals WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (goal_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    return _goal_response(
        created,
        template=template,
        requested_value=body.target_value,
    )


async def create_goal_from_template(
    db,
    *,
    user: dict,
    body: GoalFromTemplateRequest,
) -> dict:
    async with serialized_create(db):
        return await _create_goal_from_template(db, user=user, body=body)

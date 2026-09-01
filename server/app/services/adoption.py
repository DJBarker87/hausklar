"""Opt-in, private, content-free evidence that HausKlar is helping in real life.

The recorder accepts only reviewed semantic route, control, screen, workflow and
sync-mutation keys. It never receives or stores request/response bodies, query
strings, domain entity IDs, labels, search text, assistant text, titles, names,
notes, amounts, health values or documents.
"""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable

from app.models.adoption import UsageInteractionEvent

from app.database import database_lease


RETENTION_DAYS = 28
SETTING_PREFIX = "usage_history:"
SHARED_MODULES = frozenset(
    {
        "artwork",
        "calendar",
        "documents",
        "dog",
        "facilities",
        "homework",
        "meals",
        "medicine",
        "naps",
        "presents",
        "routines",
        "shopping",
        "stars",
        "tasks",
    }
)
PRIVATE_MODULES = frozenset({"finance", "fitness"})
CLIENT_SOURCES = frozenset({"ios", "web"})


@dataclass(frozen=True)
class CompletedAction:
    module: str
    action: str
    outcome: str
    effort: str


@dataclass(frozen=True)
class _Rule:
    method: str
    pattern: re.Pattern[str]
    fact: CompletedAction


@dataclass(frozen=True)
class _ClientEventSpec:
    module: str
    event_kind: str
    outcomes: frozenset[str]
    surfaces: frozenset[str]
    workflow: str | None = None


def _rule(
    method: str,
    path: str,
    module: str,
    action: str,
    outcome: str,
    effort: str,
) -> _Rule:
    return _Rule(method, re.compile(path), CompletedAction(module, action, outcome, effort))


# A deliberately small taxonomy of meaningful writes. Adding a route requires a
# conscious code review; unknown mutations and all reads are invisible here.
_RULES = (
    _rule("POST", r"/calendar/?", "calendar", "add_commitment", "created", "standard"),
    _rule("PUT", r"/calendar/[^/]+", "calendar", "update_commitment", "updated", "standard"),
    _rule("POST", r"/tasks/?", "tasks", "add_task", "created", "standard"),
    _rule(
        "PATCH", r"/tasks/[^/]+/complete(?:/[^/]+)?", "tasks", "complete_task", "completed", "quick"
    ),
    _rule("POST", r"/medicine/doses", "medicine", "record_dose", "logged", "quick"),
    _rule("POST", r"/naps/start", "naps", "start_nap", "logged", "quick"),
    _rule("PATCH", r"/naps/[^/]+/end", "naps", "finish_nap", "completed", "quick"),
    _rule("POST", r"/dog/activities", "dog", "record_care", "logged", "quick"),
    _rule("POST", r"/artworks/?", "artwork", "save_artwork", "created", "involved"),
    _rule("POST", r"/documents/?", "documents", "file_document", "created", "involved"),
    _rule("POST", r"/star-charts/[^/]+/stars", "stars", "award_stars", "logged", "quick"),
    _rule("POST", r"/homework/reading", "homework", "record_reading", "logged", "quick"),
    _rule(
        "POST",
        r"/homework/spellings/[^/]+/practice",
        "homework",
        "record_practice",
        "logged",
        "quick",
    ),
    _rule(
        "POST",
        r"/homework/spellings/[^/]+/complete",
        "homework",
        "complete_spellings",
        "completed",
        "quick",
    ),
    _rule("POST", r"/meals/plan", "meals", "make_meal_plan", "created", "standard"),
    _rule("PATCH", r"/meals/shopping/[^/]+/check", "shopping", "check_item", "completed", "quick"),
    _rule("POST", r"/meals/shopping/done-all", "shopping", "finish_list", "completed", "quick"),
    _rule("POST", r"/routines/items", "routines", "add_routine", "created", "standard"),
    _rule(
        "PATCH",
        r"/children/presents/ideas/[^/]+/status",
        "presents",
        "move_present",
        "updated",
        "quick",
    ),
    _rule(
        "POST",
        r"/health-record/[^/]+/vaccinations",
        "medicine",
        "record_vaccination",
        "logged",
        "quick",
    ),
    _rule("POST", r"/fitness/activities/manual", "fitness", "log_activity", "logged", "standard"),
    _rule("POST", r"/fitness/imports/fit", "fitness", "import_activity", "created", "involved"),
    _rule(
        "POST",
        r"/fitness/strength/sessions/[^/]+/finish",
        "fitness",
        "finish_workout",
        "completed",
        "standard",
    ),
    _rule("POST", r"/fitness/food-log", "fitness", "log_food", "logged", "quick"),
    _rule("POST", r"/fitness/body/measurements", "fitness", "log_measurement", "logged", "quick"),
    _rule("POST", r"/fitness/session-checkins", "fitness", "log_checkin", "logged", "quick"),
    _rule("POST", r"/fitness/planned-sessions", "fitness", "plan_session", "created", "standard"),
    _rule(
        "POST",
        r"/fitness/goals/[^/]+/complete",
        "fitness",
        "complete_goal",
        "completed",
        "standard",
    ),
    _rule(
        "POST",
        r"/fitness/integrations/strava/sync",
        "fitness",
        "pull_strava",
        "completed",
        "quick",
    ),
    _rule(
        "POST",
        r"/finance/capture/[^/]+/confirm",
        "finance",
        "confirm_capture",
        "completed",
        "standard",
    ),
    _rule("POST", r"/finance/commitments", "finance", "add_commitment", "created", "standard"),
    _rule("POST", r"/finance/goals", "finance", "add_goal", "created", "standard"),
    _rule("POST", r"/finance/reserves", "finance", "add_reserve", "created", "standard"),
    _rule(
        "POST", r"/finance/contributions", "finance", "record_contribution", "logged", "standard"
    ),
)


_TOP_LEVEL_SURFACES = frozenset(
    {"today", "calendar", "family", "lists", "house", "finance", "fitness"}
)
_CLIENT_EVENT_SPECS = {
    ("screen_view", "view_today"): _ClientEventSpec(
        "today", "screen_view", frozenset({"viewed"}), frozenset({"today"})
    ),
    ("screen_view", "view_calendar"): _ClientEventSpec(
        "calendar", "screen_view", frozenset({"viewed"}), frozenset({"calendar"})
    ),
    ("screen_view", "view_family"): _ClientEventSpec(
        "family", "screen_view", frozenset({"viewed"}), frozenset({"family"})
    ),
    ("screen_view", "view_lists"): _ClientEventSpec(
        "lists", "screen_view", frozenset({"viewed"}), frozenset({"lists"})
    ),
    ("screen_view", "view_house"): _ClientEventSpec(
        "house", "screen_view", frozenset({"viewed"}), frozenset({"house"})
    ),
    ("screen_view", "view_finance"): _ClientEventSpec(
        "finance", "screen_view", frozenset({"viewed"}), frozenset({"finance"})
    ),
    ("screen_view", "view_fitness"): _ClientEventSpec(
        "fitness", "screen_view", frozenset({"viewed"}), frozenset({"fitness"})
    ),
    ("control", "open_capture"): _ClientEventSpec(
        "capture", "control", frozenset({"tapped"}), _TOP_LEVEL_SURFACES
    ),
    ("control", "open_add"): _ClientEventSpec(
        "capture", "control", frozenset({"tapped"}), _TOP_LEVEL_SURFACES
    ),
    ("control", "open_search"): _ClientEventSpec(
        "search", "control", frozenset({"tapped"}), _TOP_LEVEL_SURFACES
    ),
    ("control", "open_more"): _ClientEventSpec(
        "navigation", "control", frozenset({"tapped"}), _TOP_LEVEL_SURFACES
    ),
    ("control", "open_fitness_log"): _ClientEventSpec(
        "fitness", "control", frozenset({"tapped"}), _TOP_LEVEL_SURFACES
    ),
    ("control", "open_fitness_coach"): _ClientEventSpec(
        "fitness", "control", frozenset({"tapped"}), _TOP_LEVEL_SURFACES
    ),
    ("control", "open_swimming_booking"): _ClientEventSpec(
        "facilities",
        "control",
        frozenset({"tapped"}),
        frozenset({"today_facilities", "calendar_event"}),
        "book_swimming",
    ),
}
for action in (
    "save_food_log",
    "quick_log_food",
    "save_meal_logs",
    "log_planned_meal",
    "log_meal_template",
):
    _CLIENT_EVENT_SPECS[("workflow", action)] = _ClientEventSpec(
        "fitness",
        "workflow",
        frozenset({"started", "completed", "failed", "abandoned", "cancelled"}),
        frozenset({"fitness_log", "fitness_food_editor"}),
        "log_food",
    )
_CLIENT_EVENT_SPECS[("workflow", "pull_strava")] = _ClientEventSpec(
    "fitness",
    "workflow",
    frozenset({"started", "completed", "failed", "abandoned", "cancelled"}),
    frozenset({"fitness_training"}),
    "pull_strava",
)
_CLIENT_EVENT_SPECS[("workflow", "book_swimming")] = _ClientEventSpec(
    "facilities",
    "workflow",
    frozenset({"started", "completed", "failed", "abandoned", "cancelled"}),
    frozenset({"today_facilities", "calendar_event"}),
    "book_swimming",
)


_SYNC_MUTATION_ACTIONS = {
    "food_log_entry": ("log_food", "update_food", "remove_food", "quick", "logged"),
    "planned_session": ("plan_session", "update_session", "remove_session", "standard", "created"),
    "body_measurement": (
        "log_measurement", "update_measurement", "remove_measurement", "quick", "logged"
    ),
    "session_checkin": ("log_checkin", "update_checkin", "remove_checkin", "quick", "logged"),
    "manual_activity": ("log_activity", "update_activity", "remove_activity", "standard", "logged"),
    "strength_session": ("start_workout", "update_workout", "remove_workout", "standard", "created"),
    "cycle_period_start": (
        "log_period_start", "update_period_start", "remove_period_start", "quick", "logged"
    ),
    "goal": ("add_goal", "update_goal", "remove_goal", "standard", "created"),
    "training_phase": ("add_training_phase", "update_training_phase", "remove_training_phase", "standard", "created"),
    "food": ("save_food", "update_saved_food", "remove_saved_food", "standard", "created"),
    "recipe": ("save_recipe", "update_recipe", "remove_recipe", "standard", "created"),
    "meal_template": (
        "save_meal_template", "update_meal_template", "remove_meal_template", "standard", "created"
    ),
    "nutrition_target": (
        "set_nutrition_target", "update_nutrition_target", "remove_nutrition_target", "standard", "created"
    ),
    "progress_photo": (
        "save_progress_photo", "update_progress_photo", "remove_progress_photo", "involved", "created"
    ),
}


def classify_action_request(
    method: str,
    path: str,
    status_code: int,
) -> CompletedAction | None:
    """Return an allowlisted fact for a completed or failed action attempt."""
    if not (200 <= status_code < 300 or 400 <= status_code < 600):
        return None
    clean_path = path.removeprefix("/api").rstrip("?")
    for rule in _RULES:
        if method == rule.method and rule.pattern.fullmatch(clean_path):
            if 200 <= status_code < 300:
                return rule.fact
            return CompletedAction(
                module=rule.fact.module,
                action=rule.fact.action,
                outcome="failed",
                effort=rule.fact.effort,
            )
    return None


def classify_fitness_sync_mutation(
    *, entity_type: str, operation: str, existed: bool
) -> CompletedAction | None:
    """Classify only reviewed top-level Fitness mutations, never their payloads."""
    rule = _SYNC_MUTATION_ACTIONS.get(entity_type)
    if rule is None:
        return None
    create_action, update_action, remove_action, effort, create_outcome = rule
    if operation == "delete":
        return CompletedAction("fitness", remove_action, "removed", effort)
    if operation != "upsert":
        return None
    if existed:
        return CompletedAction("fitness", update_action, "updated", effort)
    return CompletedAction("fitness", create_action, create_outcome, effort)


def _safe_action_metadata(entry_source: str, app_version: str) -> tuple[str, str]:
    source = entry_source if entry_source in CLIENT_SOURCES else "unknown"
    version = (
        app_version
        if re.fullmatch(r"[A-Za-z0-9._+-]{1,32}", app_version or "")
        else "unknown"
    )
    return source, version


def safe_client_metadata(headers) -> tuple[str, str]:
    """Reduce request metadata to two short allowlisted values."""
    raw_source = (headers.get("x-hausklar-client") or "").strip().lower()
    user_agent = headers.get("user-agent") or ""
    if raw_source in CLIENT_SOURCES:
        source = raw_source
    elif "HausKlar/" in user_agent and "iOS" in user_agent:
        source = "ios"
    else:
        source = "unknown"

    raw_version = (headers.get("x-hausklar-app-version") or "").strip()
    if not raw_version and source == "ios":
        match = re.search(r"HausKlar/([A-Za-z0-9._+-]{1,32})", user_agent)
        raw_version = match.group(1) if match else ""
    return _safe_action_metadata(source, raw_version)


def _validate_client_interaction(
    event: UsageInteractionEvent,
    *, now: datetime,
) -> _ClientEventSpec:
    spec = _CLIENT_EVENT_SPECS.get((event.event_kind, event.action))
    if spec is None:
        raise ValueError("That usage event is not allowlisted")
    if event.module != spec.module or event.outcome not in spec.outcomes:
        raise ValueError("That usage event does not match its allowlisted meaning")
    if event.surface not in spec.surfaces or event.workflow != spec.workflow:
        raise ValueError("That usage event has an invalid surface or workflow")
    if event.event_kind == "workflow" and event.workflow_run_id is None:
        raise ValueError("Workflow events require a random workflow run identifier")
    if event.event_kind == "screen_view" and (
        event.workflow_run_id is not None or event.workflow is not None
    ):
        raise ValueError("Screen views cannot carry workflow identifiers")
    if event.event_kind != "workflow" and (
        event.workflow_run_id is not None
        or event.duration_bucket != "unknown"
        or event.interaction_count is not None
        or event.connectivity != "unknown"
        or event.failure_class is not None
    ):
        raise ValueError("Only workflows can carry workflow measurements")
    if event.outcome == "started" and (
        event.duration_bucket != "unknown"
        or event.interaction_count is not None
        or event.connectivity != "unknown"
        or event.failure_class is not None
    ):
        raise ValueError("Workflow starts cannot carry completion measurements")
    if event.outcome == "failed" and event.failure_class is None:
        raise ValueError("Failed workflows require a generic failure class")
    if event.outcome == "cancelled" and event.failure_class != "cancelled":
        raise ValueError("Cancelled workflows require the cancelled failure class")
    if event.outcome not in {"failed", "cancelled"} and event.failure_class is not None:
        raise ValueError("Successful interactions cannot carry a failure class")
    occurred_at = event.occurred_at
    if occurred_at.tzinfo is None:
        raise ValueError("Usage event timestamps must include a timezone")
    observed = occurred_at.astimezone(timezone.utc)
    if observed > now + timedelta(minutes=5) or observed < now - timedelta(days=RETENTION_DAYS):
        raise ValueError("Usage events must fall inside the active retention window")
    return spec


def _interaction_effort(event: UsageInteractionEvent) -> str:
    if event.event_kind != "workflow" or event.duration_bucket == "under_10s":
        return "quick"
    if event.duration_bucket == "under_1m":
        return "standard"
    return "involved"


def _setting_key(user_id: str) -> str:
    return f"{SETTING_PREFIX}{user_id}"


async def usage_history_enabled(db, *, user_id: str, family_id: str) -> bool:
    """Return true only for a valid, explicit adult opt-in."""
    row = await (
        await db.execute(
            "SELECT setting_value FROM family_settings WHERE family_id = ? AND setting_key = ?",
            (family_id, _setting_key(user_id)),
        )
    ).fetchone()
    if row is None:
        return False
    try:
        return json.loads(row["setting_value"]) is True
    except (TypeError, json.JSONDecodeError):
        return False


async def set_usage_history_enabled(db, *, user: dict, enabled: bool) -> None:
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "INSERT OR REPLACE INTO family_settings "
        "(family_id, setting_key, setting_value, updated_at, updated_by) "
        "VALUES (?, ?, ?, ?, ?)",
        (
            user["family_id"],
            _setting_key(user["id"]),
            json.dumps(enabled),
            now,
            user["id"],
        ),
    )
    if not enabled:
        # Withdrawing consent stops collection and removes the adult's active
        # summary immediately; soft-deleted rows remain subject to backup policy.
        await db.execute(
            "UPDATE adoption_events SET deleted_at = ?, updated_at = ? "
            "WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL",
            (now, now, user["id"], user["family_id"]),
        )


async def record_completed_actions_in_db(
    db,
    *,
    user: dict,
    facts: Iterable[CompletedAction],
    entry_source: str,
    app_version: str,
) -> int:
    """Append allowlisted server facts to the caller's existing transaction."""
    values = list(facts)
    if not values or not await usage_history_enabled(
        db, user_id=user["id"], family_id=user["family_id"]
    ):
        return 0
    source, version = _safe_action_metadata(entry_source, app_version)
    now = datetime.now(timezone.utc).isoformat()
    await db.executemany(
        """
        INSERT INTO adoption_events (
            id, user_id, module, action, outcome, entry_source, effort,
            app_version, event_kind, surface, workflow, workflow_run_id,
            duration_bucket, interaction_count, connectivity, failure_class,
            family_id, created_at, updated_at, created_by,
            client_id, client_timestamp, deleted_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'server_action', 'server', NULL, NULL,
                  'unknown', NULL, 'unknown', NULL, ?, ?, ?, ?, NULL, NULL, NULL)
        """,
        [
            (
                str(uuid.uuid4()),
                user["id"],
                fact.module,
                fact.action,
                fact.outcome,
                source,
                fact.effort,
                version,
                user["family_id"],
                now,
                now,
                user["id"],
            )
            for fact in values
        ],
    )
    return len(values)


async def record_client_interactions(
    db,
    *,
    user: dict,
    events: Iterable[UsageInteractionEvent],
    entry_source: str,
    app_version: str,
) -> int:
    """Validate and append semantic client events without accepting free text."""
    values = list(events)
    now = datetime.now(timezone.utc)
    for event in values:
        _validate_client_interaction(event, now=now)
    if not values or not await usage_history_enabled(
        db, user_id=user["id"], family_id=user["family_id"]
    ):
        return 0
    source, version = _safe_action_metadata(entry_source, app_version)
    recorded_at = now.isoformat()
    before = db.total_changes
    await db.executemany(
        """
        INSERT OR IGNORE INTO adoption_events (
            id, user_id, module, action, outcome, entry_source, effort,
            app_version, event_kind, surface, workflow, workflow_run_id,
            duration_bucket, interaction_count, connectivity, failure_class,
            family_id, created_at, updated_at, created_by,
            client_id, client_timestamp, deleted_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                  NULL, ?, NULL)
        """,
        [
            (
                str(event.id),
                user["id"],
                event.module,
                event.action,
                event.outcome,
                source,
                _interaction_effort(event),
                version,
                event.event_kind,
                event.surface,
                event.workflow,
                str(event.workflow_run_id) if event.workflow_run_id else None,
                event.duration_bucket,
                event.interaction_count,
                event.connectivity,
                event.failure_class,
                user["family_id"],
                recorded_at,
                recorded_at,
                user["id"],
                event.occurred_at.astimezone(timezone.utc).isoformat(),
            )
            for event in values
        ],
    )
    return max(db.total_changes - before, 0)


async def record_completed_action(
    *,
    user: dict,
    fact: CompletedAction,
    entry_source: str,
    app_version: str,
) -> None:
    """Persist one route fact without ever receiving a request or response body."""
    async with database_lease() as db:
        if await record_completed_actions_in_db(
            db,
            user=user,
            facts=[fact],
            entry_source=entry_source,
            app_version=app_version,
        ):
            await db.commit()


async def cleanup_expired_adoption_events(db, *, now: datetime | None = None) -> int:
    """Soft-delete content-free facts as soon as their 28-day window closes."""
    now = now or datetime.now(timezone.utc)
    now_string = now.isoformat()
    cutoff = (now - timedelta(days=RETENTION_DAYS)).isoformat()
    cursor = await db.execute(
        "UPDATE adoption_events SET deleted_at = ?, updated_at = ? "
        "WHERE deleted_at IS NULL AND datetime(created_at) < datetime(?)",
        (now_string, now_string, cutoff),
    )
    return max(cursor.rowcount, 0)

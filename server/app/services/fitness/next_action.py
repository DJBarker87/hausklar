"""One deterministic next-action decision shared by Today and Coach."""

from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.fitness_next_action import (
    FitnessNextAction,
    FitnessNextActionCommand,
    FitnessNextActionEvidence,
)
from app.services.fitness import planning, recovery


ACTIVE_PLAN_STATUSES = {"accepted", "scheduled", "in_progress"}


def _as_utc(value: str | None) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _occurs_on_day(
    plan: dict,
    *,
    day: date,
    zone: ZoneInfo,
    day_start_utc: datetime,
    day_end_utc: datetime,
) -> bool:
    if plan.get("scheduled_date") == day.isoformat():
        return True
    scheduled = _as_utc(plan.get("scheduled_start_utc"))
    if scheduled is not None and scheduled.astimezone(zone).date() == day:
        return True
    window_start = _as_utc(plan.get("time_window_start_utc"))
    window_end = _as_utc(plan.get("time_window_end_utc"))
    if window_start is not None and window_end is not None:
        return window_start < day_end_utc and window_end > day_start_utc
    if window_start is not None:
        return window_start.astimezone(zone).date() == day
    if window_end is not None:
        return window_end.astimezone(zone).date() == day
    return False


def _evidence(identifier: str, kind: str, label: str, summary: str):
    return FitnessNextActionEvidence(
        id=identifier,
        kind=kind,
        label=label,
        summary=summary,
    )


def _command(kind: str, target: str, label: str):
    return FitnessNextActionCommand(kind=kind, target=target, label=label)


def _readiness_matches_plan(readiness, plan: dict | None) -> bool:
    if readiness is None or plan is None:
        return False
    if readiness["planned_session_id"] == plan["id"]:
        return True
    return bool(
        readiness["activity_id"]
        and plan.get("completion_activity_id")
        and readiness["activity_id"] == plan["completion_activity_id"]
    )


async def next_action_for_user(
    db,
    *,
    user: dict,
    day: date | None = None,
    settings_row: dict | None = None,
    planned_sessions: list[dict] | None = None,
    recovery_detail: dict | None = None,
    latest_readiness=None,
) -> FitnessNextAction:
    """Resolve one owner-scoped answer without model calls or client heuristics."""
    settings_row = settings_row or await planning.ensure_settings(db, user=user)
    try:
        zone = ZoneInfo(settings_row["timezone"])
    except (KeyError, ZoneInfoNotFoundError):
        zone = ZoneInfo("Europe/London")
    resolved_day = day or datetime.now(timezone.utc).astimezone(zone).date()
    local_start = datetime.combine(resolved_day, time.min, tzinfo=zone)
    local_end = local_start + timedelta(days=1)
    day_start_utc = local_start.astimezone(timezone.utc)
    day_end_utc = local_end.astimezone(timezone.utc)

    if planned_sessions is None:
        planned_sessions = [
            plan
            for plan in await planning.list_planned_sessions(db, user=user)
            if plan["status"] in ACTIVE_PLAN_STATUSES
            and _occurs_on_day(
                plan,
                day=resolved_day,
                zone=zone,
                day_start_utc=day_start_utc,
                day_end_utc=day_end_utc,
            )
        ]
    primary_plan = planned_sessions[0] if planned_sessions else None

    if not _readiness_matches_plan(latest_readiness, primary_plan):
        latest_readiness = None
    if latest_readiness is None and primary_plan is not None:
        latest_readiness = await (
            await db.execute(
                "SELECT readiness_1_5, captured_at_utc, planned_session_id, activity_id "
                "FROM health_session_checkins WHERE family_id = ? AND owner_user_id = ? "
                "AND timing = 'pre' AND readiness_1_5 IS NOT NULL AND deleted_at IS NULL "
                "AND captured_at_utc >= ? AND captured_at_utc < ? "
                "AND (planned_session_id = ? OR (? IS NOT NULL AND activity_id = ?)) "
                "ORDER BY captured_at_utc DESC LIMIT 1",
                (
                    user["family_id"],
                    user["id"],
                    day_start_utc.isoformat(),
                    day_end_utc.isoformat(),
                    primary_plan["id"],
                    primary_plan.get("completion_activity_id"),
                    primary_plan.get("completion_activity_id"),
                ),
            )
        ).fetchone()
    if recovery_detail is None:
        recovery_detail = await recovery.recovery_summary(
            db,
            user=user,
            from_date=resolved_day - timedelta(days=6),
            to_date=resolved_day,
        )
    recovery_warning = next(
        (
            item
            for item in recovery_detail["baselines"]
            if item["status"] not in {"within_baseline", "insufficient_data"}
        ),
        None,
    )
    active_issue = await (
        await db.execute(
            "SELECT id, body_location_key, severity_0_10, observed_at_utc FROM "
            "health_body_issue_observations WHERE family_id = ? AND owner_user_id = ? "
            "AND status = 'active' AND deleted_at IS NULL "
            "ORDER BY severity_0_10 DESC, observed_at_utc DESC LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    coach_recommendation = await (
        await db.execute(
            "SELECT id, recommendation_type, recommendation_text, created_at FROM "
            "health_coach_recommendations WHERE family_id = ? AND owner_user_id = ? "
            "AND recommendation_type != 'weekly_review_draft' "
            "AND (status = 'active' OR (status = 'accepted' AND created_at >= ?)) "
            "AND deleted_at IS NULL "
            "ORDER BY created_at DESC LIMIT 1",
            (
                user["family_id"],
                user["id"],
                (datetime.now(timezone.utc) - timedelta(days=14)).isoformat(),
            ),
        )
    ).fetchone()

    issue_evidence = None
    issue_action = None
    severity = int(active_issue["severity_0_10"]) if active_issue else None
    if active_issue:
        location = active_issue["body_location_key"].replace("_", " ")
        issue_evidence = _evidence(
            f"body_issue:{active_issue['id']}",
            "body_issue",
            "Active body issue",
            f"{location.title()} was recorded at {severity}/10 and remains active.",
        )
        issue_action = _command(
            "open_body_issue", active_issue["id"], "Review body issue"
        )

    plan_evidence = None
    if primary_plan:
        plan_evidence = _evidence(
            f"planned_session:{primary_plan['id']}",
            "planned_session",
            primary_plan["title"],
            "This accepted session is scheduled for the current local day.",
        )
    coach_evidence = None
    if coach_recommendation:
        coach_evidence = _evidence(
            f"coach_recommendation:{coach_recommendation['id']}",
            "coach_recommendation",
            "Saved Coach recommendation",
            coach_recommendation["recommendation_text"],
        )
    recovery_evidence = None
    if recovery_warning:
        recovery_evidence = _evidence(
            f"recovery:{recovery_warning['metric_key']}",
            "recovery",
            recovery_warning["label"],
            f"The recorded value is {recovery_warning['status'].replace('_', ' ')}.",
        )

    expires_at = day_end_utc
    secondary = None
    if active_issue and severity is not None and severity >= 5:
        if primary_plan and latest_readiness is None:
            secondary = _command(
                "record_readiness", primary_plan["id"], "Record readiness"
            )
        elif coach_recommendation:
            secondary = _command(
                "open_coach", coach_recommendation["id"], "Open Coach advice"
            )
        return FitnessNextAction(
            title="Review the active body issue",
            body=(
                f"Review the recorded {active_issue['body_location_key'].replace('_', ' ')} "
                f"issue ({severity}/10) before changing today's training."
            ),
            urgency="urgent" if severity >= 8 else "attention",
            evidence=[item for item in (issue_evidence, plan_evidence) if item],
            action=issue_action,
            secondary_action=secondary,
            expires_at=expires_at,
            source=f"body_issue:{active_issue['id']}",
        )
    if primary_plan and latest_readiness is None:
        return FitnessNextAction(
            title="Record readiness before starting",
            body="Capture one-tap readiness now, then start the accepted session.",
            urgency="attention",
            evidence=[item for item in (plan_evidence, issue_evidence) if item],
            action=_command(
                "record_readiness", primary_plan["id"], "Record readiness"
            ),
            secondary_action=issue_action,
            expires_at=expires_at,
            source=f"readiness:{primary_plan['id']}",
        )
    if recovery_warning:
        return FitnessNextAction(
            title="Keep recovery context visible",
            body=(
                f"{recovery_warning['label']} is "
                f"{recovery_warning['status'].replace('_', ' ')}; use it as context, not a diagnosis."
            ),
            urgency="attention",
            evidence=[item for item in (recovery_evidence, issue_evidence) if item],
            action=_command(
                "open_recovery", recovery_warning["metric_key"], "Review recovery"
            ),
            secondary_action=issue_action,
            expires_at=expires_at,
            source=f"recovery:{recovery_warning['metric_key']}",
        )
    if coach_recommendation:
        return FitnessNextAction(
            title="Current coaching recommendation",
            body=coach_recommendation["recommendation_text"],
            urgency="routine",
            evidence=[item for item in (coach_evidence, issue_evidence) if item],
            action=_command(
                "open_coach", coach_recommendation["id"], "Open Coach advice"
            ),
            secondary_action=issue_action,
            expires_at=expires_at,
            source=f"coach_recommendation:{coach_recommendation['id']}",
        )
    if primary_plan:
        return FitnessNextAction(
            title="Next useful action",
            body=f"Complete or deliberately move {primary_plan['title']}.",
            urgency="routine",
            evidence=[item for item in (plan_evidence, issue_evidence) if item],
            action=_command(
                "open_planned_session", primary_plan["id"], "Open planned session"
            ),
            secondary_action=issue_action,
            expires_at=expires_at,
            source=f"planned_session:{primary_plan['id']}",
        )
    if active_issue:
        return FitnessNextAction(
            title="Keep the active body issue visible",
            body=(
                f"The recorded {active_issue['body_location_key'].replace('_', ' ')} "
                f"issue is {severity}/10. Review it without assuming a training change is required."
            ),
            urgency="routine",
            evidence=[issue_evidence],
            action=issue_action,
            expires_at=expires_at,
            source=f"body_issue:{active_issue['id']}",
        )
    return FitnessNextAction(
        title="Record what happens",
        body="No training adjustment is justified by the available evidence yet.",
        urgency="routine",
        evidence=[],
        action=_command("open_today", "today", "Open today"),
        expires_at=expires_at,
        source="baseline:record_today",
    )

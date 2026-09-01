"""Deterministic owner-private weekly Fitness review."""

from datetime import date, datetime, timedelta, timezone


def _activity_day(row) -> date:
    return date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10])


def _duration_seconds(row) -> float | None:
    for field in ("timer_duration_s", "elapsed_duration_s", "moving_duration_s"):
        value = row[field]
        if value is not None and float(value) > 0:
            return float(value)
    if row["ended_at_utc"]:
        start = datetime.fromisoformat(row["started_at_utc"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(row["ended_at_utc"].replace("Z", "+00:00"))
        if start.tzinfo is None:
            start = start.replace(tzinfo=timezone.utc)
        if end.tzinfo is None:
            end = end.replace(tzinfo=timezone.utc)
        return max((end - start).total_seconds(), 0)
    return None


async def _activities(db, *, user: dict, start: date, end: date):
    return await (
        await db.execute(
            "SELECT * FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
            "AND status = 'completed' AND deleted_at IS NULL "
            "AND parent_activity_id IS NULL "
            "AND COALESCE(local_calendar_date, substr(started_at_utc,1,10)) "
            "BETWEEN ? AND ? ORDER BY started_at_utc, id",
            (user["family_id"], user["id"], start.isoformat(), end.isoformat()),
        )
    ).fetchall()


async def _strength_volume(db, *, user: dict, start: date, end: date) -> float | None:
    row = await (
        await db.execute(
            "SELECT SUM(COALESCE(s.normalized_external_load_kg,0) * "
            "COALESCE(s.reps, COALESCE(s.reps_left,0) + COALESCE(s.reps_right,0), 0)) "
            "AS volume, "
            "SUM(CASE WHEN s.normalized_external_load_kg IS NOT NULL "
            "AND COALESCE(s.reps, COALESCE(s.reps_left,0) + COALESCE(s.reps_right,0), 0) > 0 "
            "THEN 1 ELSE 0 END) AS loaded_components "
            "FROM health_strength_sets s "
            "JOIN health_strength_set_groups g ON g.id = s.set_group_id "
            "AND g.family_id = s.family_id AND g.owner_user_id = s.owner_user_id "
            "JOIN health_activities a ON a.id = g.activity_id "
            "AND a.family_id = g.family_id AND a.owner_user_id = g.owner_user_id "
            "WHERE s.family_id = ? AND s.owner_user_id = ? "
            "AND s.deleted_at IS NULL AND g.deleted_at IS NULL AND a.deleted_at IS NULL "
            "AND s.component_status IN ('completed','partial') "
            "AND g.status IN ('completed','partial') "
            "AND g.training_role IN ('working','backoff','test') "
            "AND a.status = 'completed' AND a.parent_activity_id IS NULL "
            "AND COALESCE(a.local_calendar_date, substr(a.started_at_utc,1,10)) "
            "BETWEEN ? AND ?",
            (user["family_id"], user["id"], start.isoformat(), end.isoformat()),
        )
    ).fetchone()
    if row is None or int(row["loaded_components"] or 0) == 0:
        return None
    return float(row["volume"] or 0)


async def _chosen_goal(db, *, user: dict, week_end: date):
    return await (
        await db.execute(
            "SELECT * FROM health_goals WHERE family_id = ? AND owner_user_id = ? "
            "AND status = 'active' AND deleted_at IS NULL AND starts_on <= ? "
            "ORDER BY priority DESC, created_at, id LIMIT 1",
            (user["family_id"], user["id"], week_end.isoformat()),
        )
    ).fetchone()


def _percent(current: float, target: float) -> int | None:
    if target <= 0:
        return None
    return max(0, min(100, round(current / target * 100)))


async def _latest_weight(db, *, user: dict, week_end: date):
    return await (
        await db.execute(
            "SELECT value, unit_key FROM health_body_measurements "
            "WHERE family_id = ? AND owner_user_id = ? "
            "AND metric_key = 'body.weight_kg' AND canonical_state = 'canonical' "
            "AND deleted_at IS NULL AND substr(measured_at_utc,1,10) <= ? "
            "ORDER BY measured_at_utc DESC, created_at DESC LIMIT 1",
            (user["family_id"], user["id"], week_end.isoformat()),
        )
    ).fetchone()


async def _goal_progress(
    db,
    *,
    user: dict,
    goal,
    activities,
    active_days: int,
    week_end: date,
) -> dict | None:
    if goal is None:
        return None
    key = goal["metric_key"]
    target = float(goal["target_value"]) if goal["target_value"] is not None else None
    progress: int | None = None
    if key == "activity.sessions_per_week" and target is not None:
        current = len(activities)
        text = f"{current} of {target:g} sessions completed this week."
        progress = _percent(current, target)
    elif key == "running.distance_m" and target is not None:
        current_m = sum(
            float(row["distance_m"] or 0) for row in activities if row["sport_key"] == "running"
        )
        text = f"{current_m / 1_000:.1f} of {target / 1_000:g} km completed this week."
        progress = _percent(current_m, target)
    elif key == "running.sessions_per_week" and target is not None:
        current = sum(row["sport_key"] == "running" for row in activities)
        text = f"{current} of {target:g} runs completed this week."
        progress = _percent(current, target)
    elif key == "running.5k_seconds" and target is not None:
        comparable = []
        for row in activities:
            if row["sport_key"] != "running" or row["distance_m"] is None:
                continue
            distance = float(row["distance_m"])
            duration = _duration_seconds(row)
            # A short interval is not evidence of a 5K result. Match the
            # progress charts and only estimate from runs that covered 5K.
            if distance >= 5_000 and duration is not None and duration > 0:
                comparable.append(duration * 5_000 / distance)
        target_text = f"{int(target) // 60}:{int(target) % 60:02d}"
        if comparable:
            best = min(comparable)
            best_text = f"{int(round(best)) // 60}:{int(round(best)) % 60:02d}"
            text = f"Best 5K-equivalent this week: {best_text}; target {target_text}."
            progress = 100 if best <= target else None
        else:
            text = f"Complete a timed run to compare with your {target_text} 5K target."
    elif key == "strength.sessions_per_week" and target is not None:
        current = sum(row["sport_key"] == "strength" for row in activities)
        text = f"{current} of {target:g} strength sessions completed this week."
        progress = _percent(current, target)
    elif key == "activity.active_days_per_week" and target is not None:
        text = f"{active_days} of {target:g} active days completed this week."
        progress = _percent(active_days, target)
    elif key == "body.weight_kg" and target is not None:
        measurement = await _latest_weight(db, user=user, week_end=week_end)
        if measurement is None or measurement["unit_key"] != "kg":
            text = "Log a weight when it suits you to start following this goal."
        else:
            current = float(measurement["value"])
            text = f"{current:g} kg now, moving towards {target:g} kg."
            baseline = float(goal["baseline_value"]) if goal["baseline_value"] is not None else None
            if baseline is not None and baseline != target:
                progress = max(
                    0,
                    min(100, round((current - baseline) / (target - baseline) * 100)),
                )
            elif current == target:
                progress = 100
    else:
        text = f"{goal['name']} is active and ready for your next step."
    return {
        "goal_id": goal["id"],
        "goal_name": goal["name"],
        "progress_text": text,
        "progress_percent": progress,
    }


def _highlight(activities, durations: dict[str, float], totals: dict) -> dict:
    if not activities:
        return {
            "title": "A fresh week",
            "detail": "No completed sessions yet. One short session is enough to get moving.",
        }
    timed = [row for row in activities if row["id"] in durations]
    if timed:
        longest = sorted(
            timed,
            key=lambda row: (-durations[row["id"]], row["started_at_utc"], row["id"]),
        )[0]
        minutes = round(durations[longest["id"]] / 60)
        return {
            "title": "Longest session",
            "detail": f"{longest['title']} was {minutes} minutes.",
        }
    if totals["strength_volume_kg"] is not None:
        return {
            "title": "Strength work completed",
            "detail": f"You recorded {totals['strength_volume_kg']:g} kg of strength volume.",
        }
    return {
        "title": "You showed up",
        "detail": f"You completed {len(activities)} session{'s' if len(activities) != 1 else ''}.",
    }


def _opportunity(*, activities, goal, goal_progress: dict | None) -> dict:
    if not activities:
        return {
            "title": "Make the first move",
            "detail": "Choose one realistic session and put it into your week.",
            "destination": "plan",
            "action": "plan_session",
            "action_label": "Plan a session",
        }
    if goal is None:
        return {
            "title": "Choose what comes next",
            "detail": "Pick one goal so next week has a clear direction.",
            "destination": "goals",
            "action": "choose_goal",
            "action_label": "Choose a goal",
        }
    if goal_progress and goal_progress["progress_percent"] == 100:
        return {
            "title": "Build on this week",
            "detail": "Your chosen goal is on track. Put the next session in the plan.",
            "destination": "plan",
            "action": "plan_session",
            "action_label": "Plan the next session",
        }
    key = goal["metric_key"]
    if key == "strength.sessions_per_week":
        return {
            "title": "Add the next strength session",
            "detail": "A focused session is the clearest next step for this goal.",
            "destination": "strength",
            "action": "start_strength",
            "action_label": "Start strength",
        }
    if key == "body.weight_kg":
        return {
            "title": "Keep the trend useful",
            "detail": "Add a weight when it fits your routine.",
            "destination": "measurements",
            "action": "log_weight",
            "action_label": "Log weight",
        }
    if key in {
        "activity.sessions_per_week",
        "running.sessions_per_week",
        "running.distance_m",
        "running.5k_seconds",
        "activity.active_days_per_week",
    }:
        label = "Add a run" if key.startswith("running.") else "Add a session"
        return {
            "title": "Put the next step in the week",
            "detail": "Planning it now makes the goal easier to act on.",
            "destination": "plan",
            "action": "plan_session",
            "action_label": label,
        }
    return {
        "title": "Review your next step",
        "detail": "Open your goal and choose the next action that fits.",
        "destination": "goals",
        "action": "review_goal",
        "action_label": "Review goal",
    }


async def weekly_review(db, *, user: dict, week_start: date) -> dict:
    week_end = week_start + timedelta(days=6)
    activities = await _activities(db, user=user, start=week_start, end=week_end)
    durations = {
        row["id"]: duration
        for row in activities
        if (duration := _duration_seconds(row)) is not None
    }
    duration_minutes = round(sum(durations.values()) / 60) if durations else None
    distances = [float(row["distance_m"]) for row in activities if row["distance_m"] is not None]
    strength_volume = await _strength_volume(
        db,
        user=user,
        start=week_start,
        end=week_end,
    )
    active_days = len({_activity_day(row) for row in activities})
    totals = {
        "completed_sessions": len(activities),
        "active_days": active_days,
        "duration_minutes": duration_minutes,
        "distance_km": round(sum(distances) / 1_000, 2) if distances else None,
        "strength_volume_kg": (round(strength_volume, 1) if strength_volume is not None else None),
    }
    goal = await _chosen_goal(db, user=user, week_end=week_end)
    progress = await _goal_progress(
        db,
        user=user,
        goal=goal,
        activities=activities,
        active_days=active_days,
        week_end=week_end,
    )
    return {
        "week_start": week_start.isoformat(),
        "week_end": week_end.isoformat(),
        "totals": totals,
        "goal": progress,
        "highlight": _highlight(activities, durations, totals),
        "opportunity": _opportunity(
            activities=activities,
            goal=goal,
            goal_progress=progress,
        ),
    }

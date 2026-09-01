"""Health Dashboard — aggregated stats, trends, and chart data for health_data."""

import json
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Query

from app.auth import get_current_user
from app.database import get_db
from app.models.health_dashboard import (
    ExerciseHistory,
    ExercisePoint,
    HealthSummary,
    PersonalRecord,
    PersonalRecords,
    SleepHistory,
    SleepPoint,
    WeeklyExerciseAggregate,
    WeightHistory,
    WeightPoint,
)

router = APIRouter()


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _start_of_week(dt: datetime) -> datetime:
    """Return Monday 00:00:00 UTC of the week containing *dt*."""
    return (dt - timedelta(days=dt.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)


def _parse_metadata(raw: str | None) -> dict | None:
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None


# ---------------------------------------------------------------------------
# GET /summary
# ---------------------------------------------------------------------------


@router.get("/summary", response_model=HealthSummary)
async def get_summary(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Aggregated health dashboard summary."""
    now = _now_utc()
    week_start = (now - timedelta(days=7)).isoformat()
    thirty_days_ago = (now - timedelta(days=30)).isoformat()

    # Latest weight (most recent from withings)
    cursor = await db.execute(
        "SELECT value, recorded_at FROM health_data "
        "WHERE source = 'withings' AND data_type = 'weight' AND deleted_at IS NULL "
        "AND family_id = ? "
        "ORDER BY recorded_at DESC LIMIT 1",
        (current_user["family_id"],),
    )
    latest_weight_row = await cursor.fetchone()

    latest_weight = None
    latest_weight_date = None
    if latest_weight_row:
        latest_weight = latest_weight_row["value"]
        latest_weight_date = latest_weight_row["recorded_at"]

    # Weight trend: difference between most recent weight and earliest weight in last 30 days
    weight_trend_kg = None
    if latest_weight is not None:
        cursor = await db.execute(
            "SELECT value FROM health_data "
            "WHERE source = 'withings' AND data_type = 'weight' AND deleted_at IS NULL "
            "AND family_id = ? AND recorded_at >= ? "
            "ORDER BY recorded_at ASC LIMIT 1",
            (current_user["family_id"], thirty_days_ago),
        )
        oldest_recent = await cursor.fetchone()
        if oldest_recent:
            weight_trend_kg = round(latest_weight - oldest_recent["value"], 2)

    # Exercise count over the last 7 days (from strava)
    cursor = await db.execute(
        "SELECT COUNT(*) AS cnt FROM health_data "
        "WHERE source = 'strava' AND deleted_at IS NULL AND family_id = ? AND recorded_at >= ?",
        (current_user["family_id"], week_start),
    )
    exercise_row = await cursor.fetchone()
    exercise_count_this_week = exercise_row["cnt"] if exercise_row else 0

    # Average sleep over the last 7 days (from apple_health)
    cursor = await db.execute(
        "SELECT AVG(value) AS avg_sleep FROM health_data "
        "WHERE source = 'apple_health' AND data_type = 'sleep' AND deleted_at IS NULL "
        "AND family_id = ? AND recorded_at >= ?",
        (current_user["family_id"], week_start),
    )
    sleep_row = await cursor.fetchone()
    average_sleep = None
    if sleep_row and sleep_row["avg_sleep"] is not None:
        average_sleep = round(sleep_row["avg_sleep"], 2)

    # Total active minutes over the last 7 days (sum of duration_seconds from strava metadata)
    cursor = await db.execute(
        "SELECT metadata FROM health_data "
        "WHERE source = 'strava' AND deleted_at IS NULL AND family_id = ? AND recorded_at >= ?",
        (current_user["family_id"], week_start),
    )
    strava_rows = await cursor.fetchall()
    total_active_seconds = 0.0
    for row in strava_rows:
        meta = _parse_metadata(row["metadata"])
        if meta and "duration_seconds" in meta:
            total_active_seconds += meta["duration_seconds"]
    total_active_minutes = round(total_active_seconds / 60, 2) if total_active_seconds else 0

    return HealthSummary(
        latest_weight=latest_weight,
        latest_weight_date=latest_weight_date,
        weight_trend_kg=weight_trend_kg,
        exercise_count_this_week=exercise_count_this_week,
        average_sleep_hours_this_week=average_sleep,
        total_active_minutes_this_week=total_active_minutes,
    )


# ---------------------------------------------------------------------------
# GET /weight
# ---------------------------------------------------------------------------


@router.get("/weight", response_model=WeightHistory)
async def get_weight_history(
    start: str = Query(..., description="ISO 8601 start date"),
    end: str = Query(..., description="ISO 8601 end date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Weight history for charting."""
    cursor = await db.execute(
        "SELECT value, recorded_at FROM health_data "
        "WHERE source = 'withings' AND data_type = 'weight' AND deleted_at IS NULL "
        "AND family_id = ? AND recorded_at >= ? AND recorded_at <= ? "
        "ORDER BY recorded_at ASC",
        (current_user["family_id"], start, end),
    )
    rows = await cursor.fetchall()

    data = [WeightPoint(date=row["recorded_at"], value=row["value"]) for row in rows]

    if not data:
        return WeightHistory(data=[])

    values = [d.value for d in data]
    current = values[-1]
    min_val = min(values)
    max_val = max(values)
    avg_val = round(sum(values) / len(values), 2)

    # Trend: compare first half average to second half average
    if len(values) >= 2:
        first_val = values[0]
        last_val = values[-1]
        diff = last_val - first_val
        if abs(diff) < 0.5:
            trend = "stable"
        elif diff > 0:
            trend = "up"
        else:
            trend = "down"
    else:
        trend = None

    return WeightHistory(
        data=data,
        current=current,
        min=min_val,
        max=max_val,
        average=avg_val,
        trend=trend,
    )


# ---------------------------------------------------------------------------
# GET /exercise
# ---------------------------------------------------------------------------


@router.get("/exercise", response_model=ExerciseHistory)
async def get_exercise_history(
    start: str = Query(..., description="ISO 8601 start date"),
    end: str = Query(..., description="ISO 8601 end date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Exercise history for charting with weekly aggregation."""
    cursor = await db.execute(
        "SELECT data_type, value, unit, recorded_at, metadata FROM health_data "
        "WHERE source = 'strava' AND deleted_at IS NULL "
        "AND family_id = ? AND recorded_at >= ? AND recorded_at <= ? "
        "ORDER BY recorded_at ASC",
        (current_user["family_id"], start, end),
    )
    rows = await cursor.fetchall()

    data: list[ExercisePoint] = []
    weekly_buckets: dict[str, dict] = {}  # week_start_iso -> {distance, duration, count}

    for row in rows:
        meta = _parse_metadata(row["metadata"])
        data.append(
            ExercisePoint(
                date=row["recorded_at"],
                data_type=row["data_type"],
                value=row["value"],
                unit=row["unit"],
                metadata=meta,
            )
        )

        # Aggregate by week
        try:
            recorded_dt = datetime.fromisoformat(row["recorded_at"])
        except (ValueError, TypeError):
            continue
        ws = _start_of_week(recorded_dt)
        ws_key = ws.strftime("%Y-%m-%d")

        if ws_key not in weekly_buckets:
            weekly_buckets[ws_key] = {
                "total_distance_km": 0.0,
                "total_duration_seconds": 0.0,
                "count": 0,
            }
        weekly_buckets[ws_key]["total_distance_km"] += row["value"]
        weekly_buckets[ws_key]["count"] += 1
        if meta and "duration_seconds" in meta:
            weekly_buckets[ws_key]["total_duration_seconds"] += meta["duration_seconds"]

    weekly = [
        WeeklyExerciseAggregate(
            week_start=ws,
            total_distance_km=round(b["total_distance_km"], 2),
            total_duration_seconds=round(b["total_duration_seconds"], 2),
            count=b["count"],
        )
        for ws, b in sorted(weekly_buckets.items())
    ]

    return ExerciseHistory(data=data, weekly=weekly)


# ---------------------------------------------------------------------------
# GET /sleep
# ---------------------------------------------------------------------------


@router.get("/sleep", response_model=SleepHistory)
async def get_sleep_history(
    start: str = Query(..., description="ISO 8601 start date"),
    end: str = Query(..., description="ISO 8601 end date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Sleep history for charting."""
    cursor = await db.execute(
        "SELECT value, recorded_at FROM health_data "
        "WHERE source = 'apple_health' AND data_type = 'sleep' AND deleted_at IS NULL "
        "AND family_id = ? AND recorded_at >= ? AND recorded_at <= ? "
        "ORDER BY recorded_at ASC",
        (current_user["family_id"], start, end),
    )
    rows = await cursor.fetchall()

    data = [SleepPoint(date=row["recorded_at"], value=row["value"]) for row in rows]

    if not data:
        return SleepHistory(data=[])

    values = [d.value for d in data]
    return SleepHistory(
        data=data,
        average=round(sum(values) / len(values), 2),
        min=min(values),
        max=max(values),
    )


# ---------------------------------------------------------------------------
# GET /records
# ---------------------------------------------------------------------------


@router.get("/records", response_model=PersonalRecords)
async def get_personal_records(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Personal records derived from health data."""

    # Fastest 5K — look for runs with a "pace" in metadata; lower pace = faster
    # Also look for runs where distance >= 5 km and find the one with lowest duration
    cursor = await db.execute(
        "SELECT value, recorded_at, metadata FROM health_data "
        "WHERE source = 'strava' AND data_type = 'run' AND deleted_at IS NULL "
        "AND family_id = ? AND value >= 5.0 "
        "ORDER BY recorded_at DESC",
        (current_user["family_id"],),
    )
    run_rows = await cursor.fetchall()

    fastest_5k: PersonalRecord | None = None
    best_pace = None
    for row in run_rows:
        meta = _parse_metadata(row["metadata"])
        if meta and "duration_seconds" in meta:
            # Estimate 5K time proportionally: (5 / distance) * duration
            distance = row["value"]
            duration = meta["duration_seconds"]
            estimated_5k_time = (5.0 / distance) * duration
            if best_pace is None or estimated_5k_time < best_pace:
                best_pace = estimated_5k_time
                fastest_5k = PersonalRecord(
                    label="Fastest 5K",
                    value=round(estimated_5k_time, 1),
                    unit="seconds",
                    date=row["recorded_at"],
                    metadata=meta,
                )

    # Longest run — highest distance value among strava runs
    cursor = await db.execute(
        "SELECT value, recorded_at, metadata FROM health_data "
        "WHERE source = 'strava' AND data_type = 'run' AND deleted_at IS NULL "
        "AND family_id = ? "
        "ORDER BY value DESC LIMIT 1",
        (current_user["family_id"],),
    )
    longest_run_row = await cursor.fetchone()
    longest_run: PersonalRecord | None = None
    if longest_run_row:
        longest_run = PersonalRecord(
            label="Longest Run",
            value=longest_run_row["value"],
            unit="km",
            date=longest_run_row["recorded_at"],
            metadata=_parse_metadata(longest_run_row["metadata"]),
        )

    # Heaviest weight — highest weight value from withings
    cursor = await db.execute(
        "SELECT value, recorded_at FROM health_data "
        "WHERE source = 'withings' AND data_type = 'weight' AND deleted_at IS NULL "
        "AND family_id = ? "
        "ORDER BY value DESC LIMIT 1",
        (current_user["family_id"],),
    )
    heaviest_row = await cursor.fetchone()
    heaviest_weight: PersonalRecord | None = None
    if heaviest_row:
        heaviest_weight = PersonalRecord(
            label="Heaviest Weight",
            value=heaviest_row["value"],
            unit="kg",
            date=heaviest_row["recorded_at"],
        )

    # Most active week — week with the most strava activities
    cursor = await db.execute(
        "SELECT recorded_at, metadata FROM health_data "
        "WHERE source = 'strava' AND deleted_at IS NULL "
        "AND family_id = ? "
        "ORDER BY recorded_at ASC",
        (current_user["family_id"],),
    )
    all_strava = await cursor.fetchall()
    week_activity_counts: dict[str, int] = {}
    week_durations: dict[str, float] = {}
    for row in all_strava:
        try:
            recorded_dt = datetime.fromisoformat(row["recorded_at"])
        except (ValueError, TypeError):
            continue
        ws = _start_of_week(recorded_dt).strftime("%Y-%m-%d")
        week_activity_counts[ws] = week_activity_counts.get(ws, 0) + 1
        meta = _parse_metadata(row["metadata"])
        if meta and "duration_seconds" in meta:
            week_durations[ws] = week_durations.get(ws, 0) + meta["duration_seconds"]

    most_active_week: PersonalRecord | None = None
    if week_activity_counts:
        best_week = max(week_activity_counts, key=lambda w: week_activity_counts[w])
        most_active_week = PersonalRecord(
            label="Most Active Week",
            value=week_activity_counts[best_week],
            unit="activities",
            date=best_week,
            metadata={"total_duration_seconds": week_durations.get(best_week, 0)},
        )

    return PersonalRecords(
        fastest_5k=fastest_5k,
        longest_run=longest_run,
        heaviest_weight=heaviest_weight,
        most_active_week=most_active_week,
    )

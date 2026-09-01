"""Production-minded performance gates for representative Fitness history."""

from __future__ import annotations

import json
import statistics
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from time import perf_counter
from typing import Any

import pytest

from app.database import standalone_db
from app.models.fitness_coach import CoachMessageRequest
from app.services.fitness import activities, coach, planning, strength, weekly_review
from app.services.fitness.experience import overview_for_user, today_card_for_user
from fitness_scale_fixture import (
    FIT_ACTIVITY_COUNT,
    FOOD_LOG_COUNT,
    FUTURE_PLAN_COUNT,
    HISTORICAL_PLAN_COUNT,
    HISTORY_DAY_COUNT,
    LONG_STREAM_COUNT,
    PLANNED_SESSION_COUNT,
    STRENGTH_EXERCISES_PER_SESSION,
    STRENGTH_SESSION_COUNT,
    STRENGTH_SETS_PER_EXERCISE,
    seed_private_today_plan,
    seed_representative_fitness_scale,
)


pytestmark = pytest.mark.asyncio
WARM_RUNS = 5


@dataclass(frozen=True)
class PerformanceLimit:
    cold_ms: float
    warm_median_ms: float
    max_queries: int
    max_response_bytes: int


@dataclass(frozen=True)
class Measurement:
    elapsed_ms: float
    queries: int
    response_bytes: int
    result: Any


LIMITS = {
    "overview": PerformanceLimit(250, 100, 13, 16 * 1_024),
    "today_card": PerformanceLimit(150, 75, 5, 8 * 1_024),
    "weekly_review": PerformanceLimit(250, 100, 4, 32 * 1_024),
    # The rich history contract is capped at 50 rows: one page query plus
    # owner-scoped batch reads for metrics and gear.
    "activity_history": PerformanceLimit(500, 250, 3, 256 * 1_024),
    "activity_detail": PerformanceLimit(350, 150, 30, 256 * 1_024),
    "progress": PerformanceLimit(1_000, 500, 80, 1 * 1_024 * 1_024),
    # The always-available Coach baseline intentionally spans ten bounded
    # evidence groups, including one planned-versus-completed outcome read.
    "coach_context": PerformanceLimit(750, 300, 32, 128 * 1_024),
}


class _CountingConnection:
    def __init__(self, connection):
        self._connection = connection
        self.execute_count = 0

    async def execute(self, sql, parameters=None):
        self.execute_count += 1
        if parameters is None:
            return await self._connection.execute(sql)
        return await self._connection.execute(sql, parameters)

    def __getattr__(self, name):
        return getattr(self._connection, name)


def _json_value(value: Any) -> Any:
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json")
    return value


def _response_size(value: Any) -> int:
    return len(
        json.dumps(
            _json_value(value),
            default=str,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode()
    )


async def _measure(connection, operation: Callable[[Any], Awaitable[Any]]) -> Measurement:
    counted = _CountingConnection(connection)
    started = perf_counter()
    result = await operation(counted)
    elapsed_ms = (perf_counter() - started) * 1_000
    return Measurement(
        elapsed_ms=elapsed_ms,
        queries=counted.execute_count,
        response_bytes=_response_size(result),
        result=result,
    )


async def _cold_and_warm(
    db_path: str,
    operation: Callable[[Any], Awaitable[Any]],
) -> tuple[Measurement, list[Measurement]]:
    # "Cold" is a freshly configured SQLite connection. Warm measurements
    # reuse one connection so statement/page caches reflect steady-state use.
    async with standalone_db(db_path) as cold_db:
        cold = await _measure(cold_db, operation)
    async with standalone_db(db_path) as warm_db:
        warm = [await _measure(warm_db, operation) for _ in range(WARM_RUNS)]
    return cold, warm


def _assert_limit(
    name: str,
    cold: Measurement,
    warm: list[Measurement],
    record_testsuite_property,
) -> None:
    limit = LIMITS[name]
    warm_median = statistics.median(item.elapsed_ms for item in warm)
    max_queries = max([cold.queries, *(item.queries for item in warm)])
    max_bytes = max([cold.response_bytes, *(item.response_bytes for item in warm)])
    record_testsuite_property(f"fitness_{name}_cold_ms", round(cold.elapsed_ms, 3))
    record_testsuite_property(f"fitness_{name}_warm_median_ms", round(warm_median, 3))
    record_testsuite_property(f"fitness_{name}_max_queries", max_queries)
    record_testsuite_property(f"fitness_{name}_max_response_bytes", max_bytes)
    assert cold.elapsed_ms <= limit.cold_ms, (
        f"{name} cold {cold.elapsed_ms:.1f}ms exceeded {limit.cold_ms:.0f}ms"
    )
    assert warm_median <= limit.warm_median_ms, (
        f"{name} warm median {warm_median:.1f}ms exceeded "
        f"{limit.warm_median_ms:.0f}ms"
    )
    assert max_queries <= limit.max_queries, (
        f"{name} used {max_queries} queries; limit is {limit.max_queries}"
    )
    assert max_bytes <= limit.max_response_bytes, (
        f"{name} returned {max_bytes} bytes; limit is {limit.max_response_bytes}"
    )


async def _table_count(db, *, table: str, owner_id: str, where: str = "1 = 1") -> int:
    row = await (
        await db.execute(
            f"SELECT COUNT(*) AS count FROM {table} "
            f"WHERE owner_user_id = ? AND {where}",
            (owner_id,),
        )
    ).fetchone()
    return int(row["count"])


async def test_scale_fixture_is_stage17_sized_deterministic_and_owner_private(
    initialized_db,
    adult_a_user,
    adult_b_user,
):
    reference_day = datetime.now(timezone.utc).date()
    async with standalone_db(initialized_db) as db:
        fixture = await seed_representative_fitness_scale(
            db,
            user=adult_a_user,
            reference_day=reference_day,
        )
        adult_b_plan_id = await seed_private_today_plan(
            db,
            user=adult_b_user,
            reference_day=reference_day,
            title="Morgan scale sentinel",
        )

    async with standalone_db(initialized_db) as db:
        assert await _table_count(
            db,
            table="health_source_records",
            owner_id=adult_a_user["id"],
            where="origin_provider_key = 'fit'",
        ) == FIT_ACTIVITY_COUNT
        assert await _table_count(
            db,
            table="health_activities",
            owner_id=adult_a_user["id"],
            where="sport_key = 'strength'",
        ) == STRENGTH_SESSION_COUNT
        assert await _table_count(
            db,
            table="health_food_log_entries",
            owner_id=adult_a_user["id"],
        ) == FOOD_LOG_COUNT
        assert await _table_count(
            db,
            table="health_planned_sessions",
            owner_id=adult_a_user["id"],
        ) == PLANNED_SESSION_COUNT
        assert await _table_count(
            db,
            table="health_body_measurements",
            owner_id=adult_a_user["id"],
        ) == HISTORY_DAY_COUNT
        assert await _table_count(
            db,
            table="health_sleep_sessions",
            owner_id=adult_a_user["id"],
        ) == HISTORY_DAY_COUNT
        assert await _table_count(
            db,
            table="health_recovery_observations",
            owner_id=adult_a_user["id"],
        ) == HISTORY_DAY_COUNT
        assert await _table_count(
            db,
            table="health_activity_stream_assets",
            owner_id=adult_a_user["id"],
            where="row_count >= 36000",
        ) == LONG_STREAM_COUNT
        expected_sets = (
            STRENGTH_SESSION_COUNT
            * STRENGTH_EXERCISES_PER_SESSION
            * STRENGTH_SETS_PER_EXERCISE
        )
        assert await _table_count(
            db,
            table="health_strength_sets",
            owner_id=adult_a_user["id"],
        ) == expected_sets
        assert len(fixture.fit_activity_ids) == FIT_ACTIVITY_COUNT
        assert len(fixture.strength_activity_ids) == STRENGTH_SESSION_COUNT
        assert HISTORICAL_PLAN_COUNT + FUTURE_PLAN_COUNT + 1 == PLANNED_SESSION_COUNT

        adult_a_overview = await overview_for_user(db, user=adult_a_user, day=reference_day)
        adult_b_overview = await overview_for_user(db, user=adult_b_user, day=reference_day)
        assert adult_a_overview.session is not None
        assert adult_a_overview.session.id == fixture.current_plan_id
        assert adult_a_overview.session.title == "Today's easy run"
        assert adult_b_overview.session is not None
        assert adult_b_overview.session.id == adult_b_plan_id
        assert adult_b_overview.session.title == "Morgan scale sentinel"
        assert "Morgan scale sentinel" not in str(adult_a_overview.model_dump())

        batched_db = _CountingConnection(db)
        batched_sessions = await strength.list_strength_sessions(
            batched_db,
            user=adult_a_user,
            limit=10,
        )
        assert batched_db.execute_count == 7
        assert len(batched_sessions) == 10
        individual = await strength.get_strength_session(
            db,
            user=adult_a_user,
            activity_id=batched_sessions[0]["id"],
        )
        assert batched_sessions[0] == individual

        muscle_db = _CountingConnection(db)
        muscle_groups = await strength.muscle_group_summary(muscle_db, user=adult_a_user)
        assert muscle_db.execute_count == 3
        assert sum(item["direct_working_sets"] for item in muscle_groups) == expected_sets


async def test_representative_scale_read_paths_remain_bounded(
    initialized_db,
    adult_a_user,
    record_testsuite_property,
):
    reference_day = datetime.now(timezone.utc).date()
    async with standalone_db(initialized_db) as db:
        fixture = await seed_representative_fitness_scale(
            db,
            user=adult_a_user,
            reference_day=reference_day,
        )

    week_start = reference_day - timedelta(days=reference_day.weekday())
    coach_request = CoachMessageRequest(
        message="Review my training, strength, recovery, nutrition and progress this week.",
        intent="weekly",
        timezone="Europe/London",
        client_now=datetime.combine(
            reference_day,
            datetime.min.time(),
            tzinfo=timezone.utc,
        ).replace(hour=12).isoformat(),
    )

    async def overview(db):
        return await overview_for_user(db, user=adult_a_user, day=reference_day)

    async def today_card(db):
        return await today_card_for_user(db, user=adult_a_user, day=reference_day)

    async def review(db):
        return await weekly_review.weekly_review(
            db,
            user=adult_a_user,
            week_start=week_start,
        )

    async def history(db):
        return await activities.list_activities(db, user=adult_a_user, limit=50)

    async def detail(db):
        return await activities.activity_detail(
            db,
            user=adult_a_user,
            activity_id=fixture.latest_fit_activity_id,
        )

    async def progress(db):
        return await planning.progress_summary(db, user=adult_a_user)

    async def coach_context(db):
        evidence = await coach.build_evidence(db, user=adult_a_user, body=coach_request)
        assert len(evidence) <= coach.MAX_EVIDENCE_ITEMS
        return coach.bridge_context(evidence)

    operations = {
        "overview": overview,
        "today_card": today_card,
        "weekly_review": review,
        "activity_history": history,
        "activity_detail": detail,
        "progress": progress,
        "coach_context": coach_context,
    }
    results = {}
    for name, operation in operations.items():
        cold, warm = await _cold_and_warm(initialized_db, operation)
        _assert_limit(name, cold, warm, record_testsuite_property)
        results[name] = cold.result

    assert results["overview"].session.id == fixture.current_plan_id
    assert results["today_card"].session.id == fixture.current_plan_id
    assert results["weekly_review"]["totals"]["completed_sessions"] >= 2
    assert len(results["activity_history"]) == 50
    assert results["activity_detail"]["activity"]["id"] == fixture.latest_fit_activity_id
    assert len(results["activity_detail"]["available_stream_metrics"]) == 5
    assert len(results["progress"]["weight_trend"]["points"]) == HISTORY_DAY_COUNT
    assert len(results["coach_context"]["evidence"]) <= coach.MAX_EVIDENCE_ITEMS

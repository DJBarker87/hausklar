"""Tests for the health dashboard router (/api/health/dashboard)."""

import json
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite
import pytest

from conftest import EXAMPLE_FAMILY_ID

BASE = "/api/health/dashboard"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _days_ago(n: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=n)).isoformat()


def _uuid() -> str:
    return str(uuid.uuid4())


async def _insert_health(db_path: str, *, source: str, data_type: str, value: float, unit: str, recorded_at: str, metadata: dict | None = None):
    """Insert a single health_data row directly into the database."""
    now = _now_iso()
    meta_json = json.dumps(metadata) if metadata else None
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT INTO health_data (id, source, data_type, value, unit, recorded_at, metadata, family_id, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (_uuid(), source, data_type, value, unit, recorded_at, meta_json, EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()


# ---------------------------------------------------------------------------
# Summary endpoint
# ---------------------------------------------------------------------------


class TestSummary:
    """Tests for GET /summary."""

    async def test_summary_no_data(self, client, adult_a_headers):
        """With no health data, summary returns sensible defaults."""
        resp = await client.get(f"{BASE}/summary", headers=adult_a_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["latest_weight"] is None
        assert data["latest_weight_date"] is None
        assert data["weight_trend_kg"] is None
        assert data["exercise_count_this_week"] == 0
        assert data["average_sleep_hours_this_week"] is None
        assert data["total_active_minutes_this_week"] == 0

    async def test_summary_with_data(self, client, adult_a_headers, initialized_db):
        """Summary returns correct aggregated stats when data is present."""
        now = datetime.now(timezone.utc)
        today = now.isoformat()
        yesterday = (now - timedelta(days=1)).isoformat()
        twenty_days_ago = (now - timedelta(days=20)).isoformat()

        # Weight data — current and 20 days ago
        await _insert_health(initialized_db, source="withings", data_type="weight", value=80.0, unit="kg", recorded_at=twenty_days_ago)
        await _insert_health(initialized_db, source="withings", data_type="weight", value=78.5, unit="kg", recorded_at=today)

        # Exercise data this week
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="run",
            value=5.0,
            unit="km",
            recorded_at=today,
            metadata={"duration_seconds": 1800, "pace": "6:00"},
        )
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="cycle",
            value=20.0,
            unit="km",
            recorded_at=yesterday,
            metadata={"duration_seconds": 3600},
        )

        # Sleep data this week
        await _insert_health(initialized_db, source="apple_health", data_type="sleep", value=7.5, unit="hours", recorded_at=today)
        await _insert_health(initialized_db, source="apple_health", data_type="sleep", value=8.0, unit="hours", recorded_at=yesterday)

        resp = await client.get(f"{BASE}/summary", headers=adult_a_headers)
        assert resp.status_code == 200
        data = resp.json()

        # Latest weight
        assert data["latest_weight"] == 78.5
        assert data["latest_weight_date"] is not None

        # Weight trend (78.5 - 80.0 = -1.5)
        assert data["weight_trend_kg"] == -1.5

        # Exercise count this week (2 exercises)
        assert data["exercise_count_this_week"] == 2

        # Average sleep ((7.5 + 8.0) / 2 = 7.75)
        assert data["average_sleep_hours_this_week"] == 7.75

        # Total active minutes ((1800 + 3600) / 60 = 90)
        assert data["total_active_minutes_this_week"] == 90.0


# ---------------------------------------------------------------------------
# Weight endpoint
# ---------------------------------------------------------------------------


class TestWeight:
    """Tests for GET /weight."""

    async def test_weight_empty(self, client, adult_a_headers):
        """Weight endpoint returns empty data when no records exist."""
        resp = await client.get(
            f"{BASE}/weight",
            params={"start": "2025-01-01", "end": "2026-12-31"},
            headers=adult_a_headers,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["data"] == []
        assert data["current"] is None
        assert data["trend"] is None

    async def test_weight_trend_calculation(self, client, adult_a_headers, initialized_db):
        """Weight endpoint correctly calculates trend, min, max, average."""
        # Insert a series of weight readings over time
        await _insert_health(initialized_db, source="withings", data_type="weight", value=82.0, unit="kg", recorded_at="2026-01-05T08:00:00Z")
        await _insert_health(initialized_db, source="withings", data_type="weight", value=81.0, unit="kg", recorded_at="2026-01-12T08:00:00Z")
        await _insert_health(initialized_db, source="withings", data_type="weight", value=80.0, unit="kg", recorded_at="2026-01-19T08:00:00Z")
        await _insert_health(initialized_db, source="withings", data_type="weight", value=79.0, unit="kg", recorded_at="2026-01-26T08:00:00Z")

        resp = await client.get(
            f"{BASE}/weight",
            params={"start": "2026-01-01", "end": "2026-01-31"},
            headers=adult_a_headers,
        )
        assert resp.status_code == 200
        data = resp.json()

        assert len(data["data"]) == 4
        assert data["current"] == 79.0
        assert data["min"] == 79.0
        assert data["max"] == 82.0
        assert data["average"] == 80.5
        assert data["trend"] == "down"  # 79 < 82, and diff > 0.5

    async def test_weight_trend_up(self, client, adult_a_headers, initialized_db):
        """Weight trend is 'up' when weight increases."""
        await _insert_health(initialized_db, source="withings", data_type="weight", value=75.0, unit="kg", recorded_at="2026-02-01T08:00:00Z")
        await _insert_health(initialized_db, source="withings", data_type="weight", value=77.0, unit="kg", recorded_at="2026-02-05T08:00:00Z")

        resp = await client.get(
            f"{BASE}/weight",
            params={"start": "2026-02-01", "end": "2026-02-28"},
            headers=adult_a_headers,
        )
        data = resp.json()
        assert data["trend"] == "up"

    async def test_weight_trend_stable(self, client, adult_a_headers, initialized_db):
        """Weight trend is 'stable' when change is less than 0.5 kg."""
        await _insert_health(initialized_db, source="withings", data_type="weight", value=80.0, unit="kg", recorded_at="2026-02-01T08:00:00Z")
        await _insert_health(initialized_db, source="withings", data_type="weight", value=80.3, unit="kg", recorded_at="2026-02-05T08:00:00Z")

        resp = await client.get(
            f"{BASE}/weight",
            params={"start": "2026-02-01", "end": "2026-02-28"},
            headers=adult_a_headers,
        )
        data = resp.json()
        assert data["trend"] == "stable"


# ---------------------------------------------------------------------------
# Exercise endpoint
# ---------------------------------------------------------------------------


class TestExercise:
    """Tests for GET /exercise."""

    async def test_exercise_empty(self, client, adult_a_headers):
        """Exercise endpoint returns empty data when no records exist."""
        resp = await client.get(
            f"{BASE}/exercise",
            params={"start": "2025-01-01", "end": "2026-12-31"},
            headers=adult_a_headers,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["data"] == []
        assert data["weekly"] == []

    async def test_exercise_aggregation(self, client, adult_a_headers, initialized_db):
        """Exercise endpoint aggregates by week correctly."""
        # Week 1: Mon 2026-01-05 to Sun 2026-01-11
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="run",
            value=5.0,
            unit="km",
            recorded_at="2026-01-05T07:00:00Z",
            metadata={"duration_seconds": 1500, "pace": "5:00"},
        )
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="run",
            value=10.0,
            unit="km",
            recorded_at="2026-01-07T07:00:00Z",
            metadata={"duration_seconds": 3200, "pace": "5:20"},
        )

        # Week 2: Mon 2026-01-12 to Sun 2026-01-18
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="cycle",
            value=30.0,
            unit="km",
            recorded_at="2026-01-14T17:00:00Z",
            metadata={"duration_seconds": 4500},
        )

        resp = await client.get(
            f"{BASE}/exercise",
            params={"start": "2026-01-01", "end": "2026-01-31"},
            headers=adult_a_headers,
        )
        assert resp.status_code == 200
        data = resp.json()

        assert len(data["data"]) == 3
        assert len(data["weekly"]) == 2

        # First week: 2 activities, 15 km, 4700 seconds
        week1 = data["weekly"][0]
        assert week1["week_start"] == "2026-01-05"
        assert week1["count"] == 2
        assert week1["total_distance_km"] == 15.0
        assert week1["total_duration_seconds"] == 4700.0

        # Second week: 1 activity, 30 km, 4500 seconds
        week2 = data["weekly"][1]
        assert week2["week_start"] == "2026-01-12"
        assert week2["count"] == 1
        assert week2["total_distance_km"] == 30.0
        assert week2["total_duration_seconds"] == 4500.0

    async def test_exercise_returns_metadata(self, client, adult_a_headers, initialized_db):
        """Exercise data points include metadata."""
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="run",
            value=5.0,
            unit="km",
            recorded_at="2026-01-10T07:00:00Z",
            metadata={"duration_seconds": 1500, "pace": "5:00", "calories": 400},
        )

        resp = await client.get(
            f"{BASE}/exercise",
            params={"start": "2026-01-01", "end": "2026-01-31"},
            headers=adult_a_headers,
        )
        data = resp.json()
        assert len(data["data"]) == 1
        point = data["data"][0]
        assert point["metadata"]["duration_seconds"] == 1500
        assert point["metadata"]["pace"] == "5:00"
        assert point["metadata"]["calories"] == 400


# ---------------------------------------------------------------------------
# Sleep endpoint
# ---------------------------------------------------------------------------


class TestSleep:
    """Tests for GET /sleep."""

    async def test_sleep_empty(self, client, adult_a_headers):
        """Sleep endpoint returns empty data when no records exist."""
        resp = await client.get(
            f"{BASE}/sleep",
            params={"start": "2025-01-01", "end": "2026-12-31"},
            headers=adult_a_headers,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["data"] == []
        assert data["average"] is None
        assert data["min"] is None
        assert data["max"] is None

    async def test_sleep_average_calculation(self, client, adult_a_headers, initialized_db):
        """Sleep endpoint correctly calculates average, min, max."""
        await _insert_health(initialized_db, source="apple_health", data_type="sleep", value=7.0, unit="hours", recorded_at="2026-01-10T08:00:00Z")
        await _insert_health(initialized_db, source="apple_health", data_type="sleep", value=8.0, unit="hours", recorded_at="2026-01-11T08:00:00Z")
        await _insert_health(initialized_db, source="apple_health", data_type="sleep", value=6.0, unit="hours", recorded_at="2026-01-12T08:00:00Z")
        await _insert_health(initialized_db, source="apple_health", data_type="sleep", value=9.0, unit="hours", recorded_at="2026-01-13T08:00:00Z")

        resp = await client.get(
            f"{BASE}/sleep",
            params={"start": "2026-01-01", "end": "2026-01-31"},
            headers=adult_a_headers,
        )
        assert resp.status_code == 200
        data = resp.json()

        assert len(data["data"]) == 4
        assert data["average"] == 7.5  # (7+8+6+9)/4
        assert data["min"] == 6.0
        assert data["max"] == 9.0


# ---------------------------------------------------------------------------
# Personal records endpoint
# ---------------------------------------------------------------------------


class TestPersonalRecords:
    """Tests for GET /records."""

    async def test_records_no_data(self, client, adult_a_headers):
        """Records endpoint returns nulls when there is no data."""
        resp = await client.get(f"{BASE}/records", headers=adult_a_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["fastest_5k"] is None
        assert data["longest_run"] is None
        assert data["heaviest_weight"] is None
        assert data["most_active_week"] is None

    async def test_records_with_data(self, client, adult_a_headers, initialized_db):
        """Records endpoint returns correct personal records."""
        # Runs
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="run",
            value=5.0,
            unit="km",
            recorded_at="2026-01-05T07:00:00Z",
            metadata={"duration_seconds": 1500, "pace": "5:00"},
        )
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="run",
            value=10.0,
            unit="km",
            recorded_at="2026-01-10T07:00:00Z",
            metadata={"duration_seconds": 3200, "pace": "5:20"},
        )
        await _insert_health(
            initialized_db,
            source="strava",
            data_type="run",
            value=21.1,
            unit="km",
            recorded_at="2026-01-15T07:00:00Z",
            metadata={"duration_seconds": 7200, "pace": "5:42"},
        )

        # Weight
        await _insert_health(initialized_db, source="withings", data_type="weight", value=82.5, unit="kg", recorded_at="2026-01-01T08:00:00Z")
        await _insert_health(initialized_db, source="withings", data_type="weight", value=85.0, unit="kg", recorded_at="2026-01-15T08:00:00Z")

        resp = await client.get(f"{BASE}/records", headers=adult_a_headers)
        assert resp.status_code == 200
        data = resp.json()

        # Fastest 5K — the 5 km run with 1500s is exactly 5k, so estimated_5k_time = 1500
        # The 10km run: (5/10)*3200 = 1600
        # The 21.1km run: (5/21.1)*7200 ~ 1706
        # So the 5km run at 1500s should be fastest
        assert data["fastest_5k"] is not None
        assert data["fastest_5k"]["value"] == 1500.0
        assert data["fastest_5k"]["unit"] == "seconds"
        assert data["fastest_5k"]["date"] == "2026-01-05T07:00:00Z"

        # Longest run — 21.1 km
        assert data["longest_run"] is not None
        assert data["longest_run"]["value"] == 21.1
        assert data["longest_run"]["unit"] == "km"

        # Heaviest weight — 85.0 kg
        assert data["heaviest_weight"] is not None
        assert data["heaviest_weight"]["value"] == 85.0
        assert data["heaviest_weight"]["unit"] == "kg"

        # Most active week — the week of 2026-01-05 has 2 activities
        # (Jan 5 & Jan 10 are both in the week starting Jan 5 Mon)
        # Actually Jan 10 is Saturday of that same week, so yes, 2 activities
        # The week of Jan 12 has the 21.1km run on Jan 15 (Thursday), so 1 activity
        assert data["most_active_week"] is not None
        assert data["most_active_week"]["value"] == 2
        assert data["most_active_week"]["unit"] == "activities"


# ---------------------------------------------------------------------------
# Auth required
# ---------------------------------------------------------------------------


class TestAuth:
    """All dashboard endpoints require authentication."""

    @pytest.mark.parametrize(
        "path",
        [
            f"{BASE}/summary",
            f"{BASE}/weight?start=2026-01-01&end=2026-01-31",
            f"{BASE}/exercise?start=2026-01-01&end=2026-01-31",
            f"{BASE}/sleep?start=2026-01-01&end=2026-01-31",
            f"{BASE}/records",
        ],
    )
    async def test_requires_auth(self, client, path):
        """Endpoints return 401 or 403 without auth headers."""
        resp = await client.get(path)
        assert resp.status_code in (401, 403)

"""Tests for the School Brain insight pipeline (service + router)."""

import json
from datetime import date, datetime, timedelta, timezone
from unittest.mock import AsyncMock

import aiosqlite
import pytest

from app.routers.insights import refresh_limiter
from app.services.school_brain import generate_insights

DOM_FAMILY_ID = "00000000-0000-0000-0000-000000000100"


@pytest.fixture(autouse=True)
def _isolate_school_brain(monkeypatch):
    """Reset the refresh limiter and keep the weather lookup off the network."""
    refresh_limiter.reset()
    monkeypatch.setattr(
        "app.services.school_brain.get_weather_summary", AsyncMock(return_value=None)
    )


def _mock_hermes(monkeypatch, response):
    mock = AsyncMock(return_value=response)
    monkeypatch.setattr("app.services.school_brain.ask_hermes", mock)
    return mock


def _findings_json(findings: list[dict]) -> str:
    return json.dumps({"findings": findings})


def _finding(**overrides) -> dict:
    finding = {
        "kind": "prep",
        "message": "Swimming tomorrow 8:30 but no kit-packing task",
        "detail": None,
        "target_date": (date.today() + timedelta(days=1)).isoformat(),
        "source_document_id": None,
    }
    finding.update(overrides)
    return finding


async def _insert_document(db_path: str, document_id: str, title: str, family_id: str = DOM_FAMILY_ID):
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO documents
               (id, title, original_filename, media_type, storage_key, file_size, sha256,
                source, category, status, extracted_text, family_id, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (document_id, title, "letter.pdf", "application/pdf", "key", 10, "s" * 64,
             "file", "school", "inbox", "Non-uniform day on Friday", family_id, now, now),
        )
        await db.commit()


async def _insert_insight(db_path: str, insight_id: str, **overrides):
    now = datetime.now(timezone.utc).isoformat()
    row = {
        "kind": "prep",
        "message": "Pack the swim kit",
        "target_date": (date.today() + timedelta(days=1)).isoformat(),
        "status": "active",
        "family_id": DOM_FAMILY_ID,
        "created_at": now,
    }
    row.update(overrides)
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO family_insights
               (id, kind, message, target_date, status, family_id,
                created_at, updated_at, created_by, client_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (insight_id, row["kind"], row["message"], row["target_date"], row["status"],
             row["family_id"], row["created_at"], row["created_at"], "school-brain", "school-brain"),
        )
        await db.commit()


async def _all_insight_rows(db_path: str) -> list[dict]:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT * FROM family_insights ORDER BY created_at")
        return [dict(row) for row in await cursor.fetchall()]


async def test_valid_findings_are_stored_and_listed(client, adult_a_headers, adult_a_user, initialized_db, monkeypatch):
    await _insert_document(initialized_db, "letter-1", "Sports Day letter")
    soon = (date.today() + timedelta(days=5)).isoformat()
    _mock_hermes(monkeypatch, _findings_json([
        _finding(),
        _finding(
            kind="missing_event",
            message="The Sports Day letter mentions non-uniform day but there is no calendar event",
            detail="Letter received this week; nothing on the calendar that day.",
            target_date=soon,
            source_document_id="letter-1",
        ),
    ]))

    refreshed = await client.post("/api/insights/refresh", headers=adult_a_headers)
    assert refreshed.status_code == 200
    assert len(refreshed.json()) == 2

    listed = await client.get("/api/insights/", headers=adult_a_headers)
    assert listed.status_code == 200
    items = listed.json()
    assert [item["kind"] for item in items] == ["prep", "missing_event"]
    assert items[1]["source_document_id"] == "letter-1"
    assert items[1]["target_date"] == soon
    assert items[1]["detail"].startswith("Letter received")

    rows = await _all_insight_rows(initialized_db)
    assert all(row["status"] == "active" for row in rows)
    assert all(row["created_by"] == "school-brain" for row in rows)
    assert all(row["client_id"] == "school-brain" for row in rows)


async def test_manual_insight_refresh_requires_current_ai_permission(
    client, adult_a_headers, monkeypatch
):
    revoked = await client.delete("/api/auth/ai-consent", headers=adult_a_headers)
    assert revoked.status_code == 200
    hermes = _mock_hermes(monkeypatch, _findings_json([]))
    logistics = AsyncMock()
    monkeypatch.setattr("app.routers.insights.detect_logistics", logistics)

    refreshed = await client.post("/api/insights/refresh", headers=adult_a_headers)

    assert refreshed.status_code == 428
    assert "OpenAI" in refreshed.json()["detail"]
    hermes.assert_not_awaited()
    logistics.assert_not_awaited()


async def test_junk_and_unavailable_responses_store_nothing(initialized_db, adult_a_user, monkeypatch):
    _mock_hermes(monkeypatch, "sorry, I could not find any JSON to give you")
    assert await generate_insights(DOM_FAMILY_ID) == []

    _mock_hermes(monkeypatch, None)
    assert await generate_insights(DOM_FAMILY_ID) == []

    _mock_hermes(monkeypatch, 'Here you go: {"findings": []} — all covered!')
    assert await generate_insights(DOM_FAMILY_ID) == []

    assert await _all_insight_rows(initialized_db) == []


async def test_validation_drops_bad_findings_and_nulls_unknown_documents(initialized_db, adult_a_user, monkeypatch):
    _mock_hermes(monkeypatch, _findings_json([
        _finding(target_date=(date.today() + timedelta(days=40)).isoformat()),
        _finding(target_date=(date.today() - timedelta(days=1)).isoformat()),
        _finding(target_date="next Friday"),
        _finding(kind="reminder"),
        _finding(message="   "),
        "not even a dict",
        _finding(message="Wellies needed", kind="weather", source_document_id="no-such-document"),
    ]))

    inserted = await generate_insights(DOM_FAMILY_ID)
    assert len(inserted) == 1
    assert inserted[0]["message"] == "Wellies needed"
    assert inserted[0]["source_document_id"] is None

    rows = await _all_insight_rows(initialized_db)
    assert len(rows) == 1
    assert rows[0]["source_document_id"] is None


async def test_findings_are_capped_at_five(initialized_db, adult_a_user, monkeypatch):
    _mock_hermes(monkeypatch, _findings_json([
        _finding(message=f"Gap number {index}") for index in range(8)
    ]))
    inserted = await generate_insights(DOM_FAMILY_ID)
    assert len(inserted) == 5


async def test_second_run_deduplicates_active_findings(initialized_db, adult_a_user, monkeypatch):
    _mock_hermes(monkeypatch, _findings_json([_finding()]))
    first = await generate_insights(DOM_FAMILY_ID)
    assert len(first) == 1

    # Same finding again, with different letter casing, must not duplicate.
    _mock_hermes(monkeypatch, _findings_json([
        _finding(message=_finding()["message"].upper())
    ]))
    second = await generate_insights(DOM_FAMILY_ID)
    assert second == []
    assert len(await _all_insight_rows(initialized_db)) == 1


async def test_dismiss_flow_and_family_isolation(
    client, adult_a_headers, other_family_headers, adult_a_user, other_family_user, initialized_db
):
    await _insert_insight(initialized_db, "insight-1")

    other_list = await client.get("/api/insights/", headers=other_family_headers)
    assert other_list.status_code == 200
    assert other_list.json() == []

    other_dismiss = await client.post("/api/insights/insight-1/dismiss", headers=other_family_headers)
    assert other_dismiss.status_code == 404

    unknown = await client.post("/api/insights/no-such-insight/dismiss", headers=adult_a_headers)
    assert unknown.status_code == 404

    dismissed = await client.post("/api/insights/insight-1/dismiss", headers=adult_a_headers)
    assert dismissed.status_code == 200
    assert dismissed.json() == {"status": "dismissed"}

    again = await client.post("/api/insights/insight-1/dismiss", headers=adult_a_headers)
    assert again.status_code == 409

    listed = await client.get("/api/insights/", headers=adult_a_headers)
    assert listed.json() == []


async def test_prep_insight_adds_one_tap_task_exactly_once(
    client, adult_a_headers, adult_a_user, initialized_db
):
    await _insert_insight(
        initialized_db,
        "swimming-insight",
        message="Swimming is today but there is no preparation task for the kit",
        target_date=date.today().isoformat(),
    )

    listed = await client.get("/api/insights/", headers=adult_a_headers)
    assert listed.json()[0]["suggested_task_title"] == "Pack swim kit and towels"

    first = await client.post(
        "/api/insights/swimming-insight/add-task", headers=adult_a_headers
    )
    assert first.status_code == 200, first.text
    assert first.json()["title"] == "Pack swim kit and towels"

    replay = await client.post(
        "/api/insights/swimming-insight/add-task", headers=adult_a_headers
    )
    assert replay.status_code == 200
    assert replay.json()["task_id"] == first.json()["task_id"]

    tasks = await client.get("/api/tasks/", headers=adult_a_headers)
    matching = [item for item in tasks.json() if item["client_id"] == "insight-prep:swimming-insight"]
    assert len(matching) == 1
    assert matching[0]["title"] == "Pack swim kit and towels"
    assert (await client.get("/api/insights/", headers=adult_a_headers)).json() == []


async def test_non_prep_insight_cannot_create_suggested_task(
    client, adult_a_headers, adult_a_user, initialized_db
):
    await _insert_insight(initialized_db, "weather-insight", kind="weather")
    response = await client.post(
        "/api/insights/weather-insight/add-task", headers=adult_a_headers
    )
    assert response.status_code == 422


async def test_generate_auto_expires_past_dated_insights(initialized_db, adult_a_user, monkeypatch):
    yesterday = (date.today() - timedelta(days=1)).isoformat()
    await _insert_insight(initialized_db, "stale-insight", target_date=yesterday)
    _mock_hermes(monkeypatch, _findings_json([]))

    assert await generate_insights(DOM_FAMILY_ID) == []

    rows = await _all_insight_rows(initialized_db)
    assert rows[0]["status"] == "dismissed"


async def test_list_hides_past_dated_insights(client, adult_a_headers, adult_a_user, initialized_db):
    yesterday = (date.today() - timedelta(days=1)).isoformat()
    await _insert_insight(initialized_db, "stale-insight", target_date=yesterday)
    await _insert_insight(initialized_db, "fresh-insight", message="Still relevant")

    listed = await client.get("/api/insights/", headers=adult_a_headers)
    assert [item["id"] for item in listed.json()] == ["fresh-insight"]


async def test_refresh_is_rate_limited_per_user(client, adult_a_headers, adult_a_user, monkeypatch):
    monkeypatch.setattr(refresh_limiter, "max_attempts", 1)
    _mock_hermes(monkeypatch, _findings_json([]))

    first = await client.post("/api/insights/refresh", headers=adult_a_headers)
    assert first.status_code == 200

    second = await client.post("/api/insights/refresh", headers=adult_a_headers)
    assert second.status_code == 429


async def test_insights_require_auth(client):
    listed = await client.get("/api/insights/")
    assert listed.status_code in (401, 403)
    refreshed = await client.post("/api/insights/refresh")
    assert refreshed.status_code in (401, 403)

import json
from unittest.mock import AsyncMock

import aiosqlite

from app.config import settings
from app.services import swimming_scraper
from app.services.swimming_scraper import (
    _configured_child_ids,
    _extract_lesson_dates,
    refresh_swimming_lessons,
)


def test_extract_lesson_dates_uses_embedded_json_and_keeps_only_sundays():
    html = """
    <script>
      var w_dates = [
        "Sun Jul 12 2026",
        "Mon Jul 13 2026",
        "Sun Jul 12 2026",
        "Sun Jul 19 2026",
        "not a date"
      ];
    </script>
    """

    assert _extract_lesson_dates(html) == ["2026-07-12", "2026-07-19"]


def test_extract_lesson_dates_never_evaluates_javascript():
    assert _extract_lesson_dates("var w_dates = process.env;") == []
    assert _extract_lesson_dates('var w_dates = ["Sun Jul 12 2026"]; alert(1);') == [
        "2026-07-12"
    ]


def test_configured_child_ids_filters_invalid_values_and_duplicates(monkeypatch):
    child_id = "00000000-0000-0000-0000-000000000011"
    monkeypatch.setattr(
        settings,
        "swimming_child_ids",
        f"invalid,{child_id.upper()},{child_id}",
    )

    assert _configured_child_ids() == [child_id]


async def test_refresh_validates_family_and_replaces_events(
    initialized_db,
    child1,
    monkeypatch,
):
    monkeypatch.setattr(settings, "swimming_child_ids", child1["id"])
    fetch = AsyncMock(return_value=["2099-07-12", "2099-07-19"])
    monkeypatch.setattr(swimming_scraper, "_fetch_lesson_dates", fetch)

    result = await refresh_swimming_lessons(
        family_id="00000000-0000-0000-0000-000000000100"
    )

    assert result == {
        "status": "ok",
        "total_sunday_dates": 2,
        "events_created": 2,
    }
    fetch.assert_awaited_once()
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT family_id, family_member_ids FROM calendar_events "
                "WHERE created_by = 'swimming-scraper' AND deleted_at IS NULL"
            )
        ).fetchall()
    assert len(rows) == 2
    assert {row["family_id"] for row in rows} == {
        "00000000-0000-0000-0000-000000000100"
    }
    assert all(json.loads(row["family_member_ids"]) == [child1["id"]] for row in rows)


async def test_refresh_does_not_fetch_for_unconfigured_or_foreign_children(
    child1,
    second_family,
    monkeypatch,
):
    fetch = AsyncMock(return_value=["2099-07-12"])
    monkeypatch.setattr(swimming_scraper, "_fetch_lesson_dates", fetch)

    monkeypatch.setattr(settings, "swimming_child_ids", "")
    assert await refresh_swimming_lessons(family_id=second_family["id"]) == {
        "status": "not_configured",
        "events_created": 0,
    }

    monkeypatch.setattr(settings, "swimming_child_ids", child1["id"])
    assert await refresh_swimming_lessons(family_id=second_family["id"]) == {
        "status": "not_configured",
        "events_created": 0,
    }
    fetch.assert_not_awaited()

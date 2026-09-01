import json
from datetime import datetime, timedelta

import aiosqlite

from app.services.second_brain import detect_logistics
from zoneinfo import ZoneInfo

LOCAL = ZoneInfo("Europe/London")


async def _event(db, family_id, created_by, title, start, *, end=None, location=None, assigned_to=None, members=None):
    await db.execute(
        """INSERT INTO calendar_events
           (id, title, start_time, end_time, all_day, location, assigned_to, family_member_ids,
            family_id, created_by)
           VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?)""",
        (
            f"ev-{title}-{start}",
            title,
            start,
            end,
            location,
            assigned_to,
            json.dumps(members) if members else None,
            family_id,
            created_by,
        ),
    )


def _at(days_ahead: int, hour: int, minute: int = 0) -> str:
    day = (datetime.now(LOCAL) + timedelta(days=days_ahead)).date()
    return datetime.combine(day, datetime.min.time(), tzinfo=LOCAL).replace(hour=hour, minute=minute).isoformat()


async def test_detects_overlapping_clash_at_different_places(
    initialized_db, adult_a_user, child1, child2
):
    async with aiosqlite.connect(initialized_db) as db:
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Swimming",
                     _at(2, 9, 0), end=_at(2, 10, 0), location="Example Town", assigned_to=child1["id"])
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Doctor",
                     _at(2, 9, 15), end=_at(2, 10, 0), location="Example School", assigned_to=child2["id"])
        await db.commit()

    found = await detect_logistics(adult_a_user["family_id"])
    assert len(found) == 1
    assert found[0]["kind"] == "conflict"
    assert "Clash" in found[0]["message"]

    async with aiosqlite.connect(initialized_db) as db:
        count = (await (await db.execute(
            "SELECT COUNT(*) FROM family_insights WHERE created_by = 'second-brain' AND status = 'active'"
        )).fetchone())[0]
    assert count == 1


async def test_no_clash_when_same_place_or_same_person(initialized_db, adult_a_user, child1):
    async with aiosqlite.connect(initialized_db) as db:
        # Same location -> not a clash.
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Assembly",
                     _at(3, 9, 0), end=_at(3, 10, 0), location="School", assigned_to=child1["id"])
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Class photo",
                     _at(3, 9, 30), end=_at(3, 10, 0), location="School", assigned_to=child1["id"])
        await db.commit()
    assert await detect_logistics(adult_a_user["family_id"]) == []


async def test_detects_tight_turnaround(initialized_db, adult_a_user, child1):
    async with aiosqlite.connect(initialized_db) as db:
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Football",
                     _at(4, 15, 0), end=_at(4, 16, 0), location="Park", assigned_to=child1["id"])
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Piano",
                     _at(4, 16, 10), end=_at(4, 17, 0), location="Town", assigned_to=child1["id"])
        await db.commit()
    found = await detect_logistics(adult_a_user["family_id"])
    assert any("Tight turnaround" in f["message"] for f in found)


async def test_logistics_is_deduped_on_second_run(initialized_db, adult_a_user, child1, child2):
    async with aiosqlite.connect(initialized_db) as db:
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Swimming",
                     _at(2, 9, 0), end=_at(2, 10, 0), location="Example Town", assigned_to=child1["id"])
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Doctor",
                     _at(2, 9, 15), end=_at(2, 10, 0), location="Example School", assigned_to=child2["id"])
        await db.commit()
    first = await detect_logistics(adult_a_user["family_id"])
    second = await detect_logistics(adult_a_user["family_id"])
    assert len(first) == 1
    assert second == []


async def test_all_day_events_do_not_clash(initialized_db, adult_a_user, child1, child2):
    async with aiosqlite.connect(initialized_db) as db:
        day = (datetime.now(LOCAL) + timedelta(days=2)).date().isoformat()
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Term starts", day, assigned_to=child1["id"])
        await _event(db, adult_a_user["family_id"], adult_a_user["id"], "Inset day", day, assigned_to=child2["id"])
        await db.execute("UPDATE calendar_events SET all_day = 1 WHERE start_time = ?", (day,))
        await db.commit()
    assert await detect_logistics(adult_a_user["family_id"]) == []

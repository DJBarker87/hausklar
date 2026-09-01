"""Tests for the bin collection scraper service (app.services.bin_scraper)."""

import uuid

import aiosqlite
import pytest

from app.database import init_db
from app.services.bin_scraper import (
    _actionable_from,
    _classify_bin_type,
    _parse_collection_date,
    _replace_bin_tasks,
    parse_collections,
    refresh_bin_tasks,
)


# ---------------------------------------------------------------------------
# Sample HTML (mimics the Local authority bin collection page structure)
# ---------------------------------------------------------------------------

SAMPLE_HTML = """
<html>
<body>
<h2>Your bin collection dates</h2>
<p>Your usual collection day is Thursday</p>
<table>
<tr><th>Service</th><th>Date</th></tr>
<tr><td>Recycling Collection Service</td><td>12th February 2026</td></tr>
<tr><td>Refuse Collection Service</td><td>19th February 2026</td></tr>
<tr><td>Recycling Collection Service</td><td>26th February 2026</td></tr>
<tr><td>Garden Waste Collection Service</td><td>5th March 2026</td></tr>
</table>
</body>
</html>
"""

FUTURE_HTML = """
<table>
<tr><td>Recycling Collection Service</td><td>12th February 2099</td></tr>
<tr><td>Refuse Collection Service</td><td>19th February 2099</td></tr>
<tr><td>Recycling Collection Service</td><td>26th February 2099</td></tr>
<tr><td>Garden Waste Collection Service</td><td>5th March 2099</td></tr>
</table>
"""


# ---------------------------------------------------------------------------
# Date parsing
# ---------------------------------------------------------------------------


async def test_parse_date_th_suffix():
    assert _parse_collection_date("12th February 2026") == "2026-02-12"


async def test_parse_date_st_suffix():
    assert _parse_collection_date("1st March 2026") == "2026-03-01"


async def test_parse_date_nd_suffix():
    assert _parse_collection_date("2nd January 2026") == "2026-01-02"


async def test_parse_date_rd_suffix():
    assert _parse_collection_date("3rd April 2026") == "2026-04-03"


async def test_parse_date_no_suffix():
    """Handles dates that happen to have no ordinal suffix."""
    assert _parse_collection_date("15 June 2026") == "2026-06-15"


async def test_parse_date_rejects_impossible_calendar_date():
    with pytest.raises(ValueError):
        _parse_collection_date("31st February 2026")


@pytest.mark.parametrize("value", ["1st January 1999", "1st January 2101"])
async def test_parse_date_rejects_implausible_year(value):
    with pytest.raises(ValueError):
        _parse_collection_date(value)


async def test_actionable_from_uses_london_summer_time():
    assert _actionable_from("2026-07-16") == "2026-07-15T17:00:00Z"


async def test_actionable_from_uses_london_winter_time():
    assert _actionable_from("2026-02-12") == "2026-02-11T18:00:00Z"


# ---------------------------------------------------------------------------
# Bin type classification
# ---------------------------------------------------------------------------


async def test_classify_refuse():
    assert _classify_bin_type("Refuse Collection Service") == "black"


async def test_classify_recycling():
    assert _classify_bin_type("Recycling Collection Service") == "blue"


async def test_classify_garden():
    assert _classify_bin_type("Garden Waste Collection Service") == "green"


async def test_classify_unknown():
    assert _classify_bin_type("Unknown Service") is None


# ---------------------------------------------------------------------------
# HTML parsing
# ---------------------------------------------------------------------------


async def test_parse_collections_basic():
    """parse_collections extracts all bin types and dates from sample HTML."""
    results = parse_collections(SAMPLE_HTML)
    assert len(results) == 4

    assert results[0] == {"bin_type": "blue", "collection_date": "2026-02-12"}
    assert results[1] == {"bin_type": "black", "collection_date": "2026-02-19"}
    assert results[2] == {"bin_type": "blue", "collection_date": "2026-02-26"}
    assert results[3] == {"bin_type": "green", "collection_date": "2026-03-05"}


async def test_parse_collections_empty():
    """parse_collections returns empty list for HTML without a matching table."""
    assert parse_collections("<html><body>No bins here</body></html>") == []
    assert parse_collections("") == []


async def test_parse_collections_skips_header_row():
    """parse_collections skips the header row (Service/Date th cells)."""
    html = """
    <table>
    <tr><th>Service</th><th>Date</th></tr>
    <tr><td>Refuse Collection Service</td><td>1st January 2026</td></tr>
    </table>
    """
    results = parse_collections(html)
    assert len(results) == 1
    assert results[0]["bin_type"] == "black"


async def test_parse_collections_normalises_entities_and_nested_markup():
    html = """
    <table><tr><td><strong>Recycling&nbsp;Collection</strong> Service</td>
    <td>19th&nbsp;February&nbsp;2026</td></tr></table>
    """

    assert parse_collections(html) == [{"bin_type": "blue", "collection_date": "2026-02-19"}]


# ---------------------------------------------------------------------------
# Database: refresh_bin_tasks
# ---------------------------------------------------------------------------


async def test_replace_bin_tasks_rejects_empty_collection_without_mutating(db_path):
    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        result = await _replace_bin_tasks(db, [], family_id=None)
        count = (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0]

    assert result == {"status": "parse_failed", "tasks": 0}
    assert count == 0


async def test_refresh_bin_tasks_creates_tasks(db_path, monkeypatch):
    """refresh_bin_tasks creates one task per collection day."""
    await init_db(db_path)

    # Mock fetch_bin_page to return sample HTML
    async def mock_fetch():
        return SAMPLE_HTML

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        result = await refresh_bin_tasks(db)

    assert result["status"] == "ok"
    # 4 different dates in sample → 4 tasks
    assert result["tasks"] == 4
    assert result["created"] == 4
    assert result["first_date"] == "2026-02-12"
    assert result["last_date"] == "2026-03-05"

    # Verify tasks in DB
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM tasks WHERE category = 'bins' AND deleted_at IS NULL ORDER BY due_date"
        )
        rows = await cursor.fetchall()

    assert len(rows) == 4
    # All tasks titled "Bins", description holds colour keys
    for row in rows:
        assert row["title"] == "Bins"
        assert row["created_by"] == "bin-scraper"
        assert row["priority"] == 2
        assert row["category"] == "bins"

    assert rows[0]["description"] == "blue"
    assert rows[0]["due_date"] == "2026-02-12"
    assert rows[1]["description"] == "black"
    assert rows[3]["description"] == "green"


async def test_refresh_bin_tasks_heals_managed_row_with_changed_category(
    db_path,
    monkeypatch,
):
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO tasks
               (id,title,description,due_date,category,priority,created_by)
               VALUES ('legacy-managed','Old bins','blue','2026-02-12',
                       'household',1,'bin-scraper')"""
        )
        await db.commit()

    async def mock_fetch():
        return SAMPLE_HTML

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        result = await refresh_bin_tasks(db)
        rows = await (
            await db.execute(
                """SELECT id,title,category,priority FROM tasks
                   WHERE due_date='2026-02-12' AND deleted_at IS NULL"""
            )
        ).fetchall()

    assert result["updated"] == 1
    assert result["created"] == 3
    assert [row["id"] for row in rows] == ["legacy-managed"]
    assert rows[0]["title"] == "Bins"
    assert rows[0]["category"] == "bins"
    assert rows[0]["priority"] == 2


async def test_refresh_bin_tasks_is_idempotent(db_path, monkeypatch):
    """An unchanged rescan retains task IDs instead of churning soft-deletes."""
    await init_db(db_path)

    async def mock_fetch():
        return SAMPLE_HTML

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)

    # First run — creates tasks (4 unique dates → 4 tasks)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await refresh_bin_tasks(db)

    # Capture old task IDs
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT id FROM tasks WHERE category = 'bins' AND deleted_at IS NULL"
        )
        old_ids = [r["id"] for r in await cursor.fetchall()]
    assert len(old_ids) == 4

    # Second run — should reuse the same active records.
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        result = await refresh_bin_tasks(db)

    assert result["status"] == "ok"
    assert result["tasks"] == 4

    assert result["created"] == 0
    assert result["updated"] == 0
    assert result["unchanged"] == 4
    assert result["retired"] == 0

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT id FROM tasks WHERE category = 'bins' AND deleted_at IS NULL"
        )
        active_ids = [row["id"] for row in await cursor.fetchall()]
        deleted_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM tasks WHERE category = 'bins' AND deleted_at IS NOT NULL"
                )
            ).fetchone()
        )[0]
    assert sorted(active_ids) == sorted(old_ids)
    assert deleted_count == 0


async def test_refresh_bin_tasks_preserves_user_responsibility_and_retires_old_assignments(
    initialized_db,
    adult_a_user,
    adult_b_user,
    monkeypatch,
):
    async def mock_fetch():
        return SAMPLE_HTML

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """INSERT INTO tasks
               (id,title,due_date,completed_at,category,family_id,created_by,assigned_to)
               VALUES (?,'Bins',?,?,'bins',?,'bin-scraper',?)""",
            [
                (
                    "older-completed-bin",
                    "2026-01-29",
                    "2026-01-29T12:00:00+00:00",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
                (
                    "old-bin",
                    "2026-02-05",
                    None,
                    adult_a_user["family_id"],
                    adult_b_user["id"],
                ),
            ],
        )
        await db.executemany(
            """INSERT INTO task_assignments
               (id,task_id,assignee_id,assignee_type,family_id,created_by,
                created_at,updated_at)
               VALUES (?,?,?,'user',?,?,?,?)""",
            [
                (
                    "older-dom-assignment",
                    "older-completed-bin",
                    adult_a_user["id"],
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                    "2026-01-20T12:00:00+00:00",
                    "2026-01-20T12:00:00+00:00",
                ),
                (
                    "old-bin-assignment",
                    "old-bin",
                    adult_b_user["id"],
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                    "2026-02-01T12:00:00+00:00",
                    "2026-02-01T12:00:00+00:00",
                ),
            ],
        )
        await db.commit()
        db.row_factory = aiosqlite.Row
        result = await refresh_bin_tasks(db, family_id=adult_a_user["family_id"])

    assert result["status"] == "ok"
    assert result["tasks"] == 4
    assert result["created"] == 4
    assert result["retired"] == 1
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        old_task = await (
            await db.execute("SELECT deleted_at FROM tasks WHERE id='old-bin'")
        ).fetchone()
        old_assignment = await (
            await db.execute(
                "SELECT deleted_at FROM task_assignments WHERE id='old-bin-assignment'"
            )
        ).fetchone()
        completed_task = await (
            await db.execute("SELECT deleted_at FROM tasks WHERE id='older-completed-bin'")
        ).fetchone()
        rows = await (
            await db.execute(
                """SELECT t.id,t.assigned_to,ta.assignee_id,ta.assignee_type
                   FROM tasks t JOIN task_assignments ta ON ta.task_id=t.id
                   WHERE t.category='bins' AND t.created_by='bin-scraper'
                     AND t.deleted_at IS NULL AND ta.deleted_at IS NULL
                     AND t.completed_at IS NULL
                   ORDER BY t.due_date"""
            )
        ).fetchall()
    assert old_task["deleted_at"] is not None
    assert old_assignment["deleted_at"] is not None
    assert completed_task["deleted_at"] is None
    assert len(rows) == 4
    assert all(row["assigned_to"] == adult_b_user["id"] for row in rows)
    assert all(row["assignee_id"] == adult_b_user["id"] for row in rows)
    assert all(row["assignee_type"] == "user" for row in rows)


async def test_refresh_bin_tasks_does_not_resurrect_completed_collection(
    db_path,
    monkeypatch,
):
    await init_db(db_path)

    async def mock_fetch():
        return SAMPLE_HTML

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await refresh_bin_tasks(db)
        row = await (
            await db.execute(
                "SELECT id FROM tasks WHERE due_date='2026-02-12' AND deleted_at IS NULL"
            )
        ).fetchone()
        task_id = row["id"]
        await db.execute(
            "UPDATE tasks SET completed_at='2026-02-11T20:00:00Z' WHERE id=?",
            (task_id,),
        )
        await db.commit()
        result = await refresh_bin_tasks(db)
        rows = await (
            await db.execute(
                "SELECT id,completed_at FROM tasks WHERE due_date='2026-02-12' AND deleted_at IS NULL"
            )
        ).fetchall()

    assert result["created"] == 0
    assert len(rows) == 1
    assert rows[0]["id"] == task_id
    assert rows[0]["completed_at"] == "2026-02-11T20:00:00Z"


async def test_refresh_bin_tasks_keeps_later_dates_after_first_only_response(
    db_path,
    monkeypatch,
):
    await init_db(db_path)
    responses = iter(
        [
            FUTURE_HTML,
            """<table><tr><td>Recycling Collection Service</td>
                   <td>12th February 2099</td></tr></table>""",
        ]
    )

    async def mock_fetch():
        return next(responses)

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await refresh_bin_tasks(db)
        result = await refresh_bin_tasks(db)
        rows = await (
            await db.execute(
                """SELECT due_date FROM tasks
                   WHERE category='bins' AND deleted_at IS NULL ORDER BY due_date"""
            )
        ).fetchall()

    assert result["tasks"] == 1
    assert result["retired"] == 0
    assert [row["due_date"] for row in rows] == [
        "2099-02-12",
        "2099-02-19",
        "2099-02-26",
        "2099-03-05",
    ]


async def test_refresh_bin_tasks_keeps_earlier_dates_after_last_only_response(
    db_path,
    monkeypatch,
):
    await init_db(db_path)
    responses = iter(
        [
            FUTURE_HTML,
            """<table><tr><td>Garden Waste Collection Service</td>
                   <td>5th March 2099</td></tr></table>""",
        ]
    )

    async def mock_fetch():
        return next(responses)

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await refresh_bin_tasks(db)
        result = await refresh_bin_tasks(db)
        rows = await (
            await db.execute(
                """SELECT due_date FROM tasks
                   WHERE category='bins' AND deleted_at IS NULL ORDER BY due_date"""
            )
        ).fetchall()

    assert result["tasks"] == 1
    assert result["retired"] == 0
    assert [row["due_date"] for row in rows] == [
        "2099-02-12",
        "2099-02-19",
        "2099-02-26",
        "2099-03-05",
    ]


async def test_refresh_bin_tasks_keeps_middle_dates_after_first_and_last_only_response(
    db_path,
    monkeypatch,
):
    await init_db(db_path)
    responses = iter(
        [
            FUTURE_HTML,
            """<table>
                <tr><td>Recycling Collection Service</td><td>12th February 2099</td></tr>
                <tr><td>Garden Waste Collection Service</td><td>5th March 2099</td></tr>
                </table>""",
        ]
    )

    async def mock_fetch():
        return next(responses)

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await refresh_bin_tasks(db)
        result = await refresh_bin_tasks(db)
        rows = await (
            await db.execute(
                """SELECT due_date FROM tasks
                   WHERE category='bins' AND deleted_at IS NULL ORDER BY due_date"""
            )
        ).fetchall()

    assert result["retired"] == 0
    assert [row["due_date"] for row in rows] == [
        "2099-02-12",
        "2099-02-19",
        "2099-02-26",
        "2099-03-05",
    ]


async def test_refresh_bin_tasks_preserves_manual_tasks(db_path, monkeypatch):
    """refresh_bin_tasks does not soft-delete manually created bin tasks."""
    await init_db(db_path)

    # Insert a manually created bin task (created_by is a user ID, not 'bin-scraper')
    manual_id = str(uuid.uuid4())
    now = "2026-02-09T12:00:00.000Z"
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO tasks (id, title, due_date, category, priority,
               created_at, updated_at, created_by)
               VALUES (?, ?, ?, 'bins', 2, ?, ?, ?)""",
            (
                manual_id,
                "Manual bin task",
                "2026-02-20",
                now,
                now,
                "00000000-0000-0000-0000-000000000001",
            ),
        )
        await db.commit()

    async def mock_fetch():
        return SAMPLE_HTML

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await refresh_bin_tasks(db)

    # Verify manual task is still active
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT * FROM tasks WHERE id = ?", (manual_id,))
        row = await cursor.fetchone()
    assert row is not None
    assert row["deleted_at"] is None


async def test_refresh_bin_tasks_groups_same_day(db_path, monkeypatch):
    """Bins on the same day produce a single task with comma-separated colour keys."""
    await init_db(db_path)

    same_day_html = """
    <table>
    <tr><th>Service</th><th>Date</th></tr>
    <tr><td>Recycling Collection Service</td><td>19th February 2026</td></tr>
    <tr><td>Refuse Collection Service</td><td>19th February 2026</td></tr>
    <tr><td>Recycling Collection Service</td><td>5th March 2026</td></tr>
    </table>
    """

    async def mock_fetch():
        return same_day_html

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        result = await refresh_bin_tasks(db)

    assert result["status"] == "ok"
    # 2 unique dates → 2 tasks
    assert result["tasks"] == 2

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM tasks WHERE category = 'bins' AND deleted_at IS NULL ORDER BY due_date"
        )
        rows = await cursor.fetchall()

    assert len(rows) == 2
    # First task: 19 Feb has both blue and black
    assert rows[0]["due_date"] == "2026-02-19"
    assert rows[0]["title"] == "Bins"
    assert rows[0]["description"] == "blue,black"
    # Second task: 5 Mar has only blue
    assert rows[1]["due_date"] == "2026-03-05"
    assert rows[1]["description"] == "blue"


async def test_refresh_bin_tasks_preserves_same_day_type_after_partial_parse(
    db_path,
    monkeypatch,
):
    await init_db(db_path)
    responses = iter(
        [
            """<table>
                <tr><td>Recycling Collection Service</td><td>19th February 2099</td></tr>
                <tr><td>Refuse Collection Service</td><td>19th February 2099</td></tr>
                </table>""",
            """<table>
                <tr><td>Recycling Collection Service</td><td>19th February 2099</td></tr>
                <tr><td>Unrecognised Collection Service</td><td>19th February 2099</td></tr>
                </table>""",
        ]
    )

    async def mock_fetch():
        return next(responses)

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await refresh_bin_tasks(db)
        result = await refresh_bin_tasks(db)
        row = await (
            await db.execute(
                """SELECT description FROM tasks
                   WHERE due_date='2099-02-19' AND deleted_at IS NULL"""
            )
        ).fetchone()

    assert result["updated"] == 0
    assert result["unchanged"] == 1
    assert row["description"] == "blue,black"


async def test_refresh_bin_tasks_fetch_failed(db_path, monkeypatch):
    """refresh_bin_tasks returns fetch_failed when page fetch fails."""
    await init_db(db_path)

    async def mock_fetch():
        return ""

    monkeypatch.setattr("app.services.bin_scraper.fetch_bin_page", mock_fetch)

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        result = await refresh_bin_tasks(db)

    assert result["status"] == "fetch_failed"
    assert result["tasks"] == 0

"""Tests for sync conflict resolution via the /api/sync endpoints."""

import json
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite

from conftest import EXAMPLE_FAMILY_ID, SECOND_FAMILY_ID


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _iso_offset(*, minutes: int = 0) -> str:
    """Return an ISO-8601 UTC timestamp offset from *now* by the given minutes."""
    return (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()


def _make_push_body(items: list[dict]) -> dict:
    return {"items": items}


def _task_create_item(
    record_id: str | None = None,
    title: str = "Test task",
    client_id: str | None = None,
    client_timestamp: str | None = None,
    **extra_payload,
) -> dict:
    """Return a single SyncPushItem dict for creating a task."""
    return {
        "operation": "create",
        "table_name": "tasks",
        "record_id": record_id or str(uuid.uuid4()),
        "client_id": client_id or str(uuid.uuid4()),
        "client_timestamp": client_timestamp or _now_iso(),
        "payload": {"title": title, **extra_payload},
    }


def _task_update_item(
    record_id: str,
    client_timestamp: str | None = None,
    **payload,
) -> dict:
    """Return a single SyncPushItem dict for updating a task."""
    return {
        "operation": "update",
        "table_name": "tasks",
        "record_id": record_id,
        "client_id": str(uuid.uuid4()),
        "client_timestamp": client_timestamp or _now_iso(),
        "payload": payload,
    }


def _task_delete_item(
    record_id: str,
    client_timestamp: str | None = None,
) -> dict:
    """Return a single SyncPushItem dict for deleting a task."""
    return {
        "operation": "delete",
        "table_name": "tasks",
        "record_id": record_id,
        "client_id": str(uuid.uuid4()),
        "client_timestamp": client_timestamp or _now_iso(),
        "payload": None,
    }


def _calendar_create_item(
    record_id: str | None = None,
    client_timestamp: str | None = None,
    **payload,
) -> dict:
    return {
        "operation": "create",
        "table_name": "calendar_events",
        "record_id": record_id or str(uuid.uuid4()),
        "client_id": str(uuid.uuid4()),
        "client_timestamp": client_timestamp or _now_iso(),
        "payload": {
            "title": "Family event",
            "start_time": _now_iso(),
            **payload,
        },
    }


def _calendar_update_item(
    record_id: str,
    client_timestamp: str | None = None,
    **payload,
) -> dict:
    return {
        "operation": "update",
        "table_name": "calendar_events",
        "record_id": record_id,
        "client_id": str(uuid.uuid4()),
        "client_timestamp": client_timestamp or _now_iso(),
        "payload": payload,
    }


def _medicine_type_create_item(child_id: str, **payload) -> dict:
    return {
        "operation": "create",
        "table_name": "medicine_types",
        "record_id": str(uuid.uuid4()),
        "client_id": str(uuid.uuid4()),
        "client_timestamp": _now_iso(),
        "payload": {
            "name": "Calpol",
            "min_hours_between_doses": 4,
            "max_doses_24h": 4,
            "child_id": child_id,
            **payload,
        },
    }


def _medicine_dose_create_item(child_id: str, **payload) -> dict:
    return {
        "operation": "create",
        "table_name": "medicine_doses",
        "record_id": str(uuid.uuid4()),
        "client_id": str(uuid.uuid4()),
        "client_timestamp": _now_iso(),
        "payload": {
            "child_id": child_id,
            "given_at": _now_iso(),
            "medicine_name": "Other medicine",
            **payload,
        },
    }


# ---------------------------------------------------------------------------
# Helper to insert a task directly into the database
# ---------------------------------------------------------------------------


async def _insert_task(
    db_path: str,
    task_id: str,
    title: str = "Seed task",
    created_by: str | None = None,
    updated_at: str | None = None,
    category: str = "other",
) -> dict:
    """Insert a task row directly and return its column values as a dict."""
    now = updated_at or _now_iso()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO tasks
                (id, title, category, created_by, family_id, created_at, updated_at,
                 client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                task_id,
                title,
                category,
                created_by,
                EXAMPLE_FAMILY_ID,
                now,
                now,
                str(uuid.uuid4()),
                now,
            ),
        )
        await db.commit()
    return {"id": task_id, "title": title, "created_by": created_by, "updated_at": now}


async def _insert_document(db_path: str, document_id: str, family_id: str) -> None:
    now = _now_iso()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO documents
                (id, title, original_filename, media_type, storage_key, file_size,
                 sha256, source, category, status, page_count, processor,
                 family_id, created_at, updated_at)
            VALUES (?, 'Offline attachment', 'attachment.pdf', 'application/pdf',
                    ?, 12, ?, 'file', 'other', 'filed', 1, 'device', ?, ?, ?)
            """,
            (
                document_id,
                f"{family_id}/{document_id}/attachment.pdf",
                "0" * 64,
                family_id,
                now,
                now,
            ),
        )
        await db.commit()


# ===========================================================================
# Tests
# ===========================================================================


async def test_sync_push_create(client, adult_a_user, adult_a_headers, initialized_db):
    """Pushing a brand-new task should be accepted and visible via pull."""
    task_id = str(uuid.uuid4())
    item = _task_create_item(record_id=task_id, title="Buy milk")

    resp = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )
    assert resp.status_code == 200

    body = resp.json()
    assert len(body["results"]) == 1
    assert body["results"][0]["status"] == "accepted"
    assert body["results"][0]["record_id"] == task_id

    # Verify the task is now in the database by pulling changes.
    old_ts = _iso_offset(minutes=-1)
    pull_resp = await client.get(
        f"/api/sync/pull?since={old_ts}",
        headers=adult_a_headers,
    )
    assert pull_resp.status_code == 200
    records = pull_resp.json()["records"]

    task_records = [r for r in records if r["record_id"] == task_id]
    assert len(task_records) == 1
    assert task_records[0]["data"]["title"] == "Buy milk"


async def test_sync_push_update(client, adult_a_user, adult_a_headers, initialized_db):
    """Updating an existing task via sync push should be accepted."""
    task_id = str(uuid.uuid4())
    await _insert_task(initialized_db, task_id, title="Original", created_by=adult_a_user["id"])

    # Push an update with a client_timestamp slightly in the future so it is
    # more recent than the server record (outside conflict window does not
    # matter here — we just need it accepted).
    item = _task_update_item(
        record_id=task_id,
        client_timestamp=_iso_offset(minutes=10),
        title="Updated via sync",
    )

    resp = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )
    assert resp.status_code == 200

    result = resp.json()["results"][0]
    assert result["status"] == "accepted"
    assert result["record_id"] == task_id


async def test_sync_push_delete(client, adult_a_user, adult_a_headers, initialized_db):
    """Deleting a task via sync should set deleted_at on the record."""
    task_id = str(uuid.uuid4())
    await _insert_task(initialized_db, task_id, title="To be deleted", created_by=adult_a_user["id"])

    item = _task_delete_item(
        record_id=task_id,
        client_timestamp=_iso_offset(minutes=10),
    )

    resp = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["results"][0]["status"] == "accepted"

    # Verify deleted_at is set in the database.
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT deleted_at FROM tasks WHERE id = ?", (task_id,))
        row = await cursor.fetchone()

    assert row is not None
    assert row["deleted_at"] is not None


async def test_sync_kat_wins_conflict(
    client, adult_a_user, adult_b_user, adult_a_headers, adult_b_headers, initialized_db
):
    """Within the conflict window, the higher-priority user (Morgan) wins.

    Morgan creates a task (created_by=Morgan, priority 10).  Alex then pushes an
    update with a client_timestamp within 5 minutes of the server's
    updated_at.  Alex (priority 5) < Morgan (priority 10), so Alex should
    receive status="conflict".
    """
    task_id = str(uuid.uuid4())
    server_ts = _now_iso()
    await _insert_task(
        initialized_db,
        task_id,
        title="Morgan's task",
        created_by=adult_b_user["id"],
        updated_at=server_ts,
    )

    # Alex pushes an update within the conflict window (1 minute after server).
    adult_a_item = _task_update_item(
        record_id=task_id,
        client_timestamp=_iso_offset(minutes=1),
        title="Alex tries to change it",
    )

    resp = await client.post(
        "/api/sync/push",
        json=_make_push_body([adult_a_item]),
        headers=adult_a_headers,
    )
    assert resp.status_code == 200

    result = resp.json()["results"][0]
    assert result["status"] == "conflict", (
        f"Expected Alex to lose the conflict against Morgan, got status={result['status']}"
    )
    assert result["server_version"] is not None


async def test_sync_outside_window_latest_wins(
    client, adult_a_user, adult_b_user, adult_a_headers, initialized_db
):
    """Outside the 5-minute conflict window the most-recent timestamp wins.

    Morgan creates a task, then Alex pushes an update with a client_timestamp
    10 minutes later.  Even though Morgan has higher priority, Alex's push
    should be accepted because the timestamps are outside the window.
    """
    task_id = str(uuid.uuid4())
    server_ts = _now_iso()
    await _insert_task(
        initialized_db,
        task_id,
        title="Morgan's old task",
        created_by=adult_b_user["id"],
        updated_at=server_ts,
    )

    item = _task_update_item(
        record_id=task_id,
        client_timestamp=_iso_offset(minutes=10),
        title="Alex updates later",
    )

    resp = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["results"][0]["status"] == "accepted"


async def test_sync_outside_window_server_newer(client, adult_a_user, adult_a_headers, initialized_db):
    """When the client_timestamp is older than the server record (outside
    the conflict window), the push should be rejected as a conflict because
    the server is more recent.
    """
    task_id = str(uuid.uuid4())
    # Server record has a timestamp 10 minutes in the future from now.
    server_ts = _iso_offset(minutes=10)
    await _insert_task(
        initialized_db,
        task_id,
        title="Recent server task",
        created_by=adult_a_user["id"],
        updated_at=server_ts,
    )

    # Push with a client_timestamp that is *now* (10 minutes before the server).
    item = _task_update_item(
        record_id=task_id,
        client_timestamp=_now_iso(),
        title="Stale client update",
    )

    resp = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )
    assert resp.status_code == 200

    result = resp.json()["results"][0]
    assert result["status"] == "conflict"
    assert result["server_version"] is not None


async def test_sync_pull_changes(client, adult_a_user, adult_a_headers, initialized_db):
    """GET /api/sync/pull should return records updated after the given timestamp."""
    old_ts = _iso_offset(minutes=-5)

    # Create two tasks via sync push so they have recent updated_at.
    items = [
        _task_create_item(title="Task A"),
        _task_create_item(title="Task B"),
    ]
    push_resp = await client.post(
        "/api/sync/push",
        json=_make_push_body(items),
        headers=adult_a_headers,
    )
    assert push_resp.status_code == 200

    pull_resp = await client.get(
        f"/api/sync/pull?since={old_ts}",
        headers=adult_a_headers,
    )
    assert pull_resp.status_code == 200

    body = pull_resp.json()
    assert "records" in body
    assert "server_timestamp" in body

    titles = {r["data"]["title"] for r in body["records"] if r["table_name"] == "tasks"}
    assert "Task A" in titles
    assert "Task B" in titles


async def test_sync_pull_pages_share_one_stable_snapshot(
    client, adult_a_headers, initialized_db
):
    since = _now_iso()
    first_id = str(uuid.uuid4())
    second_id = str(uuid.uuid4())
    await _insert_task(initialized_db, first_id, title="Page one")
    await _insert_task(initialized_db, second_id, title="Page two")

    first = await client.get(
        "/api/sync/pull",
        params={"since": since, "limit": 1},
        headers=adult_a_headers,
    )
    assert first.status_code == 200
    first_body = first.json()
    assert first_body["has_more"] is True
    assert first_body["next_cursor"]
    assert len(first_body["records"]) == 1

    second = await client.get(
        "/api/sync/pull",
        params={
            "since": since,
            "limit": 1,
            "cursor": first_body["next_cursor"],
        },
        headers=adult_a_headers,
    )
    assert second.status_code == 200
    second_body = second.json()
    assert second_body["server_timestamp"] == first_body["server_timestamp"]
    returned_ids = {
        first_body["records"][0]["record_id"],
        second_body["records"][0]["record_id"],
    }
    assert returned_ids == {first_id, second_id}
    assert second_body["has_more"] is False
    assert second_body["next_cursor"] is None


async def test_sync_record_history(client, adult_a_user, adult_a_headers, initialized_db):
    """Updating a record via sync should create a snapshot in record_history."""
    task_id = str(uuid.uuid4())
    await _insert_task(initialized_db, task_id, title="Before update", created_by=adult_a_user["id"])

    item = _task_update_item(
        record_id=task_id,
        client_timestamp=_iso_offset(minutes=10),
        title="After update",
    )

    resp = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["results"][0]["status"] == "accepted"

    # Check the record_history table for a snapshot of the previous values.
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM record_history WHERE table_name = 'tasks' AND record_id = ?",
            (task_id,),
        )
        rows = await cursor.fetchall()

    assert len(rows) >= 1, "record_history should contain at least one snapshot"

    history_row = dict(rows[0])
    previous = json.loads(history_row["previous_values"])
    assert previous["title"] == "Before update"
    assert history_row["changed_by"] == adult_a_user["id"]


async def test_sync_invalid_table(client, adult_a_user, adult_a_headers, initialized_db):
    """Pushing to a table not in SYNCABLE_TABLES should return status='error'."""
    item = {
        "operation": "create",
        "table_name": "nonexistent_table",
        "record_id": str(uuid.uuid4()),
        "client_id": str(uuid.uuid4()),
        "client_timestamp": _now_iso(),
        "payload": {"foo": "bar"},
    }

    resp = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )
    assert resp.status_code == 200

    result = resp.json()["results"][0]
    assert result["status"] == "error"
    assert "not syncable" in result["detail"].lower()


async def test_sync_never_discloses_or_mutates_another_family_record(
    client,
    adult_a_headers,
    other_family_headers,
    initialized_db,
):
    task_id = str(uuid.uuid4())
    await _insert_task(initialized_db, task_id, title="Private family task")

    item = _task_update_item(
        record_id=task_id,
        client_timestamp=_iso_offset(minutes=10),
        title="Cross-family change",
    )
    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=other_family_headers,
    )

    assert response.status_code == 200
    result = response.json()["results"][0]
    assert result["status"] == "error"
    assert result["server_version"] is None
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute("SELECT title FROM tasks WHERE id = ?", (task_id,))
        ).fetchone()
    assert row[0] == "Private family task"


async def test_sync_rejects_protected_or_unknown_payload_fields(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
):
    protected = _task_create_item(
        family_id="00000000-0000-0000-0000-000000000999",
        created_by="attacker",
    )
    injected = _task_create_item(**{'title) VALUES ("bad"); --': "value"})

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([protected, injected]),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert [item["status"] for item in response.json()["results"]] == ["error", "error"]
    async with aiosqlite.connect(initialized_db) as db:
        count = (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0]
    assert count == 0


async def test_sync_medicine_type_create_enforces_bounds_and_child_ownership(
    client,
    adult_a_headers,
    child1,
    second_family,
    initialized_db,
):
    foreign_child_id = str(uuid.uuid4())
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, family_id) VALUES (?, ?, ?, ?)",
            (foreign_child_id, "Other child", "2020-01-01", SECOND_FAMILY_ID),
        )
        await db.commit()

    foreign_child = _medicine_type_create_item(foreign_child_id)
    oversized_name = _medicine_type_create_item(child1["id"], name="x" * 201)
    unsafe_bounds = _medicine_type_create_item(
        child1["id"],
        min_hours_between_doses=0,
        max_doses_24h=25,
    )
    valid = _medicine_type_create_item(child1["id"], name="Ibuprofen")

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([foreign_child, oversized_name, unsafe_bounds, valid]),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert [result["status"] for result in response.json()["results"]] == [
        "error",
        "error",
        "error",
        "accepted",
    ]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute("SELECT * FROM medicine_types")).fetchall()
    assert [row["id"] for row in rows] == [valid["record_id"]]
    assert rows[0]["child_id"] == child1["id"]
    assert rows[0]["family_id"] == EXAMPLE_FAMILY_ID


async def test_sync_medicine_dose_rejects_foreign_references_and_invalid_payloads(
    client,
    adult_a_headers,
    child1,
    child2,
    second_family,
    initialized_db,
):
    own_type_id = str(uuid.uuid4())
    foreign_child_id = str(uuid.uuid4())
    foreign_type_id = str(uuid.uuid4())
    now = _now_iso()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO medicine_types
                (id, name, child_id, family_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (own_type_id, "Calpol", child1["id"], EXAMPLE_FAMILY_ID, now, now),
        )
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, family_id) VALUES (?, ?, ?, ?)",
            (foreign_child_id, "Other child", "2020-01-01", SECOND_FAMILY_ID),
        )
        await db.execute(
            """
            INSERT INTO medicine_types
                (id, name, child_id, family_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (foreign_type_id, "Private medicine", foreign_child_id, SECOND_FAMILY_ID, now, now),
        )
        await db.commit()

    items = [
        _medicine_dose_create_item(foreign_child_id),
        _medicine_dose_create_item(
            child1["id"],
            medicine_type_id=foreign_type_id,
            medicine_name=None,
        ),
        _medicine_dose_create_item(
            child2["id"],
            medicine_type_id=own_type_id,
            medicine_name=None,
        ),
        _medicine_dose_create_item(child1["id"], medicine_name=None),
        _medicine_dose_create_item(child1["id"], dose_amount="x" * 101),
        _medicine_dose_create_item(child1["id"], given_at="not-a-timestamp"),
    ]
    invalid_client_time = _medicine_dose_create_item(child1["id"])
    invalid_client_time["client_timestamp"] = "not-a-timestamp"
    items.append(invalid_client_time)

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body(items),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert all(result["status"] == "error" for result in response.json()["results"])
    async with aiosqlite.connect(initialized_db) as db:
        count = (await (await db.execute("SELECT COUNT(*) FROM medicine_doses")).fetchone())[0]
    assert count == 0


async def test_sync_medicine_dose_returns_safety_warnings_and_ignores_forged_giver(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    initialized_db,
):
    medicine_type_id = str(uuid.uuid4())
    existing_dose_id = str(uuid.uuid4())
    replayed_dose_id = str(uuid.uuid4())
    proposed_at = datetime.now(timezone.utc)
    existing_at = proposed_at - timedelta(hours=1)
    created_at = _now_iso()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO medicine_types
                (id, name, min_hours_between_doses, max_doses_24h, child_id,
                 family_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                medicine_type_id,
                "Calpol",
                4,
                4,
                child1["id"],
                EXAMPLE_FAMILY_ID,
                created_at,
                created_at,
            ),
        )
        await db.execute(
            """
            INSERT INTO medicine_doses
                (id, medicine_type_id, child_id, given_at, given_by, family_id,
                 created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                existing_dose_id,
                medicine_type_id,
                child1["id"],
                existing_at.isoformat(),
                "Morgan",
                EXAMPLE_FAMILY_ID,
                created_at,
                created_at,
            ),
        )
        await db.commit()

    item = _medicine_dose_create_item(
        child1["id"],
        medicine_type_id=medicine_type_id,
        medicine_name=None,
        given_at=proposed_at.isoformat(),
        dose_amount="5 ml",
        given_by="attacker-controlled",
    )
    item["record_id"] = replayed_dose_id

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    result = response.json()["results"][0]
    assert result["status"] == "accepted"
    assert [warning["type"] for warning in result["warnings"]] == ["too_soon"]
    assert result["warnings"][0]["next_safe_at"] is not None
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        row = await (
            await db.execute("SELECT * FROM medicine_doses WHERE id = ?", (replayed_dose_id,))
        ).fetchone()
    assert row is not None
    assert row["given_by"] == adult_a_user["name"]
    assert row["family_id"] == EXAMPLE_FAMILY_ID
    assert row["given_at"] == proposed_at.isoformat()


async def test_sync_rejects_medicine_update_delete_but_accepts_nap_create(
    client,
    adult_a_headers,
    child1,
):
    medicine_update = _medicine_type_create_item(child1["id"])
    medicine_update["operation"] = "update"
    medicine_delete = _medicine_dose_create_item(child1["id"])
    medicine_delete["operation"] = "delete"
    medicine_delete["payload"] = None
    nap_create = {
        "operation": "create",
        "table_name": "naps",
        "record_id": str(uuid.uuid4()),
        "client_id": str(uuid.uuid4()),
        "client_timestamp": _now_iso(),
        "payload": {"child_id": child1["id"], "started_at": _now_iso()},
    }

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([medicine_update, medicine_delete, nap_create]),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert [result["status"] for result in response.json()["results"]] == [
        "error",
        "error",
        "accepted",
    ]


async def test_sync_pull_keeps_tables_that_are_not_pushable(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    nap_id = str(uuid.uuid4())
    now = _now_iso()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO naps
                (id, child_id, started_at, family_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (nap_id, child1["id"], now, EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()

    response = await client.get(
        f"/api/sync/pull?since={_iso_offset(minutes=-1)}",
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert any(
        record["table_name"] == "naps" and record["record_id"] == nap_id
        for record in response.json()["records"]
    )


async def test_sync_rejects_unreasonable_future_client_timestamps(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
):
    task_id = str(uuid.uuid4())
    await _insert_task(
        initialized_db,
        task_id,
        title="Server truth",
        created_by=adult_a_user["id"],
    )
    far_future = _iso_offset(minutes=24 * 60)
    items = [
        _task_create_item(client_timestamp=far_future),
        _task_update_item(
            task_id,
            client_timestamp=far_future,
            title="Future timestamp wins",
        ),
    ]

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body(items),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert [result["status"] for result in response.json()["results"]] == [
        "error",
        "error",
    ]
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute("SELECT title FROM tasks WHERE id = ?", (task_id,))
        ).fetchone()
        count = (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0]
    assert row[0] == "Server truth"
    assert count == 1


async def test_sync_task_create_uses_typed_limits_and_date_invariants(
    client,
    adult_a_headers,
    initialized_db,
):
    items = [
        _task_create_item(title="x" * 301),
        _task_create_item(description="x" * 10_001),
        _task_create_item(category="private"),
        _task_create_item(priority=4),
        _task_create_item(due_date="not-a-date"),
        _task_create_item(
            due_date="2026-07-11T10:00:00Z",
            actionable_from="2026-07-11T11:00:00Z",
        ),
        _task_create_item(recurrence_rule="FREQ=SECONDLY"),
        _task_create_item(source_document_id=str(uuid.uuid4())),
        _task_create_item(completed_at=_now_iso()),
    ]
    items.append(_task_create_item())
    items[-1]["payload"] = {"priority": 2}

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body(items),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert all(result["status"] == "error" for result in response.json()["results"])
    async with aiosqlite.connect(initialized_db) as db:
        count = (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0]
    assert count == 0


async def test_sync_task_update_uses_typed_limits_and_completion_invariants(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
):
    task_id = str(uuid.uuid4())
    await _insert_task(
        initialized_db,
        task_id,
        title="Original",
        created_by=adult_a_user["id"],
    )
    items = [
        _task_update_item(task_id, title="x" * 301),
        _task_update_item(task_id, priority=0),
        _task_update_item(task_id, due_date="not-a-date"),
        _task_update_item(task_id, recurrence_rule="FREQ=SECONDLY"),
        _task_update_item(task_id, source_document_id=str(uuid.uuid4())),
        _task_update_item(
            task_id,
            completed_at=_iso_offset(minutes=24 * 60),
        ),
    ]

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body(items),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert all(result["status"] == "error" for result in response.json()["results"])
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT title, completed_at FROM tasks WHERE id = ?",
                (task_id,),
            )
        ).fetchone()
    assert row == ("Original", None)


async def test_sync_links_and_unlinks_family_documents_for_events_and_tasks(
    client,
    adult_a_headers,
    initialized_db,
):
    own_document_id = str(uuid.uuid4())
    other_document_id = str(uuid.uuid4())
    await _insert_document(initialized_db, own_document_id, EXAMPLE_FAMILY_ID)
    await _insert_document(initialized_db, other_document_id, SECOND_FAMILY_ID)
    task_id = str(uuid.uuid4())
    event_id = str(uuid.uuid4())

    created = await client.post(
        "/api/sync/push",
        json=_make_push_body(
            [
                _task_create_item(
                    record_id=task_id,
                    source_document_id=own_document_id,
                ),
                _calendar_create_item(
                    record_id=event_id,
                    source_document_id=own_document_id,
                ),
                _task_create_item(source_document_id=other_document_id),
                _calendar_create_item(source_document_id=other_document_id),
            ]
        ),
        headers=adult_a_headers,
    )
    assert [item["status"] for item in created.json()["results"]] == [
        "accepted",
        "accepted",
        "error",
        "error",
    ]

    unlinked = await client.post(
        "/api/sync/push",
        json=_make_push_body(
            [
                _task_update_item(
                    task_id,
                    client_timestamp=_iso_offset(minutes=1),
                    source_document_id=None,
                ),
                _calendar_update_item(
                    event_id,
                    client_timestamp=_iso_offset(minutes=1),
                    source_document_id=None,
                ),
            ]
        ),
        headers=adult_a_headers,
    )
    assert [item["status"] for item in unlinked.json()["results"]] == [
        "accepted",
        "accepted",
    ]

    async with aiosqlite.connect(initialized_db) as db:
        task_link = (
            await (
                await db.execute("SELECT source_document_id FROM tasks WHERE id = ?", (task_id,))
            ).fetchone()
        )[0]
        event_link = (
            await (
                await db.execute(
                    "SELECT source_document_id FROM calendar_events WHERE id = ?",
                    (event_id,),
                )
            ).fetchone()
        )[0]
    assert task_link is None
    assert event_link is None


async def test_sync_rejects_empty_document_ids_on_create_and_update(
    client,
    adult_a_headers,
):
    task_id = str(uuid.uuid4())
    event_id = str(uuid.uuid4())
    created = await client.post(
        "/api/sync/push",
        json=_make_push_body(
            [
                _task_create_item(source_document_id=""),
                _calendar_create_item(source_document_id=""),
                _task_create_item(record_id=task_id),
                _calendar_create_item(record_id=event_id),
            ]
        ),
        headers=adult_a_headers,
    )
    assert [item["status"] for item in created.json()["results"]] == [
        "error",
        "error",
        "accepted",
        "accepted",
    ]

    updated = await client.post(
        "/api/sync/push",
        json=_make_push_body(
            [
                _task_update_item(
                    task_id,
                    client_timestamp=_iso_offset(minutes=1),
                    source_document_id="",
                ),
                _calendar_update_item(
                    event_id,
                    client_timestamp=_iso_offset(minutes=1),
                    source_document_id="",
                ),
            ]
        ),
        headers=adult_a_headers,
    )
    assert [item["status"] for item in updated.json()["results"]] == ["error", "error"]


async def test_sync_task_assignees_are_family_scoped_and_deduplicated(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    other_family_user,
    initialized_db,
):
    items = [
        _task_create_item(
            assignees=[
                {"assignee_id": adult_a_user["id"], "assignee_type": "user"},
                {"assignee_id": adult_a_user["id"], "assignee_type": "user"},
            ]
        ),
        _task_create_item(
            assignees=[
                {
                    "assignee_id": other_family_user["id"],
                    "assignee_type": "user",
                }
            ]
        ),
        _task_create_item(assignees=[{"assignee_id": child1["id"], "assignee_type": "user"}]),
        _task_create_item(assigned_to=other_family_user["id"]),
    ]

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body(items),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert all(result["status"] == "error" for result in response.json()["results"])
    async with aiosqlite.connect(initialized_db) as db:
        task_count = (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0]
        assignment_count = (
            await (await db.execute("SELECT COUNT(*) FROM task_assignments")).fetchone()
        )[0]
    assert task_count == 0
    assert assignment_count == 0


async def test_sync_task_assignment_completion_and_delete_lifecycle(
    client,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    child1,
    initialized_db,
):
    task_id = str(uuid.uuid4())
    create = _task_create_item(
        record_id=task_id,
        title="Pack bags",
        due_date="2026-08-01T12:00:00Z",
        actionable_from="2026-07-20T09:00:00Z",
        recurrence_rule="FREQ=WEEKLY;BYDAY=MO",
        assignees=[
            {"assignee_id": adult_a_user["id"], "assignee_type": "user"},
            {"assignee_id": child1["id"], "assignee_type": "child"},
        ],
    )
    created = await client.post(
        "/api/sync/push",
        json=_make_push_body([create]),
        headers=adult_a_headers,
    )
    assert created.json()["results"][0]["status"] == "accepted"

    replace = _task_update_item(
        task_id,
        assignees=[{"assignee_id": adult_b_user["id"], "assignee_type": "user"}],
    )
    replaced = await client.post(
        "/api/sync/push",
        json=_make_push_body([replace]),
        headers=adult_a_headers,
    )
    assert replaced.json()["results"][0]["status"] == "accepted"

    completed_at = _iso_offset(minutes=-2)
    completed = await client.post(
        "/api/sync/push",
        json=_make_push_body([_task_update_item(task_id, completed_at=completed_at)]),
        headers=adult_a_headers,
    )
    assert completed.json()["results"][0]["status"] == "accepted"

    delete_item = _task_delete_item(task_id)
    delete_item["payload"] = {}
    deleted = await client.post(
        "/api/sync/push",
        json=_make_push_body([delete_item]),
        headers=adult_a_headers,
    )
    assert deleted.json()["results"][0]["status"] == "accepted"

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        task = await (await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))).fetchone()
        assignments = await (
            await db.execute(
                "SELECT * FROM task_assignments WHERE task_id = ?",
                (task_id,),
            )
        ).fetchall()
        next_task = await (
            await db.execute(
                "SELECT * FROM tasks WHERE client_id = ? AND deleted_at IS NULL",
                (f"hausklar:task-recurrence:{task_id}",),
            )
        ).fetchone()
        next_assignments = await (
            await db.execute(
                "SELECT * FROM task_assignments WHERE task_id = ? AND deleted_at IS NULL",
                (next_task["id"],),
            )
        ).fetchall()
    assert task["completed_at"] == completed_at
    assert task["deleted_at"] is not None
    active_before_delete = [row for row in assignments if row["assignee_id"] == adult_b_user["id"]]
    assert len(active_before_delete) == 1
    assert active_before_delete[0]["completed_at"] == completed_at
    assert all(row["deleted_at"] is not None for row in assignments)
    next_due = datetime.fromisoformat(next_task["due_date"].replace("Z", "+00:00"))
    next_actionable = datetime.fromisoformat(
        next_task["actionable_from"].replace("Z", "+00:00")
    )
    assert next_due > datetime.fromisoformat(completed_at.replace("Z", "+00:00"))
    assert next_due.weekday() == 0
    assert next_due - next_actionable == timedelta(days=12, hours=3)
    assert next_task["recurrence_rule"] == "FREQ=WEEKLY;BYDAY=MO"
    assert len(next_assignments) == 1
    assert next_assignments[0]["assignee_id"] == adult_b_user["id"]
    assert next_assignments[0]["completed_at"] is None


async def test_sync_scraper_managed_task_only_accepts_completion(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
):
    """Offline sync cannot overwrite/delete scraper truth or smuggle mixed edits."""
    task_id = str(uuid.uuid4())
    assignment_id = str(uuid.uuid4())
    await _insert_task(
        initialized_db,
        task_id,
        title="Bins",
        created_by="bin-scraper",
        category="household",
    )
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO task_assignments
                (id,task_id,assignee_id,assignee_type,family_id,created_at,
                 updated_at,created_by)
            VALUES (?,?,?,'user',?,?,?,?)
            """,
            (
                assignment_id,
                task_id,
                adult_a_user["id"],
                EXAMPLE_FAMILY_ID,
                _now_iso(),
                _now_iso(),
                "bin-scraper",
            ),
        )
        await db.commit()

    blocked_items = [
        _task_update_item(
            task_id,
            title="Disguised edit",
            completed_at=_iso_offset(minutes=-1),
        ),
        _task_update_item(
            task_id,
            assignees=[{"assignee_id": adult_a_user["id"], "assignee_type": "user"}],
        ),
        _task_delete_item(task_id),
    ]
    blocked = await client.post(
        "/api/sync/push",
        json=_make_push_body(blocked_items),
        headers=adult_a_headers,
    )

    assert blocked.status_code == 200
    assert [result["status"] for result in blocked.json()["results"]] == [
        "error",
        "error",
        "error",
    ]
    assert all("managed automatically" in result["detail"] for result in blocked.json()["results"])
    async with aiosqlite.connect(initialized_db) as db:
        task_before = await (
            await db.execute(
                "SELECT title,completed_at,deleted_at FROM tasks WHERE id = ?",
                (task_id,),
            )
        ).fetchone()
        history_before = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id IN (?, ?)",
                    (task_id, assignment_id),
                )
            ).fetchone()
        )[0]
    assert task_before == ("Bins", None, None)
    assert history_before == 0

    completed_at = _iso_offset(minutes=-10)
    completion_item = _task_update_item(
        task_id,
        client_timestamp=completed_at,
        completed_at=completed_at,
    )
    completed = await client.post(
        "/api/sync/push",
        json=_make_push_body([completion_item]),
        headers=adult_a_headers,
    )
    assert completed.json()["results"][0]["status"] == "accepted"

    async with aiosqlite.connect(initialized_db) as db:
        first_update = await (
            await db.execute(
                "SELECT completed_at,updated_at FROM tasks WHERE id = ?",
                (task_id,),
            )
        ).fetchone()
        first_history_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id IN (?, ?)",
                    (task_id, assignment_id),
                )
            ).fetchone()
        )[0]

    replayed = await client.post(
        "/api/sync/push",
        json=_make_push_body([completion_item]),
        headers=adult_a_headers,
    )
    deleted = await client.post(
        "/api/sync/push",
        json=_make_push_body([_task_delete_item(task_id)]),
        headers=adult_a_headers,
    )

    assert replayed.json()["results"][0]["status"] == "accepted"
    assert deleted.json()["results"][0]["status"] == "error"
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        task = await (await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))).fetchone()
        assignment = await (
            await db.execute(
                "SELECT * FROM task_assignments WHERE id = ?",
                (assignment_id,),
            )
        ).fetchone()
        histories = await (
            await db.execute(
                """
                SELECT table_name,record_id,previous_values FROM record_history
                WHERE record_id IN (?, ?) ORDER BY table_name
                """,
                (task_id, assignment_id),
            )
        ).fetchall()
        final_history_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id IN (?, ?)",
                    (task_id, assignment_id),
                )
            ).fetchone()
        )[0]
    assert task["completed_at"] == completed_at
    assert (task["completed_at"], task["updated_at"]) == first_update
    assert task["deleted_at"] is None
    assert assignment["completed_at"] == completed_at
    assert {(row["table_name"], row["record_id"]) for row in histories} == {
        ("tasks", task_id),
        ("task_assignments", assignment_id),
    }
    assignment_snapshot = next(row for row in histories if row["table_name"] == "task_assignments")
    assert json.loads(assignment_snapshot["previous_values"])["completed_at"] is None
    assert first_history_count == final_history_count == 2


async def test_sync_calendar_uses_typed_validation_and_family_references(
    client,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    child1,
    other_family_user,
    initialized_db,
):
    items = [
        _calendar_create_item(title="x" * 301),
        _calendar_create_item(start_time="not-a-date"),
        _calendar_create_item(
            start_time="2026-07-11T10:00:00Z",
            end_time="2026-07-11T09:00:00Z",
        ),
        _calendar_create_item(recurrence_rule="FREQ=SECONDLY"),
        _calendar_create_item(assigned_to=other_family_user["id"]),
        _calendar_create_item(family_member_ids=[other_family_user["id"]]),
        _calendar_create_item(
            family_member_ids=[child1["id"]],
            affected_member_ids=[child1["id"]],
        ),
        _calendar_create_item(
            family_member_ids=[child1["id"]],
            affected_member_ids=[other_family_user["id"]],
        ),
        _calendar_create_item(source_document_id=str(uuid.uuid4())),
    ]
    valid = _calendar_create_item(
        title="Football",
        start_time="2026-07-11T15:00:00Z",
        end_time="2026-07-11T16:15:00Z",
        recurrence_rule="freq=weekly;byday=sa",
        family_member_ids=[child1["id"]],
        assigned_to=adult_a_user["id"],
        affected_member_ids=[adult_b_user["id"]],
        exertion=2,
    )
    items.append(valid)

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body(items),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    statuses = [result["status"] for result in response.json()["results"]]
    assert statuses == ["error"] * 9 + ["accepted"]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute("SELECT * FROM calendar_events")).fetchall()
    assert [row["id"] for row in rows] == [valid["record_id"]]
    assert rows[0]["recurrence_rule"] == "FREQ=WEEKLY;BYDAY=SA"
    assert json.loads(rows[0]["family_member_ids"]) == [child1["id"]]
    assert rows[0]["assigned_to"] == adult_a_user["id"]
    assert json.loads(rows[0]["affected_member_ids"]) == [adult_b_user["id"]]


async def test_sync_calendar_sparse_update_preserves_timing_rule_and_people(
    client,
    adult_a_user,
    adult_a_headers,
    adult_b_user,
    child1,
    initialized_db,
):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Swimming",
            "start_time": "2026-09-08T16:00:00Z",
            "end_time": "2026-09-08T17:00:00Z",
            "recurrence_rule": "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;COUNT=10",
            "family_member_ids": [adult_b_user["id"], child1["id"]],
            "affected_member_ids": [adult_a_user["id"]],
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    event_id = created.json()["id"]
    item = _calendar_update_item(
        event_id,
        client_timestamp=_iso_offset(minutes=1),
        title="Swimming lesson",
    )

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json()["results"][0]["status"] == "accepted"
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        row = await (
            await db.execute("SELECT * FROM calendar_events WHERE id = ?", (event_id,))
        ).fetchone()
    assert row["title"] == "Swimming lesson"
    assert row["start_time"] == "2026-09-08T16:00:00Z"
    assert row["end_time"] == "2026-09-08T17:00:00Z"
    assert row["recurrence_rule"] == "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;COUNT=10"
    assert json.loads(row["family_member_ids"]) == [adult_b_user["id"], child1["id"]]
    assert json.loads(row["affected_member_ids"]) == [adult_a_user["id"]]
    assert row["client_id"] == item["client_id"]
    assert row["client_timestamp"] == item["client_timestamp"]


async def test_sync_calendar_update_honours_kat_wins(
    client,
    adult_a_headers,
    adult_b_headers,
):
    created = await client.post(
        "/api/calendar/",
        json={"title": "Morgan's event", "start_time": "2026-09-08T16:00:00Z"},
        headers=adult_b_headers,
    )
    assert created.status_code == 201
    item = _calendar_update_item(
        created.json()["id"],
        client_timestamp=_iso_offset(minutes=1),
        title="Alex's edit",
    )

    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([item]),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json()["results"][0]["status"] == "conflict"
    listed = await client.get(
        "/api/calendar/",
        headers=adult_b_headers,
    )
    assert (
        next(event for event in listed.json() if event["id"] == created.json()["id"])["title"]
        == "Morgan's event"
    )


async def test_sync_delete_rejects_non_empty_payloads(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
):
    task_id = str(uuid.uuid4())
    event_id = str(uuid.uuid4())
    await _insert_task(
        initialized_db,
        task_id,
        title="Keep task",
        created_by=adult_a_user["id"],
    )
    now = _now_iso()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO calendar_events
                (id, title, start_time, family_id, created_at, updated_at,
                 created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                event_id,
                "Keep event",
                now,
                EXAMPLE_FAMILY_ID,
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.commit()

    task_delete = _task_delete_item(task_id)
    task_delete["payload"] = {"title": "ignored"}
    event_delete = {
        "operation": "delete",
        "table_name": "calendar_events",
        "record_id": event_id,
        "client_id": str(uuid.uuid4()),
        "client_timestamp": _now_iso(),
        "payload": {"title": "ignored"},
    }
    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([task_delete, event_delete]),
        headers=adult_a_headers,
    )

    assert [result["status"] for result in response.json()["results"]] == [
        "error",
        "error",
    ]
    async with aiosqlite.connect(initialized_db) as db:
        task = await (
            await db.execute("SELECT deleted_at FROM tasks WHERE id = ?", (task_id,))
        ).fetchone()
        event = await (
            await db.execute(
                "SELECT deleted_at FROM calendar_events WHERE id = ?",
                (event_id,),
            )
        ).fetchone()
    assert task[0] is None
    assert event[0] is None


async def test_sync_cannot_delete_generated_term_boundary(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    initialized_db,
):
    term = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "Protected Term",
            "start_date": "2026-09-03",
            "end_date": "2026-12-18",
        },
        headers=adult_a_headers,
    )
    assert term.status_code == 201

    async with aiosqlite.connect(initialized_db) as db:
        event_id = (
            await (
                await db.execute(
                    """
                    SELECT id FROM calendar_events
                    WHERE source_term_date_id = ? AND term_boundary = 'first'
                    """,
                    (term.json()["id"],),
                )
            ).fetchone()
        )[0]

    delete_item = {
        "operation": "delete",
        "table_name": "calendar_events",
        "record_id": event_id,
        "client_id": str(uuid.uuid4()),
        "client_timestamp": _iso_offset(minutes=1),
        "payload": None,
    }
    response = await client.post(
        "/api/sync/push",
        json=_make_push_body([delete_item]),
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json()["results"] == [
        {
            "operation_id": None,
            "record_id": event_id,
            "status": "error",
            "detail": "Calendar event is read-only",
            "server_version": None,
            "warnings": [],
        }
    ]
    async with aiosqlite.connect(initialized_db) as db:
        event = await (
            await db.execute(
                "SELECT deleted_at FROM calendar_events WHERE id = ?",
                (event_id,),
            )
        ).fetchone()
        history_count = (
            await (
                await db.execute(
                    """
                    SELECT COUNT(*) FROM record_history
                    WHERE table_name = 'calendar_events' AND record_id = ?
                    """,
                    (event_id,),
                )
            ).fetchone()
        )[0]
    assert event[0] is None
    assert history_count == 0

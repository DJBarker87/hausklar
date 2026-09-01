"""Tests for the tasks router (/api/tasks)."""

import json
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite

from conftest import EXAMPLE_FAMILY_ID


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


async def test_create_task(client, adult_a_headers):
    """POST /api/tasks/ with valid data returns 201 and the new task."""
    resp = await client.post(
        "/api/tasks/",
        json={"title": "Take out the bins", "category": "bins", "priority": 1},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["title"] == "Take out the bins"
    assert data["category"] == "bins"
    assert data["priority"] == 1
    assert data["id"] is not None
    assert data["created_at"] is not None
    assert data["completed_at"] is None
    assert data["assignees"] == []


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------


async def test_list_tasks(client, adult_a_headers):
    """GET /api/tasks/ returns all non-deleted tasks."""
    # Create two tasks
    await client.post(
        "/api/tasks/",
        json={"title": "Task A"},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/tasks/",
        json={"title": "Task B"},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/tasks/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 2
    titles = [t["title"] for t in data]
    assert "Task A" in titles
    assert "Task B" in titles


async def test_attention_order_returns_high_priority_tasks_first(client, adult_a_headers):
    """The compact Today query should rank the backlog before applying its limit."""
    high = await client.post(
        "/api/tasks/",
        json={"title": "Urgent older task", "priority": 3},
        headers=adult_a_headers,
    )
    low = await client.post(
        "/api/tasks/",
        json={"title": "Recent low priority task", "priority": 1},
        headers=adult_a_headers,
    )
    assert high.status_code == 201
    assert low.status_code == 201

    resp = await client.get(
        "/api/tasks/?status=pending&order=attention&limit=1",
        headers=adult_a_headers,
    )

    assert resp.status_code == 200
    assert [task["id"] for task in resp.json()] == [high.json()["id"]]


# ---------------------------------------------------------------------------
# Filter by category
# ---------------------------------------------------------------------------


async def test_filter_by_category(client, adult_a_headers):
    """GET /api/tasks/?category=shopping only returns tasks in that category."""
    await client.post(
        "/api/tasks/",
        json={"title": "Buy milk", "category": "shopping"},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/tasks/",
        json={"title": "Mow the lawn", "category": "household"},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/tasks/?category=shopping", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert all(t["category"] == "shopping" for t in data)
    assert any(t["title"] == "Buy milk" for t in data)


# ---------------------------------------------------------------------------
# Filter by status
# ---------------------------------------------------------------------------


async def test_filter_by_status(client, adult_a_headers):
    """GET /api/tasks/?status=completed|pending filters correctly."""
    # Create a task and complete it
    create_resp = await client.post(
        "/api/tasks/",
        json={"title": "Completed chore"},
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]
    await client.patch(f"/api/tasks/{task_id}/complete", headers=adult_a_headers)

    # Create a pending task
    await client.post(
        "/api/tasks/",
        json={"title": "Pending chore"},
        headers=adult_a_headers,
    )

    # Filter by completed
    resp = await client.get("/api/tasks/?status=completed", headers=adult_a_headers)
    assert resp.status_code == 200
    completed = resp.json()
    assert all(t["completed_at"] is not None for t in completed)
    assert any(t["title"] == "Completed chore" for t in completed)

    # Filter by pending
    resp = await client.get("/api/tasks/?status=pending", headers=adult_a_headers)
    assert resp.status_code == 200
    pending = resp.json()
    assert all(t["completed_at"] is None for t in pending)
    assert any(t["title"] == "Pending chore" for t in pending)


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------


async def test_update_task(client, adult_a_headers):
    """PUT /api/tasks/{id} updates fields and returns the updated task."""
    create_resp = await client.post(
        "/api/tasks/",
        json={"title": "Original title", "priority": 2},
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]

    resp = await client.put(
        f"/api/tasks/{task_id}",
        json={"title": "Updated title", "priority": 3},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["title"] == "Updated title"
    assert data["priority"] == 3


# ---------------------------------------------------------------------------
# Complete
# ---------------------------------------------------------------------------


async def test_complete_task(client, adult_a_headers):
    """PATCH /api/tasks/{id}/complete sets completed_at."""
    create_resp = await client.post(
        "/api/tasks/",
        json={"title": "Do laundry"},
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]
    assert create_resp.json()["completed_at"] is None

    resp = await client.patch(f"/api/tasks/{task_id}/complete", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["completed_at"] is not None


# ---------------------------------------------------------------------------
# Delete (soft)
# ---------------------------------------------------------------------------


async def test_delete_task(client, adult_a_headers):
    """DELETE /api/tasks/{id} soft-deletes and returns 204."""
    create_resp = await client.post(
        "/api/tasks/",
        json={"title": "Temporary task"},
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]

    resp = await client.delete(f"/api/tasks/{task_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    # Task should no longer appear in the list
    list_resp = await client.get("/api/tasks/", headers=adult_a_headers)
    ids = [t["id"] for t in list_resp.json()]
    assert task_id not in ids


async def test_scraper_managed_task_only_allows_coordination_and_completion(
    client,
    adult_a_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    """A scraper ownership marker survives category drift and protects council data."""
    task_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO tasks
                (id,title,description,due_date,category,priority,family_id,
                 created_at,updated_at,created_by)
            VALUES (?, 'Bins', 'black,blue', '2026-07-16', 'other', 2, ?, ?, ?,
                    'bin-scraper')
            """,
            (task_id, EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()

    update = await client.put(
        f"/api/tasks/{task_id}",
        json={"title": "Hide the council task", "assigned_to": adult_b_user["id"]},
        headers=adult_a_headers,
    )
    delete = await client.delete(f"/api/tasks/{task_id}", headers=adult_a_headers)

    assert update.status_code == 409
    assert delete.status_code == 409
    assert "managed automatically" in update.json()["detail"]
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT title,assigned_to,deleted_at FROM tasks WHERE id = ?",
                (task_id,),
            )
        ).fetchone()
        history_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id = ?",
                    (task_id,),
                )
            ).fetchone()
        )[0]
    assert row == ("Bins", None, None)
    assert history_count == 0

    assigned = await client.post(
        f"/api/coordination/load/{task_id}/assign",
        json={"assignee_id": adult_b_user["id"]},
        headers=adult_a_headers,
    )
    completed = await client.patch(f"/api/tasks/{task_id}/complete", headers=adult_a_headers)

    async with aiosqlite.connect(initialized_db) as db:
        history_after_completion = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id = ?",
                    (task_id,),
                )
            ).fetchone()
        )[0]
    replayed = await client.patch(f"/api/tasks/{task_id}/complete", headers=adult_a_headers)

    assert assigned.status_code == 204
    assert completed.status_code == 200
    assert replayed.status_code == 200
    body = completed.json()
    assert body["assigned_to"] == adult_b_user["id"]
    assert body["completed_at"] is not None
    assert len(body["assignees"]) == 1
    assert body["assignees"][0]["completed_at"] is not None
    assert replayed.json()["completed_at"] == body["completed_at"]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        histories = await (
            await db.execute(
                """
                SELECT table_name,previous_values FROM record_history
                WHERE table_name = 'task_assignments'
                  AND record_id IN (
                    SELECT id FROM task_assignments WHERE task_id = ?
                  )
                """,
                (task_id,),
            )
        ).fetchall()
        history_after_replay = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id = ?",
                    (task_id,),
                )
            ).fetchone()
        )[0]
    assert len(histories) == 1
    assert json.loads(histories[0]["previous_values"])["completed_at"] is None
    assert history_after_replay == history_after_completion


async def test_per_person_completion_records_assignment_history(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    created = await client.post(
        "/api/tasks/",
        json={
            "title": "Record individual completion",
            "assignees": [{"assignee_id": adult_a_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )
    task_id = created.json()["id"]
    assignment_id = created.json()["assignees"][0]["id"]
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE tasks SET created_by = 'bin-scraper', category = 'other' WHERE id = ?",
            (task_id,),
        )
        await db.commit()

    response = await client.patch(
        f"/api/tasks/{task_id}/complete/{adult_a_user['id']}",
        headers=adult_a_headers,
    )
    replay = await client.patch(
        f"/api/tasks/{task_id}/complete/{adult_a_user['id']}",
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert replay.status_code == 200
    assert (
        replay.json()["assignees"][0]["completed_at"]
        == response.json()["assignees"][0]["completed_at"]
    )
    async with aiosqlite.connect(initialized_db) as db:
        snapshots = await (
            await db.execute(
                """
                SELECT previous_values FROM record_history
                WHERE table_name = 'task_assignments' AND record_id = ?
                """,
                (assignment_id,),
            )
        ).fetchall()
    assert len(snapshots) == 1
    assert json.loads(snapshots[0][0])["completed_at"] is None


# ---------------------------------------------------------------------------
# Recurring task
# ---------------------------------------------------------------------------


async def test_recurring_task(client, adult_a_headers):
    """Creating a task with recurrence_rule stores the rule correctly."""
    resp = await client.post(
        "/api/tasks/",
        json={
            "title": "Weekly bins",
            "category": "bins",
            "recurrence_rule": "FREQ=WEEKLY;BYDAY=TU",
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["recurrence_rule"] == "FREQ=WEEKLY;BYDAY=TU"


async def test_completing_monthly_task_creates_one_next_occurrence_and_reopen_undoes_it(
    client,
    adult_a_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    today = datetime.now(timezone.utc).date()
    first_month_index = today.year * 12 + today.month
    first_year, first_month_zero_based = divmod(first_month_index, 12)
    first_due = datetime(first_year, first_month_zero_based + 1, 4, tzinfo=timezone.utc).date()
    next_month_index = first_year * 12 + first_due.month
    next_year, next_month_zero_based = divmod(next_month_index, 12)
    next_due = datetime(next_year, next_month_zero_based + 1, 4, tzinfo=timezone.utc).date()

    created = await client.post(
        "/api/tasks/",
        json={
            "title": "Pay Little Gym",
            "due_date": first_due.isoformat(),
            "actionable_from": (first_due - timedelta(days=3)).isoformat(),
            "recurrence_rule": "FREQ=MONTHLY;BYMONTHDAY=4",
            "assignees": [
                {"assignee_id": adult_a_user["id"], "assignee_type": "user"},
                {"assignee_id": adult_b_user["id"], "assignee_type": "user"},
            ],
        },
        headers=adult_a_headers,
    )
    task_id = created.json()["id"]

    completed = await client.patch(f"/api/tasks/{task_id}/complete", headers=adult_a_headers)

    assert completed.status_code == 200
    assert completed.json()["completed_at"] is not None
    pending = await client.get("/api/tasks/?status=pending", headers=adult_a_headers)
    successors = [task for task in pending.json() if task["title"] == "Pay Little Gym"]
    assert len(successors) == 1
    successor = successors[0]
    assert successor["id"] != task_id
    assert successor["due_date"] == next_due.isoformat()
    assert successor["actionable_from"] == (next_due - timedelta(days=3)).isoformat()
    assert successor["recurrence_rule"] == "FREQ=MONTHLY;BYMONTHDAY=4"
    assert {item["assignee_id"] for item in successor["assignees"]} == {
        adult_a_user["id"],
        adult_b_user["id"],
    }
    assert all(item["completed_at"] is None for item in successor["assignees"])

    replay = await client.patch(f"/api/tasks/{task_id}/complete", headers=adult_a_headers)
    assert replay.status_code == 200
    replayed_pending = await client.get("/api/tasks/?status=pending", headers=adult_a_headers)
    assert [
        task["id"] for task in replayed_pending.json() if task["title"] == "Pay Little Gym"
    ] == [successor["id"]]

    reopened = await client.patch(f"/api/tasks/{task_id}/reopen", headers=adult_a_headers)
    assert reopened.status_code == 200
    assert reopened.json()["completed_at"] is None
    after_reopen = await client.get("/api/tasks/?status=pending", headers=adult_a_headers)
    assert [task["id"] for task in after_reopen.json() if task["title"] == "Pay Little Gym"] == [
        task_id
    ]
    async with aiosqlite.connect(initialized_db) as db:
        generated = await (
            await db.execute("SELECT deleted_at FROM tasks WHERE id = ?", (successor["id"],))
        ).fetchone()
    assert generated[0] is not None


async def test_finite_repeating_task_stops_after_its_last_occurrence(client, adult_a_headers):
    first_due = datetime.now(timezone.utc).date() + timedelta(days=1)
    created = await client.post(
        "/api/tasks/",
        json={
            "title": "Two-day check",
            "due_date": first_due.isoformat(),
            "recurrence_rule": "FREQ=DAILY;COUNT=2",
        },
        headers=adult_a_headers,
    )
    first_id = created.json()["id"]

    await client.patch(f"/api/tasks/{first_id}/complete", headers=adult_a_headers)
    pending = await client.get("/api/tasks/?status=pending", headers=adult_a_headers)
    successors = [task for task in pending.json() if task["title"] == "Two-day check"]
    assert len(successors) == 1
    assert successors[0]["due_date"] == (first_due + timedelta(days=1)).isoformat()
    assert successors[0]["recurrence_rule"] == "FREQ=DAILY;COUNT=1"

    await client.patch(
        f"/api/tasks/{successors[0]['id']}/complete",
        headers=adult_a_headers,
    )
    final_pending = await client.get("/api/tasks/?status=pending", headers=adult_a_headers)
    assert not [task for task in final_pending.json() if task["title"] == "Two-day check"]


# ===========================================================================
# Multi-person assignment tests
# ===========================================================================


# ---------------------------------------------------------------------------
# Create task with multiple assignees
# ---------------------------------------------------------------------------


async def test_create_task_with_multiple_assignees(client, adult_a_headers, adult_a_user, adult_b_user):
    """POST /api/tasks/ with assignees creates junction rows."""
    resp = await client.post(
        "/api/tasks/",
        json={
            "title": "Tidy kitchen",
            "assignees": [
                {"assignee_id": adult_a_user["id"], "assignee_type": "user"},
                {"assignee_id": adult_b_user["id"], "assignee_type": "user"},
            ],
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert len(data["assignees"]) == 2
    assignee_ids = {a["assignee_id"] for a in data["assignees"]}
    assert adult_a_user["id"] in assignee_ids
    assert adult_b_user["id"] in assignee_ids
    # Names should be resolved
    names = {a["assignee_name"] for a in data["assignees"]}
    assert "Alex" in names
    assert "Morgan" in names


# ---------------------------------------------------------------------------
# Create task with child assignee
# ---------------------------------------------------------------------------


async def test_create_task_with_child_assignee(client, adult_a_headers, child1):
    """POST /api/tasks/ with a child assignee works correctly."""
    resp = await client.post(
        "/api/tasks/",
        json={
            "title": "Tidy bedroom",
            "assignees": [
                {"assignee_id": child1["id"], "assignee_type": "child"},
            ],
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert len(data["assignees"]) == 1
    assert data["assignees"][0]["assignee_id"] == child1["id"]
    assert data["assignees"][0]["assignee_type"] == "child"
    assert data["assignees"][0]["assignee_name"] == "Child 1"


# ---------------------------------------------------------------------------
# Per-person completion
# ---------------------------------------------------------------------------


async def test_per_person_completion(client, adult_a_headers, adult_a_user, adult_b_user):
    """PATCH complete/{assignee_id} marks one person done, other stays pending."""
    # Create task assigned to both
    create_resp = await client.post(
        "/api/tasks/",
        json={
            "title": "Pack lunches",
            "assignees": [
                {"assignee_id": adult_a_user["id"], "assignee_type": "user"},
                {"assignee_id": adult_b_user["id"], "assignee_type": "user"},
            ],
        },
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]

    # Complete for Alex only
    resp = await client.patch(
        f"/api/tasks/{task_id}/complete/{adult_a_user['id']}",
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()

    # Task itself should NOT be completed
    assert data["completed_at"] is None

    # Alex's assignment should be completed, Morgan's should not
    adult_a_assignment = next(a for a in data["assignees"] if a["assignee_id"] == adult_a_user["id"])
    adult_b_assignment = next(a for a in data["assignees"] if a["assignee_id"] == adult_b_user["id"])
    assert adult_a_assignment["completed_at"] is not None
    assert adult_b_assignment["completed_at"] is None


# ---------------------------------------------------------------------------
# Overall complete marks all assignments
# ---------------------------------------------------------------------------


async def test_overall_complete_marks_all_assignments(client, adult_a_headers, adult_a_user, adult_b_user):
    """PATCH /complete marks the task AND all assignments as done."""
    create_resp = await client.post(
        "/api/tasks/",
        json={
            "title": "Wash car",
            "assignees": [
                {"assignee_id": adult_a_user["id"], "assignee_type": "user"},
                {"assignee_id": adult_b_user["id"], "assignee_type": "user"},
            ],
        },
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]

    resp = await client.patch(f"/api/tasks/{task_id}/complete", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["completed_at"] is not None

    # Both assignments should be completed
    for a in data["assignees"]:
        assert a["completed_at"] is not None


# ---------------------------------------------------------------------------
# Filter assigned_to finds junction table matches
# ---------------------------------------------------------------------------


async def test_filter_assigned_to_junction(client, adult_a_headers, adult_a_user, adult_b_user):
    """GET /tasks/?assigned_to= searches the junction table."""
    # Create task assigned to Alex only
    await client.post(
        "/api/tasks/",
        json={
            "title": "Alex-only task",
            "assignees": [{"assignee_id": adult_a_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )
    # Create task assigned to Morgan only
    await client.post(
        "/api/tasks/",
        json={
            "title": "Morgan-only task",
            "assignees": [{"assignee_id": adult_b_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )

    # Filter for Alex
    resp = await client.get(f"/api/tasks/?assigned_to={adult_a_user['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    titles = [t["title"] for t in data]
    assert "Alex-only task" in titles
    assert "Morgan-only task" not in titles


# ---------------------------------------------------------------------------
# Backwards compat: old assigned_to creates junction row
# ---------------------------------------------------------------------------


async def test_backwards_compat_assigned_to(client, adult_a_headers, adult_a_user):
    """POST with assigned_to (no assignees) creates a junction row."""
    resp = await client.post(
        "/api/tasks/",
        json={"title": "Old-style task", "assigned_to": adult_a_user["id"]},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["assigned_to"] == adult_a_user["id"]
    assert len(data["assignees"]) == 1
    assert data["assignees"][0]["assignee_id"] == adult_a_user["id"]
    assert data["assignees"][0]["assignee_type"] == "user"


# ---------------------------------------------------------------------------
# Overview endpoint
# ---------------------------------------------------------------------------


async def test_overview_endpoint(client, adult_a_headers, adult_a_user, adult_b_user):
    """GET /tasks/overview returns correct per-person counts."""
    # Create a pending task assigned to both
    await client.post(
        "/api/tasks/",
        json={
            "title": "Overview task 1",
            "assignees": [
                {"assignee_id": adult_a_user["id"], "assignee_type": "user"},
                {"assignee_id": adult_b_user["id"], "assignee_type": "user"},
            ],
        },
        headers=adult_a_headers,
    )

    # Create and complete a task for Alex
    create_resp = await client.post(
        "/api/tasks/",
        json={
            "title": "Overview task 2",
            "assignees": [{"assignee_id": adult_a_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )
    task2_id = create_resp.json()["id"]
    await client.patch(f"/api/tasks/{task2_id}/complete/{adult_a_user['id']}", headers=adult_a_headers)

    resp = await client.get("/api/tasks/overview", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()

    adult_a_overview = next(p for p in data if p["person_id"] == adult_a_user["id"])
    adult_b_overview = next(p for p in data if p["person_id"] == adult_b_user["id"])

    # Alex has 1 pending (task1) + 1 completed today (task2)
    assert adult_a_overview["total_pending"] == 1
    assert adult_a_overview["total_completed_today"] == 1

    # Morgan has 1 pending (task1)
    assert adult_b_overview["total_pending"] == 1
    assert adult_b_overview["total_completed_today"] == 0


# ---------------------------------------------------------------------------
# Update assignees replaces previous
# ---------------------------------------------------------------------------


async def test_update_assignees_replaces(client, adult_a_headers, adult_a_user, adult_b_user):
    """PUT with new assignees replaces the old ones."""
    create_resp = await client.post(
        "/api/tasks/",
        json={
            "title": "Reassign me",
            "assignees": [{"assignee_id": adult_a_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]
    assert len(create_resp.json()["assignees"]) == 1

    # Update to Morgan only
    resp = await client.put(
        f"/api/tasks/{task_id}",
        json={
            "assignees": [{"assignee_id": adult_b_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["assignees"]) == 1
    assert data["assignees"][0]["assignee_id"] == adult_b_user["id"]


# ---------------------------------------------------------------------------
# Complete nonexistent assignment → 404
# ---------------------------------------------------------------------------


async def test_complete_nonexistent_assignment(client, adult_a_headers, adult_a_user, adult_b_user):
    """PATCH complete/{assignee_id} for unassigned person returns 404."""
    create_resp = await client.post(
        "/api/tasks/",
        json={
            "title": "Only Alex",
            "assignees": [{"assignee_id": adult_a_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]

    # Try to complete for Morgan (not assigned)
    resp = await client.patch(
        f"/api/tasks/{task_id}/complete/{adult_b_user['id']}",
        headers=adult_a_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["detail"] == "Assignment not found"


# ===========================================================================
# Task Actionability tests (10 tests)
# ===========================================================================


async def test_create_task_with_actionable_from(client, adult_a_headers):
    """POST /api/tasks/ with actionable_from stores it correctly."""
    resp = await client.post(
        "/api/tasks/",
        json={"title": "Future task", "actionable_from": "2099-01-01T18:00:00Z"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    assert resp.json()["actionable_from"] == "2099-01-01T18:00:00Z"


async def test_default_actionable_from_is_null(client, adult_a_headers):
    """Tasks without actionable_from have it as null (always actionable)."""
    resp = await client.post(
        "/api/tasks/",
        json={"title": "Normal task"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    assert resp.json()["actionable_from"] is None


async def test_no_actionable_from_appears_in_now(client, adult_a_headers):
    """Task with no actionable_from appears in ?actionable=now."""
    await client.post("/api/tasks/", json={"title": "Always actionable"}, headers=adult_a_headers)

    resp = await client.get("/api/tasks/?actionable=now", headers=adult_a_headers)
    assert resp.status_code == 200
    titles = [t["title"] for t in resp.json()]
    assert "Always actionable" in titles


async def test_past_actionable_from_appears_in_now(client, adult_a_headers):
    """Task with actionable_from in the past appears in ?actionable=now."""
    await client.post(
        "/api/tasks/",
        json={"title": "Past actionable", "actionable_from": "2020-01-01T00:00:00Z"},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/tasks/?actionable=now", headers=adult_a_headers)
    titles = [t["title"] for t in resp.json()]
    assert "Past actionable" in titles


async def test_future_actionable_from_in_upcoming(client, adult_a_headers):
    """Task with future actionable_from appears in ?actionable=upcoming, NOT in now."""
    await client.post(
        "/api/tasks/",
        json={"title": "Future bins", "actionable_from": "2099-12-31T18:00:00Z"},
        headers=adult_a_headers,
    )

    now_resp = await client.get("/api/tasks/?actionable=now", headers=adult_a_headers)
    now_titles = [t["title"] for t in now_resp.json()]
    assert "Future bins" not in now_titles

    upcoming_resp = await client.get("/api/tasks/?actionable=upcoming", headers=adult_a_headers)
    upcoming_titles = [t["title"] for t in upcoming_resp.json()]
    assert "Future bins" in upcoming_titles


async def test_future_actionable_not_in_now(client, adult_a_headers):
    """Task with future actionable_from does NOT appear in ?actionable=now."""
    await client.post(
        "/api/tasks/",
        json={"title": "Not yet", "actionable_from": "2099-06-01T00:00:00Z"},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/tasks/?actionable=now", headers=adult_a_headers)
    titles = [t["title"] for t in resp.json()]
    assert "Not yet" not in titles


async def test_actionability_filters_normalize_iso_timestamps_from_today(client, adult_a_headers):
    """ISO timestamps from today compare correctly with SQLite's current time."""
    now = datetime.now(timezone.utc).replace(microsecond=0)
    past = (now - timedelta(minutes=2)).isoformat().replace("+00:00", "Z")
    future = (now + timedelta(minutes=2)).isoformat().replace("+00:00", "Z")
    await client.post(
        "/api/tasks/",
        json={"title": "Available moments ago", "actionable_from": past},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/tasks/",
        json={"title": "Available shortly", "actionable_from": future},
        headers=adult_a_headers,
    )

    now_response = await client.get("/api/tasks/?actionable=now", headers=adult_a_headers)
    upcoming_response = await client.get("/api/tasks/?actionable=upcoming", headers=adult_a_headers)

    now_titles = {task["title"] for task in now_response.json()}
    upcoming_titles = {task["title"] for task in upcoming_response.json()}
    assert "Available moments ago" in now_titles
    assert "Available shortly" not in now_titles
    assert "Available shortly" in upcoming_titles
    assert "Available moments ago" not in upcoming_titles


async def test_update_actionable_from(client, adult_a_headers):
    """PUT /api/tasks/{id} can update actionable_from."""
    create_resp = await client.post(
        "/api/tasks/",
        json={"title": "Update test", "actionable_from": "2099-01-01T00:00:00Z"},
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]

    resp = await client.put(
        f"/api/tasks/{task_id}",
        json={"actionable_from": "2020-01-01T00:00:00Z"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["actionable_from"] == "2020-01-01T00:00:00Z"


async def test_overview_counts_only_actionable(client, adult_a_headers, adult_a_user):
    """Overview endpoint counts only currently actionable tasks as pending."""
    # Create actionable task
    await client.post(
        "/api/tasks/",
        json={
            "title": "Actionable now",
            "assignees": [{"assignee_id": adult_a_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )
    # Create future task
    await client.post(
        "/api/tasks/",
        json={
            "title": "Future task",
            "actionable_from": "2099-12-31T00:00:00Z",
            "assignees": [{"assignee_id": adult_a_user["id"], "assignee_type": "user"}],
        },
        headers=adult_a_headers,
    )

    resp = await client.get("/api/tasks/overview", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    adult_a_overview = next(p for p in data if p["person_id"] == adult_a_user["id"])
    # Only the actionable task should count as pending
    assert adult_a_overview["total_pending"] == 1


async def test_completed_tasks_excluded_from_both_filters(client, adult_a_headers):
    """Completed tasks don't appear in actionable=now or upcoming."""
    create_resp = await client.post(
        "/api/tasks/",
        json={"title": "Done task"},
        headers=adult_a_headers,
    )
    task_id = create_resp.json()["id"]
    await client.patch(f"/api/tasks/{task_id}/complete", headers=adult_a_headers)

    now_resp = await client.get("/api/tasks/?actionable=now&status=pending", headers=adult_a_headers)
    now_titles = [t["title"] for t in now_resp.json()]
    assert "Done task" not in now_titles

    upcoming_resp = await client.get("/api/tasks/?actionable=upcoming", headers=adult_a_headers)
    upcoming_titles = [t["title"] for t in upcoming_resp.json()]
    assert "Done task" not in upcoming_titles


async def test_bin_task_gets_actionable_from(client, adult_a_headers, initialized_db):
    """Bin scraper sets actionable_from to 6pm day before due_date."""
    import aiosqlite

    # Manually insert a bin task the way the scraper would
    async with aiosqlite.connect(initialized_db) as db:
        import uuid
        from datetime import datetime, timezone

        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """
            INSERT INTO tasks (id, title, description, due_date, category, priority,
                actionable_from, family_id, created_at, updated_at, created_by)
            VALUES (?, 'Bins', 'black,blue', '2026-02-10', 'bins', 2,
                '2026-02-09T18:00:00Z', ?, ?, ?, 'bin-scraper')
            """,
            (str(uuid.uuid4()), EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()

    resp = await client.get("/api/tasks/?category=bins", headers=adult_a_headers)
    assert resp.status_code == 200
    bins = resp.json()
    assert len(bins) >= 1
    bin_task = next(t for t in bins if t["title"] == "Bins")
    assert bin_task["actionable_from"] == "2026-02-09T18:00:00Z"


async def test_bin_refresh_is_scoped_to_requesting_family(client, other_family_headers):
    response = await client.post(
        "/api/tasks/bins/refresh",
        headers=other_family_headers,
    )

    assert response.status_code == 200

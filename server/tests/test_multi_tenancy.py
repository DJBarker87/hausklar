"""Multi-tenancy isolation tests.

Verifies that data created by Family A is invisible to Family B,
and that the registration/invite flow works correctly.
"""

from conftest import EXAMPLE_FAMILY_ID


# ---------------------------------------------------------------------------
# Data isolation — Family B cannot see Family A's data
# ---------------------------------------------------------------------------


async def test_children_isolation(client, adult_a_headers, other_family_headers, child1):
    """Family B cannot see Family A's children."""
    # Family A sees child1
    r = await client.get("/api/children/", headers=adult_a_headers)
    assert r.status_code == 200
    assert len(r.json()) >= 1

    # Family B sees nothing
    r = await client.get("/api/children/", headers=other_family_headers)
    assert r.status_code == 200
    assert len(r.json()) == 0


async def test_calendar_isolation(client, adult_a_headers, other_family_headers):
    """Family B cannot see Family A's calendar events."""
    # Create an event as Family A
    event = {
        "title": "Family A Event",
        "start_time": "2026-03-01T09:00:00Z",
        "end_time": "2026-03-01T10:00:00Z",
        "all_day": False,
    }
    r = await client.post("/api/calendar/", json=event, headers=adult_a_headers)
    assert r.status_code == 201

    # Family A can list it
    r = await client.get("/api/calendar/?start=2026-03-01T00:00:00Z&end=2026-03-01T23:59:59Z", headers=adult_a_headers)
    assert r.status_code == 200
    assert len(r.json()) >= 1

    # Family B cannot
    r = await client.get("/api/calendar/?start=2026-03-01T00:00:00Z&end=2026-03-01T23:59:59Z", headers=other_family_headers)
    assert r.status_code == 200
    assert len(r.json()) == 0


async def test_tasks_isolation(client, adult_a_headers, other_family_headers):
    """Family B cannot see Family A's tasks."""
    task = {"title": "Family A Task", "category": "admin"}
    r = await client.post("/api/tasks/", json=task, headers=adult_a_headers)
    assert r.status_code == 201
    task_id = r.json()["id"]

    # Family A sees it
    r = await client.get("/api/tasks/", headers=adult_a_headers)
    assert r.status_code == 200
    assert any(t["id"] == task_id for t in r.json())

    # Family B does not
    r = await client.get("/api/tasks/", headers=other_family_headers)
    assert r.status_code == 200
    assert not any(t["id"] == task_id for t in r.json())


async def test_tasks_update_isolation(client, adult_a_headers, other_family_headers):
    """Family B cannot update Family A's task."""
    task = {"title": "Protected Task"}
    r = await client.post("/api/tasks/", json=task, headers=adult_a_headers)
    assert r.status_code == 201
    task_id = r.json()["id"]

    # Family B gets 404 when trying to update
    r = await client.put(f"/api/tasks/{task_id}", json={"title": "Hacked"}, headers=other_family_headers)
    assert r.status_code == 404


async def test_task_cannot_assign_member_from_another_family(
    client,
    adult_a_headers,
    other_family_user,
):
    response = await client.post(
        "/api/tasks/",
        headers=adult_a_headers,
        json={
            "title": "Cross-family assignment",
            "assignees": [
                {
                    "assignee_id": other_family_user["id"],
                    "assignee_type": "user",
                }
            ],
        },
    )

    assert response.status_code == 400
    listed = await client.get("/api/tasks/", headers=adult_a_headers)
    assert all(item["title"] != "Cross-family assignment" for item in listed.json())


async def test_calendar_and_routine_reject_people_from_another_family(
    client,
    adult_a_headers,
    other_family_user,
):
    calendar = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "Cross-family event",
            "start_time": "2026-08-01T10:00:00Z",
            "assigned_to": other_family_user["id"],
        },
    )
    routine = await client.post(
        "/api/routines/items",
        headers=adult_a_headers,
        json={
            "person_id": other_family_user["id"],
            "name": "Cross-family routine",
            "color": "#336699",
            "days_of_week": [1],
        },
    )

    assert calendar.status_code == 400
    assert routine.status_code == 400


async def test_birthdays_isolation(client, adult_a_headers, other_family_headers):
    """Family B cannot see Family A's birthdays."""
    bday = {
        "person_name": "Uncle Bob",
        "date_of_birth": "1970-05-15",
        "relationship": "family",
    }
    r = await client.post("/api/birthdays/", json=bday, headers=adult_a_headers)
    assert r.status_code == 201

    # Family B sees nothing
    r = await client.get("/api/birthdays/", headers=other_family_headers)
    assert r.status_code == 200
    assert len(r.json()) == 0


async def test_dog_isolation(client, adult_a_headers, other_family_headers):
    """Family B cannot see Family A's dog activities."""
    activity = {
        "activity_type": "walk",
        "started_at": "2026-03-01T08:00:00Z",
    }
    r = await client.post("/api/dog/activities", json=activity, headers=adult_a_headers)
    assert r.status_code == 201

    # Family B sees nothing
    r = await client.get("/api/dog/activities", headers=other_family_headers)
    assert r.status_code == 200
    assert len(r.json()) == 0


async def test_medicine_isolation(client, adult_a_headers, other_family_headers, child1):
    """Family B cannot see Family A's medicine types."""
    med = {
        "name": "Family A Calpol",
        "child_id": child1["id"],
        "min_hours_between_doses": 4,
        "max_doses_24h": 4,
        "color": "#FF0000",
    }
    r = await client.post("/api/medicine/types", json=med, headers=adult_a_headers)
    assert r.status_code == 201

    # Family B sees nothing for this child (and also can't access the child)
    r = await client.get(f"/api/medicine/types?child_id={child1['id']}", headers=other_family_headers)
    assert r.status_code == 200
    assert len(r.json()) == 0


async def test_sync_pull_isolation(client, adult_a_headers, other_family_headers):
    """Sync pull only returns data from the requesting user's family."""
    # Create a task in Family A
    r = await client.post("/api/tasks/", json={"title": "Sync Test"}, headers=adult_a_headers)
    assert r.status_code == 201

    # Family A can pull it
    r = await client.get("/api/sync/pull?since=2020-01-01T00:00:00Z", headers=adult_a_headers)
    assert r.status_code == 200
    assert len(r.json()["records"]) >= 1

    # Family B pull returns nothing
    r = await client.get("/api/sync/pull?since=2020-01-01T00:00:00Z", headers=other_family_headers)
    assert r.status_code == 200
    assert len(r.json()["records"]) == 0


# ---------------------------------------------------------------------------
# Registration and invite flow
# ---------------------------------------------------------------------------


async def test_register_family(client):
    """POST /auth/register-family creates a new family + admin user."""
    body = {
        "family_name": "New Family",
        "user_name": "Alice",
        "email": "demo-person-45@example.invalid",
        "password": "secure-password-123",
    }
    r = await client.post("/api/auth/register-family", json=body)
    assert r.status_code == 200
    data = r.json()
    assert "access_token" in data
    assert "refresh_token" in data
    assert data["user"]["name"] == "Alice"
    assert data["user"]["role"] == "admin"
    assert data["user"]["family_id"] is not None


async def test_register_duplicate_email(client, adult_a_user):
    """Cannot register with an email already in use."""
    body = {
        "family_name": "Dup Family",
        "user_name": "Alex2",
        "email": "demo-person-51@example.invalid",
        "password": "secure-password-123",
    }
    r = await client.post("/api/auth/register-family", json=body)
    assert r.status_code == 409


async def test_invite_and_join_flow(client, adult_a_headers, adult_a_user):
    """Full flow: admin generates invite code, new user joins with it."""
    # Generate invite
    r = await client.post("/api/auth/invite", headers=adult_a_headers)
    assert r.status_code == 200
    invite_code = r.json()["invite_code"]
    assert len(invite_code) == 8

    # Join with invite code
    body = {
        "invite_code": invite_code,
        "user_name": "Bob",
        "email": "demo-person-50@example.invalid",
        "password": "secure-password-123",
    }
    r = await client.post("/api/auth/join-family", json=body)
    assert r.status_code == 200
    data = r.json()
    assert data["user"]["name"] == "Bob"
    assert data["user"]["family_id"] == adult_a_user["family_id"]
    assert data["user"]["role"] == "user"


async def test_invite_requires_admin(client, adult_b_headers):
    """Non-admin users cannot generate invite codes."""
    r = await client.post("/api/auth/invite", headers=adult_b_headers)
    assert r.status_code == 403


async def test_join_invalid_invite(client):
    """Joining with a bogus invite code returns 404."""
    body = {
        "invite_code": "BOGUS123",
        "user_name": "Charlie",
        "email": "demo-person-37@example.invalid",
        "password": "secure-password-123",
    }
    r = await client.post("/api/auth/join-family", json=body)
    assert r.status_code == 404


async def test_login_includes_family_id(client, adult_a_user):
    """Login response includes family_id."""
    r = await client.post("/api/auth/login", json={
        "email": "demo-person-51@example.invalid",
        "password": "password123",
    })
    assert r.status_code == 200
    assert r.json()["user"]["family_id"] == EXAMPLE_FAMILY_ID


async def test_me_includes_family_id(client, adult_a_headers):
    """GET /auth/me returns family_id."""
    r = await client.get("/api/auth/me", headers=adult_a_headers)
    assert r.status_code == 200
    assert r.json()["family_id"] == EXAMPLE_FAMILY_ID

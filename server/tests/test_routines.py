"""Tests for the routines router (/api/routines)."""

from datetime import datetime, timedelta, timezone

import aiosqlite

from app.services.term_scraper import update_term_dates


# ---------------------------------------------------------------------------
# Routine Items CRUD
# ---------------------------------------------------------------------------


async def test_create_routine_item(client, adult_a_user, adult_a_headers):
    """POST /api/routines/items creates a new routine item."""
    payload = {
        "person_id": adult_a_user["id"],
        "name": "PE",
        "color": "#FF6B6B",
        "days_of_week": [0, 2, 4],
        "sort_order": 1,
    }
    resp = await client.post("/api/routines/items", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["name"] == "PE"
    assert data["color"] == "#FF6B6B"
    assert data["days_of_week"] == [0, 2, 4]
    assert data["sort_order"] == 1
    assert data["person_id"] == adult_a_user["id"]
    assert data["created_by"] == adult_a_user["id"]
    assert "id" in data
    assert "created_at" in data


async def test_routine_item_keeps_practical_week_context_and_packing_link(
    client, adult_a_user, child1, adult_a_headers
):
    template = await client.post(
        "/api/prep-packs/templates",
        json={
            "name": "Swimming bag",
            "match_terms": ["swimming"],
            "items": ["Goggles", "Towel"],
            "lead_hours": 12,
            "assigned_to": adult_a_user["id"],
        },
        headers=adult_a_headers,
    )
    assert template.status_code == 201, template.text

    response = await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "Swimming",
            "color": "#45B7D1",
            "days_of_week": [0],
            "time_of_day": "16:30",
            "location": "Leisure centre",
            "preparation_note": "Costume under uniform",
            "prep_template_id": template.json()["id"],
            "reminder_minutes": 45,
            "calendar_projection": True,
            "term_only": False,
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 201, response.text
    expected = {
        "time_of_day": "16:30",
        "location": "Leisure centre",
        "preparation_note": "Costume under uniform",
        "prep_template_id": template.json()["id"],
        "reminder_minutes": 45,
        "calendar_projection": True,
        "term_only": False,
    }
    assert {key: response.json()[key] for key in expected} == expected

    past_term = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "Past term",
            "start_date": "2025-01-01",
            "end_date": "2025-01-31",
        },
        headers=adult_a_headers,
    )
    assert past_term.status_code == 201

    active = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-09"},
        headers=adult_a_headers,
    )
    assert active.status_code == 200
    assert active.json()[0]["time_of_day"] == "16:30"
    assert active.json()[0]["location"] == "Leisure centre"
    assert active.json()[0]["prep_template_id"] == template.json()["id"]

    hidden = await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "Private household rhythm",
            "color": "#546E7A",
            "days_of_week": [0],
            "calendar_projection": False,
            "term_only": False,
        },
        headers=adult_a_headers,
    )
    assert hidden.status_code == 201
    refreshed = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-09"},
        headers=adult_a_headers,
    )
    assert [item["name"] for item in refreshed.json()] == ["Swimming"]


async def test_duplicate_routine_to_sibling_keeps_week_context(
    client, adult_a_user, child1, adult_a_headers
):
    created = await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "Football",
            "color": "#6BCB77",
            "days_of_week": [5],
            "time_of_day": "09:15",
            "location": "Playing fields",
            "calendar_projection": True,
            "term_only": False,
        },
        headers=adult_a_headers,
    )
    duplicate = await client.post(
        f"/api/routines/items/{created.json()['id']}/duplicate",
        json={"target_person_id": adult_a_user["id"]},
        headers=adult_a_headers,
    )

    assert duplicate.status_code == 201, duplicate.text
    assert duplicate.json()["person_id"] == adult_a_user["id"]
    assert duplicate.json()["name"] == "Football"
    assert duplicate.json()["days_of_week"] == [5]
    assert duplicate.json()["time_of_day"] == "09:15"
    assert duplicate.json()["location"] == "Playing fields"


async def test_list_routine_items(client, adult_a_user, adult_a_headers):
    """GET /api/routines/items returns created items."""
    payload = {
        "person_id": adult_a_user["id"],
        "name": "Swimming",
        "color": "#45B7D1",
        "days_of_week": [1, 3],
    }
    await client.post("/api/routines/items", json=payload, headers=adult_a_headers)

    resp = await client.get("/api/routines/items", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 1
    names = [item["name"] for item in data]
    assert "Swimming" in names


async def test_list_routine_items_filter_by_person(client, adult_a_user, adult_a_headers, child1):
    """GET /api/routines/items?person_id= filters by person."""
    # Create item for dom
    await client.post(
        "/api/routines/items",
        json={
            "person_id": adult_a_user["id"],
            "name": "Alex Item",
            "color": "#FF6B6B",
            "days_of_week": [0],
        },
        headers=adult_a_headers,
    )
    # Create item for child
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "Child Item",
            "color": "#45B7D1",
            "days_of_week": [1],
        },
        headers=adult_a_headers,
    )

    # Filter for child only
    resp = await client.get(
        "/api/routines/items",
        params={"person_id": child1["id"]},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    names = [item["name"] for item in data]
    assert "Child Item" in names
    assert "Alex Item" not in names


async def test_update_routine_item(client, adult_a_user, adult_a_headers):
    """PUT /api/routines/items{id} updates an item."""
    create_resp = await client.post(
        "/api/routines/items",
        json={
            "person_id": adult_a_user["id"],
            "name": "Original",
            "color": "#FF6B6B",
            "days_of_week": [0],
        },
        headers=adult_a_headers,
    )
    item_id = create_resp.json()["id"]

    update_resp = await client.put(
        f"/api/routines/items/{item_id}",
        json={"name": "Updated", "color": "#45B7D1"},
        headers=adult_a_headers,
    )
    assert update_resp.status_code == 200
    data = update_resp.json()
    assert data["name"] == "Updated"
    assert data["color"] == "#45B7D1"
    assert data["days_of_week"] == [0]  # unchanged


async def test_update_routine_item_days(client, adult_a_user, adult_a_headers):
    """PUT /api/routines/items{id} can update days_of_week."""
    create_resp = await client.post(
        "/api/routines/items",
        json={
            "person_id": adult_a_user["id"],
            "name": "Test",
            "color": "#FF6B6B",
            "days_of_week": [0, 1],
        },
        headers=adult_a_headers,
    )
    item_id = create_resp.json()["id"]

    update_resp = await client.put(
        f"/api/routines/items/{item_id}",
        json={"days_of_week": [2, 3, 4]},
        headers=adult_a_headers,
    )
    assert update_resp.status_code == 200
    assert update_resp.json()["days_of_week"] == [2, 3, 4]


async def test_delete_routine_item(client, adult_a_user, adult_a_headers):
    """DELETE /api/routines/items{id} soft-deletes the item (204)."""
    create_resp = await client.post(
        "/api/routines/items",
        json={
            "person_id": adult_a_user["id"],
            "name": "To Delete",
            "color": "#FF6B6B",
            "days_of_week": [0],
        },
        headers=adult_a_headers,
    )
    item_id = create_resp.json()["id"]

    del_resp = await client.delete(f"/api/routines/items/{item_id}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    list_resp = await client.get("/api/routines/items", headers=adult_a_headers)
    ids = [item["id"] for item in list_resp.json()]
    assert item_id not in ids


async def test_update_nonexistent_item(client, adult_a_user, adult_a_headers):
    """PUT /api/routines/items{id} returns 404 for nonexistent item."""
    resp = await client.put(
        "/api/routines/itemsnonexistent",
        json={"name": "Test"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 404


async def test_delete_nonexistent_item(client, adult_a_user, adult_a_headers):
    """DELETE /api/routines/items{id} returns 404 for nonexistent item."""
    resp = await client.delete("/api/routines/itemsnonexistent", headers=adult_a_headers)
    assert resp.status_code == 404


async def test_create_item_no_auth(client):
    """POST /api/routines/items without auth returns 401 or 403."""
    payload = {
        "person_id": "some-id",
        "name": "Test",
        "color": "#FF6B6B",
        "days_of_week": [0],
    }
    resp = await client.post("/api/routines/items", json=payload)
    assert resp.status_code in (401, 403)


# ---------------------------------------------------------------------------
# Term Dates CRUD
# ---------------------------------------------------------------------------


async def test_create_term_date(client, adult_a_user, adult_a_headers, child1):
    """POST /api/routines/terms creates a new term date."""
    payload = {
        "person_id": child1["id"],
        "label": "Spring Term 2026",
        "start_date": "2026-01-06",
        "end_date": "2026-04-01",
    }
    resp = await client.post("/api/routines/terms", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["label"] == "Spring Term 2026"
    assert data["start_date"] == "2026-01-06"
    assert data["end_date"] == "2026-04-01"
    assert data["person_id"] == child1["id"]


async def test_list_term_dates(client, adult_a_user, adult_a_headers, child1):
    """GET /api/routines/terms returns term dates."""
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )

    resp = await client.get("/api/routines/terms", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 1


async def test_list_term_dates_filter_by_person(client, adult_a_user, adult_a_headers, child1):
    """GET /api/routines/terms?person_id= filters by person."""
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "Child Term",
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": adult_a_user["id"],
            "label": "Alex Term",
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/terms",
        params={"person_id": child1["id"]},
        headers=adult_a_headers,
    )
    data = resp.json()
    labels = [t["label"] for t in data]
    assert "Child Term" in labels
    assert "Alex Term" not in labels


async def test_update_term_date(client, adult_a_user, adult_a_headers, child1):
    """PUT /api/routines/terms{id} updates a term date."""
    create_resp = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "Old Label",
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )
    term_id = create_resp.json()["id"]

    update_resp = await client.put(
        f"/api/routines/terms/{term_id}",
        json={"label": "New Label", "end_date": "2026-04-10"},
        headers=adult_a_headers,
    )
    assert update_resp.status_code == 200
    data = update_resp.json()
    assert data["label"] == "New Label"
    assert data["end_date"] == "2026-04-10"
    assert data["start_date"] == "2026-01-06"  # unchanged


async def test_editing_imported_term_dates_survives_a_later_refresh(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await update_term_dates(
            db,
            "primary_school",
            [
                {
                    "label": "Imported Autumn",
                    "start_date": "2026-09-03",
                    "end_date": "2026-10-23",
                }
            ],
            family_id=adult_a_user["family_id"],
        )
        imported = await (
            await db.execute(
                """
                SELECT id FROM term_dates
                WHERE person_id = ? AND created_by = 'term-scraper'
                  AND deleted_at IS NULL
                """,
                (child1["id"],),
            )
        ).fetchone()

    edited = await client.put(
        f"/api/routines/terms/{imported['id']}",
        json={
            "label": "Child One’s actual first half",
            "start_date": "2026-09-07",
            "end_date": "2026-10-22",
        },
        headers=adult_a_headers,
    )
    assert edited.status_code == 200
    assert edited.json()["is_imported"] is True
    assert edited.json()["is_overridden"] is True

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await update_term_dates(
            db,
            "primary_school",
            [
                {
                    "label": "Imported Autumn refreshed",
                    "start_date": "2026-09-03",
                    "end_date": "2026-10-23",
                }
            ],
            family_id=adult_a_user["family_id"],
        )
        active = await (
            await db.execute(
                """
                SELECT id, label, start_date, end_date, user_overridden
                FROM term_dates
                WHERE person_id = ? AND deleted_at IS NULL
                """,
                (child1["id"],),
            )
        ).fetchall()

    assert [tuple(row) for row in active] == [
        (
            imported["id"],
            "Child One’s actual first half",
            "2026-09-07",
            "2026-10-22",
            1,
        )
    ]


async def test_delete_term_date(client, adult_a_user, adult_a_headers, child1):
    """DELETE /api/routines/terms{id} soft-deletes (204)."""
    create_resp = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )
    term_id = create_resp.json()["id"]

    del_resp = await client.delete(f"/api/routines/terms/{term_id}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    list_resp = await client.get("/api/routines/terms", headers=adult_a_headers)
    ids = [t["id"] for t in list_resp.json()]
    assert term_id not in ids


async def test_term_date_creates_read_only_calendar_boundaries(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    response = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "Spring Term 2026",
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 201
    term_id = response.json()["id"]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                """
                SELECT * FROM calendar_events
                WHERE source_term_date_id = ? AND deleted_at IS NULL
                ORDER BY start_time
                """,
                (term_id,),
            )
        ).fetchall()

    assert [(row["term_boundary"], row["start_time"], row["end_time"]) for row in rows] == [
        ("first", "2026-01-06", "2026-01-07"),
        ("last", "2026-04-01", "2026-04-02"),
    ]
    assert all(row["assigned_to"] == child1["id"] for row in rows)
    assert all(row["all_day"] == 1 and row["read_only"] == 1 for row in rows)
    assert {row["title"] for row in rows} == {
        "Child 1 — First day of Spring Term 2026",
        "Child 1 — Last day of Spring Term 2026",
    }

    for boundary_date, expected_boundary in (
        ("2026-01-06", "first"),
        ("2026-04-01", "last"),
    ):
        listed = await client.get(
            "/api/calendar/",
            params={"start": boundary_date, "end": boundary_date, "limit": 200},
            headers=adult_a_headers,
        )
        assert listed.status_code == 200
        matching = [event for event in listed.json() if event["id"] in {row["id"] for row in rows}]
        assert len(matching) == 1
        assert expected_boundary in {
            row["term_boundary"] for row in rows if row["id"] == matching[0]["id"]
        }
        assert matching[0]["read_only"] is True


async def test_term_update_reconciles_boundaries_idempotently(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    created = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "Old Term",
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )
    term_id = created.json()["id"]

    async with aiosqlite.connect(initialized_db) as db:
        original_ids = dict(
            await (
                await db.execute(
                    """
                    SELECT term_boundary, id FROM calendar_events
                    WHERE source_term_date_id = ? AND deleted_at IS NULL
                    """,
                    (term_id,),
                )
            ).fetchall()
        )

    updated = await client.put(
        f"/api/routines/terms/{term_id}",
        json={
            "label": "New Term",
            "start_date": "2026-01-07",
            "end_date": "2026-04-02",
        },
        headers=adult_a_headers,
    )
    assert updated.status_code == 200
    retried = await client.put(
        f"/api/routines/terms/{term_id}",
        json={},
        headers=adult_a_headers,
    )
    assert retried.status_code == 200

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                """
                SELECT * FROM calendar_events
                WHERE source_term_date_id = ? AND deleted_at IS NULL
                ORDER BY term_boundary
                """,
                (term_id,),
            )
        ).fetchall()
        event_history_count = (
            await (
                await db.execute(
                    """
                    SELECT COUNT(*) FROM record_history
                    WHERE table_name = 'calendar_events'
                      AND record_id IN (?, ?)
                    """,
                    tuple(original_ids.values()),
                )
            ).fetchone()
        )[0]

    assert len(rows) == 2
    assert {row["term_boundary"]: row["id"] for row in rows} == original_ids
    assert {row["start_time"] for row in rows} == {"2026-01-07", "2026-04-02"}
    assert all("New Term" in row["title"] for row in rows)
    assert event_history_count == 2


async def test_term_delete_removes_only_generated_calendar_events(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    manual = await client.post(
        "/api/calendar/",
        json={
            "title": "Manual school event",
            "start_time": "2026-01-06",
            "all_day": True,
            "assigned_to": child1["id"],
        },
        headers=adult_a_headers,
    )
    assert manual.status_code == 201
    created = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )
    term_id = created.json()["id"]

    async with aiosqlite.connect(initialized_db) as db:
        source_event_id = (
            await (
                await db.execute(
                    """
                    SELECT id FROM calendar_events
                    WHERE source_term_date_id = ? AND term_boundary = 'first'
                    """,
                    (term_id,),
                )
            ).fetchone()
        )[0]
    edited = await client.put(
        f"/api/calendar/{source_event_id}",
        json={"title": "Corrected first day"},
        headers=adult_a_headers,
    )
    assert edited.status_code == 200
    override_id = edited.json()["id"]

    deleted = await client.delete(f"/api/routines/terms/{term_id}", headers=adult_a_headers)
    assert deleted.status_code == 204

    async with aiosqlite.connect(initialized_db) as db:
        generated = await (
            await db.execute(
                "SELECT deleted_at FROM calendar_events WHERE source_term_date_id = ?",
                (term_id,),
            )
        ).fetchall()
        manual_deleted_at = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM calendar_events WHERE id = ?",
                    (manual.json()["id"],),
                )
            ).fetchone()
        )[0]
        override_deleted_at = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM calendar_events WHERE id = ?",
                    (override_id,),
                )
            ).fetchone()
        )[0]

    assert len(generated) == 2
    assert all(row[0] is not None for row in generated)
    assert manual_deleted_at is None
    assert override_deleted_at is not None


async def test_one_day_term_creates_one_combined_boundary(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    created = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "One-day term",
            "start_date": "2026-09-01",
            "end_date": "2026-09-01",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201

    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                """
                SELECT term_boundary, title FROM calendar_events
                WHERE source_term_date_id = ? AND deleted_at IS NULL
                """,
                (created.json()["id"],),
            )
        ).fetchall()

    assert rows == [("first_last", "Child 1 — First and last day of One-day term")]


async def test_manual_term_create_suppresses_overlapping_scraped_term_and_events(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    initialized_db,
):
    family_id = adult_a_user["family_id"]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await update_term_dates(
            db,
            "primary_school",
            [
                {
                    "label": "Auto Autumn",
                    "start_date": "2026-09-03",
                    "end_date": "2026-10-23",
                }
            ],
            family_id=family_id,
        )
        auto_term = await (
            await db.execute(
                """
                SELECT id FROM term_dates
                WHERE person_id = ? AND created_by = 'term-scraper'
                  AND deleted_at IS NULL
                """,
                (child1["id"],),
            )
        ).fetchone()

    created = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "Manual Autumn",
            "start_date": "2026-09-01",
            "end_date": "2026-10-24",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201

    async with aiosqlite.connect(initialized_db) as db:
        auto_deleted = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM term_dates WHERE id = ?",
                    (auto_term["id"],),
                )
            ).fetchone()
        )[0]
        auto_events = await (
            await db.execute(
                """
                SELECT deleted_at FROM calendar_events
                WHERE source_term_date_id = ?
                """,
                (auto_term["id"],),
            )
        ).fetchall()
        history_actor = (
            await (
                await db.execute(
                    """
                    SELECT changed_by FROM record_history
                    WHERE table_name = 'term_dates' AND record_id = ?
                    ORDER BY changed_at DESC LIMIT 1
                    """,
                    (auto_term["id"],),
                )
            ).fetchone()
        )[0]

    assert auto_deleted is not None
    assert len(auto_events) == 2
    assert all(row[0] is not None for row in auto_events)
    assert history_actor == adult_a_user["id"]


async def test_manual_term_update_suppresses_newly_overlapping_scraped_term(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    initialized_db,
):
    created = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "label": "Manual Spring",
            "start_date": "2027-01-04",
            "end_date": "2027-02-11",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await update_term_dates(
            db,
            "primary_school",
            [
                {
                    "label": "Auto Autumn",
                    "start_date": "2026-09-03",
                    "end_date": "2026-10-23",
                }
            ],
            family_id=adult_a_user["family_id"],
        )
        auto_term = await (
            await db.execute(
                """
                SELECT id FROM term_dates
                WHERE person_id = ? AND created_by = 'term-scraper'
                  AND deleted_at IS NULL
                """,
                (child1["id"],),
            )
        ).fetchone()

    updated = await client.put(
        f"/api/routines/terms/{created.json()['id']}",
        json={"start_date": "2026-09-01", "end_date": "2026-10-24"},
        headers=adult_a_headers,
    )
    assert updated.status_code == 200

    async with aiosqlite.connect(initialized_db) as db:
        auto_deleted = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM term_dates WHERE id = ?",
                    (auto_term["id"],),
                )
            ).fetchone()
        )[0]
        active_boundaries = (
            await (
                await db.execute(
                    """
                    SELECT COUNT(*) FROM calendar_events
                    WHERE source_term_date_id = ? AND deleted_at IS NULL
                    """,
                    (auto_term["id"],),
                )
            ).fetchone()
        )[0]

    assert auto_deleted is not None
    assert active_boundaries == 0


async def test_term_dates_reject_invalid_or_reversed_ranges(
    client,
    adult_a_headers,
    child1,
):
    invalid = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "06/01/2026",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )
    assert invalid.status_code == 422

    reversed_range = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-04-01",
            "end_date": "2026-01-06",
        },
        headers=adult_a_headers,
    )
    assert reversed_range.status_code == 422

    created = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-01-06",
            "end_date": "2026-04-01",
        },
        headers=adult_a_headers,
    )
    update = await client.put(
        f"/api/routines/terms/{created.json()['id']}",
        json={"end_date": "2026-01-05"},
        headers=adult_a_headers,
    )
    assert update.status_code == 400


# ---------------------------------------------------------------------------
# Term Override
# ---------------------------------------------------------------------------


async def test_override_default_auto(client, adult_a_user, adult_a_headers, child1):
    """GET /api/routines/override/{person_id} returns auto by default."""
    resp = await client.get(f"/api/routines/override/{child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["mode"] == "auto"
    assert data["person_id"] == child1["id"]


async def test_set_override_force_on(client, adult_a_user, adult_a_headers, child1):
    """PUT /api/routines/override/{person_id} sets force_on."""
    resp = await client.put(
        f"/api/routines/override/{child1['id']}",
        json={"is_active": True},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["mode"] == "force_on"


async def test_set_override_force_off(client, adult_a_user, adult_a_headers, child1):
    """PUT /api/routines/override/{person_id} sets force_off."""
    resp = await client.put(
        f"/api/routines/override/{child1['id']}",
        json={"is_active": False},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["mode"] == "force_off"


async def test_term_override_has_an_explicit_expiry(client, adult_a_headers, child1):
    saved = await client.put(
        f"/api/routines/override/{child1['id']}",
        json={"is_active": False, "expires_on": "2020-01-02"},
        headers=adult_a_headers,
    )
    assert saved.status_code == 200
    assert saved.json()["expires_on"] == "2020-01-02"

    current = await client.get(
        f"/api/routines/override/{child1['id']}", headers=adult_a_headers
    )
    assert current.status_code == 200
    assert current.json() == {
        "person_id": child1["id"],
        "mode": "auto",
        "expires_on": None,
    }


async def test_update_existing_override(client, adult_a_user, adult_a_headers, child1):
    """PUT /api/routines/override/{person_id} updates existing override."""
    await client.put(
        f"/api/routines/override/{child1['id']}",
        json={"is_active": True},
        headers=adult_a_headers,
    )
    resp = await client.put(
        f"/api/routines/override/{child1['id']}",
        json={"is_active": False},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["mode"] == "force_off"


async def test_delete_override(client, adult_a_user, adult_a_headers, child1):
    """DELETE /api/routines/override/{person_id} removes override (204)."""
    await client.put(
        f"/api/routines/override/{child1['id']}",
        json={"is_active": True},
        headers=adult_a_headers,
    )
    del_resp = await client.delete(f"/api/routines/override/{child1['id']}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    get_resp = await client.get(f"/api/routines/override/{child1['id']}", headers=adult_a_headers)
    assert get_resp.json()["mode"] == "auto"


async def test_delete_nonexistent_override(client, adult_a_user, adult_a_headers, child1):
    """DELETE /api/routines/override/{person_id} returns 404 when no override."""
    resp = await client.delete(f"/api/routines/override/{child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Active Routines
# ---------------------------------------------------------------------------


async def test_active_routines_no_items(client, adult_a_user, adult_a_headers):
    """GET /api/routines/active with no items returns empty list."""
    resp = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-15"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json() == []


# ---------------------------------------------------------------------------
# Term-time handoffs
# ---------------------------------------------------------------------------


async def test_handoffs_project_term_defaults_and_daily_changes(
    client,
    adult_a_user,
    adult_b_user,
    child1,
    adult_a_headers,
    initialized_db,
):
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-02-09",
            "end_date": "2026-02-13",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": adult_a_user["id"],
            "start_date": "2026-02-09",
            "end_date": "2026-02-13",
        },
        headers=adult_a_headers,
    )
    saved = await client.put(
        "/api/routines/handoffs/schedule",
        json={
            "client_timestamp": "2026-02-01T10:00:00Z",
            "items": [
                {
                    "kind": "pickup",
                    "weekday": weekday,
                    "time_of_day": "15:20",
                    "term_person_id": child1["id"],
                }
                for weekday in range(5)
            ]
            + [
                {
                    "kind": "work_departure",
                    "weekday": weekday,
                    "time_of_day": "17:05",
                    "term_person_id": adult_a_user["id"],
                    "owner_user_id": adult_a_user["id"],
                }
                for weekday in range(5)
            ],
        },
        headers=adult_a_headers,
    )
    assert saved.status_code == 200
    assert len(saved.json()["items"]) == 10
    saved_pickup = next(
        item for item in saved.json()["items"] if item["kind"] == "pickup"
    )
    assert saved_pickup["owner_user_id"] == child1["id"]
    async with aiosqlite.connect(initialized_db) as db:
        stored = await (
            await db.execute(
                "SELECT kind, owner_user_id FROM term_time_handoffs "
                "WHERE family_id = ? AND deleted_at IS NULL ORDER BY kind",
                (adult_a_user["family_id"],),
            )
        ).fetchall()
    assert all(owner_id is None for kind, owner_id in stored if kind == "pickup")
    assert all(owner_id == adult_a_user["id"] for kind, owner_id in stored if kind == "work_departure")

    projected = await client.get(
        "/api/routines/handoffs",
        params={"start": "2026-02-09", "end": "2026-02-16"},
        headers=adult_a_headers,
    )
    assert projected.status_code == 200
    assert len(projected.json()) == 10
    monday_pickup = next(
        item
        for item in projected.json()
        if item["date"] == "2026-02-09" and item["kind"] == "pickup"
    )
    assert monday_pickup["label"] == f"{child1['name']} pickup"
    assert monday_pickup["term_person_name"] == child1["name"]
    assert monday_pickup["owner_user_id"] == child1["id"]
    assert monday_pickup["owner_name"] == child1["name"]
    monday_work = next(
        item
        for item in projected.json()
        if item["date"] == "2026-02-09" and item["kind"] == "work_departure"
    )
    wrong_work_person = await client.put(
        f"/api/routines/handoffs/{monday_work['handoff_id']}/dates/2026-02-09",
        json={
            "time_of_day": "17:15",
            "owner_user_id": adult_b_user["id"],
            "client_timestamp": "2026-02-09T07:59:00Z",
        },
        headers=adult_a_headers,
    )
    assert wrong_work_person.status_code == 422
    assert not any(item["date"] == "2026-02-16" for item in projected.json())

    changed = await client.put(
        f"/api/routines/handoffs/{monday_pickup['handoff_id']}/dates/2026-02-09",
        json={
            "time_of_day": "15:45",
            "client_timestamp": "2026-02-09T08:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert changed.status_code == 200
    assert changed.json()["time_of_day"] == "15:45"
    assert changed.json()["label"] == f"{child1['name']} pickup"
    assert changed.json()["owner_user_id"] == child1["id"]
    assert changed.json()["is_override"] is True
    async with aiosqlite.connect(initialized_db) as db:
        override_owner = await (
            await db.execute(
                "SELECT owner_user_id FROM term_time_handoff_overrides "
                "WHERE handoff_id = ? AND deleted_at IS NULL",
                (monday_pickup["handoff_id"],),
            )
        ).fetchone()
    assert override_owner[0] is None

    cancelled = await client.put(
        f"/api/routines/handoffs/{monday_pickup['handoff_id']}/dates/2026-02-09",
        json={
            "time_of_day": "15:45",
            "is_cancelled": True,
            "client_timestamp": "2026-02-09T08:01:00Z",
        },
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 200
    assert cancelled.json() is None


async def test_handoff_schedule_applies_kat_wins_conflict_rule(
    client,
    adult_a_user,
    adult_b_user,
    child1,
    adult_a_headers,
    adult_b_headers,
):
    def body(time: str, timestamp: str):
        return {
            "client_timestamp": timestamp,
            "items": [
                {
                    "kind": "pickup",
                    "weekday": 0,
                    "time_of_day": time,
                    "term_person_id": child1["id"],
                }
            ],
        }

    assert (
        await client.put(
            "/api/routines/handoffs/schedule",
            json=body("15:20", "2026-02-01T10:00:00Z"),
            headers=adult_a_headers,
        )
    ).status_code == 200
    adult_b_change = await client.put(
        "/api/routines/handoffs/schedule",
        json=body("15:30", "2026-02-01T10:01:00Z"),
        headers=adult_b_headers,
    )
    assert adult_b_change.json()["items"][0]["time_of_day"] == "15:30"

    adult_a_conflict = await client.put(
        "/api/routines/handoffs/schedule",
        json=body("15:40", "2026-02-01T10:02:00Z"),
        headers=adult_a_headers,
    )
    assert adult_a_conflict.status_code == 200
    assert adult_a_conflict.json()["items"][0]["time_of_day"] == "15:30"


async def test_handoff_daily_change_and_restore_respect_kat_wins(
    client,
    adult_a_user,
    adult_b_user,
    child1,
    adult_a_headers,
    adult_b_headers,
):
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-02-09",
            "end_date": "2026-02-09",
        },
        headers=adult_a_headers,
    )
    schedule = await client.put(
        "/api/routines/handoffs/schedule",
        json={
            "items": [{
                "kind": "pickup",
                "weekday": 0,
                "time_of_day": "15:20",
                "term_person_id": child1["id"],
            }],
        },
        headers=adult_a_headers,
    )
    handoff_id = schedule.json()["items"][0]["id"]
    adult_b_time = datetime.now(timezone.utc)
    adult_b_change = await client.put(
        f"/api/routines/handoffs/{handoff_id}/dates/2026-02-09",
        json={
            "time_of_day": "15:30",
            "client_timestamp": adult_b_time.isoformat(),
        },
        headers=adult_b_headers,
    )
    assert adult_b_change.json()["time_of_day"] == "15:30"

    adult_a_change = await client.put(
        f"/api/routines/handoffs/{handoff_id}/dates/2026-02-09",
        json={
            "time_of_day": "15:45",
            "client_timestamp": (adult_b_time + timedelta(minutes=1)).isoformat(),
        },
        headers=adult_a_headers,
    )
    assert adult_a_change.json()["time_of_day"] == "15:30"

    restore = await client.delete(
        f"/api/routines/handoffs/{handoff_id}/dates/2026-02-09",
        headers=adult_a_headers,
    )
    assert restore.status_code == 200
    assert restore.json()["time_of_day"] == "15:30"
    assert restore.json()["is_override"] is True


async def test_handoff_discards_legacy_pickup_owner_assignment(
    client,
    child1,
    adult_a_user,
    adult_a_headers,
    other_family_user,
    initialized_db,
):
    response = await client.put(
        "/api/routines/handoffs/schedule",
        json={
            "items": [
                {
                    "kind": "pickup",
                    "weekday": 0,
                    "time_of_day": "15:20",
                    "term_person_id": child1["id"],
                    # Older clients still send this. Even an invalid adult is
                    # ignored because pickup responsibility is not modelled.
                    "owner_user_id": other_family_user["id"],
                }
            ]
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    assert response.json()["items"][0]["owner_user_id"] == child1["id"]
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT owner_user_id FROM term_time_handoffs "
                "WHERE family_id = ? AND kind = 'pickup' AND deleted_at IS NULL",
                (adult_a_user["family_id"],),
            )
        ).fetchone()
    assert row[0] is None


async def test_handoff_rejects_other_family_term_person(
    client,
    adult_a_headers,
    other_family_user,
):
    response = await client.put(
        "/api/routines/handoffs/schedule",
        json={
            "items": [
                {
                    "kind": "pickup",
                    "weekday": 0,
                    "time_of_day": "15:20",
                    "term_person_id": other_family_user["id"],
                }
            ]
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 422


async def test_active_routines_basic(client, adult_a_user, adult_a_headers):
    """GET /api/routines/active returns expanded routine entries."""
    # Create item for Monday and Wednesday (0, 2)
    await client.post(
        "/api/routines/items",
        json={
            "person_id": adult_a_user["id"],
            "name": "PE",
            "color": "#FF6B6B",
            "days_of_week": [0, 2],
        },
        headers=adult_a_headers,
    )

    # 2026-02-09 is Monday, 2026-02-15 is Sunday
    resp = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-15"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    dates = [r["date"] for r in data]
    assert "2026-02-09" in dates  # Monday
    assert "2026-02-11" in dates  # Wednesday
    assert "2026-02-10" not in dates  # Tuesday — not in days_of_week
    for r in data:
        assert r["name"] == "PE"
        assert r["color"] == "#FF6B6B"
        assert r["person_name"] == "Alex"


async def test_active_routines_with_term_dates(client, adult_a_user, adult_a_headers, child1):
    """Active routines respect term dates — only show during term."""
    # Create item for child on every weekday
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "Book Change",
            "color": "#4ECDC4",
            "days_of_week": [0, 1, 2, 3, 4],
        },
        headers=adult_a_headers,
    )

    # Term covers only Mon-Wed (Feb 9-11)
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-02-09",
            "end_date": "2026-02-11",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-15"},
        headers=adult_a_headers,
    )
    data = resp.json()
    dates = [r["date"] for r in data]
    assert "2026-02-09" in dates  # Mon, in term
    assert "2026-02-10" in dates  # Tue, in term
    assert "2026-02-11" in dates  # Wed, in term
    assert "2026-02-12" not in dates  # Thu, out of term
    assert "2026-02-13" not in dates  # Fri, out of term


async def test_active_routines_override_force_on(client, adult_a_user, adult_a_headers, child1):
    """Force-on override shows routines even outside term."""
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "PE",
            "color": "#FF6B6B",
            "days_of_week": [0],
        },
        headers=adult_a_headers,
    )

    # Term only covers a past period
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2025-01-01",
            "end_date": "2025-01-31",
        },
        headers=adult_a_headers,
    )

    # Force on
    await client.put(
        f"/api/routines/override/{child1['id']}",
        json={"is_active": True},
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-09"},
        headers=adult_a_headers,
    )
    data = resp.json()
    assert len(data) == 1
    assert data[0]["name"] == "PE"
    assert data[0]["date"] == "2026-02-09"


async def test_active_routines_override_force_off(client, adult_a_user, adult_a_headers, child1):
    """Force-off override hides routines even during term."""
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "PE",
            "color": "#FF6B6B",
            "days_of_week": [0],
        },
        headers=adult_a_headers,
    )

    # Term covers the requested week
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-02-01",
            "end_date": "2026-02-28",
        },
        headers=adult_a_headers,
    )

    # Force off
    await client.put(
        f"/api/routines/override/{child1['id']}",
        json={"is_active": False},
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-09"},
        headers=adult_a_headers,
    )
    assert resp.json() == []


async def test_active_routines_no_terms_always_active(client, adult_a_user, adult_a_headers):
    """No term dates at all -> routines always active."""
    await client.post(
        "/api/routines/items",
        json={
            "person_id": adult_a_user["id"],
            "name": "Gym",
            "color": "#6BCB77",
            "days_of_week": [0, 1, 2, 3, 4, 5, 6],
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-15"},
        headers=adult_a_headers,
    )
    data = resp.json()
    assert len(data) == 7  # every day


# ---------------------------------------------------------------------------
# Holiday Dates CRUD
# ---------------------------------------------------------------------------


async def test_create_holiday_date(client, adult_a_user, adult_a_headers, child1):
    """POST /api/routines/holidays creates a holiday date."""
    payload = {
        "person_id": child1["id"],
        "date": "2026-02-10",
        "label": "INSET Day",
    }
    resp = await client.post("/api/routines/holidays", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["person_id"] == child1["id"]
    assert data["date"] == "2026-02-10"
    assert data["label"] == "INSET Day"
    assert "id" in data
    assert "created_at" in data


async def test_create_holiday_date_no_label(client, adult_a_user, adult_a_headers, child1):
    """POST /api/routines/holidays works without a label."""
    payload = {"person_id": child1["id"], "date": "2026-03-15"}
    resp = await client.post("/api/routines/holidays", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    assert resp.json()["label"] is None


async def test_list_holiday_dates(client, adult_a_user, adult_a_headers, child1):
    """GET /api/routines/holidays returns created holidays."""
    await client.post(
        "/api/routines/holidays",
        json={
            "person_id": child1["id"],
            "date": "2026-02-10",
            "label": "INSET",
        },
        headers=adult_a_headers,
    )

    resp = await client.get("/api/routines/holidays", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 1
    assert any(h["date"] == "2026-02-10" for h in data)


async def test_list_holidays_filter_by_person(client, adult_a_user, adult_a_headers, child1, child2):
    """GET /api/routines/holidays?person_id= filters by person."""
    await client.post(
        "/api/routines/holidays",
        json={
            "person_id": child1["id"],
            "date": "2026-02-10",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/holidays",
        json={
            "person_id": child2["id"],
            "date": "2026-02-11",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/holidays",
        params={"person_id": child1["id"]},
        headers=adult_a_headers,
    )
    data = resp.json()
    assert all(h["person_id"] == child1["id"] for h in data)


async def test_list_holidays_filter_by_year(client, adult_a_user, adult_a_headers, child1):
    """GET /api/routines/holidays?year= filters by year."""
    await client.post(
        "/api/routines/holidays",
        json={
            "person_id": child1["id"],
            "date": "2026-06-15",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/holidays",
        json={
            "person_id": child1["id"],
            "date": "2025-06-15",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/holidays",
        params={"year": 2026},
        headers=adult_a_headers,
    )
    data = resp.json()
    assert all(h["date"].startswith("2026") for h in data)


async def test_delete_holiday_date(client, adult_a_user, adult_a_headers, child1):
    """DELETE /api/routines/holidays/{id} soft-deletes (204)."""
    create_resp = await client.post(
        "/api/routines/holidays",
        json={
            "person_id": child1["id"],
            "date": "2026-02-10",
        },
        headers=adult_a_headers,
    )
    holiday_id = create_resp.json()["id"]

    del_resp = await client.delete(f"/api/routines/holidays/{holiday_id}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    list_resp = await client.get("/api/routines/holidays", headers=adult_a_headers)
    ids = [h["id"] for h in list_resp.json()]
    assert holiday_id not in ids


async def test_delete_nonexistent_holiday(client, adult_a_user, adult_a_headers):
    """DELETE /api/routines/holidays/{id} returns 404 for nonexistent."""
    resp = await client.delete("/api/routines/holidays/nonexistent", headers=adult_a_headers)
    assert resp.status_code == 404


async def test_holiday_no_auth(client):
    """POST /api/routines/holidays without auth returns 401 or 403."""
    resp = await client.post(
        "/api/routines/holidays",
        json={
            "person_id": "some-id",
            "date": "2026-02-10",
        },
    )
    assert resp.status_code in (401, 403)


# ---------------------------------------------------------------------------
# Term Status
# ---------------------------------------------------------------------------


async def test_term_status_all_in_term(client, adult_a_user, adult_a_headers, child1):
    """GET /api/routines/term-status returns correct status when in term."""
    # Create routine item for child1 (so they appear in the status)
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "PE",
            "color": "#FF0000",
            "days_of_week": [0, 1, 2, 3, 4],
        },
        headers=adult_a_headers,
    )
    # Create term covering the date
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-02-01",
            "end_date": "2026-02-28",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/term-status",
        params={"date": "2026-02-10"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "statuses" in data
    assert "all_same" in data
    child_status = next((s for s in data["statuses"] if s["person_id"] == child1["id"]), None)
    assert child_status is not None
    assert child_status["in_term"] is True


async def test_term_status_holiday_overrides_term(client, adult_a_user, adult_a_headers, child1):
    """Holiday date makes person not in term even when term dates say they should be."""
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "PE",
            "color": "#FF0000",
            "days_of_week": [0, 1, 2, 3, 4],
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-02-01",
            "end_date": "2026-02-28",
        },
        headers=adult_a_headers,
    )
    # Add holiday date for Feb 10
    await client.post(
        "/api/routines/holidays",
        json={
            "person_id": child1["id"],
            "date": "2026-02-10",
            "label": "INSET Day",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/term-status",
        params={"date": "2026-02-10"},
        headers=adult_a_headers,
    )
    data = resp.json()
    child_status = next(s for s in data["statuses"] if s["person_id"] == child1["id"])
    assert child_status["in_term"] is False


async def test_term_status_mixed(client, adult_a_user, adult_a_headers, child1, child2):
    """Term status shows all_same=false when people differ."""
    # child1 has term, child2 does not
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "PE",
            "color": "#FF0000",
            "days_of_week": [0, 1, 2, 3, 4],
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child2["id"],
            "name": "Art",
            "color": "#00FF00",
            "days_of_week": [0, 1, 2, 3, 4],
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-02-01",
            "end_date": "2026-02-28",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child2["id"],
            "start_date": "2026-03-01",
            "end_date": "2026-03-28",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/term-status",
        params={"date": "2026-02-10"},
        headers=adult_a_headers,
    )
    data = resp.json()
    assert data["all_same"] is False
    c1 = next(s for s in data["statuses"] if s["person_id"] == child1["id"])
    c2 = next(s for s in data["statuses"] if s["person_id"] == child2["id"])
    assert c1["in_term"] is True
    assert c2["in_term"] is False


async def test_active_routines_holiday_date_hides(client, adult_a_user, adult_a_headers, child1):
    """Holiday date makes a routine inactive even during term."""
    await client.post(
        "/api/routines/items",
        json={
            "person_id": child1["id"],
            "name": "PE",
            "color": "#FF6B6B",
            "days_of_week": [0, 1, 2, 3, 4],
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/routines/terms",
        json={
            "person_id": child1["id"],
            "start_date": "2026-02-01",
            "end_date": "2026-02-28",
        },
        headers=adult_a_headers,
    )
    # Add holiday on Tuesday Feb 10
    await client.post(
        "/api/routines/holidays",
        json={
            "person_id": child1["id"],
            "date": "2026-02-10",
            "label": "INSET Day",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-09", "end": "2026-02-11"},
        headers=adult_a_headers,
    )
    data = resp.json()
    dates = [r["date"] for r in data]
    assert "2026-02-09" in dates  # Mon — in term, no holiday
    assert "2026-02-10" not in dates  # Tue — holiday
    assert "2026-02-11" in dates  # Wed — in term, no holiday


async def test_active_routines_rejects_range_over_400_days(client, adult_a_headers):
    """Routine expansion has a hard date-range ceiling."""
    response = await client.get(
        "/api/routines/active",
        params={"start": "2026-01-01", "end": "2027-02-06"},
        headers=adult_a_headers,
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Routine range cannot exceed 400 days"


async def test_active_routines_rejects_reversed_range(client, adult_a_headers):
    response = await client.get(
        "/api/routines/active",
        params={"start": "2026-02-10", "end": "2026-02-09"},
        headers=adult_a_headers,
    )

    assert response.status_code == 400


async def test_external_schedule_refresh_requires_admin(client, adult_b_headers):
    """A normal family user cannot trigger expensive external scrapers."""
    swimming = await client.post("/api/routines/swimming/refresh", headers=adult_b_headers)
    terms = await client.post("/api/routines/terms/refresh", headers=adult_b_headers)

    assert swimming.status_code == 403
    assert terms.status_code == 403


async def test_external_schedule_refresh_is_scoped_to_requesting_family(
    client,
    other_family_headers,
):
    swimming = await client.post(
        "/api/routines/swimming/refresh",
        headers=other_family_headers,
    )
    terms = await client.post(
        "/api/routines/terms/refresh",
        headers=other_family_headers,
    )

    assert swimming.status_code == 200
    assert terms.status_code == 200

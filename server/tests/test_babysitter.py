"""Tests for the babysitter mode endpoint (GET /api/babysitter).

Covers: children data, medicine schedule with next-dose calculation,
active naps, today's events, read-only enforcement, empty state,
and data completeness.
"""

import hashlib
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlsplit

import aiosqlite

from conftest import EXAMPLE_FAMILY_ID


# ---------------------------------------------------------------------------
# Helpers — insert test data directly into the database
# ---------------------------------------------------------------------------


async def _insert_medicine_type(db_path, child_id, name="Calpol", min_hours=4.0, max_doses=4):
    """Insert a medicine type and return its id."""
    async with aiosqlite.connect(db_path) as db:
        type_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            "INSERT INTO medicine_types "
            "(id, name, min_hours_between_doses, max_doses_24h, child_id, family_id, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (type_id, name, min_hours, max_doses, child_id, EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()
        return type_id


async def _insert_medicine_dose(db_path, type_id, child_id, given_by, given_at, dose_amount=None):
    """Insert a medicine dose and return its id."""
    async with aiosqlite.connect(db_path) as db:
        dose_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            "INSERT INTO medicine_doses "
            "(id, medicine_type_id, child_id, given_at, given_by, dose_amount, family_id, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (dose_id, type_id, child_id, given_at, given_by, dose_amount, EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()
        return dose_id


async def _insert_nap(db_path, child_id, started_at, location=None, ended_at=None):
    """Insert a nap and return its id."""
    async with aiosqlite.connect(db_path) as db:
        nap_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            "INSERT INTO naps "
            "(id, child_id, started_at, ended_at, location, family_id, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (nap_id, child_id, started_at, ended_at, location, EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()
        return nap_id


async def _insert_calendar_event(
    db_path,
    title,
    start_time,
    end_time,
    *,
    assigned_to=None,
    family_member_ids=None,
    recurrence_rule=None,
    location=None,
):
    """Insert a calendar event and return its id."""
    async with aiosqlite.connect(db_path) as db:
        event_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            "INSERT INTO calendar_events "
            "(id, title, start_time, end_time, assigned_to, family_member_ids, "
            "recurrence_rule, location, family_id, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                event_id,
                title,
                start_time,
                end_time,
                assigned_to,
                family_member_ids,
                recurrence_rule,
                location,
                EXAMPLE_FAMILY_ID,
                now,
                now,
            ),
        )
        await db.commit()
        return event_id


# ---------------------------------------------------------------------------
# Test: children data is included
# ---------------------------------------------------------------------------


async def test_babysitter_includes_children(client, adult_a_headers, child1):
    """GET /api/babysitter returns children with name, age, date_of_birth, and notes."""
    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    assert "children" in data
    assert len(data["children"]) >= 1

    child = data["children"][0]
    assert child["name"] == "Child 1"
    assert child["date_of_birth"] == "2020-02-20"
    assert isinstance(child["age"], int)
    assert child["age"] >= 6  # synthetic 2019 birth date
    assert "notes" in child


# ---------------------------------------------------------------------------
# Test: medicine schedule with next dose calculation
# ---------------------------------------------------------------------------


async def test_babysitter_medicine_schedule(client, adult_a_user, adult_a_headers, child3, initialized_db):
    """Medicine schedule includes next_dose_allowed_at calculated from last dose + min_hours."""
    type_id = await _insert_medicine_type(initialized_db, child3["id"], name="Calpol", min_hours=4.0)

    given_at = datetime(2026, 2, 8, 14, 0, 0, tzinfo=timezone.utc).isoformat()
    await _insert_medicine_dose(
        initialized_db, type_id, child3["id"], adult_a_user["id"], given_at, dose_amount="5ml"
    )

    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    assert "medicine_schedule" in data
    assert len(data["medicine_schedule"]) >= 1

    med = data["medicine_schedule"][0]
    assert med["child_name"] == "Child 3"
    assert med["medicine_name"] == "Calpol"
    assert med["last_given_at"] == given_at
    assert med["last_given_by"] == "Alex"
    assert med["min_hours_between"] == 4.0

    # next_dose_allowed_at should be given_at + 4 hours = 18:00
    expected_next = datetime(2026, 2, 8, 18, 0, 0, tzinfo=timezone.utc).isoformat()
    assert med["next_dose_allowed_at"] == expected_next


# ---------------------------------------------------------------------------
# Test: medicine schedule with no doses yet
# ---------------------------------------------------------------------------


async def test_babysitter_medicine_no_doses(client, adult_a_headers, child1, initialized_db):
    """Medicine types with no doses should still appear with null last_given_at."""
    await _insert_medicine_type(initialized_db, child1["id"], name="Ibuprofen", min_hours=6.0)

    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    assert len(data["medicine_schedule"]) >= 1
    med = data["medicine_schedule"][0]
    assert med["medicine_name"] == "Ibuprofen"
    assert med["last_given_at"] is None
    assert med["last_given_by"] is None
    assert med["next_dose_allowed_at"] is None


# ---------------------------------------------------------------------------
# Test: active naps are included
# ---------------------------------------------------------------------------


async def test_babysitter_active_naps(client, adult_a_headers, child3, initialized_db):
    """Active naps (ended_at IS NULL) appear in the babysitter view."""
    started_at = datetime(2026, 2, 8, 13, 0, 0, tzinfo=timezone.utc).isoformat()
    await _insert_nap(initialized_db, child3["id"], started_at, location="cot")

    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    assert "active_naps" in data
    assert len(data["active_naps"]) >= 1

    nap = data["active_naps"][0]
    assert nap["child_name"] == "Child 3"
    assert nap["started_at"] == started_at
    assert nap["location"] == "cot"


# ---------------------------------------------------------------------------
# Test: ended naps do not appear in active_naps
# ---------------------------------------------------------------------------


async def test_babysitter_ended_nap_excluded(client, adult_a_headers, child1, initialized_db):
    """Naps with ended_at set should NOT appear in active_naps."""
    started_at = datetime(2026, 2, 8, 10, 0, 0, tzinfo=timezone.utc).isoformat()
    ended_at = datetime(2026, 2, 8, 11, 30, 0, tzinfo=timezone.utc).isoformat()
    await _insert_nap(initialized_db, child1["id"], started_at, ended_at=ended_at)

    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    # The ended nap should not be in active_naps
    assert len(data["active_naps"]) == 0


# ---------------------------------------------------------------------------
# Test: today's events are included
# ---------------------------------------------------------------------------


async def test_babysitter_todays_events(client, adult_a_headers, initialized_db):
    """Today's calendar events appear in the babysitter view."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    start = f"{today}T10:00:00Z"
    end = f"{today}T10:30:00Z"
    await _insert_calendar_event(initialized_db, "Swimming lesson", start, end)

    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    assert "todays_events" in data
    assert len(data["todays_events"]) >= 1

    event = data["todays_events"][0]
    assert event["title"] == "Swimming lesson"
    assert event["start_time"] == start
    assert event["end_time"] == end


# ---------------------------------------------------------------------------
# Test: events from other days are excluded
# ---------------------------------------------------------------------------


async def test_babysitter_excludes_other_day_events(client, adult_a_headers, initialized_db):
    """Calendar events on other days should NOT appear in todays_events."""
    await _insert_calendar_event(
        initialized_db,
        "Tomorrow's event",
        "2099-12-31T10:00:00Z",
        "2099-12-31T11:00:00Z",
    )

    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    assert len(data["todays_events"]) == 0


# ---------------------------------------------------------------------------
# Test: read-only — no write endpoints on this router
# ---------------------------------------------------------------------------


async def test_babysitter_is_read_only(client, adult_a_headers):
    """The babysitter router exposes only GET — POST, PUT, PATCH, DELETE should all 405."""
    post_resp = await client.post("/api/babysitter/", headers=adult_a_headers, json={})
    put_resp = await client.put("/api/babysitter/", headers=adult_a_headers, json={})
    patch_resp = await client.patch("/api/babysitter/", headers=adult_a_headers, json={})
    delete_resp = await client.delete("/api/babysitter/", headers=adult_a_headers)

    assert post_resp.status_code == 405
    assert put_resp.status_code == 405
    assert patch_resp.status_code == 405
    assert delete_resp.status_code == 405


# ---------------------------------------------------------------------------
# Test: empty state — no children, no medicines, no events
# ---------------------------------------------------------------------------


async def test_babysitter_empty_state(client, adult_a_headers):
    """When the database has no children or events, the endpoint returns empty lists."""
    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    assert data["children"] == []
    assert data["medicine_schedule"] == []
    assert data["active_naps"] == []
    assert data["todays_events"] == []


# ---------------------------------------------------------------------------
# Test: caregiver-pack readiness is truthful
# ---------------------------------------------------------------------------


async def test_babysitter_reports_incomplete_caregiver_pack(client, adult_a_headers):
    """Missing handover data is explicit and never replaced with plausible facts."""
    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    expected_keys = {
        "caregiver_pack",
        "children",
        "medicine_schedule",
        "active_naps",
        "todays_events",
    }
    assert expected_keys == set(data.keys())

    caregiver_pack = data["caregiver_pack"]
    assert caregiver_pack == {
        "status": "incomplete",
        "missing_sections": [
            "daily_routine",
            "emergency_contacts",
            "wifi_password",
            "house_rules",
            "allergies",
        ],
        "daily_routine": None,
        "emergency_contacts": [],
        "important_info": None,
    }

    response_text = response.text
    for invented_value in (
        "Set in settings",
        "Alex (Dad)",
        "Morgan (Mum)",
        "GP Surgery",
        "Nearest A&E",
        "7:30",
        "12:00",
        "17:30",
        "13:00-14:30",
        "18:30",
        "19:00",
        "19:30",
    ):
        assert invented_value not in response_text


# ---------------------------------------------------------------------------
# Test: requires authentication
# ---------------------------------------------------------------------------


async def test_babysitter_requires_auth(client):
    """GET /api/babysitter without auth headers is rejected (401 or 403)."""
    response = await client.get("/api/babysitter/")
    assert response.status_code in (401, 403)


# ---------------------------------------------------------------------------
# Test: multiple children ordered by date_of_birth
# ---------------------------------------------------------------------------


async def test_babysitter_multiple_children(client, adult_a_headers, child1, child2, child3):
    """All non-deleted children appear, ordered by date_of_birth."""
    response = await client.get("/api/babysitter/", headers=adult_a_headers)
    assert response.status_code == 200
    data = response.json()

    assert len(data["children"]) == 3
    names = [c["name"] for c in data["children"]]
    # Ordered by date_of_birth: Child 1 (2019), Child 2 (2021), Child 3 (2024)
    assert names == ["Child 1", "Child 2", "Child 3"]


def _complete_handover(child):
    return {
        "house": {
            "address": "1 Test Lane, Example Town",
            "wifi_name": "Family Wi-Fi",
            "wifi_password": "parent-entered-password",
            "emergency_instructions": "Call us first; call 999 for an emergency.",
            "house_instructions": "The spare key stays in the kitchen drawer.",
            "dog_instructions": "Dinner is already measured in the utility room.",
        },
        "children": [
            {
                "child_id": child["id"],
                "care_notes": "Likes to know what happens next.",
                "allergies": "None known",
                "food": "Pasta is in the fridge; water before bed.",
                "comfort": "Blue rabbit and the hallway light.",
                "toileting": "Prompt before bed.",
                "bedtime": "Pyjamas, two stories, lights out at 19:30.",
            }
        ],
        "contacts": [
            {
                "name": "Alex",
                "phone": "+00000000001",
                "relationship": "Dad",
                "priority": 0,
            }
        ],
    }


async def test_adult_can_complete_authoritative_handover_readiness(
    client, adult_a_headers, child1
):
    empty = await client.get("/api/babysitter/handover", headers=adult_a_headers)
    assert empty.status_code == 200
    assert empty.json()["readiness"]["ready"] is False
    assert any(
        item["label"] == "Child 1: Allergies (or none known)" and not item["ready"]
        for item in empty.json()["readiness"]["items"]
    )

    saved = await client.put(
        "/api/babysitter/handover",
        headers=adult_a_headers,
        json=_complete_handover(child1),
    )
    assert saved.status_code == 200, saved.text
    data = saved.json()
    assert data["readiness"]["ready"] is True
    assert data["house"]["wifi_password"] == "parent-entered-password"
    assert data["children"][0]["bedtime"].startswith("Pyjamas")


async def test_booking_link_exchanges_once_and_exposes_only_selected_read_only_handover(
    client, adult_a_headers, child1, child2, initialized_db
):
    handover = _complete_handover(child1)
    handover["children"].append(
        {
            "child_id": child2["id"],
            "care_notes": "Independent with the routine.",
            "allergies": "Strawberries",
            "food": "Toast after school.",
            "comfort": "Audiobook.",
            "toileting": "Independent.",
            "bedtime": "Read until 20:00.",
        }
    )
    assert (
        await client.put("/api/babysitter/handover", headers=adult_a_headers, json=handover)
    ).status_code == 200
    now = datetime.now(timezone.utc)
    created = await client.post(
        "/api/babysitter/bookings",
        headers=adult_a_headers,
        json={
            "label": "Friday evening",
            "starts_at": (now - timedelta(minutes=1)).isoformat(),
            "expires_at": (now + timedelta(hours=5)).isoformat(),
            "child_ids": [child1["id"]],
        },
    )
    assert created.status_code == 201, created.text
    created_data = created.json()
    assert created_data["child_names"] == ["Child 1"]
    split = urlsplit(created_data["share_url"])
    assert split.query == "caregiver=1"
    code = parse_qs(split.fragment)["invite"][0]
    assert len(code) >= 32

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        row = await (
            await db.execute(
                "SELECT bootstrap_hash FROM caregiver_bookings WHERE id = ?",
                (created_data["id"],),
            )
        ).fetchone()
    assert row["bootstrap_hash"] == hashlib.sha256(code.encode()).hexdigest()
    assert code not in row["bootstrap_hash"]

    exchanged = await client.post(
        "/api/babysitter/sessions/exchange", json={"code": code}
    )
    assert exchanged.status_code == 200, exchanged.text
    assert "httponly" in exchanged.headers["set-cookie"].lower()
    assert "samesite=strict" in exchanged.headers["set-cookie"].lower()
    second_exchange = await client.post(
        "/api/babysitter/sessions/exchange", json={"code": code}
    )
    assert second_exchange.status_code == 401

    async with aiosqlite.connect(initialized_db) as db:
        rotated = await (
            await db.execute(
                "SELECT bootstrap_hash, session_hash FROM caregiver_bookings WHERE id = ?",
                (created_data["id"],),
            )
        ).fetchone()
    assert rotated[0] != hashlib.sha256(code.encode()).hexdigest()
    assert code not in rotated[0]
    assert code not in rotated[1]

    incomplete_handover = _complete_handover(child1)
    incomplete_handover["children"][0]["allergies"] = ""
    rejected_edit = await client.put(
        "/api/babysitter/handover",
        headers=adult_a_headers,
        json=incomplete_handover,
    )
    assert rejected_edit.status_code == 400
    assert "open caregiver booking" in rejected_edit.json()["detail"]

    # The caregiver's Next view expands recurring events whose stored series
    # anchor predates the booking, while still enforcing the selected-child scope.
    await _insert_calendar_event(
        initialized_db,
        "Child 1 recurring club",
        (now - timedelta(days=1)).isoformat(),
        (now - timedelta(days=1) + timedelta(minutes=30)).isoformat(),
        assigned_to=child1["id"],
        recurrence_rule="FREQ=DAILY;COUNT=10",
        location="Example Town Leisure Centre",
    )
    await _insert_calendar_event(
        initialized_db,
        "Child 2 private appointment",
        (now + timedelta(hours=1)).isoformat(),
        (now + timedelta(hours=2)).isoformat(),
        family_member_ids=f'["{child2["id"]}"]',
    )

    view = await client.get("/api/babysitter/sessions/view")
    assert view.status_code == 200, view.text
    data = view.json()
    assert data["read_only"] is True
    assert [child["name"] for child in data["now"]["children"]] == ["Child 1"]
    assert data["emergency"]["allergies"] == [
        {"child_name": "Child 1", "details": "None known"}
    ]
    assert "Child 2" not in view.text
    assert [event["title"] for event in data["next"]["events"]] == [
        "Child 1 recurring club"
    ]
    assert data["next"]["events"][0]["location"] == "Example Town Leisure Centre"
    assert "cannot record a dose" in data["medicine_disclaimer"]
    assert (await client.post("/api/babysitter/sessions/view", json={})).status_code == 405


async def test_booking_revocation_immediately_invalidates_the_caregiver_session(
    client, adult_a_headers, child1
):
    await client.put(
        "/api/babysitter/handover",
        headers=adult_a_headers,
        json=_complete_handover(child1),
    )
    now = datetime.now(timezone.utc)
    created = (
        await client.post(
            "/api/babysitter/bookings",
            headers=adult_a_headers,
            json={
                "label": "Tonight",
                "starts_at": (now - timedelta(minutes=1)).isoformat(),
                "expires_at": (now + timedelta(hours=2)).isoformat(),
                "child_ids": [child1["id"]],
            },
        )
    ).json()
    code = parse_qs(urlsplit(created["share_url"]).fragment)["invite"][0]
    assert (
        await client.post("/api/babysitter/sessions/exchange", json={"code": code})
    ).status_code == 200
    assert (await client.get("/api/babysitter/sessions/view")).status_code == 200

    revoked = await client.post(
        f"/api/babysitter/bookings/{created['id']}/revoke", headers=adult_a_headers
    )
    assert revoked.status_code == 200
    assert revoked.json() == {"status": "revoked", "booking_id": created["id"]}
    assert (await client.get("/api/babysitter/sessions/view")).status_code == 401
    # DELETE remains an idempotent web-client contract for the same booking.
    assert (
        await client.delete(
            f"/api/babysitter/bookings/{created['id']}", headers=adult_a_headers
        )
    ).status_code == 204


async def test_expired_and_unscoped_caregiver_sessions_are_rejected(
    client, adult_a_headers, child1, initialized_db
):
    assert (await client.get("/api/babysitter/sessions/view")).status_code == 401
    await client.put(
        "/api/babysitter/handover",
        headers=adult_a_headers,
        json=_complete_handover(child1),
    )
    session = "expired-session-value-which-is-not-logged"
    now = datetime.now(timezone.utc)
    async with aiosqlite.connect(initialized_db) as db:
        handover_id = (
            await (
                await db.execute(
                    "SELECT id FROM caregiver_handovers WHERE family_id = ?",
                    (EXAMPLE_FAMILY_ID,),
                )
            ).fetchone()
        )[0]
        await db.execute(
            """INSERT INTO caregiver_bookings
               (id, handover_id, label, starts_at, expires_at, child_ids,
                bootstrap_hash, bootstrap_used_at, session_hash, family_id,
                created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                "expired-booking",
                handover_id,
                "Yesterday",
                (now - timedelta(hours=3)).isoformat(),
                (now - timedelta(hours=1)).isoformat(),
                f'["{child1["id"]}"]',
                "expired-bootstrap",
                now.isoformat(),
                hashlib.sha256(session.encode()).hexdigest(),
                EXAMPLE_FAMILY_ID,
                now.isoformat(),
                now.isoformat(),
            ),
        )
        await db.commit()
    client.cookies.set(
        "hausklar_caregiver_session",
        session,
        path="/api/babysitter/sessions",
    )
    response = await client.get("/api/babysitter/sessions/view")
    assert response.status_code == 401
    assert "expired" in response.json()["detail"].lower()

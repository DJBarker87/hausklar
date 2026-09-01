"""Example School timetable parsing, confirmation, visibility and Fitness access."""

import hashlib
import io
import uuid
import zipfile
from datetime import datetime
from xml.sax.saxutils import escape
from zoneinfo import ZoneInfo

import aiosqlite

from app.models.fitness_coach import CoachMessageRequest
from app.services.assistant import build_assistant_context
from app.services.facilities import DOCX_MEDIA_TYPE, parse_example_school_timetable
from app.services.fitness.coach import build_evidence


def _cell(value: str) -> str:
    paragraphs = "".join(
        f"<w:p><w:r><w:t>{escape(line)}</w:t></w:r></w:p>" for line in value.splitlines()
    )
    return f"<w:tc>{paragraphs}</w:tc>"


def timetable_docx(rows: list[tuple[str, str, str]]) -> bytes:
    all_rows = [("Date", "Athens", "WTR"), *rows]
    table = "".join(f"<w:tr>{''.join(_cell(value) for value in row)}</w:tr>" for row in all_rows)
    document = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body><w:tbl>{table}</w:tbl></w:body></w:document>"
    ).encode()
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("word/document.xml", document)
    return output.getvalue()


SCHEDULE = timetable_docx(
    [
        ("Sunday 9th August", "12.00-17.00 Family Swimming", "Closed"),
        (
            "Monday 10th August",
            "06.00-09.30 Lane Swimming\n15.00-17.00 Family Swimming\n19.00-21.00 Lane Swimming",
            "06.00-12.00",
        ),
        ("Saturday 29th August – Monday 31st August", "Closed", "Closed"),
    ]
)


def test_parser_normalises_known_timetable_and_expands_date_ranges():
    parsed = parse_example_school_timetable(
        SCHEDULE,
        filename="Summer 26 Permit & Staff timetable.docx",
    )

    assert parsed.valid_from.isoformat() == "2026-08-09"
    assert parsed.valid_to.isoformat() == "2026-08-31"
    assert len(parsed.days) == 5
    assert parsed.days[0].family_swimming == (("12:00", "17:00"),)
    assert parsed.days[1].lane_swimming == (
        ("06:00", "09:30"),
        ("19:00", "21:00"),
    )
    assert parsed.days[-1].pool_closed is True


async def test_import_review_today_calendar_and_fitness_are_owner_aware(
    client,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    tmp_path,
    monkeypatch,
):
    from app.config import settings

    monkeypatch.setattr(settings, "document_storage_path", str(tmp_path / "documents"))
    filename = "Summer 26 Permit & Staff timetable.docx"
    upload = {"file": (filename, SCHEDULE, DOCX_MEDIA_TYPE)}

    preview_response = await client.post(
        "/api/facilities/example_school/preview",
        files=upload,
        headers=adult_a_headers,
    )
    assert preview_response.status_code == 200, preview_response.text
    preview = preview_response.json()
    assert preview["counts"] == {
        "days": 5,
        "family_swimming_sessions": 2,
        "lane_swimming_sessions": 2,
        "weights_room_open_days": 1,
        "pool_closed_days": 3,
        "weights_room_closed_days": 4,
    }
    assert preview["can_confirm"] is True

    async with aiosqlite.connect(initialized_db) as db:
        assert (await (await db.execute("SELECT COUNT(*) FROM documents")).fetchone())[0] == 0
        assert (
            await (await db.execute("SELECT COUNT(*) FROM facility_schedule_versions")).fetchone()
        )[0] == 0

    confirmation = await client.post(
        "/api/facilities/example_school/import",
        files=upload,
        data={"expected_sha256": hashlib.sha256(SCHEDULE).hexdigest()},
        # Morgan may handle the upload, but staff-only times still belong to Alex.
        headers=adult_b_headers,
    )
    assert confirmation.status_code == 201, confirmation.text
    imported = confirmation.json()
    assert imported["imported"] is True
    assert imported["document_id"]
    assert (
        await client.patch(
            "/api/usage-history/preferences",
            json={"enabled": True},
            headers=adult_a_headers,
        )
    ).status_code == 200

    booking_id = str(uuid.uuid4())
    booking_payload = {
        "id": booking_id,
        "date": "2026-08-09",
        "start": "13:30",
        "end": "14:30",
        "client_id": "facilities-test",
        "client_timestamp": "2026-08-09T11:00:00+01:00",
    }
    booking = await client.post(
        "/api/facilities/swimming-bookings",
        json=booking_payload,
        headers=adult_a_headers,
    )
    assert booking.status_code == 201, booking.text
    assert booking.json() == {
        "status": "booked",
        "event_id": booking_id,
        "title": "Swimming",
        "start_time": "2026-08-09T13:30:00+01:00",
        "end_time": "2026-08-09T14:30:00+01:00",
        "location": "Example School College",
    }

    replay = await client.post(
        "/api/facilities/swimming-bookings",
        json=booking_payload,
        headers=adult_a_headers,
    )
    assert replay.status_code == 201

    invalid_booking = await client.post(
        "/api/facilities/swimming-bookings",
        json={
            **booking_payload,
            "id": str(uuid.uuid4()),
            "start": "11:30",
            "end": "12:30",
        },
        headers=adult_a_headers,
    )
    assert invalid_booking.status_code == 422
    assert invalid_booking.json()["detail"] == (
        "Booked times must fit within one family-swimming window"
    )
    async with aiosqlite.connect(initialized_db) as db:
        booking_facts = await (
            await db.execute(
                "SELECT action, outcome FROM adoption_events "
                "WHERE user_id = ? AND deleted_at IS NULL",
                (adult_a_user["id"],),
            )
        ).fetchall()
    assert booking_facts == [("book_swimming", "created")]

    calendar = (
        await client.get(
            "/api/calendar/?start=2026-08-09&end=2026-08-09&limit=200",
            headers=adult_b_headers,
        )
    ).json()
    booked_event = next(event for event in calendar if event["id"] == booking_id)
    assert booked_event["title"] == "Swimming"
    assert booked_event["location"] == "Example School College"
    assert booked_event["family_member_ids"] is None
    assert booked_event["event_type"] == "activity"
    assert booked_event["source_document_id"] == imported["document_id"]

    async with aiosqlite.connect(initialized_db) as db:
        count = await (
            await db.execute("SELECT COUNT(*) FROM calendar_events WHERE id = ?", (booking_id,))
        ).fetchone()
        assert count[0] == 1

    adult_a_fact = (
        await client.get(
            "/api/facilities/quick-fact?date=2026-08-09",
            headers=adult_a_headers,
        )
    ).json()
    assert adult_a_fact["today"]["family_swimming"] == [{"start": "12:00", "end": "17:00"}]
    assert adult_a_fact["today"]["weights_room_status"] == "closed"
    assert adult_a_fact["tomorrow"]["weights_room"] == [{"start": "06:00", "end": "12:00"}]
    assert adult_a_fact["tomorrow"]["lane_swimming"] == [
        {"start": "06:00", "end": "09:30"},
        {"start": "19:00", "end": "21:00"},
    ]

    adult_b_fact = (
        await client.get(
            "/api/facilities/quick-fact?date=2026-08-09",
            headers=adult_b_headers,
        )
    ).json()
    assert adult_b_fact["today"]["family_swimming"] == adult_a_fact["today"]["family_swimming"]
    assert adult_b_fact["tomorrow"]["weights_room_status"] == "not_relevant"
    assert adult_b_fact["tomorrow"]["weights_room"] == []
    assert adult_b_fact["tomorrow"]["lane_swimming"] == []

    adult_a_timetable = (
        await client.get(
            "/api/facilities/timetable?start=2026-08-09&days=14",
            headers=adult_a_headers,
        )
    ).json()
    assert len(adult_a_timetable) == 14
    assert adult_a_timetable[0]["family_swimming"] == [{"start": "12:00", "end": "17:00"}]
    assert adult_a_timetable[1]["lane_swimming"] == [
        {"start": "06:00", "end": "09:30"},
        {"start": "19:00", "end": "21:00"},
    ]

    adult_b_timetable = (
        await client.get(
            "/api/facilities/timetable?start=2026-08-09&days=14",
            headers=adult_b_headers,
        )
    ).json()
    assert adult_b_timetable[0]["family_swimming"] == adult_a_timetable[0]["family_swimming"]
    assert adult_b_timetable[1]["lane_swimming"] == []
    assert adult_b_timetable[1]["weights_room"] == []

    assert (
        await client.get(
            "/api/facilities/calendar-layer?start=2026-08-09&end=2026-08-10",
            headers=adult_a_headers,
        )
    ).json() == []
    preference = await client.patch(
        "/api/facilities/calendar-preferences",
        json={"show_family_swimming": True, "show_personal_facilities": True},
        headers=adult_a_headers,
    )
    assert preference.json() == {
        "show_family_swimming": True,
        "show_personal_facilities": True,
    }
    layer = (
        await client.get(
            "/api/facilities/calendar-layer?start=2026-08-09&end=2026-08-10",
            headers=adult_a_headers,
        )
    ).json()
    assert [item["layer_kind"] for item in layer] == [
        "family_swimming",
        "family_swimming",
        "lane_swimming",
        "lane_swimming",
        "weights_room",
    ]
    assert layer[-1]["start_time"] == "2026-08-10T06:00:00+01:00"
    assert all(item["read_only"] for item in layer)

    adult_a_weights = (
        await client.get(
            "/api/fitness/weights-room-availability?start=2026-08-09&end=2026-08-10",
            headers=adult_a_headers,
        )
    ).json()
    assert adult_a_weights["relevant"] is True
    assert adult_a_weights["days"][1]["weights_room_status"] == "open"
    adult_b_weights = (
        await client.get(
            "/api/fitness/weights-room-availability?start=2026-08-09&end=2026-08-10",
            headers=adult_b_headers,
        )
    ).json()
    assert adult_b_weights == {
        "relevant": False,
        "source_title": None,
        "source_document_id": None,
        "current_to": None,
        "days": [],
    }

    strength_id = str(uuid.uuid4())
    strength_payload = {
        "id": strength_id,
        "date": "2026-08-10",
        "start": "07:00",
        "end": "08:00",
        "client_id": "facilities-strength-test",
        "client_timestamp": "2026-08-09T12:00:00+01:00",
    }
    strength = await client.post(
        "/api/facilities/weights-bookings",
        json=strength_payload,
        headers=adult_a_headers,
    )
    assert strength.status_code == 201, strength.text
    assert strength.json() == {
        "status": "planned",
        "planned_session_id": strength_id,
        "title": "Strength",
        "start_time": "2026-08-10T07:00:00+01:00",
        "end_time": "2026-08-10T08:00:00+01:00",
        "location": "Example School College",
    }
    strength_replay = await client.post(
        "/api/facilities/weights-bookings",
        json=strength_payload,
        headers=adult_a_headers,
    )
    assert strength_replay.status_code == 201
    assert strength_replay.json() == strength.json()

    changed_replay = await client.post(
        "/api/facilities/weights-bookings",
        json={**strength_payload, "start": "08:00", "end": "09:00"},
        headers=adult_a_headers,
    )
    assert changed_replay.status_code == 409
    private_booking = await client.post(
        "/api/facilities/weights-bookings",
        json={**strength_payload, "id": str(uuid.uuid4())},
        headers=adult_b_headers,
    )
    assert private_booking.status_code == 422
    assert private_booking.json()["detail"] == (
        "Weights-room times are private to their timetable owner"
    )
    invalid_strength = await client.post(
        "/api/facilities/weights-bookings",
        json={
            **strength_payload,
            "id": str(uuid.uuid4()),
            "start": "11:30",
            "end": "12:30",
        },
        headers=adult_a_headers,
    )
    assert invalid_strength.status_code == 422
    assert invalid_strength.json()["detail"] == (
        "Strength times must fit within one weights-room window"
    )

    fitness_layer = (
        await client.get(
            "/api/fitness/calendar-layer?start=2026-08-10&end=2026-08-10",
            headers=adult_a_headers,
        )
    ).json()
    strength_layer = next(item for item in fitness_layer if item["id"] == strength_id)
    assert strength_layer["display_title"] == "Strength"
    assert strength_layer["sport_key"] == "strength"
    assert strength_layer["status"] == "scheduled"
    assert strength_layer["scheduled_start_utc"] == "2026-08-10T06:00:00+00:00"
    assert strength_layer["duration_s"] == 3_600

    strength_today = (
        await client.get(
            "/api/fitness/today-card?date=2026-08-10",
            headers=adult_a_headers,
        )
    ).json()
    assert strength_today["session"]["id"] == strength_id
    assert strength_today["session"]["title"] == "Strength"
    assert strength_today["primary_action"] == {
        "kind": "start_session",
        "label": "Start",
        "destination": "plan",
        "target_id": strength_id,
    }

    async with aiosqlite.connect(initialized_db) as db:
        plan = await (
            await db.execute(
                "SELECT owner_user_id, sport_key, status, scheduled_start_utc, "
                "scheduled_date, expected_duration_s, movable, visibility "
                "FROM health_planned_sessions WHERE id = ?",
                (strength_id,),
            )
        ).fetchone()
        count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_planned_sessions WHERE id = ?",
                (strength_id,),
            )
        ).fetchone()
    assert plan == (
        adult_a_user["id"],
        "strength",
        "scheduled",
        "2026-08-10T06:00:00+00:00",
        "2026-08-10",
        3_600,
        0,
        "private",
    )
    assert count[0] == 1

    async with aiosqlite.connect(initialized_db) as db:
        document = await (
            await db.execute(
                "SELECT status, category, media_type FROM documents WHERE id = ?",
                (imported["document_id"],),
            )
        ).fetchone()
        assert document == ("filed", "activities", DOCX_MEDIA_TYPE)

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        assistant_context, _ = await build_assistant_context(
            db,
            family_id=adult_a_user["family_id"],
            user_id=adult_a_user["id"],
            message="Can we swim tomorrow, and when is the weights room open?",
            history_text="",
            reference=datetime(2026, 8, 9, 8, tzinfo=ZoneInfo("Europe/London")),
            timezone_name="Europe/London",
        )
        assert "facilities" in assistant_context["context_categories"]
        facility_context = assistant_context["family_records"]["school_facilities"]
        assert facility_context["data_through"] == "2026-08-31"
        monday = next(day for day in facility_context["days"] if day["date"] == "2026-08-10")
        assert monday["family_swimming"] == [{"start": "15:00", "end": "17:00"}]
        assert monday["weights_room"] == [{"start": "06:00", "end": "12:00"}]

        adult_b_context, _ = await build_assistant_context(
            db,
            family_id=adult_b_user["family_id"],
            user_id=adult_b_user["id"],
            message="What are the pool and gym times tomorrow?",
            history_text="",
            reference=datetime(2026, 8, 9, 8, tzinfo=ZoneInfo("Europe/London")),
            timezone_name="Europe/London",
        )
        adult_b_monday = next(
            day
            for day in adult_b_context["family_records"]["school_facilities"]["days"]
            if day["date"] == "2026-08-10"
        )
        assert adult_b_monday["family_swimming"] == [{"start": "15:00", "end": "17:00"}]
        assert adult_b_monday["weights_room"] == []
        assert adult_b_monday["lane_swimming"] == []

        general_context, _ = await build_assistant_context(
            db,
            family_id=adult_a_user["family_id"],
            user_id=adult_a_user["id"],
            message="What could we do tomorrow?",
            history_text="",
            reference=datetime(2026, 8, 9, 8, tzinfo=ZoneInfo("Europe/London")),
            timezone_name="Europe/London",
        )
        assert "facilities" in general_context["context_categories"]
        assert [
            day["date"] for day in general_context["family_records"]["school_facilities"]["days"]
        ] == [
            "2026-08-09",
            "2026-08-10",
            "2026-08-29",
            "2026-08-30",
            "2026-08-31",
        ]

        coach_evidence = await build_evidence(
            db,
            user=adult_a_user,
            body=CoachMessageRequest(
                message="Plan my weights-room strength training this week",
                intent="strength_plan",
                client_now="2026-08-09T08:00:00+01:00",
            ),
        )
        weights_evidence = next(
            item for item in coach_evidence if item["public"]["kind"] == "facility_availability"
        )
        monday_weights = next(
            day for day in weights_evidence["facts"]["days"] if day["date"] == "2026-08-10"
        )
        assert monday_weights["opening_times"] == [{"start": "06:00", "end": "12:00"}]


async def test_confirmation_requires_the_exact_reviewed_file(
    client,
    adult_a_headers,
    tmp_path,
    monkeypatch,
):
    from app.config import settings

    monkeypatch.setattr(settings, "document_storage_path", str(tmp_path / "documents"))
    response = await client.post(
        "/api/facilities/example_school/import",
        files={
            "file": (
                "Summer 26 Permit & Staff timetable.docx",
                SCHEDULE,
                DOCX_MEDIA_TYPE,
            )
        },
        data={"expected_sha256": "0" * 64},
        headers=adult_a_headers,
    )
    assert response.status_code == 409
    assert response.json()["detail"] == (
        "The timetable changed after review. Preview it again before importing"
    )

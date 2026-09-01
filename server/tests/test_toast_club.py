"""Toast Word-form imports and pickup windows."""

import io
import zipfile
from xml.sax.saxutils import escape

import aiosqlite

from app.services.toast_club import parse_booking_form


def toast_docx(
    *,
    dob: str = "20/02/2020",
    contact: str = "private.person@example.invalid +00000000006",
    first_week: tuple[str, str, str, str, str] = ("", "", "", "", "2"),
    second_week: tuple[str, str, str, str, str] = ("", "2", "2", "", "1"),
) -> bytes:
    paragraphs = [
        "TOAST TERMLY AUTUMN 2026",
        dob,
        *["Mon 31 AUG", "Tues 1 SEP", "Wed 2 SEP", "Thur 3 SEP", "Fri 4 SEP"],
        *first_week,
        *["Mon 7 SEP", "Tues 8 SEP", "Wed 9 SEP", "Thur 10 SEP", "Fri 11 SEP"],
        *second_week,
        "Total number of hours requested above:",
        "Please use 1 to indicate care until 4.30pm or 2 to indicate care until 5.30pm.",
        contact,
    ]
    body = "".join(
        f"<w:p><w:r><w:t>{escape(value)}</w:t></w:r></w:p>" for value in paragraphs
    )
    document = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body>{body}</w:body></w:document>"
    )
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("word/document.xml", document)
    return output.getvalue()


def _file(data: bytes):
    return {"file": ("Toast Autumn 2026.docx", data, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")}


async def _term(client, headers, child_id: str):
    response = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child_id,
            "label": "Autumn Term 1",
            "start_date": "2026-09-03",
            "end_date": "2026-10-23",
        },
        headers=headers,
    )
    assert response.status_code == 201, response.text


async def _import(client, headers, data: bytes):
    preview = await client.post("/api/toast-club/preview", files=_file(data), headers=headers)
    assert preview.status_code == 200, preview.text
    result = await client.post(
        "/api/toast-club/import",
        files=_file(data),
        data={"expected_sha256": preview.json()["sha256"]},
        headers=headers,
    )
    assert result.status_code == 201, result.text
    return preview.json(), result.json()


def test_parser_reads_weekday_cells_and_derives_one_shared_start_time():
    parsed = parse_booking_form(toast_docx(), filename="Toast Autumn 2026.docx")
    assert parsed.source_title == "Toast Autumn 2026"
    assert parsed.base_start_time == "15:30"
    bookings = [day for day in parsed.days if day.session_code]
    assert [(day.local_date.isoformat(), day.session_code, day.pickup_end) for day in bookings] == [
        ("2026-09-04", "2", "17:30"),
        ("2026-09-08", "2", "17:30"),
        ("2026-09-09", "2", "17:30"),
        ("2026-09-11", "1", "16:30"),
    ]


async def test_form_preview_matches_child_by_dob_and_persists_no_raw_contact_data(
    client, child1, adult_a_headers, initialized_db
):
    data = toast_docx()
    preview, result = await _import(client, adult_a_headers, data)
    assert preview["child_id"] == child1["id"]
    assert preview["child_name"] == "Child 1"
    assert preview["booked_days"] == 4
    assert preview["base_start_time"] == "15:30"
    assert preview["until_1630"] == 1
    assert preview["until_1730"] == 3
    assert result["imported"] is True

    async with aiosqlite.connect(initialized_db) as db:
        rows = await (await db.execute("SELECT * FROM toast_club_imports")).fetchall()
        days = await (await db.execute("SELECT * FROM toast_club_import_days")).fetchall()
    assert len(rows) == 1 and len(days) == 10
    database_bytes = open(initialized_db, "rb").read()
    assert b"private.person@example.invalid" not in database_bytes
    assert b"+00000000006" not in database_bytes


async def test_import_is_idempotent(client, child1, adult_a_headers):
    data = toast_docx()
    _, first = await _import(client, adult_a_headers, data)
    preview = await client.post("/api/toast-club/preview", files=_file(data), headers=adult_a_headers)
    assert preview.json()["already_imported"] is True
    second = await client.post(
        "/api/toast-club/import",
        files=_file(data),
        data={"expected_sha256": preview.json()["sha256"]},
        headers=adult_a_headers,
    )
    assert second.status_code == 201
    assert second.json()["imported"] is False
    assert second.json()["import_id"] == first["import_id"]


async def test_school_club_moves_toast_window_and_cancellation_moves_it_back(
    client, child1, adult_a_headers
):
    await _term(client, adult_a_headers, child1["id"])
    await _import(client, adult_a_headers, toast_docx())
    club = await client.post(
        "/api/clubs/",
        json={
            "name": "Football",
            "child_id": child1["id"],
            "weekday": 2,
            "start_time": "16:00",
            "end_time": "16:45",
            "active_from": "2026-09-01",
        },
        headers=adult_a_headers,
    )
    assert club.status_code == 201, club.text

    calendar = (
        await client.get(
            "/api/calendar/?start=2026-09-09&end=2026-09-10&limit=200",
            headers=adult_a_headers,
        )
    ).json()
    toast = next(item for item in calendar if item["event_type"] == "toast_club")
    assert toast["start_time"] == "2026-09-09T16:45:00+01:00"
    assert toast["end_time"] == "2026-09-09T17:30:00+01:00"
    assert toast["description"] == "After Football"

    cancelled = await client.put(
        f"/api/clubs/{club.json()['id']}/dates/2026-09-09/cancel",
        json={},
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 200, cancelled.text
    calendar = (
        await client.get(
            "/api/calendar/?start=2026-09-09&end=2026-09-10&limit=200",
            headers=adult_a_headers,
        )
    ).json()
    toast = next(item for item in calendar if item["event_type"] == "toast_club")
    assert toast["start_time"] == "2026-09-09T15:30:00+01:00"
    assert toast["description"] is None
    assert any(item["event_type"] == "school_club_cancelled" for item in calendar)


async def test_corrected_form_can_remove_a_previous_booking(
    client, child1, adult_a_headers
):
    await _import(client, adult_a_headers, toast_docx())
    corrected = toast_docx(first_week=("", "", "", "", ""))
    preview, result = await _import(client, adult_a_headers, corrected)
    assert preview["changes"]["removed"] == 1
    assert result["imported"] is True
    calendar = (
        await client.get(
            "/api/calendar/?start=2026-09-04&end=2026-09-05&limit=200",
            headers=adult_a_headers,
        )
    ).json()
    assert not any(item["event_type"].startswith("toast_club") for item in calendar)

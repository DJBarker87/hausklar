import asyncio
import json
import stat
from unittest.mock import AsyncMock

import aiosqlite
import pytest

from app.routers import calendar as calendar_router
from app.routers import documents as documents_router
from app.routers import tasks as tasks_router
from app.config import settings
from app.models.document import CaptureSuggestionCreate
from app.services.documents import (
    harden_document_store_permissions,
    resolve_storage_key,
    store_bytes,
)


@pytest.fixture(autouse=True)
def document_storage(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "document_storage_path", str(tmp_path / "documents"))
    monkeypatch.setattr(settings, "document_max_upload_bytes", 2 * 1024 * 1024)
    monkeypatch.setattr(settings, "hermes_bridge_url", "")
    monkeypatch.setattr(settings, "hermes_bridge_token", "")


async def upload_letter(
    client,
    headers,
    *,
    person_ids=None,
    suggestions=None,
    title="School letter",
    extracted_text="Sports day is Friday 17 July 2026. Please bring a packed lunch.",
    use_hermes=False,
    document_id=None,
    file_bytes=b"%PDF-1.4 test letter",
):
    return await client.post(
        "/api/documents/",
        headers=headers,
        files={"file": ("school-letter.pdf", file_bytes, "application/pdf")},
        data={
            **({"document_id": document_id} if document_id else {}),
            "title": title,
            "source": "scan",
            "category": "school",
            "document_date": "2026-07-10",
            "page_count": "2",
            "extracted_text": extracted_text,
            "person_ids": json.dumps(person_ids or []),
            "suggestions": json.dumps(suggestions or []),
            "use_hermes": "true" if use_hermes else "false",
        },
    )


async def test_store_bytes_keeps_email_evidence_owner_only(tmp_path, monkeypatch):
    storage_root = tmp_path / "private-documents"
    monkeypatch.setattr(settings, "document_storage_path", str(storage_root))

    storage_key, _, _, _ = await store_bytes(
        b"private receipt",
        filename="receipt.txt",
        media_type="text/plain",
        family_id="finance-evidence/family-1/space-1",
        document_id="source-1",
    )

    stored = resolve_storage_key(storage_key)
    assert stat.S_IMODE(stored.stat().st_mode) == 0o600
    current = stored.parent
    while current != storage_root.parent:
        assert stat.S_IMODE(current.stat().st_mode) == 0o700
        if current == storage_root:
            break
        current = current.parent


def test_startup_hardens_existing_document_store(tmp_path, monkeypatch):
    root = tmp_path / "documents"
    nested = root / "family" / "document"
    nested.mkdir(parents=True, mode=0o755)
    stored = nested / "old-receipt.pdf"
    stored.write_bytes(b"old receipt")
    root.chmod(0o755)
    (root / "family").chmod(0o755)
    nested.chmod(0o755)
    stored.chmod(0o644)
    monkeypatch.setattr(settings, "document_storage_path", str(root))

    harden_document_store_permissions()

    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    assert stat.S_IMODE((root / "family").stat().st_mode) == 0o700
    assert stat.S_IMODE(nested.stat().st_mode) == 0o700
    assert stat.S_IMODE(stored.stat().st_mode) == 0o600


async def test_upload_document_id_is_idempotent_and_family_scoped(
    client,
    adult_a_headers,
    other_family_headers,
):
    document_id = "5e3be3bd-0517-4ddc-a766-cf8cb09558f1"
    first = await upload_letter(client, adult_a_headers, document_id=document_id)
    replay = await upload_letter(client, adult_a_headers, document_id=document_id)

    assert first.status_code == 201, first.text
    assert replay.status_code == 201, replay.text
    assert first.json()["id"] == document_id
    assert replay.json()["id"] == document_id

    different_bytes = await upload_letter(
        client,
        adult_a_headers,
        document_id=document_id,
        file_bytes=b"%PDF-1.4 a different document",
    )
    another_family = await upload_letter(
        client,
        other_family_headers,
        document_id=document_id,
    )
    assert different_bytes.status_code == 409
    assert another_family.status_code == 409

    listing = await client.get("/api/documents/", headers=adult_a_headers)
    assert [item["id"] for item in listing.json()].count(document_id) == 1


async def test_upload_list_search_and_secure_download(
    client,
    adult_a_user,
    child1,
    adult_a_headers,
):
    suggestion = {
        "kind": "event",
        "title": "Sports day",
        "start_time": "2026-07-17",
        "all_day": True,
        "assigned_to": child1["id"],
        "confidence": 0.91,
        "source_text": "Sports day is Friday 17 July 2026",
    }
    response = await upload_letter(
        client,
        adult_a_headers,
        person_ids=[adult_a_user["id"], child1["id"]],
        suggestions=[suggestion],
    )
    assert response.status_code == 201, response.text
    document = response.json()
    assert document["status"] == "inbox"
    assert document["processor"] == "device"
    assert {person["person_id"] for person in document["people"]} == {
        adult_a_user["id"],
        child1["id"],
    }
    assert document["pending_suggestion_count"] == 1

    listing = await client.get(
        "/api/documents/",
        params={"person_id": child1["id"], "search": "packed lunch"},
        headers=adult_a_headers,
    )
    assert listing.status_code == 200
    assert [item["id"] for item in listing.json()] == [document["id"]]
    assert listing.json()[0]["extracted_text"] is None

    download = await client.get(document["download_url"], headers=adult_a_headers)
    assert download.status_code == 200
    assert download.content == b"%PDF-1.4 test letter"
    assert download.headers["content-type"].startswith("application/pdf")
    assert download.headers["x-content-type-options"] == "nosniff"
    assert download.headers["x-frame-options"] == "SAMEORIGIN"
    assert download.headers["content-security-policy"] == "frame-ancestors 'self'"

    detail_headers = await client.get(f"/api/documents/{document['id']}", headers=adult_a_headers)
    unauthenticated_download = await client.get(document["download_url"])
    assert detail_headers.headers["x-frame-options"] == "DENY"
    assert unauthenticated_download.status_code == 401
    assert unauthenticated_download.headers["x-frame-options"] == "DENY"


async def test_calendar_event_keeps_and_exposes_its_original_document(
    client,
    adult_a_headers,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Doctor letter")).json()

    created = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "Doctor appointment",
            "start_time": "2026-07-21T10:00:00Z",
            "end_time": "2026-07-21T10:30:00Z",
            "source_document_id": uploaded["id"],
        },
    )

    assert created.status_code == 201, created.text
    event = created.json()
    assert event["source_document_id"] == uploaded["id"]
    assert event["source_document"] == {
        "id": uploaded["id"],
        "title": "Doctor letter",
        "original_filename": "school-letter.pdf",
        "media_type": "application/pdf",
        "file_size": len(b"%PDF-1.4 test letter"),
        "download_url": f"/api/documents/{uploaded['id']}/content",
    }

    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-07-21", "end": "2026-07-21"},
        headers=adult_a_headers,
    )
    listed_event = next(item for item in listed.json() if item["id"] == event["id"])
    assert listed_event["source_document"] == event["source_document"]

    document_detail = await client.get(f"/api/documents/{uploaded['id']}", headers=adult_a_headers)
    assert document_detail.json()["linked_events"] == [
        {
            "id": event["id"],
            "title": "Doctor appointment",
            "start_time": "2026-07-21T10:00:00Z",
            "end_time": "2026-07-21T10:30:00Z",
            "all_day": False,
        }
    ]
    assert document_detail.json()["linked_tasks"] == []

    original = await client.get(
        listed_event["source_document"]["download_url"],
        headers=adult_a_headers,
    )
    assert original.content == b"%PDF-1.4 test letter"


async def test_calendar_event_preserves_ordered_labelled_attachments_across_edits(
    client,
    adult_a_headers,
    initialized_db,
):
    ticket = (await upload_letter(client, adult_a_headers, title="Train tickets")).json()
    booking = (await upload_letter(client, adult_a_headers, title="Hotel booking")).json()
    insurance = (await upload_letter(client, adult_a_headers, title="Travel insurance")).json()

    created = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "Family holiday",
            "start_time": "2026-08-20T08:00:00Z",
            "attachments": [
                {"document_id": ticket["id"], "role": "ticket"},
                {"document_id": booking["id"], "role": "booking"},
                {"document_id": insurance["id"], "role": "insurance"},
            ],
        },
    )
    assert created.status_code == 201, created.text
    event = created.json()
    assert event["source_document_id"] == ticket["id"]
    assert event["source_document"]["id"] == ticket["id"]
    assert [(item["id"], item["role"]) for item in event["attachments"]] == [
        (ticket["id"], "ticket"),
        (booking["id"], "booking"),
        (insurance["id"], "insurance"),
    ]

    ordinary_edit = await client.put(
        f"/api/calendar/{event['id']}",
        headers=adult_a_headers,
        json={"location": "St Pancras International"},
    )
    assert ordinary_edit.status_code == 200, ordinary_edit.text
    assert [item["id"] for item in ordinary_edit.json()["attachments"]] == [
        ticket["id"],
        booking["id"],
        insurance["id"],
    ]

    # An installed singular-link client may change its one visible document;
    # that must not silently erase newer attachments it cannot represent.
    legacy_edit = await client.put(
        f"/api/calendar/{event['id']}",
        headers=adult_a_headers,
        json={"source_document_id": booking["id"]},
    )
    assert legacy_edit.status_code == 200, legacy_edit.text
    assert legacy_edit.json()["source_document_id"] == booking["id"]
    assert [item["id"] for item in legacy_edit.json()["attachments"]] == [
        booking["id"],
        insurance["id"],
    ]

    relabelled = await client.put(
        f"/api/calendar/{event['id']}",
        headers=adult_a_headers,
        json={
            "attachments": [
                {"document_id": insurance["id"], "role": "insurance"},
                {"document_id": booking["id"], "role": "booking"},
            ]
        },
    )
    assert relabelled.status_code == 200, relabelled.text
    assert relabelled.json()["source_document_id"] == insurance["id"]
    assert [(item["id"], item["role"]) for item in relabelled.json()["attachments"]] == [
        (insurance["id"], "insurance"),
        (booking["id"], "booking"),
    ]

    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-08-20", "end": "2026-08-20"},
        headers=adult_a_headers,
    )
    listed_event = next(item for item in listed.json() if item["id"] == event["id"])
    assert listed_event["attachments"] == relabelled.json()["attachments"]

    async with aiosqlite.connect(initialized_db) as db:
        active = await (
            await db.execute(
                "SELECT document_id, role, position FROM calendar_event_documents "
                "WHERE event_id = ? AND deleted_at IS NULL ORDER BY position",
                (event["id"],),
            )
        ).fetchall()
        relation_history = await (
            await db.execute(
                "SELECT COUNT(*) FROM record_history "
                "WHERE table_name = 'calendar_event_documents'"
            )
        ).fetchone()
    assert active == [
        (insurance["id"], "insurance", 0),
        (booking["id"], "booking", 1),
    ]
    assert relation_history[0] >= 2


async def test_deleting_primary_calendar_attachment_promotes_the_next_document(
    client,
    adult_a_headers,
):
    ticket = (await upload_letter(client, adult_a_headers, title="Outbound ticket")).json()
    booking = (await upload_letter(client, adult_a_headers, title="Cottage booking")).json()
    event = (
        await client.post(
            "/api/calendar/",
            headers=adult_a_headers,
            json={
                "title": "Cornwall",
                "start_time": "2026-08-25",
                "all_day": True,
                "attachments": [
                    {"document_id": ticket["id"], "role": "ticket"},
                    {"document_id": booking["id"], "role": "booking"},
                ],
            },
        )
    ).json()

    deleted = await client.delete(f"/api/documents/{ticket['id']}", headers=adult_a_headers)
    assert deleted.status_code == 204

    listing = await client.get(
        "/api/calendar/",
        params={"start": "2026-08-25", "end": "2026-08-25"},
        headers=adult_a_headers,
    )
    refreshed = next(item for item in listing.json() if item["id"] == event["id"])
    assert refreshed["source_document_id"] == booking["id"]
    assert refreshed["source_document"]["id"] == booking["id"]
    assert [(item["id"], item["role"]) for item in refreshed["attachments"]] == [
        (booking["id"], "booking")
    ]

    booking_detail = await client.get(
        f"/api/documents/{booking['id']}",
        headers=adult_a_headers,
    )
    assert [item["id"] for item in booking_detail.json()["linked_events"]] == [event["id"]]


async def test_recurring_occurrence_edit_copies_all_event_attachments(
    client,
    adult_a_headers,
):
    ticket = (await upload_letter(client, adult_a_headers, title="Weekly ticket")).json()
    letter = (await upload_letter(client, adult_a_headers, title="Club letter")).json()
    series = (
        await client.post(
            "/api/calendar/",
            headers=adult_a_headers,
            json={
                "title": "Saturday club",
                "start_time": "2026-09-05T09:00:00Z",
                "recurrence_rule": "FREQ=WEEKLY;COUNT=3",
                "attachments": [
                    {"document_id": ticket["id"], "role": "ticket"},
                    {"document_id": letter["id"], "role": "school_letter"},
                ],
            },
        )
    ).json()

    isolated = await client.patch(
        f"/api/calendar/{series['id']}/occurrences",
        headers=adult_a_headers,
        json={
            "scope": "only_this",
            "occurrence_start": "2026-09-12T09:00:00Z",
            "updates": {"title": "Saturday club — later"},
        },
    )
    assert isolated.status_code == 200, isolated.text
    assert [(item["id"], item["role"]) for item in isolated.json()["attachments"]] == [
        (ticket["id"], "ticket"),
        (letter["id"], "school_letter"),
    ]

    listing = await client.get(
        "/api/calendar/",
        params={"start": "2026-09-05", "end": "2026-09-20", "limit": 50},
        headers=adult_a_headers,
    )
    club_events = [item for item in listing.json() if item["title"].startswith("Saturday club")]
    assert len(club_events) == 3
    assert all(len(item["attachments"]) == 2 for item in club_events)


async def test_empty_document_id_is_rejected_for_event_and_task_writes(
    client,
    adult_a_headers,
):
    event_create = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "Bad event attachment",
            "start_time": "2026-07-21T10:00:00Z",
            "source_document_id": "",
        },
    )
    task_create = await client.post(
        "/api/tasks/",
        headers=adult_a_headers,
        json={"title": "Bad task attachment", "source_document_id": ""},
    )
    assert event_create.status_code == 400
    assert task_create.status_code == 400

    event = (
        await client.post(
            "/api/calendar/",
            headers=adult_a_headers,
            json={"title": "Event", "start_time": "2026-07-21T11:00:00Z"},
        )
    ).json()
    task = (
        await client.post(
            "/api/tasks/",
            headers=adult_a_headers,
            json={"title": "Task"},
        )
    ).json()
    event_update = await client.put(
        f"/api/calendar/{event['id']}",
        headers=adult_a_headers,
        json={"source_document_id": ""},
    )
    task_update = await client.put(
        f"/api/tasks/{task['id']}",
        headers=adult_a_headers,
        json={"source_document_id": ""},
    )
    assert event_update.status_code == 400
    assert task_update.status_code == 400


async def test_calendar_document_link_is_family_scoped_and_history_backed(
    client,
    adult_a_headers,
    other_family_headers,
    initialized_db,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Private letter")).json()
    event = (
        await client.post(
            "/api/calendar/",
            headers=adult_a_headers,
            json={"title": "Appointment", "start_time": "2026-07-22T09:00:00Z"},
        )
    ).json()

    denied = await client.put(
        f"/api/calendar/{event['id']}",
        headers=other_family_headers,
        json={"source_document_id": uploaded["id"]},
    )
    assert denied.status_code == 404

    linked = await client.put(
        f"/api/calendar/{event['id']}",
        headers=adult_a_headers,
        json={"source_document_id": uploaded["id"]},
    )
    assert linked.status_code == 200, linked.text
    assert linked.json()["source_document"]["id"] == uploaded["id"]

    unlinked = await client.put(
        f"/api/calendar/{event['id']}",
        headers=adult_a_headers,
        json={"source_document_id": None},
    )
    assert unlinked.status_code == 200, unlinked.text
    assert unlinked.json()["source_document_id"] is None
    assert unlinked.json()["source_document"] is None

    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT previous_values FROM record_history "
                "WHERE table_name = 'calendar_events' AND record_id = ? "
                "ORDER BY changed_at",
                (event["id"],),
            )
        ).fetchall()
    assert len(rows) == 2
    assert json.loads(rows[0][0])["source_document_id"] is None
    assert json.loads(rows[1][0])["source_document_id"] == uploaded["id"]


async def test_calendar_rejects_document_from_another_family(
    client,
    adult_a_headers,
    other_family_headers,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Private letter")).json()

    response = await client.post(
        "/api/calendar/",
        headers=other_family_headers,
        json={
            "title": "Not my attachment",
            "start_time": "2026-07-22T09:00:00Z",
            "source_document_id": uploaded["id"],
        },
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Attached document is not available to this family"


async def test_task_keeps_document_through_updates_and_completion(
    client,
    adult_a_headers,
    initialized_db,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Permission form")).json()
    created = await client.post(
        "/api/tasks/",
        headers=adult_a_headers,
        json={
            "title": "Return permission form",
            "source_document_id": uploaded["id"],
        },
    )

    assert created.status_code == 201, created.text
    task = created.json()
    assert task["source_document_id"] == uploaded["id"]
    assert task["source_document"]["original_filename"] == "school-letter.pdf"

    document_detail = await client.get(f"/api/documents/{uploaded['id']}", headers=adult_a_headers)
    assert document_detail.json()["linked_tasks"] == [
        {
            "id": task["id"],
            "title": "Return permission form",
            "due_date": None,
            "completed_at": None,
        }
    ]

    edited = await client.put(
        f"/api/tasks/{task['id']}",
        headers=adult_a_headers,
        json={"title": "Return signed permission form"},
    )
    assert edited.status_code == 200
    assert edited.json()["source_document"]["id"] == uploaded["id"]

    completed = await client.patch(
        f"/api/tasks/{task['id']}/complete",
        headers=adult_a_headers,
    )
    assert completed.status_code == 200
    assert completed.json()["source_document"]["id"] == uploaded["id"]

    async with aiosqlite.connect(initialized_db) as db:
        history = await (
            await db.execute(
                "SELECT previous_values FROM record_history "
                "WHERE table_name = 'tasks' AND record_id = ? ORDER BY changed_at",
                (task["id"],),
            )
        ).fetchall()
    assert len(history) == 2
    assert all(json.loads(row[0])["source_document_id"] == uploaded["id"] for row in history)


async def test_task_document_link_can_be_removed_but_not_stolen(
    client,
    adult_a_headers,
    other_family_headers,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Private form")).json()
    other_task = (
        await client.post(
            "/api/tasks/",
            headers=other_family_headers,
            json={"title": "Other family task"},
        )
    ).json()

    denied = await client.put(
        f"/api/tasks/{other_task['id']}",
        headers=other_family_headers,
        json={"source_document_id": uploaded["id"]},
    )
    assert denied.status_code == 400
    assert denied.json()["detail"] == "Attached document is not available to this family"

    own_task = (
        await client.post(
            "/api/tasks/",
            headers=adult_a_headers,
            json={"title": "Own task", "source_document_id": uploaded["id"]},
        )
    ).json()
    unlinked = await client.put(
        f"/api/tasks/{own_task['id']}",
        headers=adult_a_headers,
        json={"source_document_id": None},
    )
    assert unlinked.status_code == 200
    assert unlinked.json()["source_document_id"] is None
    assert unlinked.json()["source_document"] is None


async def test_deleting_document_detaches_linked_event_and_task_with_history(
    client,
    adult_a_headers,
    initialized_db,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Appointment evidence")).json()
    event = (
        await client.post(
            "/api/calendar/",
            headers=adult_a_headers,
            json={
                "title": "Consultant appointment",
                "start_time": "2026-07-23T10:00:00Z",
                "source_document_id": uploaded["id"],
            },
        )
    ).json()
    task = (
        await client.post(
            "/api/tasks/",
            headers=adult_a_headers,
            json={
                "title": "Bring referral letter",
                "source_document_id": uploaded["id"],
            },
        )
    ).json()

    deleted = await client.delete(f"/api/documents/{uploaded['id']}", headers=adult_a_headers)

    assert deleted.status_code == 204
    refreshed_events = await client.get(
        "/api/calendar/",
        params={"start": "2026-07-23", "end": "2026-07-23"},
        headers=adult_a_headers,
    )
    refreshed_tasks = await client.get(
        "/api/tasks/",
        params={"status": "pending"},
        headers=adult_a_headers,
    )
    assert refreshed_events.status_code == 200
    refreshed_event = next(item for item in refreshed_events.json() if item["id"] == event["id"])
    assert refreshed_event["source_document_id"] is None
    assert refreshed_event["source_document"] is None
    assert refreshed_tasks.status_code == 200
    refreshed_task = next(item for item in refreshed_tasks.json() if item["id"] == task["id"])
    assert refreshed_task["source_document_id"] is None
    assert refreshed_task["source_document"] is None

    async with aiosqlite.connect(initialized_db) as db:
        history = await (
            await db.execute(
                "SELECT table_name, record_id, previous_values FROM record_history "
                "WHERE record_id IN (?, ?) ORDER BY table_name",
                (event["id"], task["id"]),
            )
        ).fetchall()
    assert [(row[0], row[1]) for row in history] == [
        ("calendar_events", event["id"]),
        ("tasks", task["id"]),
    ]
    assert all(json.loads(row[2])["source_document_id"] == uploaded["id"] for row in history)


async def test_calendar_attachment_update_serializes_with_document_deletion(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Race proof letter")).json()
    event = (
        await client.post(
            "/api/calendar/",
            headers=adult_a_headers,
            json={"title": "Appointment", "start_time": "2026-07-24T10:00:00Z"},
        )
    ).json()

    validation_finished = asyncio.Event()
    release_update = asyncio.Event()
    original_normalise = calendar_router._normalised_event_updates

    async def pause_after_validation(*args, **kwargs):
        updates = await original_normalise(*args, **kwargs)
        validation_finished.set()
        await release_update.wait()
        return updates

    monkeypatch.setattr(calendar_router, "_normalised_event_updates", pause_after_validation)
    update_task = asyncio.create_task(
        client.put(
            f"/api/calendar/{event['id']}",
            headers=adult_a_headers,
            json={"source_document_id": uploaded["id"]},
        )
    )
    await asyncio.wait_for(validation_finished.wait(), timeout=1)
    delete_task = asyncio.create_task(
        client.delete(f"/api/documents/{uploaded['id']}", headers=adult_a_headers)
    )

    # The update acquired its write reservation before validating the attachment,
    # so deletion must not overtake it after validation and recreate a dangling ID.
    completed, _ = await asyncio.wait({delete_task}, timeout=0.1)
    release_update.set()
    updated, deleted = await asyncio.gather(update_task, delete_task)

    assert not completed
    assert updated.status_code == 200, updated.text
    assert deleted.status_code == 204, deleted.text
    async with aiosqlite.connect(initialized_db) as db:
        stored_source = (
            await (
                await db.execute(
                    "SELECT source_document_id FROM calendar_events WHERE id = ?",
                    (event["id"],),
                )
            ).fetchone()
        )[0]
    assert stored_source is None


async def test_task_attachment_update_reserves_writer_before_document_deletion(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Task race proof")).json()
    task = (
        await client.post(
            "/api/tasks/",
            headers=adult_a_headers,
            json={"title": "Bring the letter"},
        )
    ).json()

    history_reached = asyncio.Event()
    release_update = asyncio.Event()
    original_save_history = tasks_router._save_history

    async def pause_before_history(*args, **kwargs):
        history_reached.set()
        await release_update.wait()
        return await original_save_history(*args, **kwargs)

    monkeypatch.setattr(tasks_router, "_save_history", pause_before_history)
    update_task = asyncio.create_task(
        client.put(
            f"/api/tasks/{task['id']}",
            headers=adult_a_headers,
            json={"source_document_id": uploaded["id"]},
        )
    )
    await asyncio.wait_for(history_reached.wait(), timeout=1)
    delete_task = asyncio.create_task(
        client.delete(f"/api/documents/{uploaded['id']}", headers=adult_a_headers)
    )

    completed, _ = await asyncio.wait({delete_task}, timeout=0.1)
    release_update.set()
    updated, deleted = await asyncio.gather(update_task, delete_task)

    assert not completed
    assert updated.status_code == 200, updated.text
    assert deleted.status_code == 204, deleted.text
    async with aiosqlite.connect(initialized_db) as db:
        stored_source = (
            await (
                await db.execute(
                    "SELECT source_document_id FROM tasks WHERE id = ?",
                    (task["id"],),
                )
            ).fetchone()
        )[0]
    assert stored_source is None


async def test_create_suggestion_cannot_leave_orphan_during_document_deletion(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    uploaded = (await upload_letter(client, adult_a_headers, title="Suggestion race proof")).json()
    insert_reached = asyncio.Event()
    release_create = asyncio.Event()
    original_insert_suggestions = documents_router._insert_suggestions

    async def pause_before_insert(*args, **kwargs):
        insert_reached.set()
        await release_create.wait()
        return await original_insert_suggestions(*args, **kwargs)

    monkeypatch.setattr(documents_router, "_insert_suggestions", pause_before_insert)
    create_task = asyncio.create_task(
        client.post(
            f"/api/documents/{uploaded['id']}/suggestions",
            headers=adult_a_headers,
            json={"kind": "task", "title": "Read the letter"},
        )
    )
    await asyncio.wait_for(insert_reached.wait(), timeout=1)
    delete_task = asyncio.create_task(
        client.delete(f"/api/documents/{uploaded['id']}", headers=adult_a_headers)
    )

    completed, _ = await asyncio.wait({delete_task}, timeout=0.1)
    release_create.set()
    created, deleted = await asyncio.gather(create_task, delete_task)

    assert not completed
    assert created.status_code == 201, created.text
    assert deleted.status_code == 204, deleted.text
    async with aiosqlite.connect(initialized_db) as db:
        active_suggestions = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM capture_suggestions "
                    "WHERE document_id = ? AND deleted_at IS NULL",
                    (uploaded["id"],),
                )
            ).fetchone()
        )[0]
    assert active_suggestions == 0


async def test_accept_all_suggestions_creates_records_and_reports_skips(
    client, adult_a_user, child1, adult_a_headers, initialized_db
):
    suggestions = [
        {
            "kind": "event",
            "title": "Sports day",
            "start_time": "2026-07-17",
            "all_day": True,
            "assigned_to": child1["id"],
            "confidence": 0.9,
        },
        {
            "kind": "task",
            "title": "Return permission slip",
            "due_date": "2026-07-15",
            "confidence": 0.8,
        },
        {
            "kind": "event",
            "title": "Assigned to a stranger",
            "start_time": "2026-07-18",
            "all_day": True,
            "confidence": 0.7,
        },
    ]
    upload = await upload_letter(client, adult_a_headers, suggestions=suggestions)
    document = upload.json()

    # Simulate the assignee being removed between upload and review.
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE capture_suggestions SET assigned_to = 'not-in-this-family' "
            "WHERE document_id = ? AND title = 'Assigned to a stranger'",
            (document["id"],),
        )
        await db.commit()

    response = await client.post(
        f"/api/documents/{document['id']}/suggestions/accept-all",
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    outcome = response.json()
    assert len(outcome["accepted"]) == 2
    assert {item["result_type"] for item in outcome["accepted"]} == {"event", "task"}
    assert len(outcome["skipped"]) == 1
    assert "family member" in outcome["skipped"][0]["reason"]

    event_id = next(
        item["result_id"] for item in outcome["accepted"] if item["result_type"] == "event"
    )
    events = await client.get(
        "/api/calendar/?start=2026-07-16&end=2026-07-18",
        headers=adult_a_headers,
    )
    assert any(item["id"] == event_id for item in events.json())

    tasks = await client.get("/api/tasks/?status=pending", headers=adult_a_headers)
    assert any(item["title"] == "Return permission slip" for item in tasks.json())

    # Re-running finds nothing pending and accepts nothing new.
    repeat = await client.post(
        f"/api/documents/{document['id']}/suggestions/accept-all",
        headers=adult_a_headers,
    )
    assert repeat.status_code == 200
    assert repeat.json()["accepted"] == []


async def test_accept_all_is_isolated_by_family(client, adult_a_headers, other_family_headers):
    upload = await upload_letter(
        client,
        adult_a_headers,
        suggestions=[
            {
                "kind": "task",
                "title": "Pay invoice",
                "due_date": "2026-07-20",
                "confidence": 0.9,
            }
        ],
    )
    document = upload.json()

    response = await client.post(
        f"/api/documents/{document['id']}/suggestions/accept-all",
        headers=other_family_headers,
    )
    assert response.status_code == 404


async def test_document_search_index_tracks_edits_and_deletes(client, adult_a_headers):
    first = (await upload_letter(client, adult_a_headers)).json()
    second = (
        await upload_letter(
            client,
            adult_a_headers,
            title="Trumpet recital",
            extracted_text="The trumpet recital takes place in the concert hall.",
        )
    ).json()

    listing = await client.get("/api/documents/", params={"search": "trumpet"}, headers=adult_a_headers)
    assert [item["id"] for item in listing.json()] == [second["id"]]

    # Re-titling a document must update the search index.
    updated = await client.patch(
        f"/api/documents/{first['id']}",
        json={"title": "Violin timetable"},
        headers=adult_a_headers,
    )
    assert updated.status_code == 200
    listing = await client.get("/api/documents/", params={"search": "violin"}, headers=adult_a_headers)
    assert [item["id"] for item in listing.json()] == [first["id"]]

    # Deleted documents must drop out of search results.
    removed = await client.delete(f"/api/documents/{second['id']}", headers=adult_a_headers)
    assert removed.status_code in (200, 204)
    listing = await client.get("/api/documents/", params={"search": "trumpet"}, headers=adult_a_headers)
    assert listing.json() == []


async def test_document_access_is_isolated_by_family(
    client,
    adult_a_headers,
    other_family_headers,
):
    response = await upload_letter(client, adult_a_headers)
    document = response.json()

    assert (
        await client.get(f"/api/documents/{document['id']}", headers=other_family_headers)
    ).status_code == 404
    assert (
        await client.get(f"/api/documents/{document['id']}/content", headers=other_family_headers)
    ).status_code == 404
    assert (await client.get("/api/documents/", headers=other_family_headers)).json() == []


async def test_invalid_person_and_media_type_are_rejected(client, adult_a_headers):
    invalid_person = await upload_letter(
        client,
        adult_a_headers,
        person_ids=["00000000-0000-0000-0000-999999999999"],
    )
    assert invalid_person.status_code == 422

    invalid_media = await client.post(
        "/api/documents/",
        headers=adult_a_headers,
        files={"file": ("archive.zip", b"not allowed", "application/zip")},
        data={"title": "Archive"},
    )
    assert invalid_media.status_code == 413
    assert "Only PDF" in invalid_media.json()["detail"]


async def test_hermes_suggestions_replace_device_fallback(
    client,
    child1,
    adult_a_headers,
    monkeypatch,
):
    hermes_result = [
        CaptureSuggestionCreate(
            kind="task",
            title="Pack lunch",
            due_date="2026-07-17T07:00:00Z",
            assigned_to=child1["id"],
            confidence=0.98,
        )
    ]
    mock_extract = AsyncMock(return_value=hermes_result)
    monkeypatch.setattr("app.routers.documents.extract_capture_suggestions", mock_extract)

    response = await upload_letter(
        client,
        adult_a_headers,
        person_ids=[child1["id"]],
        suggestions=[
            {
                "kind": "event",
                "title": "Device guess",
                "start_time": "2026-07-17",
            }
        ],
        use_hermes=True,
    )
    assert response.status_code == 201, response.text
    document = response.json()
    assert document["processor"] == "hermes"
    assert [item["title"] for item in document["suggestions"]] == ["Pack lunch"]
    mock_extract.assert_awaited_once()


async def test_hermes_processing_requires_explicit_opt_in(client, adult_a_headers, monkeypatch):
    mock_extract = AsyncMock()
    monkeypatch.setattr("app.routers.documents.extract_capture_suggestions", mock_extract)

    response = await client.post(
        "/api/documents/",
        headers=adult_a_headers,
        files={"file": ("letter.txt", b"Please pay by Friday", "text/plain")},
        data={
            "title": "Letter",
            "source": "text",
            "extracted_text": "Please pay by Friday",
        },
    )

    assert response.status_code == 201, response.text
    assert response.json()["processor"] == "fallback"
    mock_extract.assert_not_awaited()


async def test_hermes_upload_requires_current_ai_permission(client, adult_a_headers, monkeypatch):
    revoked = await client.delete("/api/auth/ai-consent", headers=adult_a_headers)
    assert revoked.status_code == 200
    mock_extract = AsyncMock()
    monkeypatch.setattr("app.routers.documents.extract_capture_suggestions", mock_extract)

    response = await upload_letter(client, adult_a_headers, use_hermes=True)

    assert response.status_code == 428
    assert "OpenAI" in response.json()["detail"]
    mock_extract.assert_not_awaited()


async def test_accept_event_creates_linked_calendar_entry_and_files_document(
    client,
    child1,
    adult_a_headers,
    initialized_db,
):
    response = await upload_letter(
        client,
        adult_a_headers,
        person_ids=[child1["id"]],
        suggestions=[
            {
                "kind": "event",
                "title": "Sports day",
                "start_time": "2026-07-17",
                "all_day": True,
                "assigned_to": child1["id"],
            }
        ],
    )
    document = response.json()
    suggestion = document["suggestions"][0]

    accepted = await client.post(
        f"/api/documents/{document['id']}/suggestions/{suggestion['id']}/accept",
        json={"title": "Junior sports day"},
        headers=adult_a_headers,
    )
    assert accepted.status_code == 200, accepted.text
    result = accepted.json()
    assert result["result_type"] == "event"

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM calendar_events WHERE id = ?",
            (result["result_id"],),
        )
        event = await cursor.fetchone()
        assert event["title"] == "Junior sports day"
        assert event["source_document_id"] == document["id"]
        assert event["assigned_to"] == child1["id"]

    detail = await client.get(f"/api/documents/{document['id']}", headers=adult_a_headers)
    assert detail.json()["status"] == "filed"
    assert detail.json()["suggestions"][0]["status"] == "accepted"
    assert detail.json()["suggestions"][0]["result_status"] == "scheduled"

    filed_listing = await client.get(
        "/api/documents/", params={"status": "filed"}, headers=adult_a_headers
    )
    listed_document = next(item for item in filed_listing.json() if item["id"] == document["id"])
    assert listed_document["suggestions"] == []


async def test_accept_task_creates_assignment_and_preserves_other_pending_item(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
):
    response = await upload_letter(
        client,
        adult_a_headers,
        person_ids=[adult_a_user["id"]],
        suggestions=[
            {
                "kind": "task",
                "title": "Return permission slip",
                "due_date": "2026-07-15T17:00:00Z",
                "assigned_to": adult_a_user["id"],
            },
            {
                "kind": "event",
                "title": "Synthetic public demo record 18",
                "start_time": "2026-07-20",
            },
        ],
    )
    document = response.json()
    suggestion = document["suggestions"][0]

    accepted = await client.post(
        f"/api/documents/{document['id']}/suggestions/{suggestion['id']}/accept",
        json={},
        headers=adult_a_headers,
    )
    assert accepted.status_code == 200
    result_id = accepted.json()["result_id"]

    async with aiosqlite.connect(initialized_db) as db:
        cursor = await db.execute(
            "SELECT source_document_id FROM tasks WHERE id = ?",
            (result_id,),
        )
        assert (await cursor.fetchone())[0] == document["id"]
        cursor = await db.execute(
            "SELECT assignee_id, assignee_type FROM task_assignments WHERE task_id = ?",
            (result_id,),
        )
        assert await cursor.fetchone() == (adult_a_user["id"], "user")

    detail = await client.get(f"/api/documents/{document['id']}", headers=adult_a_headers)
    assert detail.json()["status"] == "inbox"
    assert detail.json()["pending_suggestion_count"] == 1
    assert detail.json()["suggestions"][0]["result_status"] == "open"


async def test_concurrent_accept_creates_exactly_one_linked_result(
    client,
    adult_a_headers,
    initialized_db,
):
    document = (
        await upload_letter(
            client,
            adult_a_headers,
            suggestions=[{"kind": "task", "title": "Pay nursery invoice"}],
        )
    ).json()
    suggestion_id = document["suggestions"][0]["id"]
    path = f"/api/documents/{document['id']}/suggestions/{suggestion_id}/accept"

    responses = await asyncio.gather(
        client.post(path, json={}, headers=adult_a_headers),
        client.post(path, json={}, headers=adult_a_headers),
    )

    assert sorted(response.status_code for response in responses) == [200, 409]
    winner = next(response.json() for response in responses if response.status_code == 200)
    async with aiosqlite.connect(initialized_db) as db:
        task_rows = await (
            await db.execute(
                "SELECT id FROM tasks WHERE source_document_id = ? AND deleted_at IS NULL",
                (document["id"],),
            )
        ).fetchall()
        suggestion = await (
            await db.execute(
                "SELECT status, result_id FROM capture_suggestions WHERE id = ?",
                (suggestion_id,),
            )
        ).fetchone()

    assert task_rows == [(winner["result_id"],)]
    assert suggestion == ("accepted", winner["result_id"])


async def test_concurrent_accept_and_dismiss_have_one_consistent_winner(
    client,
    adult_a_headers,
    initialized_db,
):
    document = (
        await upload_letter(
            client,
            adult_a_headers,
            suggestions=[{"kind": "task", "title": "Review nursery invoice"}],
        )
    ).json()
    suggestion_id = document["suggestions"][0]["id"]
    base = f"/api/documents/{document['id']}/suggestions/{suggestion_id}"

    accepted, dismissed = await asyncio.gather(
        client.post(f"{base}/accept", json={}, headers=adult_a_headers),
        client.post(f"{base}/dismiss", headers=adult_a_headers),
    )

    assert sorted([accepted.status_code, dismissed.status_code]) == [200, 409]
    async with aiosqlite.connect(initialized_db) as db:
        result_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM tasks "
                    "WHERE source_document_id = ? AND deleted_at IS NULL",
                    (document["id"],),
                )
            ).fetchone()
        )[0]
        suggestion = await (
            await db.execute(
                "SELECT status, result_id FROM capture_suggestions WHERE id = ?",
                (suggestion_id,),
            )
        ).fetchone()

    if accepted.status_code == 200:
        assert result_count == 1
        assert suggestion == ("accepted", accepted.json()["result_id"])
    else:
        assert result_count == 0
        assert suggestion == ("dismissed", None)


async def test_manual_document_action_tracks_task_completion(
    client,
    adult_a_user,
    adult_a_headers,
):
    document = (await upload_letter(client, adult_a_headers)).json()

    created = await client.post(
        f"/api/documents/{document['id']}/suggestions",
        json={
            "kind": "task",
            "title": "Pay nursery invoice",
            "due_date": "2026-07-20T17:00:00Z",
            "assigned_to": adult_a_user["id"],
            "confidence": 1,
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    suggestion = created.json()
    assert suggestion["result_status"] == "pending"

    accepted = await client.post(
        f"/api/documents/{document['id']}/suggestions/{suggestion['id']}/accept",
        json={},
        headers=adult_a_headers,
    )
    assert accepted.status_code == 200, accepted.text
    task_id = accepted.json()["result_id"]

    listing = await client.get("/api/documents/", headers=adult_a_headers)
    assert listing.json()[0]["suggestions"] == []
    detail = await client.get(f"/api/documents/{document['id']}", headers=adult_a_headers)
    linked_action = detail.json()["suggestions"][0]
    assert linked_action["result_status"] == "open"
    assert linked_action["assigned_to_name"] == adult_a_user["name"]

    completed = await client.patch(
        f"/api/tasks/{task_id}/complete",
        json={},
        headers=adult_a_headers,
    )
    assert completed.status_code == 200, completed.text

    detail = await client.get(f"/api/documents/{document['id']}", headers=adult_a_headers)
    action = detail.json()["suggestions"][0]
    assert action["result_status"] == "completed"
    assert action["result_completed_at"] is not None


async def test_dismiss_last_suggestion_updates_stats_and_soft_delete_hides_document(
    client,
    child1,
    adult_a_headers,
    initialized_db,
):
    response = await upload_letter(
        client,
        adult_a_headers,
        person_ids=[child1["id"]],
        suggestions=[{"kind": "task", "title": "Ignore this", "assigned_to": child1["id"]}],
    )
    document = response.json()
    suggestion_id = document["suggestions"][0]["id"]

    stats = await client.get("/api/documents/stats", headers=adult_a_headers)
    assert stats.json()["inbox_documents"] == 1
    assert stats.json()["pending_suggestions"] == 1
    assert stats.json()["by_person"][child1["id"]] == 1

    dismissed = await client.post(
        f"/api/documents/{document['id']}/suggestions/{suggestion_id}/dismiss",
        headers=adult_a_headers,
    )
    assert dismissed.status_code == 200
    assert (await client.get(f"/api/documents/{document['id']}", headers=adult_a_headers)).json()[
        "status"
    ] == "filed"

    deleted = await client.delete(f"/api/documents/{document['id']}", headers=adult_a_headers)
    assert deleted.status_code == 204
    assert (
        await client.get(f"/api/documents/{document['id']}", headers=adult_a_headers)
    ).status_code == 404

    async with aiosqlite.connect(initialized_db) as db:
        cursor = await db.execute(
            "SELECT deleted_at, storage_key FROM documents WHERE id = ?",
            (document["id"],),
        )
        deleted_at, storage_key = await cursor.fetchone()
        assert deleted_at is not None
    assert not resolve_storage_key(storage_key).exists()


async def test_family_document_quota_rejects_cumulative_storage(
    client,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(settings, "document_family_quota_bytes", 30)

    first = await upload_letter(client, adult_a_headers, title="First letter")
    second = await upload_letter(client, adult_a_headers, title="Second letter")
    stats = await client.get("/api/documents/stats", headers=adult_a_headers)

    assert first.status_code == 201
    assert second.status_code == 413
    assert "quota" in second.json()["detail"].lower()
    assert stats.json()["storage_bytes"] == len(b"%PDF-1.4 test letter")
    assert stats.json()["storage_quota_bytes"] == 30


async def test_update_document_people_and_archive(client, adult_a_user, child1, adult_a_headers):
    response = await upload_letter(client, adult_a_headers, person_ids=[child1["id"]])
    document = response.json()

    updated = await client.patch(
        f"/api/documents/{document['id']}",
        json={
            "title": "Updated letter",
            "person_ids": [adult_a_user["id"]],
            "status": "archived",
        },
        headers=adult_a_headers,
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["title"] == "Updated letter"
    assert [person["person_id"] for person in updated.json()["people"]] == [adult_a_user["id"]]
    assert (await client.get("/api/documents/", headers=adult_a_headers)).json() == []
    archived = await client.get(
        "/api/documents/",
        params={"status": "archived"},
        headers=adult_a_headers,
    )
    assert [item["id"] for item in archived.json()] == [document["id"]]


async def test_file_ready_batch_skips_uncertain_metadata_and_pending_actions(
    client,
    adult_a_headers,
    initialized_db,
):
    ready = (await upload_letter(client, adult_a_headers, title="Reviewed passport")).json()
    pending = (
        await upload_letter(
            client,
            adult_a_headers,
            title="Trip form",
            suggestions=[{"kind": "task", "title": "Return the trip form"}],
        )
    ).json()
    uncertain = (await upload_letter(client, adult_a_headers, title="Forwarded invoice")).json()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE documents SET category_confidence = 0.25, "
            "document_date_confidence = 0.35 WHERE id = ?",
            (uncertain["id"],),
        )
        await db.commit()

    uncertain_detail = await client.get(
        f"/api/documents/{uncertain['id']}", headers=adult_a_headers
    )
    assert uncertain_detail.json()["ready_for_batch_filing"] is False

    filed = await client.post(
        "/api/documents/file-ready",
        json={"document_ids": [ready["id"], pending["id"], uncertain["id"]]},
        headers=adult_a_headers,
    )
    assert filed.status_code == 200, filed.text
    assert filed.json() == {
        "filed_ids": [ready["id"]],
        "skipped_ids": [pending["id"], uncertain["id"]],
    }

    reviewed = await client.patch(
        f"/api/documents/{uncertain['id']}",
        json={"category": "finance", "document_date": None},
        headers=adult_a_headers,
    )
    assert reviewed.status_code == 200, reviewed.text
    assert reviewed.json()["category_confidence"] is None
    assert reviewed.json()["document_date_confidence"] is None
    assert reviewed.json()["ready_for_batch_filing"] is True


async def test_archived_documents_still_count_towards_storage(client, adult_a_headers):
    uploaded = await upload_letter(client, adult_a_headers)
    document = uploaded.json()
    archived = await client.patch(
        f"/api/documents/{document['id']}",
        json={"status": "archived"},
        headers=adult_a_headers,
    )
    assert archived.status_code == 200

    stats = await client.get("/api/documents/stats", headers=adult_a_headers)
    assert stats.status_code == 200
    assert stats.json()["total_documents"] == 0
    assert stats.json()["storage_bytes"] == len(b"%PDF-1.4 test letter")

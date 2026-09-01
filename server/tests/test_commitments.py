"""Focused coverage for review-first incoming family commitments."""

import json
import uuid
from datetime import datetime

import aiosqlite
import pytest

from conftest import EXAMPLE_FAMILY_ID
from app.database import init_db
from app.models.commitment import CommitmentPlan
from app.services.account_deletion import delete_account_data
from app.services.calendar_recurrence import CalendarRecurrenceError, expand_calendar_rows
from app.services.commitments import _deterministic_id, _material_changes


def _id(index: int) -> str:
    return f"10000000-0000-4000-8000-{index:012d}"


async def _insert_document(db_path: str, document_id: str, *, family_id: str = EXAMPLE_FAMILY_ID):
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO documents
               (id, title, original_filename, media_type, storage_key, file_size,
                sha256, source, category, status, extracted_text, family_id,
                created_at, updated_at, created_by)
               VALUES (?, ?, 'source.pdf', 'application/pdf', ?, 128, ?, 'file',
                       'school', 'inbox', ?, ?, ?, ?, ?)""",
            (
                document_id,
                "Source letter",
                f"documents/{document_id}.pdf",
                f"sha-{document_id}",
                "World Book Day is Thursday 20 August 2026. Bring a costume.",
                family_id,
                "2026-08-12T09:00:00+00:00",
                "2026-08-12T09:00:00+00:00",
                _id(999),
            ),
        )
        await db.commit()


def _manual_source(index: int = 1) -> dict:
    return {"id": _id(100 + index), "kind": "manual", "label": "Reviewed message"}


def _school_payload(child_id: str, *, commitment_id: str | None = None) -> dict:
    event_id = _id(201)
    return {
        "id": commitment_id or _id(1),
        "kind": "school",
        "visibility": "family",
        "title": "World Book Day",
        "summary": "Costume and payment required",
        "sources": [_manual_source()],
        "plan": {
            "events": [
                {
                    "id": event_id,
                    "title": "World Book Day",
                    "start_time": "2026-08-20",
                    "all_day": True,
                    "person_ids": [child_id],
                    "assigned_to": child_id,
                    "event_type": "school",
                }
            ],
            "tasks": [
                {
                    "id": _id(202),
                    "title": "Pay for World Book Day",
                    "due_date": "2026-08-14",
                    "priority": 2,
                }
            ],
            "preparations": [
                {
                    "id": _id(203),
                    "event_id": event_id,
                    "name": "School preparation",
                    "items": ["Prepare costume", "Pack school bag"],
                    "lead_hours": 48,
                }
            ],
        },
    }


def _typed_single_event_payload(
    kind: str,
    child_id: str,
    *,
    commitment_id: str,
    event_id: str,
    source_id: str,
    visibility: str = "family",
) -> dict:
    return {
        "id": commitment_id,
        "kind": kind,
        "visibility": visibility,
        "title": f"{kind.title()} plan",
        "sources": [{"id": source_id, "kind": "manual", "label": "Reviewed plan"}],
        "plan": {
            "events": [
                {
                    "id": event_id,
                    "title": f"{kind.title()} event",
                    "start_time": "2026-09-15T10:00:00+01:00",
                    "end_time": "2026-09-15T12:00:00+01:00",
                    "person_ids": [child_id],
                    "event_type": kind,
                }
            ]
        },
    }


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("kind", "event_count", "needs_action"),
    [
        ("school", 1, False),
        ("invitation", 1, True),
        ("outing", 1, False),
        ("childcare", 1, False),
        ("appointment", 1, True),
        ("travel", 2, False),
    ],
)
async def test_each_workflow_kind_has_a_valid_review_only_entry_contract(
    client, adult_a_headers, child1, kind, event_count, needs_action
):
    kind_index = {
        "school": 31,
        "invitation": 32,
        "outing": 33,
        "childcare": 34,
        "appointment": 35,
        "travel": 36,
    }[kind]
    events = [
        {
            "id": _id(300 + kind_index * 2 + index),
            "title": f"{kind.title()} event {index + 1}",
            "start_time": f"2026-09-{10 + index:02d}T10:00:00+01:00",
            "person_ids": [child1["id"]],
            "event_type": "childcare" if kind == "childcare" else kind,
        }
        for index in range(event_count)
    ]
    external_action = None
    if needs_action:
        external_action = {
            "kind": "rsvp" if kind == "invitation" else "book",
            "label": "Reply" if kind == "invitation" else "Book appointment",
            "target_type": "manual",
            "target": "Follow the reviewed source instructions",
        }
    payload = {
        "id": _id(kind_index),
        "kind": kind,
        "title": f"{kind.title()} workflow",
        "sources": [{"id": _id(400 + kind_index), "kind": "manual", "label": "Reviewed source"}],
        "plan": {"events": events, "external_action": external_action},
    }
    if kind == "school":
        payload["plan"]["tasks"] = [{"id": _id(500), "title": "School action"}]
    response = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert response.status_code == 201, response.text
    assert response.json()["kind"] == kind
    assert response.json()["results"] == []
    assert response.json()["status"] == ("action_required" if needs_action else "draft")


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "kind",
    ["school", "invitation", "outing", "childcare", "appointment", "travel"],
)
async def test_each_workflow_persists_incomplete_draft_but_blocks_confirmation(
    client, adult_a_headers, kind
):
    commitment_id = str(uuid.uuid4())
    response = await client.post(
        "/api/commitments/",
        headers=adult_a_headers,
        json={
            "id": commitment_id,
            "kind": kind,
            "title": "Incomplete source",
            "sources": [{"id": str(uuid.uuid4()), "kind": "manual", "label": "Reviewed source"}],
            "plan": {},
        },
    )
    assert response.status_code == 201, response.text
    draft = response.json()
    assert draft["review_issues"]
    confirmation = await client.post(
        f"/api/commitments/{commitment_id}/confirm",
        headers=adult_a_headers,
        json={"expected_revision": 1, "confirmed": True},
    )
    assert confirmation.status_code == 400


@pytest.mark.parametrize(
    ("all_day", "start_time", "end_time", "expected_status"),
    [
        (True, "2026-08-20", "2026-08-21", 201),
        (False, "2026-08-20T09:00:00+01:00", "2026-08-20T10:00:00+01:00", 201),
        (True, "2026-08-20T09:00:00+01:00", None, 422),
        (False, "2026-08-20", None, 422),
        (True, "2026-08-20", "2026-08-21T10:00:00+01:00", 422),
    ],
)
async def test_event_all_day_flag_requires_matching_iso_precision(
    client, adult_a_headers, child1, all_day, start_time, end_time, expected_status
):
    payload = _school_payload(child1["id"], commitment_id=str(uuid.uuid4()))
    payload["sources"][0]["id"] = str(uuid.uuid4())
    event = payload["plan"]["events"][0]
    event["all_day"] = all_day
    event["start_time"] = start_time
    event["end_time"] = end_time
    response = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert response.status_code == expected_status, response.text


@pytest.mark.asyncio
async def test_school_commitment_is_review_only_then_materializes_all_handoffs(
    client, adult_a_headers, child1, initialized_db
):
    created = await client.post(
        "/api/commitments/", json=_school_payload(child1["id"]), headers=adult_a_headers
    )
    assert created.status_code == 201, created.text
    draft = created.json()
    assert draft["status"] == "draft"
    assert draft["results"] == []

    async with aiosqlite.connect(initialized_db) as db:
        assert (await (await db.execute("SELECT COUNT(*) FROM calendar_events")).fetchone())[0] == 0
        assert (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0] == 0

    confirmed = await client.post(
        f"/api/commitments/{draft['id']}/confirm",
        json={"expected_revision": 1, "confirmed": True},
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 200, confirmed.text
    result = confirmed.json()
    assert result["status"] == "confirmed"
    assert result["revision"] == 2
    assert [item["result_type"] for item in result["results"]].count("calendar_event") == 1
    assert [item["result_type"] for item in result["results"]].count("task") == 1
    assert [item["result_type"] for item in result["results"]].count("preparation_task") == 2

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        events = await (await db.execute("SELECT * FROM calendar_events")).fetchall()
        tasks = await (await db.execute("SELECT * FROM tasks ORDER BY title")).fetchall()
        history = await (
            await db.execute(
                "SELECT table_name FROM record_history WHERE record_id = ?",
                (draft["id"],),
            )
        ).fetchall()
    assert len(events) == 1
    assert json.loads(events[0]["family_member_ids"]) == [child1["id"]]
    assert len(tasks) == 3
    assert sum(task["source_event_id"] is not None for task in tasks) == 2
    assert [row["table_name"] for row in history] == ["family_commitments"]


@pytest.mark.asyncio
async def test_confirmation_retry_is_exactly_once(client, adult_a_headers, child1, initialized_db):
    payload = _school_payload(child1["id"], commitment_id=_id(2))
    draft = (await client.post("/api/commitments/", json=payload, headers=adult_a_headers)).json()
    request = {"expected_revision": draft["revision"], "confirmed": True}
    first = await client.post(
        f"/api/commitments/{draft['id']}/confirm", json=request, headers=adult_a_headers
    )
    second = await client.post(
        f"/api/commitments/{draft['id']}/confirm", json=request, headers=adult_a_headers
    )
    assert first.status_code == second.status_code == 200
    assert first.json()["results"] == second.json()["results"]
    async with aiosqlite.connect(initialized_db) as db:
        event_count = (await (await db.execute("SELECT COUNT(*) FROM calendar_events")).fetchone())[
            0
        ]
        task_count = (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0]
    assert event_count == 1
    assert task_count == 3


@pytest.mark.parametrize("collision_kind", ["calendar_event", "task"])
async def test_confirmation_rejects_same_family_deterministic_result_id_collision(
    client,
    adult_a_headers,
    adult_a_user,
    child1,
    initialized_db,
    collision_kind,
):
    commitment_id = str(uuid.uuid4())
    payload = _school_payload(child1["id"], commitment_id=commitment_id)
    payload["sources"][0]["id"] = str(uuid.uuid4())
    created = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert created.status_code == 201, created.text

    event_id = _deterministic_id(
        commitment_id,
        "event",
        payload["plan"]["events"][0]["id"],
    )
    task_id = _deterministic_id(
        commitment_id,
        "task",
        payload["plan"]["tasks"][0]["id"],
    )
    collision_id = event_id if collision_kind == "calendar_event" else task_id
    async with aiosqlite.connect(initialized_db) as db:
        if collision_kind == "calendar_event":
            await db.execute(
                """INSERT INTO calendar_events
                   (id, title, start_time, family_id, created_at, updated_at, created_by)
                   VALUES (?, 'Unrelated existing event', '2026-08-20', ?, ?, ?, ?)""",
                (
                    collision_id,
                    adult_a_user["family_id"],
                    "2026-08-12T09:00:00+00:00",
                    "2026-08-12T09:00:00+00:00",
                    adult_a_user["id"],
                ),
            )
        else:
            await db.execute(
                """INSERT INTO tasks
                   (id, title, family_id, created_at, updated_at, created_by)
                   VALUES (?, 'Unrelated existing task', ?, ?, ?, ?)""",
                (
                    collision_id,
                    adult_a_user["family_id"],
                    "2026-08-12T09:00:00+00:00",
                    "2026-08-12T09:00:00+00:00",
                    adult_a_user["id"],
                ),
            )
        await db.commit()

    confirmed = await client.post(
        f"/api/commitments/{commitment_id}/confirm",
        json={"expected_revision": 1, "confirmed": True},
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 409, confirmed.text
    assert "result ID is already in use" in confirmed.json()["detail"]

    retained = await client.get(f"/api/commitments/{commitment_id}", headers=adult_a_headers)
    assert retained.status_code == 200
    assert retained.json()["status"] == "draft"
    assert retained.json()["results"] == []
    async with aiosqlite.connect(initialized_db) as db:
        table = "calendar_events" if collision_kind == "calendar_event" else "tasks"
        title = (
            await (
                await db.execute(f"SELECT title FROM {table} WHERE id = ?", (collision_id,))
            ).fetchone()
        )[0]
        materialized_event = await (
            await db.execute("SELECT id FROM calendar_events WHERE id = ?", (event_id,))
        ).fetchone()
    assert title == (
        "Unrelated existing event"
        if collision_kind == "calendar_event"
        else "Unrelated existing task"
    )
    # A later task collision rolls back the event created earlier in the same confirmation.
    if collision_kind == "task":
        assert materialized_event is None


@pytest.mark.asyncio
async def test_every_commitment_mutation_records_history_before_change(
    client, adult_a_headers, child1, initialized_db
):
    commitment_id = _id(18)
    event_id = _id(218)
    source_id = _id(118)
    created = await client.post(
        "/api/commitments/",
        headers=adult_a_headers,
        json={
            "id": commitment_id,
            "kind": "invitation",
            "title": "Party invitation",
            "sources": [{"id": source_id, "kind": "manual", "label": "Original invitation"}],
            "plan": {
                "events": [
                    {
                        "id": event_id,
                        "title": "Party",
                        "start_time": "2026-08-24T14:00:00+01:00",
                        "person_ids": [child1["id"]],
                    }
                ],
                "external_action": {
                    "kind": "rsvp",
                    "label": "Reply",
                    "target_type": "email",
                    "target": "parent@example.invalid",
                },
            },
        },
    )
    assert created.status_code == 201
    edited = await client.patch(
        f"/api/commitments/{commitment_id}",
        headers=adult_a_headers,
        json={
            "expected_revision": 1,
            "title": "Updated party invitation",
            "sources": [{"id": source_id, "kind": "manual", "label": "Reviewed invitation"}],
        },
    )
    assert edited.status_code == 200, edited.text
    action = await client.post(
        f"/api/commitments/{commitment_id}/external-action/complete",
        headers=adult_a_headers,
        json={"expected_revision": 2, "completed": True, "outcome": "accepted"},
    )
    assert action.status_code == 200
    confirmed = await client.post(
        f"/api/commitments/{commitment_id}/confirm",
        headers=adult_a_headers,
        json={"expected_revision": 3, "confirmed": True},
    )
    assert confirmed.status_code == 200
    deleted = await client.delete(f"/api/commitments/{commitment_id}", headers=adult_a_headers)
    assert deleted.status_code == 204

    async with aiosqlite.connect(initialized_db) as db:
        parent_history = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history "
                    "WHERE table_name = 'family_commitments' AND record_id = ?",
                    (commitment_id,),
                )
            ).fetchone()
        )[0]
        source_history = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history "
                    "WHERE table_name = 'family_commitment_sources' AND record_id = ?",
                    (source_id,),
                )
            ).fetchone()
        )[0]
        deleted_at = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM family_commitments WHERE id = ?",
                    (commitment_id,),
                )
            ).fetchone()
        )[0]
    assert parent_history == 4
    assert source_history == 2
    assert deleted_at is not None


@pytest.mark.asyncio
async def test_invitation_requires_acknowledged_rsvp_before_calendar_confirmation(
    client, adult_a_headers, child1
):
    event_id = _id(211)
    payload = {
        "id": _id(3),
        "kind": "invitation",
        "title": "Alex's birthday",
        "sources": [_manual_source(2)],
        "plan": {
            "events": [
                {
                    "id": event_id,
                    "title": "Alex's birthday party",
                    "start_time": "2026-08-22T14:00:00+01:00",
                    "end_time": "2026-08-22T16:00:00+01:00",
                    "person_ids": [child1["id"]],
                }
            ],
            "preparations": [
                {
                    "id": _id(212),
                    "event_id": event_id,
                    "name": "Synthetic public demo record 11",
                    "items": ["Choose a gift", "Write a card"],
                }
            ],
            "external_action": {
                "kind": "rsvp",
                "label": "Reply to Alex's parent",
                "target_type": "email",
                "target": "alex-parent@example.invalid",
            },
        },
    }
    draft = (await client.post("/api/commitments/", json=payload, headers=adult_a_headers)).json()
    assert draft["status"] == "action_required"

    premature = await client.post(
        f"/api/commitments/{draft['id']}/confirm",
        json={"expected_revision": 1, "confirmed": True},
        headers=adult_a_headers,
    )
    assert premature.status_code == 409
    assert "external RSVP or booking" in premature.json()["detail"]

    acknowledged = await client.post(
        f"/api/commitments/{draft['id']}/external-action/complete",
        json={"expected_revision": 1, "completed": True, "outcome": "accepted"},
        headers=adult_a_headers,
    )
    assert acknowledged.status_code == 200
    assert acknowledged.json()["status"] == "ready"
    assert acknowledged.json()["external_action_status"] == "completed"

    confirmed = await client.post(
        f"/api/commitments/{draft['id']}/confirm",
        json={"expected_revision": 2, "confirmed": True},
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 200
    assert confirmed.json()["status"] == "confirmed"


@pytest.mark.asyncio
async def test_owner_visibility_and_family_boundaries(
    client,
    adult_a_headers,
    adult_b_headers,
    other_family_headers,
    child1,
):
    owner_payload = _school_payload(child1["id"], commitment_id=_id(4))
    owner_payload["visibility"] = "owner"
    owner = await client.post("/api/commitments/", json=owner_payload, headers=adult_a_headers)
    assert owner.status_code == 201
    assert "Share this plan with the family" in " ".join(owner.json()["review_issues"])
    assert (await client.get(f"/api/commitments/{_id(4)}", headers=adult_b_headers)).status_code == 404
    assert (
        await client.get(f"/api/commitments/{_id(4)}", headers=other_family_headers)
    ).status_code == 404

    family_payload = _school_payload(child1["id"], commitment_id=_id(5))
    family_payload["sources"][0]["id"] = _id(105)
    assert (
        await client.post("/api/commitments/", json=family_payload, headers=adult_a_headers)
    ).status_code == 201
    assert (await client.get(f"/api/commitments/{_id(5)}", headers=adult_b_headers)).status_code == 200

    private_confirm = await client.post(
        f"/api/commitments/{_id(4)}/confirm",
        json={"expected_revision": 1, "confirmed": True},
        headers=adult_a_headers,
    )
    assert private_confirm.status_code == 409
    promoted = await client.patch(
        f"/api/commitments/{_id(4)}",
        json={"expected_revision": 1, "visibility": "family"},
        headers=adult_a_headers,
    )
    assert promoted.status_code == 200, promoted.text
    assert promoted.json()["visibility"] == "family"
    assert "Share this plan with the family" not in " ".join(promoted.json()["review_issues"])


@pytest.mark.asyncio
async def test_non_owner_cannot_make_a_shared_commitment_private(
    client, adult_a_headers, adult_b_headers, child1
):
    payload = _school_payload(child1["id"], commitment_id=_id(14))
    payload["sources"][0]["id"] = _id(114)
    created = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert created.status_code == 201
    hidden = await client.patch(
        f"/api/commitments/{_id(14)}",
        json={"expected_revision": 1, "visibility": "owner"},
        headers=adult_b_headers,
    )
    assert hidden.status_code == 409


@pytest.mark.asyncio
async def test_stale_family_edit_obeys_priority_conflict_rule(
    client, adult_a_headers, adult_b_headers, child1
):
    payload = _school_payload(child1["id"], commitment_id=_id(12))
    created = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert created.status_code == 201
    adult_a_edit = await client.patch(
        f"/api/commitments/{_id(12)}",
        headers=adult_a_headers,
        json={
            "expected_revision": 1,
            "title": "Alex's title",
            "client_timestamp": "2026-08-12T10:00:00+00:00",
        },
    )
    assert adult_a_edit.status_code == 200, adult_a_edit.text
    assert adult_a_edit.json()["revision"] == 2

    adult_b_wins = await client.patch(
        f"/api/commitments/{_id(12)}",
        headers=adult_b_headers,
        json={
            "expected_revision": 1,
            "title": "Morgan's title",
            "client_timestamp": "2026-08-12T10:01:00+00:00",
        },
    )
    assert adult_b_wins.status_code == 200, adult_b_wins.text
    assert adult_b_wins.json()["revision"] == 3
    assert adult_b_wins.json()["title"] == "Morgan's title"

    adult_a_loses = await client.patch(
        f"/api/commitments/{_id(12)}",
        headers=adult_a_headers,
        json={
            "expected_revision": 2,
            "title": "Stale Alex title",
            "client_timestamp": "2026-08-12T10:02:00+00:00",
        },
    )
    assert adult_a_loses.status_code == 409


@pytest.mark.asyncio
async def test_document_and_external_url_inputs_are_security_scoped(
    client, adult_a_headers, other_family_headers, initialized_db, second_family, child1
):
    foreign_document = _id(701)
    await _insert_document(initialized_db, foreign_document, family_id=second_family["id"])
    payload = _school_payload(child1["id"], commitment_id=_id(6))
    payload["sources"] = [{"id": _id(106), "kind": "document", "document_id": foreign_document}]
    denied = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert denied.status_code == 400
    assert "not available to this family" in denied.json()["detail"]

    payload = {
        "id": _id(7),
        "kind": "invitation",
        "title": "Unsafe invitation",
        "sources": [_manual_source(7)],
        "plan": {
            "events": [
                {
                    "id": _id(220),
                    "title": "Party",
                    "start_time": "2026-08-22T14:00:00+01:00",
                }
            ],
            "external_action": {
                "kind": "rsvp",
                "label": "RSVP",
                "target_type": "https",
                "target": "https://127.0.0.1/admin",
            },
        },
    }
    unsafe = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert unsafe.status_code == 422
    assert "public host" in unsafe.text


@pytest.mark.asyncio
async def test_from_source_fallback_persists_review_draft_dedupes_and_surfaces_updates(
    client, adult_a_headers, child1, initialized_db
):
    source = {
        "id": _id(8),
        "kind": "school",
        "text": (
            "World Book Day for Child 1 is Thursday 20 August 2026. "
            "Please bring a costume. Pay three pounds by Friday 14 August 2026."
        ),
        "source_label": "School email",
        "client_now": "2026-08-12T09:00:00+01:00",
        "timezone": "Europe/London",
    }
    created = await client.post("/api/commitments/from-source", json=source, headers=adult_a_headers)
    assert created.status_code == 201, created.text
    result = created.json()
    assert result["processor"] == "fallback"
    assert result["commitment"]["status"] == "draft"
    assert result["commitment"]["plan"]["events"]
    assert result["commitment"]["plan"]["tasks"]
    assert result["commitment"]["plan"]["preparations"]

    retry = {**source, "id": _id(9)}
    deduplicated = await client.post(
        "/api/commitments/from-source", json=retry, headers=adult_a_headers
    )
    assert deduplicated.status_code == 201
    assert deduplicated.json()["deduplicated"] is True
    assert deduplicated.json()["commitment"]["id"] == result["commitment"]["id"]

    changed = {
        **source,
        "id": _id(10),
        "text": source["text"].replace("20 August", "21 August"),
        "supersedes_id": result["commitment"]["id"],
    }
    revised = await client.post("/api/commitments/from-source", json=changed, headers=adult_a_headers)
    assert revised.status_code == 201, revised.text
    assert "Event details or times changed" in revised.json()["material_changes"]
    assert revised.json()["commitment"]["supersedes_id"] == result["commitment"]["id"]
    assert revised.json()["commitment"]["plan"]["events"][0]["event_type"] == "school"

    repeated_update = await client.post(
        "/api/commitments/from-source",
        json={**changed, "id": _id(12)},
        headers=adult_a_headers,
    )
    assert repeated_update.status_code == 201, repeated_update.text
    assert repeated_update.json()["deduplicated"] is True
    assert repeated_update.json()["commitment"]["id"] == revised.json()["commitment"]["id"]

    different_predecessor = await client.post(
        "/api/commitments/from-source",
        json={
            **changed,
            "id": _id(14),
            "supersedes_id": revised.json()["commitment"]["id"],
        },
        headers=adult_a_headers,
    )
    assert different_predecessor.status_code == 201, different_predecessor.text
    assert different_predecessor.json()["deduplicated"] is False
    assert (
        different_predecessor.json()["commitment"]["supersedes_id"]
        == revised.json()["commitment"]["id"]
    )

    async with aiosqlite.connect(initialized_db) as db:
        assert (await (await db.execute("SELECT COUNT(*) FROM calendar_events")).fetchone())[0] == 0
        assert (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0] == 0


@pytest.mark.asyncio
async def test_source_update_rejects_visibility_changes_and_self_supersession(
    client, adult_a_headers
):
    base = {
        "id": _id(150),
        "kind": "outing",
        "visibility": "owner",
        "text": "Museum visit on Thursday 20 August 2026 at 10:00.",
        "client_now": "2026-08-12T09:00:00+01:00",
        "timezone": "Europe/London",
    }
    created = await client.post("/api/commitments/from-source", json=base, headers=adult_a_headers)
    assert created.status_code == 201, created.text

    visibility_change = await client.post(
        "/api/commitments/from-source",
        json={
            **base,
            "id": _id(151),
            "visibility": "family",
            "supersedes_id": _id(150),
        },
        headers=adult_a_headers,
    )
    assert visibility_change.status_code == 400
    assert "visibility" in visibility_change.json()["detail"]

    self_cycle = await client.post(
        "/api/commitments/from-source",
        json={**base, "id": _id(152), "supersedes_id": _id(152)},
        headers=adult_a_headers,
    )
    assert self_cycle.status_code == 400
    assert "cannot supersede itself" in self_cycle.json()["detail"]


def test_material_change_summary_ignores_relation_ids_but_covers_review_fields():
    old_event_id = _id(170)
    new_event_id = _id(171)
    old = CommitmentPlan.model_validate(
        {
            "events": [
                {
                    "id": old_event_id,
                    "title": "Museum visit",
                    "description": "Use the side entrance",
                    "start_time": "2026-08-20T10:00:00+01:00",
                    "end_time": "2026-08-20T12:00:00+01:00",
                    "location": "Example Town",
                    "person_ids": [_id(901)],
                    "event_type": "outing",
                }
            ],
            "tasks": [
                {
                    "id": _id(172),
                    "title": "Buy tickets",
                    "due_date": "2026-08-19",
                    "priority": 2,
                }
            ],
            "preparations": [
                {
                    "id": _id(173),
                    "event_id": old_event_id,
                    "name": "Day bag",
                    "items": ["Water", "Tickets"],
                }
            ],
        }
    )
    same_details = CommitmentPlan.model_validate(
        {
            "events": [{**old.events[0].model_dump(mode="json"), "id": new_event_id}],
            "tasks": [{**old.tasks[0].model_dump(mode="json"), "id": _id(174)}],
            "preparations": [
                {
                    **old.preparations[0].model_dump(mode="json"),
                    "id": _id(175),
                    "event_id": new_event_id,
                    "items": ["Tickets", "Water"],
                }
            ],
        }
    )
    assert _material_changes(old, same_details) == []

    revised = same_details.model_copy(deep=True)
    revised.events[0].location = "London"
    revised.tasks[0].priority = 3
    revised.preparations[0].lead_hours = 48
    assert _material_changes(old, revised) == [
        "Event details or times changed",
        "Actions or deadlines changed",
        "Preparation changed",
    ]


@pytest.mark.asyncio
async def test_open_only_filter_is_applied_before_pagination(
    client, adult_a_headers, adult_a_user, initialized_db
):
    now = "2026-08-12T09:00:00+00:00"
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """INSERT INTO family_commitments
               (id, kind, visibility, owner_user_id, title, status, revision,
                plan_json, external_action_status, family_id, created_at,
                updated_at, created_by, updated_by)
               VALUES (?, 'school', 'family', ?, ?, ?, 1, ?, 'not_required',
                       ?, ?, ?, ?, ?)""",
            [
                (
                    str(uuid.uuid4()),
                    adult_a_user["id"],
                    f"Closed {index}",
                    "confirmed",
                    json.dumps({"events": [], "tasks": [], "preparations": []}),
                    EXAMPLE_FAMILY_ID,
                    now,
                    f"2026-08-12T{10 + index:02d}:00:00+00:00",
                    adult_a_user["id"],
                    adult_a_user["id"],
                )
                for index in range(3)
            ],
        )
        await db.execute(
            """INSERT INTO family_commitments
               (id, kind, visibility, owner_user_id, title, status, revision,
                plan_json, external_action_status, family_id, created_at,
                updated_at, created_by, updated_by)
               VALUES (?, 'school', 'family', ?, 'Open plan', 'draft', 1, ?,
                       'not_required', ?, ?, '2026-08-12T09:00:00+00:00', ?, ?)""",
            (
                _id(160),
                adult_a_user["id"],
                json.dumps({"events": [], "tasks": [], "preparations": []}),
                EXAMPLE_FAMILY_ID,
                now,
                adult_a_user["id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()

    response = await client.get(
        "/api/commitments/",
        params={"open_only": "true", "limit": 1},
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    assert [item["id"] for item in response.json()] == [_id(160)]

    ambiguous = await client.get(
        "/api/commitments/",
        params={"open_only": "true", "status": "draft"},
        headers=adult_a_headers,
    )
    assert ambiguous.status_code == 400


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", ["outing", "childcare"])
async def test_typed_everyday_commitments_semantically_dedupe_new_client_ids(
    client, adult_a_headers, child1, kind
):
    first_payload = _typed_single_event_payload(
        kind,
        child1["id"],
        commitment_id=str(uuid.uuid4()),
        event_id=str(uuid.uuid4()),
        source_id=str(uuid.uuid4()),
    )
    if kind == "outing":
        first_payload["sources"][0]["provider_reference"] = str(uuid.uuid4())
    first = await client.post("/api/commitments/", headers=adult_a_headers, json=first_payload)
    second = await client.post(
        "/api/commitments/",
        headers=adult_a_headers,
        json={
            **first_payload,
            "id": str(uuid.uuid4()),
            "sources": [
                {
                    **first_payload["sources"][0],
                    "id": str(uuid.uuid4()),
                    "provider_reference": (
                        str(uuid.uuid4())
                        if kind == "outing"
                        else first_payload["sources"][0].get("provider_reference")
                    ),
                }
            ],
            "plan": {
                **first_payload["plan"],
                "events": [
                    {**first_payload["plan"]["events"][0], "id": str(uuid.uuid4())}
                ],
            },
        },
    )
    assert first.status_code == second.status_code == 201
    assert second.json()["id"] == first.json()["id"]


@pytest.mark.asyncio
async def test_owner_only_typed_dedupe_does_not_cross_adults(
    client, adult_a_headers, adult_b_headers, child1
):
    payload = _typed_single_event_payload(
        "outing",
        child1["id"],
        commitment_id=str(uuid.uuid4()),
        event_id=str(uuid.uuid4()),
        source_id=str(uuid.uuid4()),
        visibility="owner",
    )
    dom = await client.post("/api/commitments/", headers=adult_a_headers, json=payload)
    kat = await client.post(
        "/api/commitments/",
        headers=adult_b_headers,
        json={
            **payload,
            "id": str(uuid.uuid4()),
            "sources": [{**payload["sources"][0], "id": str(uuid.uuid4())}],
            "plan": {
                **payload["plan"],
                "events": [{**payload["plan"]["events"][0], "id": str(uuid.uuid4())}],
            },
        },
    )
    assert dom.status_code == kat.status_code == 201
    assert dom.json()["id"] != kat.json()["id"]


@pytest.mark.asyncio
async def test_commitment_task_dates_are_date_only_and_extracted_times_normalize(
    client, adult_a_headers, monkeypatch
):
    invalid = {
        "id": str(uuid.uuid4()),
        "kind": "school",
        "title": "Timed task",
        "sources": [{"kind": "manual", "label": "Reviewed source"}],
        "plan": {
            "tasks": [
                {
                    "title": "Return form",
                    "due_date": "2026-08-20T17:00:00+01:00",
                }
            ]
        },
    }
    rejected = await client.post("/api/commitments/", headers=adult_a_headers, json=invalid)
    assert rejected.status_code == 422
    assert "date-only" in rejected.text

    from app.services import commitments

    monkeypatch.setattr(
        commitments,
        "fallback_capture_suggestions",
        lambda *_args, **_kwargs: [
            commitments.CaptureSuggestionCreate(
                kind="task",
                title="Return form",
                due_date="2026-08-20T17:00:00+01:00",
            )
        ],
    )
    extracted = await client.post(
        "/api/commitments/from-source",
        headers=adult_a_headers,
        json={
            "kind": "school",
            "text": "Return the form by Thursday.",
            "client_now": "2026-08-12T09:00:00+01:00",
        },
    )
    assert extracted.status_code == 201, extracted.text
    assert extracted.json()["commitment"]["plan"]["tasks"][0]["due_date"] == "2026-08-20"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "kind",
    ["school", "invitation", "outing", "childcare", "appointment", "travel"],
)
async def test_extracted_event_type_matches_workflow(client, adult_a_headers, monkeypatch, kind):
    from app.services import commitments

    monkeypatch.setattr(
        commitments,
        "fallback_capture_suggestions",
        lambda *_args, **_kwargs: [
            commitments.CaptureSuggestionCreate(
                kind="event",
                title="Reviewed event",
                start_time="2026-08-20T10:00:00+01:00",
                end_time="2026-08-20T11:00:00+01:00",
                all_day=False,
            )
        ],
    )
    response = await client.post(
        "/api/commitments/from-source",
        headers=adult_a_headers,
        json={"kind": kind, "text": f"A reviewed {kind} event."},
    )
    assert response.status_code == 201, response.text
    assert response.json()["commitment"]["plan"]["events"][0]["event_type"] == kind


@pytest.mark.asyncio
async def test_incomplete_invitation_source_remains_an_editable_review_draft(client, adult_a_headers):
    response = await client.post(
        "/api/commitments/from-source",
        headers=adult_a_headers,
        json={
            "id": _id(13),
            "kind": "invitation",
            "text": "Please RSVP for Sam's party to parent@example.invalid. Date to follow.",
            "source_label": "WhatsApp invitation",
            "client_now": "2026-08-12T09:00:00+01:00",
            "timezone": "Europe/London",
        },
    )
    assert response.status_code == 201, response.text
    draft = response.json()["commitment"]
    assert draft["plan"]["events"] == []
    assert "Add the invitation's date and time" in draft["review_issues"]
    confirmation = await client.post(
        f"/api/commitments/{draft['id']}/confirm",
        headers=adult_a_headers,
        json={"expected_revision": draft["revision"], "confirmed": True},
    )
    assert confirmation.status_code == 400


@pytest.mark.asyncio
async def test_free_windows_fit_only_viable_reviewed_outings(
    client, adult_a_headers, adult_a_user, adult_b_user, initialized_db
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, start_time, end_time, family_member_ids, family_id,
                created_at, updated_at, created_by)
               VALUES (?, 'Busy', ?, ?, ?, ?, ?, ?, ?)""",
            (
                _id(801),
                "2026-08-15T10:00:00+01:00",
                "2026-08-15T11:00:00+01:00",
                json.dumps([adult_a_user["id"]]),
                EXAMPLE_FAMILY_ID,
                "2026-08-12T09:00:00+00:00",
                "2026-08-12T09:00:00+00:00",
                adult_a_user["id"],
            ),
        )
        await db.commit()
    response = await client.post(
        "/api/commitments/free-windows/query",
        headers=adult_a_headers,
        json={
            "start_time": "2026-08-15T09:00:00+01:00",
            "end_time": "2026-08-15T13:00:00+01:00",
            "person_ids": [adult_a_user["id"], adult_b_user["id"]],
            "minimum_minutes": 60,
            "candidates": [
                {
                    "id": "museum",
                    "title": "Museum",
                    "available_start": "2026-08-15T09:30:00+01:00",
                    "available_end": "2026-08-15T12:30:00+01:00",
                    "duration_minutes": 90,
                    "booking_url": "https://example.org/book",
                },
                {
                    "id": "long-trip",
                    "title": "Long trip",
                    "available_start": "2026-08-15T09:00:00+01:00",
                    "available_end": "2026-08-15T13:00:00+01:00",
                    "duration_minutes": 180,
                },
            ],
        },
    )
    assert response.status_code == 200, response.text
    data = response.json()
    assert [window["duration_minutes"] for window in data["windows"]] == [60, 120]
    assert [outing["candidate_id"] for outing in data["viable_outings"]] == ["museum"]
    assert data["viable_outings"][0]["proposed_start"] == "2026-08-15T11:00:00+01:00"


@pytest.mark.asyncio
async def test_childcare_gaps_use_term_holidays_and_explicit_calendar_coverage(
    client, adult_a_headers, child1, initialized_db
):
    async with aiosqlite.connect(initialized_db) as db:
        now = "2026-08-12T09:00:00+00:00"
        await db.execute(
            "INSERT INTO term_dates (id, person_id, label, start_date, end_date, family_id, "
            "created_at, updated_at) VALUES (?, ?, 'Autumn', '2026-10-19', '2026-10-23', ?, ?, ?)",
            (_id(901), child1["id"], EXAMPLE_FAMILY_ID, now, now),
        )
        await db.execute(
            "INSERT INTO holiday_dates (id, person_id, date, label, family_id, created_at, updated_at) "
            "VALUES (?, ?, '2026-10-21', 'Inset day', ?, ?, ?)",
            (_id(902), child1["id"], EXAMPLE_FAMILY_ID, now, now),
        )
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, start_time, all_day, family_member_ids, event_type,
                family_id, created_at, updated_at)
               VALUES (?, 'Grandparents', '2026-10-26', 1, ?, 'childcare', ?, ?, ?)""",
            (_id(903), json.dumps([child1["id"]]), EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()
    response = await client.get(
        "/api/commitments/childcare-gaps",
        params={
            "child_id": child1["id"],
            "from": "2026-10-19",
            "to": "2026-10-30",
            "timezone": "Europe/London",
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    gaps = response.json()
    assert [gap["date"] for gap in gaps] == [
        "2026-10-21",
        "2026-10-27",
        "2026-10-28",
        "2026-10-29",
        "2026-10-30",
    ]
    assert gaps[0] == {
        "date": "2026-10-21",
        "label": "Inset day",
        "source": "explicit_holiday",
    }


@pytest.mark.asyncio
async def test_childcare_gap_requires_complete_day_coverage(
    client, adult_a_headers, child1, initialized_db
):
    now = "2026-08-12T09:00:00+00:00"
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            "INSERT INTO holiday_dates (id, person_id, date, label, family_id, "
            "created_at, updated_at) VALUES (?, ?, ?, 'Holiday', ?, ?, ?)",
            [
                (_id(920), child1["id"], "2026-10-21", EXAMPLE_FAMILY_ID, now, now),
                (_id(921), child1["id"], "2026-10-22", EXAMPLE_FAMILY_ID, now, now),
            ],
        )
        await db.executemany(
            """INSERT INTO calendar_events
               (id, title, start_time, end_time, all_day, family_member_ids,
                event_type, family_id, created_at, updated_at)
               VALUES (?, 'Childcare', ?, ?, ?, ?, 'childcare', ?, ?, ?)""",
            [
                (
                    _id(922),
                    "2026-10-21T00:00:00+01:00",
                    "2026-10-22T00:00:00+01:00",
                    0,
                    json.dumps([child1["id"]]),
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                ),
                (
                    _id(923),
                    "2026-10-22T09:00:00+01:00",
                    "2026-10-22T10:00:00+01:00",
                    0,
                    json.dumps([child1["id"]]),
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                ),
            ],
        )
        await db.commit()

    response = await client.get(
        "/api/commitments/childcare-gaps",
        params={
            "child_id": child1["id"],
            "from": "2026-10-21",
            "to": "2026-10-22",
            "timezone": "Europe/London",
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    assert [gap["date"] for gap in response.json()] == ["2026-10-22"]


@pytest.mark.asyncio
async def test_free_windows_apply_cancelled_and_moved_recurrence_exceptions(
    client, adult_a_headers, adult_a_user, initialized_db
):
    now = "2026-08-12T09:00:00+00:00"
    series_id = _id(930)
    replacement_id = _id(931)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, start_time, end_time, recurrence_rule, family_member_ids,
                family_id, created_at, updated_at, created_by)
               VALUES (?, 'Daily busy', '2026-08-14T10:00:00+01:00',
                       '2026-08-14T11:00:00+01:00', 'FREQ=DAILY;COUNT=3', ?, ?, ?, ?, ?)""",
            (series_id, json.dumps([adult_a_user["id"]]), EXAMPLE_FAMILY_ID, now, now, adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, start_time, end_time, family_member_ids, family_id,
                created_at, updated_at, created_by)
               VALUES (?, 'Moved busy', '2026-08-16T11:30:00+01:00',
                       '2026-08-16T12:30:00+01:00', ?, ?, ?, ?, ?)""",
            (
                replacement_id,
                json.dumps([adult_a_user["id"]]),
                EXAMPLE_FAMILY_ID,
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.executemany(
            """INSERT INTO calendar_event_exceptions
               (id, series_id, occurrence_start, action, replacement_event_id,
                family_id, created_at, updated_at, created_by)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                (
                    _id(932),
                    series_id,
                    "2026-08-15T09:00:00+00:00",
                    "cancelled",
                    None,
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                    adult_a_user["id"],
                ),
                (
                    _id(933),
                    series_id,
                    "2026-08-16T09:00:00+00:00",
                    "replacement",
                    replacement_id,
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                    adult_a_user["id"],
                ),
            ],
        )
        await db.commit()

    async def windows(day: str) -> list[dict]:
        response = await client.post(
            "/api/commitments/free-windows/query",
            headers=adult_a_headers,
            json={
                "start_time": f"{day}T09:00:00+01:00",
                "end_time": f"{day}T13:00:00+01:00",
                "person_ids": [adult_a_user["id"]],
                "minimum_minutes": 30,
            },
        )
        assert response.status_code == 200, response.text
        return response.json()["windows"]

    assert [item["duration_minutes"] for item in await windows("2026-08-15")] == [240]
    moved = await windows("2026-08-16")
    assert [(item["start_time"], item["end_time"]) for item in moved] == [
        ("2026-08-16T09:00:00+01:00", "2026-08-16T11:30:00+01:00"),
        ("2026-08-16T12:30:00+01:00", "2026-08-16T13:00:00+01:00"),
    ]


@pytest.mark.asyncio
async def test_childcare_gaps_apply_cancelled_and_moved_recurrence_exceptions(
    client, adult_a_headers, child1, initialized_db
):
    now = "2026-08-12T09:00:00+00:00"
    moved_series = _id(940)
    cancelled_series = _id(941)
    replacement_id = _id(942)
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            "INSERT INTO holiday_dates (id, person_id, date, label, family_id, "
            "created_at, updated_at) VALUES (?, ?, ?, 'Holiday', ?, ?, ?)",
            [
                (_id(943), child1["id"], "2026-10-26", EXAMPLE_FAMILY_ID, now, now),
                (_id(944), child1["id"], "2026-10-27", EXAMPLE_FAMILY_ID, now, now),
                (_id(945), child1["id"], "2026-10-28", EXAMPLE_FAMILY_ID, now, now),
            ],
        )
        await db.executemany(
            """INSERT INTO calendar_events
               (id, title, start_time, all_day, recurrence_rule, family_member_ids,
                event_type, family_id, created_at, updated_at)
               VALUES (?, 'Recurring childcare', ?, 1, ?, ?, 'childcare', ?, ?, ?)""",
            [
                (
                    moved_series,
                    "2026-10-26",
                    "FREQ=DAILY;COUNT=1",
                    json.dumps([child1["id"]]),
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                ),
                (
                    cancelled_series,
                    "2026-10-28",
                    "FREQ=DAILY;COUNT=1",
                    json.dumps([child1["id"]]),
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                ),
            ],
        )
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, start_time, all_day, family_member_ids, event_type,
                family_id, created_at, updated_at)
               VALUES (?, 'Moved childcare', '2026-10-27', 1, ?, 'childcare', ?, ?, ?)""",
            (replacement_id, json.dumps([child1["id"]]), EXAMPLE_FAMILY_ID, now, now),
        )
        await db.executemany(
            """INSERT INTO calendar_event_exceptions
               (id, series_id, occurrence_start, action, replacement_event_id,
                family_id, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                (
                    _id(946),
                    moved_series,
                    "2026-10-26",
                    "replacement",
                    replacement_id,
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                ),
                (
                    _id(947),
                    cancelled_series,
                    "2026-10-28",
                    "cancelled",
                    None,
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                ),
            ],
        )
        await db.commit()

    response = await client.get(
        "/api/commitments/childcare-gaps",
        params={
            "child_id": child1["id"],
            "from": "2026-10-26",
            "to": "2026-10-28",
            "timezone": "Europe/London",
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    assert [item["date"] for item in response.json()] == ["2026-10-26", "2026-10-28"]


@pytest.mark.asyncio
async def test_range_scans_do_not_lose_current_events_behind_old_history(
    client, adult_a_headers, adult_a_user, child1, initialized_db
):
    now = "2026-08-12T09:00:00+00:00"
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """INSERT INTO calendar_events
               (id, title, start_time, all_day, family_member_ids, event_type,
                family_id, created_at, updated_at)
               VALUES (?, 'Old', '2020-01-01', 1, ?, ?, ?, ?, ?)""",
            [
                (
                    str(uuid.uuid4()),
                    json.dumps([child1["id"] if index < 1_200 else adult_a_user["id"]]),
                    "childcare" if index < 1_200 else "other",
                    EXAMPLE_FAMILY_ID,
                    now,
                    now,
                )
                for index in range(2_500)
            ],
        )
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, start_time, end_time, family_member_ids, family_id,
                created_at, updated_at)
               VALUES (?, 'Current busy', '2026-08-15T10:00:00+01:00',
                       '2026-08-15T11:00:00+01:00', ?, ?, ?, ?)""",
            (_id(950), json.dumps([adult_a_user["id"]]), EXAMPLE_FAMILY_ID, now, now),
        )
        await db.execute(
            "INSERT INTO holiday_dates (id, person_id, date, label, family_id, "
            "created_at, updated_at) VALUES (?, ?, '2026-10-26', 'Holiday', ?, ?, ?)",
            (_id(951), child1["id"], EXAMPLE_FAMILY_ID, now, now),
        )
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, start_time, all_day, family_member_ids, event_type,
                family_id, created_at, updated_at)
               VALUES (?, 'Current childcare', '2026-10-26', 1, ?, 'childcare', ?, ?, ?)""",
            (_id(952), json.dumps([child1["id"]]), EXAMPLE_FAMILY_ID, now, now),
        )
        await db.commit()

    free = await client.post(
        "/api/commitments/free-windows/query",
        headers=adult_a_headers,
        json={
            "start_time": "2026-08-15T09:00:00+01:00",
            "end_time": "2026-08-15T12:00:00+01:00",
            "person_ids": [adult_a_user["id"]],
            "minimum_minutes": 30,
        },
    )
    assert free.status_code == 200, free.text
    assert [item["duration_minutes"] for item in free.json()["windows"]] == [60, 60]

    childcare = await client.get(
        "/api/commitments/childcare-gaps",
        params={
            "child_id": child1["id"],
            "from": "2026-10-26",
            "to": "2026-10-26",
            "timezone": "Europe/London",
        },
        headers=adult_a_headers,
    )
    assert childcare.status_code == 200, childcare.text
    assert childcare.json() == []


@pytest.mark.asyncio
async def test_recurrence_expansion_can_fail_instead_of_silently_truncating(initialized_db):
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        with pytest.raises(CalendarRecurrenceError, match="too many occurrences"):
            await expand_calendar_rows(
                db,
                family_id=EXAMPLE_FAMILY_ID,
                rows=[
                    {
                        "id": _id(960),
                        "start_time": "2026-08-15T09:00:00+01:00",
                        "end_time": "2026-08-15T09:30:00+01:00",
                        "all_day": 0,
                        "recurrence_rule": "FREQ=MINUTELY;COUNT=20",
                    }
                ],
                range_start=datetime.fromisoformat("2026-08-15T09:00:00+01:00"),
                range_end=datetime.fromisoformat("2026-08-15T10:00:00+01:00"),
                max_occurrences_per_series=3,
                fail_on_truncation=True,
            )


@pytest.mark.asyncio
async def test_travel_dossier_groups_segments_and_attaches_source_document(
    client, adult_a_headers, adult_a_user, initialized_db
):
    document_id = _id(710)
    await _insert_document(initialized_db, document_id)
    payload = {
        "id": _id(11),
        "kind": "travel",
        "title": "Edinburgh weekend",
        "group_key": "trip-edinburgh-2026",  # gitleaks:allow — deterministic test key
        "sources": [{"id": _id(111), "kind": "document", "document_id": document_id}],
        "plan": {
            "events": [
                {
                    "id": _id(231),
                    "title": "Train to Edinburgh",
                    "start_time": "2026-09-04T09:00:00+01:00",
                    "end_time": "2026-09-04T13:30:00+01:00",
                    "person_ids": [adult_a_user["id"]],
                    "location": "London King's Cross",
                    "event_type": "travel",
                },
                {
                    "id": _id(232),
                    "title": "Hotel check-in",
                    "start_time": "2026-09-04T15:00:00+01:00",
                    "person_ids": [adult_a_user["id"]],
                    "location": "Edinburgh",
                    "event_type": "travel",
                },
            ],
        },
    }
    draft_response = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert draft_response.status_code == 201, draft_response.text
    draft = draft_response.json()
    confirmed = await client.post(
        f"/api/commitments/{draft['id']}/confirm",
        json={"expected_revision": 1, "confirmed": True},
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 200, confirmed.text
    assert (
        len(
            [
                item
                for item in confirmed.json()["results"]
                if item["result_type"] == "calendar_event"
            ]
        )
        == 2
    )
    async with aiosqlite.connect(initialized_db) as db:
        attachments = await (
            await db.execute(
                "SELECT event_id, document_id, role FROM calendar_event_documents ORDER BY event_id"
            )
        ).fetchall()
    assert len(attachments) == 2
    assert {row[1] for row in attachments} == {document_id}
    assert {row[2] for row in attachments} == {"booking"}


@pytest.mark.asyncio
async def test_deleting_source_document_detaches_commitment_provenance_and_plan_links(
    client, adult_a_headers, child1, initialized_db
):
    document_id = _id(711)
    commitment_id = _id(19)
    source_id = _id(119)
    await _insert_document(initialized_db, document_id)
    payload = _school_payload(child1["id"], commitment_id=commitment_id)
    payload["sources"] = [{"id": source_id, "kind": "document", "document_id": document_id}]
    payload["plan"]["events"][0]["document_ids"] = [document_id]
    payload["plan"]["tasks"][0]["document_id"] = document_id
    created = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert created.status_code == 201, created.text

    deleted = await client.delete(f"/api/documents/{document_id}", headers=adult_a_headers)
    assert deleted.status_code == 204, deleted.text
    retained = await client.get(f"/api/commitments/{commitment_id}", headers=adult_a_headers)
    assert retained.status_code == 200, retained.text
    data = retained.json()
    assert data["revision"] == 2
    assert data["sources"] == [
        {
            "id": source_id,
            "kind": "manual",
            "document_id": None,
            "label": "Deleted source document",
            "provider_reference": None,
            "source_url": None,
            "observed_at": None,
        }
    ]
    assert data["plan"]["events"][0]["document_ids"] == []
    assert data["plan"]["tasks"][0]["document_id"] is None

    async with aiosqlite.connect(initialized_db) as db:
        history = await (
            await db.execute(
                "SELECT table_name, record_id FROM record_history "
                "WHERE record_id IN (?, ?) ORDER BY table_name",
                (commitment_id, source_id),
            )
        ).fetchall()
    assert history == [
        ("family_commitment_sources", source_id),
        ("family_commitments", commitment_id),
    ]


@pytest.mark.asyncio
async def test_departing_adult_private_commitments_are_erased_and_shared_plans_transfer(
    client, adult_a_headers, adult_b_headers, adult_a_user, adult_b_user, child1, initialized_db
):
    private = _school_payload(child1["id"], commitment_id=_id(15))
    private["visibility"] = "owner"
    private["sources"] = [
        {
            "id": _id(115),
            "kind": "email",
            "label": "Private message for demo-person-51@example.invalid",
            "provider_reference": f"mailbox:{adult_a_user['id']}",
        }
    ]
    shared = _school_payload(child1["id"], commitment_id=_id(16))
    shared["title"] = "Alex's World Book Day plan"
    shared["summary"] = f"Forwarded by Alex at demo-person-51@example.invalid ({adult_a_user['id']})"
    shared["sources"] = [
        {
            "id": _id(116),
            "kind": "email",
            "label": "Forwarded by Alex at demo-person-51@example.invalid",
            "provider_reference": f"Alex-sender:{adult_a_user['id']}",
            "source_url": "https://example.org/message/Alex",
        }
    ]
    shared["plan"]["events"][0]["title"] = "World Book Day with Alex"
    shared["plan"]["tasks"][0]["description"] = "Alex should pay via demo-person-51@example.invalid"
    shared["plan"]["events"][0]["person_ids"] = [child1["id"], adult_a_user["id"]]
    shared["plan"]["tasks"][0]["assigned_to"] = adult_a_user["id"]
    shared["plan"]["preparations"][0]["items"].append("Ask Alex to pack it")
    shared["plan"]["external_action"] = {
        "kind": "contact",
        "label": "Ask Alex to confirm",
        "target_type": "email",
        "target": "demo-person-51@example.invalid",
    }
    for payload in (private, shared):
        response = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
        assert response.status_code == 201, response.text

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        deletion = await delete_account_data(
            db,
            user_id=adult_a_user["id"],
            family_id=adult_a_user["family_id"],
        )
    assert deletion.final_family is False

    assert (await client.get(f"/api/commitments/{_id(15)}", headers=adult_b_headers)).status_code == 404
    retained = await client.get(f"/api/commitments/{_id(16)}", headers=adult_b_headers)
    assert retained.status_code == 200, retained.text
    data = retained.json()
    assert data["owner_user_id"] == adult_b_user["id"]
    encoded = json.dumps(data)
    assert adult_a_user["id"] not in encoded
    assert "demo-person-51@example.invalid" not in encoded
    assert "Alex" not in encoded
    assert data["plan"]["tasks"][0]["assigned_to"] is None
    assert data["plan"]["external_action"]["target_type"] == "manual"
    assert data["sources"][0]["source_url"] is None


@pytest.mark.asyncio
async def test_commitment_schema_upgrade_is_repeatable_and_preserves_rows(
    initialized_db, adult_a_user, child1, client, adult_a_headers
):
    payload = _school_payload(child1["id"], commitment_id=_id(17))
    payload["sources"][0]["id"] = _id(117)
    created = await client.post("/api/commitments/", json=payload, headers=adult_a_headers)
    assert created.status_code == 201

    await init_db(initialized_db)
    await init_db(initialized_db)
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT title, revision FROM family_commitments WHERE id = ?",
                (_id(17),),
            )
        ).fetchone()
        indexes = {
            item[0]
            for item in await (
                await db.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'index' "
                    "AND name LIKE 'idx_family_commitment%'"
                )
            ).fetchall()
        }
    assert row == ("World Book Day", 1)
    assert {
        "idx_family_commitments_family_status",
        "idx_family_commitments_owner_status",
        "idx_family_commitments_dedupe",
        "idx_family_commitment_sources_document",
        "idx_family_commitment_results_target",
    }.issubset(indexes)

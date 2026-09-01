from datetime import date, timedelta

import aiosqlite

from app.services.renewals import check_renewals


async def test_renewals_requires_authentication(client):
    assert (await client.get("/api/renewals/")).status_code == 401


async def test_create_list_and_status(client, adult_a_headers):
    soon = (date.today() + timedelta(days=10)).isoformat()
    created = await client.post(
        "/api/renewals/",
        json={"title": "Car MOT", "category": "vehicle", "due_date": soon, "reminder_days_before": 21, "cost_pence": 5500},
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["status"] == "due_soon"
    assert body["days_until"] == 10
    assert body["category"] == "vehicle"

    far = await client.post(
        "/api/renewals/",
        json={"title": "Passport", "category": "document", "due_date": (date.today() + timedelta(days=200)).isoformat()},
        headers=adult_a_headers,
    )
    assert far.json()["status"] == "upcoming"

    listing = await client.get("/api/renewals/", headers=adult_a_headers)
    assert {r["title"] for r in listing.json()} == {"Car MOT", "Passport"}


async def test_mark_renewed_advances_recurring(client, adult_a_headers):
    due = (date.today() - timedelta(days=1)).isoformat()
    created = await client.post(
        "/api/renewals/",
        json={"title": "TV licence", "category": "subscription", "due_date": due, "recurrence_months": 12},
        headers=adult_a_headers,
    )
    renewal_id = created.json()["id"]
    assert created.json()["status"] == "overdue"

    renewed = await client.post(f"/api/renewals/{renewal_id}/renewed", headers=adult_a_headers)
    assert renewed.status_code == 200
    new_due = date.fromisoformat(renewed.json()["due_date"])
    assert 360 <= (new_due - date.fromisoformat(due)).days <= 372  # ~12 months on


async def test_mark_renewed_archives_one_off(client, adult_a_headers):
    created = await client.post(
        "/api/renewals/",
        json={"title": "One-off", "due_date": date.today().isoformat()},
        headers=adult_a_headers,
    )
    renewal_id = created.json()["id"]
    await client.post(f"/api/renewals/{renewal_id}/renewed", headers=adult_a_headers)
    assert (await client.get("/api/renewals/", headers=adult_a_headers)).json() == []


async def test_renewals_are_family_isolated(
    client, initialized_db, adult_a_headers, other_family_headers, other_family_user
):
    created = await client.post(
        "/api/renewals/",
        json={"title": "Insurance", "due_date": date.today().isoformat()},
        headers=adult_a_headers,
    )
    renewal_id = created.json()["id"]
    assert (await client.get("/api/renewals/", headers=other_family_headers)).json() == []
    assert (await client.delete(f"/api/renewals/{renewal_id}", headers=other_family_headers)).status_code == 404


async def test_due_soon_renewal_stays_out_of_family_insights(client, adult_a_headers, adult_a_user, initialized_db):
    due = (date.today() + timedelta(days=7)).isoformat()
    await client.post(
        "/api/renewals/",
        json={"title": "Car insurance", "category": "insurance", "due_date": due, "reminder_days_before": 21},
        headers=adult_a_headers,
    )
    first = await check_renewals(adult_a_user["family_id"])
    assert first == []

    async with aiosqlite.connect(initialized_db) as db:
        count = (await (await db.execute(
            "SELECT COUNT(*) FROM family_insights WHERE created_by = 'renewals' AND status = 'active'"
        )).fetchone())[0]
        assert count == 0


async def test_renewal_insight_message_is_stable_across_days(client, adult_a_headers, adult_a_user):
    """The insight message must not embed a day count, so it dedups once-only."""
    from app.services.renewals import _phrase

    # Different days-until must produce the same message (else a new card daily).
    assert _phrase("Car MOT", 14) == _phrase("Car MOT", 3) == _phrase("Car MOT", 0)
    assert "days" not in _phrase("Car MOT", 7)
    # Expired is a distinct stable message.
    assert _phrase("Car MOT", -1) != _phrase("Car MOT", 3)


async def test_far_off_renewal_creates_no_family_insight(client, adult_a_headers, adult_a_user):
    await client.post(
        "/api/renewals/",
        json={"title": "Distant", "due_date": (date.today() + timedelta(days=90)).isoformat(), "reminder_days_before": 21},
        headers=adult_a_headers,
    )
    assert await check_renewals(adult_a_user["family_id"]) == []


async def test_linked_renewal_is_one_finance_owned_record_with_stable_task_history(
    client, initialized_db, adult_a_headers, adult_a_user
):
    due = date.today() + timedelta(days=30)
    created = await client.post(
        "/api/renewals/",
        json={
            "title": "Car insurance",
            "category": "insurance",
            "due_date": due.isoformat(),
            "recurrence_months": 12,
            "cost_pence": 62000,
            "include_in_household_finance": True,
            "payment_handling": "RENEWAL",
            "show_in_calendar": True,
            "show_in_tasks": True,
            "responsible_user_id": adult_a_user["id"],
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    renewal = created.json()
    assert renewal["finance_commitment_id"]
    assert renewal["cost_pence"] == 62000

    calendar_rows = (
        await client.get(
            "/api/calendar/",
            params={
                "start": date.today().isoformat(),
                "end": (date.today() + timedelta(days=60)).isoformat(),
            },
            headers=adult_a_headers,
        )
    ).json()
    finance_event = next(
        event for event in calendar_rows if event["event_type"] == "finance_commitment"
    )
    assert finance_event["title"] == "Car insurance renewal due"
    assert finance_event["managed_source"] == {
        "kind": "finance_renewal",
        "source_id": renewal["id"],
        "deep_link": f"/?view=finance&section=more&renewal={renewal['id']}",
        "label": "Finance renewal",
    }
    assert "62000" not in str(finance_event) and "GBP" not in str(finance_event)

    tasks = (await client.get("/api/tasks/", headers=adult_a_headers)).json()
    task = next(item for item in tasks if item["id"].startswith("finance-task-"))
    assert task["title"] == "Review or renew Car insurance"
    completed = await client.patch(
        f"/api/tasks/{task['id']}/complete", headers=adult_a_headers
    )
    assert completed.status_code == 200
    assert completed.json()["completed_at"] is not None
    async with aiosqlite.connect(initialized_db) as db:
        history_after_completion = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history "
                    "WHERE table_name = 'finance_commitment_occurrences' "
                    "AND record_id = ("
                    "SELECT id FROM finance_commitment_occurrences "
                    "WHERE task_projection_id = ?)",
                    (task["id"],),
                )
            ).fetchone()
        )[0]
    replayed_completion = await client.patch(
        f"/api/tasks/{task['id']}/complete", headers=adult_a_headers
    )
    assert replayed_completion.status_code == 200
    assert replayed_completion.json()["completed_at"] == completed.json()["completed_at"]
    async with aiosqlite.connect(initialized_db) as db:
        history_after_replay = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history "
                    "WHERE table_name = 'finance_commitment_occurrences' "
                    "AND record_id = ("
                    "SELECT id FROM finance_commitment_occurrences "
                    "WHERE task_projection_id = ?)",
                    (task["id"],),
                )
            ).fetchone()
        )[0]
    assert history_after_replay == history_after_completion

    corrected_due = due + timedelta(days=2)
    corrected = await client.patch(
        f"/api/renewals/{renewal['id']}",
        json={"due_date": corrected_due.isoformat()},
        headers=adult_a_headers,
    )
    assert corrected.status_code == 200, corrected.text
    corrected_task = next(
        item
        for item in (await client.get("/api/tasks/", headers=adult_a_headers)).json()
        if item["id"].startswith("finance-task-")
    )
    assert corrected_task["id"] == task["id"]
    assert corrected_task["completed_at"] is not None

    direct_date_edit = await client.patch(
        f"/api/finance/commitments/{renewal['finance_commitment_id']}",
        json={"reviewed_dates": [(corrected_due + timedelta(days=1)).isoformat()]},
        headers=adult_a_headers,
    )
    assert direct_date_edit.status_code == 409

    renewed = await client.post(
        f"/api/renewals/{renewal['id']}/renewed", headers=adult_a_headers
    )
    assert renewed.status_code == 200
    renewed_task = next(
        item
        for item in (await client.get("/api/tasks/", headers=adult_a_headers)).json()
        if item["id"].startswith("finance-task-")
    )
    assert renewed_task["id"] == task["id"]
    assert renewed_task["completed_at"] is None
    assert date.fromisoformat(renewed_task["due_date"]) > corrected_due

    async with aiosqlite.connect(initialized_db) as db:
        history_before_reopen_replay = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history "
                    "WHERE table_name = 'finance_commitment_occurrences' "
                    "AND record_id = ("
                    "SELECT id FROM finance_commitment_occurrences "
                    "WHERE task_projection_id = ?)",
                    (task["id"],),
                )
            ).fetchone()
        )[0]
    first_reopen = await client.patch(
        f"/api/tasks/{task['id']}/reopen", headers=adult_a_headers
    )
    replayed_reopen = await client.patch(
        f"/api/tasks/{task['id']}/reopen", headers=adult_a_headers
    )
    assert first_reopen.status_code == replayed_reopen.status_code == 200
    assert first_reopen.json()["completed_at"] is None
    assert replayed_reopen.json()["completed_at"] is None
    async with aiosqlite.connect(initialized_db) as db:
        history_after_reopen_replay = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history "
                    "WHERE table_name = 'finance_commitment_occurrences' "
                    "AND record_id = ("
                    "SELECT id FROM finance_commitment_occurrences "
                    "WHERE task_projection_id = ?)",
                    (task["id"],),
                )
            ).fetchone()
        )[0]
    assert history_after_reopen_replay == history_before_reopen_replay

    async with aiosqlite.connect(initialized_db) as db:
        occurrence_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM finance_commitment_occurrences WHERE commitment_id = ?",
                    (renewal["finance_commitment_id"],),
                )
            ).fetchone()
        )[0]
        renewal_history = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE table_name = 'renewals' AND record_id = ?",
                    (renewal["id"],),
                )
            ).fetchone()
        )[0]
    assert occurrence_count == 1
    assert renewal_history >= 2


async def test_renewal_rejects_blank_title_and_foreign_document(
    client, adult_a_headers, other_family_headers, other_family_user, initialized_db
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO documents
                (id, title, original_filename, storage_key, media_type, file_size,
                 sha256, family_id, created_at, updated_at, created_by)
            VALUES ('foreign-renewal-document', 'Foreign', 'foreign.pdf',
                    'foreign.pdf', 'application/pdf', 1, 'fixture-digest', ?,
                    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', ?)
            """,
            (other_family_user["family_id"], other_family_user["id"]),
        )
        await db.commit()
    blank = await client.post(
        "/api/renewals/",
        json={"title": "   ", "due_date": date.today().isoformat()},
        headers=adult_a_headers,
    )
    assert blank.status_code == 422
    foreign = await client.post(
        "/api/renewals/",
        json={
            "title": "Passport",
            "due_date": date.today().isoformat(),
            "source_document_id": "foreign-renewal-document",
        },
        headers=adult_a_headers,
    )
    assert foreign.status_code == 422


async def test_renewal_surfaces_its_linked_document(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO documents
                (id, title, original_filename, storage_key, media_type, file_size,
                 sha256, status, family_id, created_at, updated_at, created_by)
            VALUES ('renewal-document', 'Passport scan', 'passport.pdf',
                    'passport.pdf', 'application/pdf', 1234, 'fixture-digest', 'filed', ?,
                    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', ?)
            """,
            (adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    created = await client.post(
        "/api/renewals/",
        json={
            "title": "Alex's passport",
            "due_date": date.today().isoformat(),
            "source_document_id": "renewal-document",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    assert created.json()["source_document"] == {
        "id": "renewal-document",
        "title": "Passport scan",
        "original_filename": "passport.pdf",
        "media_type": "application/pdf",
        "file_size": 1234,
        "download_url": "/api/documents/renewal-document/content",
    }

    listing = await client.get("/api/renewals/", headers=adult_a_headers)
    assert listing.json()[0]["source_document"]["title"] == "Passport scan"


async def test_complete_renewal_workflow_with_checklist_and_optional_calendar_task(
    client, adult_a_headers, adult_a_user
):
    due = date.today() + timedelta(days=20)
    created = await client.post(
        "/api/renewals/",
        json={
            "title": "Home insurance",
            "category": "insurance",
            "due_date": due.isoformat(),
            "recurrence_months": 12,
            "cost_pence": 48000,
            "provider": "Useful Insurance",
            "reference": "POL-123",
            "action_url": "https://example.com/renew",
            "comparison_url": "https://example.com/compare",
            "contact_url": "mailto:renewals@example.invalid",
            "responsible_user_id": adult_a_user["id"],
            "show_in_calendar": True,
            "show_in_tasks": True,
            "checklist": ["Check cover", "Compare price"],
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    renewal = created.json()
    assert renewal["provider"] == "Useful Insurance"
    assert renewal["reference"] == "POL-123"
    assert renewal["responsible_user_name"] == adult_a_user["name"]
    assert [item["title"] for item in renewal["checklist"]] == [
        "Check cover",
        "Compare price",
    ]

    calendar_rows = (
        await client.get(
            "/api/calendar/",
            params={
                "start": date.today().isoformat(),
                "end": (date.today() + timedelta(days=40)).isoformat(),
            },
            headers=adult_a_headers,
        )
    ).json()
    projected_event = next(item for item in calendar_rows if item["id"].startswith("renewal-calendar-"))
    assert projected_event["title"] == "Home insurance renewal due"
    assert projected_event["managed_source"]["deep_link"].endswith(renewal["id"])

    tasks = (await client.get("/api/tasks/", headers=adult_a_headers)).json()
    projected_task = next(item for item in tasks if item["id"].startswith("renewal-task-"))
    assert projected_task["assigned_to"] == adult_a_user["id"]
    completed = await client.patch(
        f"/api/tasks/{projected_task['id']}/complete", headers=adult_a_headers
    )
    assert completed.status_code == 200
    assert completed.json()["completed_at"] is not None

    first_step = renewal["checklist"][0]
    checked = await client.patch(
        f"/api/renewals/{renewal['id']}/checklist/{first_step['id']}",
        json={"checked": True},
        headers=adult_a_headers,
    )
    assert checked.status_code == 200
    assert checked.json()["checked_at"] is not None

    next_due = date.today() + timedelta(days=385)
    decided = await client.post(
        f"/api/renewals/{renewal['id']}/decision",
        json={
            "outcome": "renewed",
            "next_due_date": next_due.isoformat(),
            "cost_pence": 51000,
            "notes": "Kept the same cover",
        },
        headers=adult_a_headers,
    )
    assert decided.status_code == 200, decided.text
    updated = decided.json()
    assert updated["due_date"] == next_due.isoformat()
    assert updated["cost_pence"] == 51000
    assert updated["history"][0]["cost_pence"] == 51000
    assert updated["history"][0]["notes"] == "Kept the same cover"
    assert all(item["checked_at"] is None for item in updated["checklist"])


async def test_renewal_document_draft_is_review_only(client, adult_a_headers, adult_a_user, initialized_db):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO documents
                (id, title, original_filename, storage_key, media_type, file_size,
                 sha256, status, extracted_text, family_id, created_at, updated_at, created_by)
            VALUES ('insurance-letter', 'Home insurance', 'renewal.pdf',
                    'renewal.pdf', 'application/pdf', 1234, 'draft-digest', 'filed',
                    'Provider: Useful Insurance\nPolicy number: POL-123\nAnnual premium £510.00\nRenew by 20/09/2026\nhttps://example.com/renew',
                    ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', ?)
            """,
            (adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    preview = await client.post(
        "/api/renewals/draft",
        json={"document_id": "insurance-letter"},
        headers=adult_a_headers,
    )
    assert preview.status_code == 200, preview.text
    assert preview.json() == {
        "title": "Home insurance",
        "category": "insurance",
        "due_date": "2026-09-20",
        "recurrence_months": 12,
        "cost_pence": 51000,
        "provider": "Useful Insurance",
        "reference": "POL-123",
        "action_url": "https://example.com/renew",
        "source_document_id": "insurance-letter",
        "uncertain_fields": [],
    }
    assert (await client.get("/api/renewals/", headers=adult_a_headers)).json() == []


async def test_not_renewing_can_be_undone(client, adult_a_headers):
    created = await client.post(
        "/api/renewals/",
        json={"title": "Old membership", "due_date": date.today().isoformat()},
        headers=adult_a_headers,
    )
    renewal_id = created.json()["id"]
    stopped = await client.post(
        f"/api/renewals/{renewal_id}/decision",
        json={"outcome": "not_renewing"},
        headers=adult_a_headers,
    )
    assert stopped.status_code == 200
    assert (await client.get("/api/renewals/", headers=adult_a_headers)).json() == []

    restored = await client.post(
        f"/api/renewals/{renewal_id}/restore", headers=adult_a_headers
    )
    assert restored.status_code == 200, restored.text
    assert restored.json()["id"] == renewal_id
    assert restored.json()["history"] == []

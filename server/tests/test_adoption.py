"""Privacy and usefulness contracts for the short usage history."""

from datetime import datetime, timedelta, timezone
import uuid

import aiosqlite

from app.database import init_db
from app.services.adoption import (
    CompletedAction,
    classify_action_request,
    cleanup_expired_adoption_events,
)


def _client_headers(headers: dict, source: str = "web") -> dict:
    return {
        **headers,
        "X-HausKlar-Client": source,
        "X-HausKlar-App-Version": "1.2.3",
    }


async def _create_task(client, headers: dict, title: str):
    return await client.post(
        "/api/tasks/",
        headers=_client_headers(headers),
        json={"id": str(uuid.uuid4()), "title": title},
    )


async def _set_enabled(client, headers: dict, enabled: bool = True):
    return await client.patch(
        "/api/usage-history/preferences",
        headers=headers,
        json={"enabled": enabled},
    )


def _fitness_mutation(entity_type: str, entity_id: str, payload: dict) -> dict:
    return {
        "mutation_id": str(uuid.uuid4()),
        "entity_type": entity_type,
        "entity_id": entity_id,
        "operation": "upsert",
        "payload_schema_version": 1,
        "base_revision": None,
        "payload": payload,
        "created_at_client": "2026-08-20T10:00:00+00:00",
    }


def _fitness_sync(mutations: list[dict]) -> dict:
    return {
        "sync_protocol_version": 1,
        "client_schema_version": 1,
        "client_app_version": "1.8.2",
        "client_build": "17",
        "platform": "ios",
        "device_id": str(uuid.uuid4()),
        "cursor": 0,
        "mutations": mutations,
    }


def test_only_allowlisted_action_outcomes_are_classified():
    assert classify_action_request("POST", "/api/tasks/", 201) == CompletedAction(
        "tasks", "add_task", "created", "standard"
    )
    assert classify_action_request("POST", "/api/tasks/", 422) == CompletedAction(
        "tasks", "add_task", "failed", "standard"
    )
    assert classify_action_request("GET", "/api/tasks/", 200) is None
    assert classify_action_request("POST", "/api/search", 200) is None
    assert classify_action_request("POST", "/api/assistant/chat", 200) is None
    assert classify_action_request("POST", "/api/sync", 200) is None
    assert classify_action_request(
        "POST", "/api/fitness/integrations/strava/sync", 200
    ) == CompletedAction("fitness", "pull_strava", "completed", "quick")
    # Idempotent booking routes record inside their transaction so an HTTP
    # retry cannot look like another booking to the usage summary.
    assert classify_action_request("POST", "/api/facilities/swimming-bookings", 201) is None
    assert classify_action_request("POST", "/api/facilities/weights-bookings", 201) is None


async def test_semantic_interactions_are_allowlisted_deduplicated_and_summarized(
    client, adult_a_headers, initialized_db
):
    assert (await _set_enabled(client, adult_a_headers)).status_code == 200
    workflow_run_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    events = [
        {
            "id": str(uuid.uuid4()),
            "event_kind": "screen_view",
            "module": "today",
            "action": "view_today",
            "outcome": "viewed",
            "surface": "today",
            "occurred_at": now,
        },
        {
            "id": str(uuid.uuid4()),
            "event_kind": "control",
            "module": "facilities",
            "action": "open_swimming_booking",
            "outcome": "tapped",
            "surface": "today_facilities",
            "workflow": "book_swimming",
            "occurred_at": now,
        },
        {
            "id": str(uuid.uuid4()),
            "event_kind": "workflow",
            "module": "facilities",
            "action": "book_swimming",
            "outcome": "started",
            "surface": "today_facilities",
            "workflow": "book_swimming",
            "workflow_run_id": workflow_run_id,
            "occurred_at": now,
        },
        {
            "id": str(uuid.uuid4()),
            "event_kind": "workflow",
            "module": "facilities",
            "action": "book_swimming",
            "outcome": "completed",
            "surface": "today_facilities",
            "workflow": "book_swimming",
            "workflow_run_id": workflow_run_id,
            "duration_bucket": "under_1m",
            "interaction_count": 4,
            "connectivity": "queued",
            "occurred_at": now,
        },
    ]
    for _ in range(2):
        response = await client.post(
            "/api/usage-history/events",
            headers=_client_headers(adult_a_headers, "ios"),
            json={"events": events},
        )
        assert response.status_code == 204, response.text

    rejected = await client.post(
        "/api/usage-history/events",
        headers=_client_headers(adult_a_headers, "ios"),
        json={
            "events": [
                {
                    "id": str(uuid.uuid4()),
                    "event_kind": "control",
                    "module": "family",
                    "action": "private_child_name",
                    "outcome": "tapped",
                    "surface": "family",
                    "occurred_at": now,
                }
            ]
        },
    )
    assert rejected.status_code == 422

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT * FROM adoption_events ORDER BY client_timestamp, event_kind"
            )
        ).fetchall()
    assert len(rows) == 4
    assert {row["event_kind"] for row in rows} == {
        "screen_view",
        "control",
        "workflow",
    }
    assert all(row["entry_source"] == "ios" for row in rows)
    assert all(row["app_version"] == "1.2.3" for row in rows)

    summary = await client.get("/api/usage-history/summary", headers=adult_a_headers)
    assert summary.status_code == 200, summary.text
    body = summary.json()
    assert body["meaningful_actions"] == 0
    assert body["screen_views"] == [
        {"module": "today", "surface": "today", "views": 1, "active_days": 1}
    ]
    assert body["control_uses"] == [
        {
            "module": "facilities",
            "action": "open_swimming_booking",
            "surface": "today_facilities",
            "presses": 1,
            "active_days": 1,
        }
    ]
    assert body["workflows"] == [
        {
            "module": "facilities",
            "workflow": "book_swimming",
            "action": "book_swimming",
            "starts": 1,
            "completions": 1,
            "failures": 0,
            "abandonments": 0,
            "queued_completions": 1,
            "average_interactions": 4.0,
        }
    ]


async def test_fitness_sync_records_fresh_semantic_actions_without_replay_duplicates(
    client, adult_a_headers, initialized_db
):
    assert (await _set_enabled(client, adult_a_headers)).status_code == 200
    food_id = str(uuid.uuid4())
    version_id = str(uuid.uuid4())
    entry_id = str(uuid.uuid4())
    body = _fitness_sync(
        [
            _fitness_mutation(
                "food",
                food_id,
                {
                    "name": "Private breakfast name",
                    "version": {
                        "id": version_id,
                        "reference_amount": 100,
                        "reference_unit": "g",
                        "calories_kcal": 400,
                        "protein_g": 12,
                    },
                },
            ),
            _fitness_mutation(
                "food_log_entry",
                entry_id,
                {
                    "food_version_id": version_id,
                    "logged_at_utc": "2026-08-20T08:00:00+00:00",
                    "local_timezone": "Europe/London",
                    "meal_key": "breakfast",
                    "entered_amount": 50,
                    "entered_unit": "g",
                    "canonical_amount": 50,
                    "canonical_unit": "g",
                    "measurement_quality": "weighed",
                },
            ),
        ]
    )
    for _ in range(2):
        response = await client.post(
            "/api/fitness/sync", headers=adult_a_headers, json=body
        )
        assert response.status_code == 200, response.text

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT * FROM adoption_events WHERE event_kind = 'server_action' "
                "ORDER BY action"
            )
        ).fetchall()
    assert [(row["action"], row["outcome"]) for row in rows] == [
        ("log_food", "logged"),
        ("save_food", "created"),
    ]
    assert all(row["entry_source"] == "ios" for row in rows)
    assert all(row["app_version"] == "1.8.2" for row in rows)
    stored_values = " ".join(str(value) for row in rows for value in row)
    assert "Private breakfast name" not in stored_values


async def test_upgrade_soft_deletes_events_that_predate_explicit_consent(
    adult_a_user, initialized_db
):
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO adoption_events (
                id, user_id, module, action, outcome, entry_source, effort,
                app_version, family_id, created_at, updated_at, created_by
            ) VALUES (?, ?, 'tasks', 'add_task', 'created', 'ios',
                      'standard', '1.6', ?, ?, ?, ?)""",
            (
                str(uuid.uuid4()), adult_a_user["id"], adult_a_user["family_id"],
                now, now, adult_a_user["id"],
            ),
        )
        await db.commit()

    await init_db(initialized_db)

    async with aiosqlite.connect(initialized_db) as db:
        deleted_at = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM adoption_events WHERE user_id = ?",
                    (adult_a_user["id"],),
                )
            ).fetchone()
        )[0]
    assert deleted_at is not None


async def test_startup_adds_interaction_columns_before_their_indexes(db_path):
    """An installed pre-interaction database must survive normal startup."""
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DROP TABLE adoption_events")
        await db.execute(
            """CREATE TABLE adoption_events (
                id TEXT PRIMARY KEY, user_id TEXT NOT NULL, module TEXT NOT NULL,
                action TEXT NOT NULL, outcome TEXT NOT NULL,
                entry_source TEXT NOT NULL CHECK (entry_source IN ('ios', 'web', 'unknown')),
                effort TEXT NOT NULL CHECK (effort IN ('quick', 'standard', 'involved')),
                app_version TEXT NOT NULL, family_id TEXT NOT NULL,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL, created_by TEXT,
                client_id TEXT, client_timestamp TEXT, deleted_at TEXT
            )"""
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        columns = {
            row[1]
            for row in await (
                await db.execute("PRAGMA table_info(adoption_events)")
            ).fetchall()
        }
        indexes = {
            row[1]
            for row in await (
                await db.execute("PRAGMA index_list(adoption_events)")
            ).fetchall()
        }
    assert {
        "event_kind",
        "surface",
        "workflow",
        "workflow_run_id",
        "duration_bucket",
        "interaction_count",
        "connectivity",
        "failure_class",
    } <= columns
    assert {
        "idx_adoption_owner_interaction_time",
        "idx_adoption_owner_workflow_time",
    } <= indexes


async def test_server_records_no_content_only_after_opt_in_and_erases_on_withdrawal(
    client, adult_a_headers, adult_a_user, initialized_db
):
    preferences = await client.get("/api/usage-history/preferences", headers=adult_a_headers)
    assert preferences.json() == {"enabled": False, "retention_days": 28}
    assert (await _create_task(client, adult_a_headers, "Not consented")).status_code == 201
    async with aiosqlite.connect(initialized_db) as db:
        before_opt_in = (
            await (await db.execute("SELECT COUNT(*) FROM adoption_events")).fetchone()
        )[0]
    assert before_opt_in == 0

    enabled = await _set_enabled(client, adult_a_headers)
    assert enabled.json() == {"enabled": True, "retention_days": 28}

    secret_title = "SECRET child name and private note"
    created = await _create_task(client, adult_a_headers, secret_title)
    assert created.status_code == 201, created.text
    failed_secret = "FAILED-PRIVATE-" + ("x" * 300)
    failed = await _create_task(client, adult_a_headers, failed_secret)
    assert failed.status_code == 422

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute("SELECT * FROM adoption_events")).fetchall()
        columns = {
            row[1]
            for row in await (await db.execute("PRAGMA table_info(adoption_events)")).fetchall()
        }
    assert len(rows) == 2
    assert {row["outcome"] for row in rows} == {"created", "failed"}
    assert all(row["module"] == "tasks" and row["action"] == "add_task" for row in rows)
    assert all(row["entry_source"] == "web" and row["app_version"] == "1.2.3" for row in rows)
    stored_values = " ".join(str(value) for row in rows for value in row)
    assert secret_title not in stored_values
    assert failed_secret not in stored_values
    assert not columns.intersection(
        {"title", "name", "notes", "amount", "entity_id", "record_id", "search_text", "content"}
    )

    disabled = await _set_enabled(client, adult_a_headers, False)
    assert disabled.json() == {"enabled": False, "retention_days": 28}
    assert (await _create_task(client, adult_a_headers, "Another private title")).status_code == 201
    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM adoption_events WHERE deleted_at IS NULL"
                )
            ).fetchone()
        )[0]
    assert count == 0


async def test_summary_counts_repeat_use_and_shared_adult_contribution_without_private_leakage(
    client, adult_a_headers, adult_b_headers, adult_a_user, adult_b_user, initialized_db
):
    assert (await _set_enabled(client, adult_a_headers)).status_code == 200
    assert (await _set_enabled(client, adult_b_headers)).status_code == 200
    assert (await _create_task(client, adult_a_headers, "Alex task")).status_code == 201
    assert (await _create_task(client, adult_b_headers, "Morgan task")).status_code == 201
    assert (
        await _create_task(client, adult_a_headers, "Private invalid title " + ("x" * 300))
    ).status_code == 422
    yesterday = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE adoption_events SET created_at = ? WHERE user_id = ?",
            (yesterday, adult_a_user["id"]),
        )
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """INSERT INTO adoption_events (
                id, user_id, module, action, outcome, entry_source, effort,
                app_version, family_id, created_at, updated_at, created_by
            ) VALUES (?, ?, 'tasks', 'complete_task', 'completed', 'ios',
                      'quick', '2.0', ?, ?, ?, ?)""",
            (str(uuid.uuid4()), adult_a_user["id"], adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO adoption_events (
                id, user_id, module, action, outcome, entry_source, effort,
                app_version, family_id, created_at, updated_at, created_by
            ) VALUES (?, ?, 'finance', 'add_goal', 'created', 'web',
                      'standard', '2.0', ?, ?, ?, ?)""",
            (str(uuid.uuid4()), adult_b_user["id"], adult_b_user["family_id"], now, now, adult_b_user["id"]),
        )
        await db.commit()

    summary = await client.get("/api/usage-history/summary", headers=adult_a_headers)
    assert summary.status_code == 200, summary.text
    body = summary.json()
    assert body["meaningful_actions"] == 2
    assert body["failed_actions"] == 1
    assert body["active_days"] == 2
    assert body["use_signal"] == "returning"
    assert body["repeat_modules"] == [{"module": "tasks", "actions": 2, "active_days": 2}]
    assert body["both_adults_contributed"] is True
    assert body["shared_family_actions"] == 3

    exported = (await client.get("/api/usage-history/export", headers=adult_a_headers)).json()
    assert len(exported["events"]) == 3
    assert {event["module"] for event in exported["events"]} == {"tasks"}
    assert {event["outcome"] for event in exported["events"]} == {"created", "completed", "failed"}
    assert all("id" not in event and "title" not in event for event in exported["events"])


async def test_clear_retention_and_account_deletion_remove_only_the_owner_history(
    client, adult_a_headers, adult_b_headers, adult_a_user, adult_b_user, initialized_db
):
    assert (await _set_enabled(client, adult_a_headers)).status_code == 200
    assert (await _set_enabled(client, adult_b_headers)).status_code == 200
    await _create_task(client, adult_a_headers, "Alex task")
    await _create_task(client, adult_b_headers, "Morgan task")

    cleared = await client.delete("/api/usage-history/", headers=adult_a_headers)
    assert cleared.status_code == 200
    assert cleared.json()["cleared"] == 1
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute("SELECT user_id, deleted_at FROM adoption_events")
        ).fetchall()
    assert next(row for row in rows if row["user_id"] == adult_a_user["id"])["deleted_at"]
    assert next(row for row in rows if row["user_id"] == adult_b_user["id"])["deleted_at"] is None

    old = (datetime.now(timezone.utc) - timedelta(days=29)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE adoption_events SET created_at = ? WHERE user_id = ?",
            (old, adult_b_user["id"]),
        )
        assert await cleanup_expired_adoption_events(db) == 1
        await db.commit()

    # A departing adult's usage facts and preference are private account data.
    await _set_enabled(client, adult_a_headers, False)
    await client.patch(
        "/api/auth/onboarding",
        headers=adult_a_headers,
        json={"selected_modules": ["children"], "dismissed": True},
    )
    deleted = await client.delete("/api/auth/me", headers=adult_a_headers)
    assert deleted.status_code == 204, deleted.text
    async with aiosqlite.connect(initialized_db) as db:
        facts = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM adoption_events WHERE user_id = ?", (adult_a_user["id"],)
                )
            ).fetchone()
        )[0]
        settings = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM family_settings WHERE family_id = ? "
                    "AND setting_key IN (?, ?)",
                    (
                        adult_a_user["family_id"],
                        f"usage_history:{adult_a_user['id']}",
                        f"onboarding:{adult_a_user['id']}",
                    ),
                )
            ).fetchone()
        )[0]
    assert facts == 0
    assert settings == 0

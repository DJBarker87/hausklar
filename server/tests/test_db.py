"""Tests for database initialisation (schema, WAL mode, table creation)."""

import json
import stat
from pathlib import Path

import aiosqlite
import pytest

from app.auth import hash_refresh_token
from app.config import settings
from app.database import _ConnectionPool, close_db_pool, get_db, init_db, set_db_path


EXPECTED_TABLES = [
    "users",
    "refresh_tokens",
    "children",
    "calendar_events",
    "caregiver_handovers",
    "caregiver_child_profiles",
    "caregiver_contacts",
    "caregiver_bookings",
    "tasks",
    "medicine_types",
    "medicine_doses",
    "naps",
    "dog_activities",
    "birthdays",
    "meals",
    "meal_plans",
    "meal_ratings",
    "shopping_items",
    "grocery_items",
    "purchase_batches",
    "purchases",
    "consumption_events",
    "health_data",
    "homework_reading",
    "homework_spellings",
    "growth_records",
    "record_history",
    "sync_queue",
]


async def test_db_initialises(db_path: str):
    """Calling init_db should create at least one table in sqlite_master."""
    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        cursor = await db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
        tables = [row[0] for row in await cursor.fetchall()]

    assert len(tables) > 0, "init_db should create tables in the database"


async def test_db_wal_mode(db_path: str):
    """init_db should enable WAL journal mode for crash resilience."""
    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        cursor = await db.execute("PRAGMA journal_mode")
        row = await cursor.fetchone()

    assert row is not None
    assert row[0].lower() == "wal", f"Expected WAL mode, got '{row[0]}'"


async def test_db_and_existing_wal_sidecars_are_owner_only(db_path: str):
    await init_db(db_path)
    database = Path(db_path)
    database.chmod(0o644)

    await init_db(db_path)

    assert stat.S_IMODE(database.stat().st_mode) == 0o600
    for suffix in ("-wal", "-shm"):
        sidecar = Path(f"{database}{suffix}")
        if sidecar.exists():
            assert stat.S_IMODE(sidecar.stat().st_mode) == 0o600


async def test_db_all_tables_exist(db_path: str):
    """Every table defined in schema.sql must be present after init_db."""
    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        cursor = await db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
        tables = {row[0] for row in await cursor.fetchall()}

    for expected in EXPECTED_TABLES:
        assert expected in tables, f"Table '{expected}' is missing from the database"


async def test_existing_database_gains_new_family_workflow_tables(db_path: str):
    """Normal startup applies schema additions to an existing database."""
    await init_db(db_path)
    expected = {
        "dog_profiles": "idx_dog_profiles_family_active",
        "dog_weights": "idx_dog_weights_family_measured",
        "dog_document_links": "idx_dog_document_links_active",
        "birthday_preparations": "idx_birthday_preparations_active",
        "birthday_preparation_links": "idx_birthday_preparation_links_active",
        "renewal_checklist_items": "idx_renewal_checklist_active",
        "renewal_outcomes": "idx_renewal_outcomes_history",
    }
    async with aiosqlite.connect(db_path) as db:
        for table in expected:
            await db.execute(f"DROP TABLE {table}")
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        tables = {
            row[0]
            for row in await (
                await db.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"
                )
            ).fetchall()
        }
        indexes = {
            row[0]
            for row in await (
                await db.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'index'"
                )
            ).fetchall()
        }

    assert expected.keys() <= tables
    assert set(expected.values()) <= indexes


async def test_handoff_migration_removes_pickup_adults_and_preserves_work_owner(
    db_path: str,
):
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        for index in (
            "idx_term_time_handoff_weekday_active",
            "idx_term_time_handoff_term_person",
            "idx_term_time_handoff_override_active",
            "idx_term_time_handoff_override_date",
        ):
            await db.execute(f"DROP INDEX IF EXISTS {index}")
        await db.execute("DROP TABLE term_time_handoff_overrides")
        await db.execute("DROP TABLE term_time_handoffs")
        await db.executescript(
            """
            CREATE TABLE term_time_handoffs (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                weekday INTEGER NOT NULL,
                time_of_day TEXT NOT NULL,
                term_person_id TEXT NOT NULL,
                owner_user_id TEXT NOT NULL,
                family_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                created_by TEXT,
                updated_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            );
            CREATE TABLE term_time_handoff_overrides (
                id TEXT PRIMARY KEY,
                handoff_id TEXT NOT NULL,
                occurrence_date TEXT NOT NULL,
                time_of_day TEXT NOT NULL,
                owner_user_id TEXT NOT NULL,
                is_cancelled INTEGER NOT NULL DEFAULT 0,
                family_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                created_by TEXT,
                updated_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            );
            INSERT INTO term_time_handoffs
                (id, kind, weekday, time_of_day, term_person_id, owner_user_id,
                 family_id, created_at, updated_at)
            VALUES
                ('pickup', 'pickup', 0, '15:20', 'child', 'kat',
                 'family', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
                ('work', 'work_departure', 0, '17:00', 'dom', 'dom',
                 'family', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
            INSERT INTO term_time_handoff_overrides
                (id, handoff_id, occurrence_date, time_of_day, owner_user_id,
                 is_cancelled, family_id, created_at, updated_at)
            VALUES
                ('pickup-day', 'pickup', '2026-02-02', '15:45', 'dom', 0,
                 'family', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
                ('work-day', 'work', '2026-02-02', '17:15', 'dom', 0,
                 'family', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
            """
        )
        await db.commit()

    await init_db(db_path)
    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        handoff_columns = await (
            await db.execute("PRAGMA table_info(term_time_handoffs)")
        ).fetchall()
        override_columns = await (
            await db.execute("PRAGMA table_info(term_time_handoff_overrides)")
        ).fetchall()
        handoffs = await (
            await db.execute(
                "SELECT id, owner_user_id FROM term_time_handoffs ORDER BY id"
            )
        ).fetchall()
        overrides = await (
            await db.execute(
                "SELECT id, owner_user_id FROM term_time_handoff_overrides ORDER BY id"
            )
        ).fetchall()
        history = await (
            await db.execute(
                "SELECT table_name, previous_values FROM record_history "
                "WHERE changed_by = 'handoff-owner-migration' ORDER BY table_name"
            )
        ).fetchall()

    assert next(row[3] for row in handoff_columns if row[1] == "owner_user_id") == 0
    assert next(row[3] for row in override_columns if row[1] == "owner_user_id") == 0
    assert dict(handoffs) == {"pickup": None, "work": "dom"}
    assert dict(overrides) == {"pickup-day": None, "work-day": "dom"}
    assert len(history) == 2
    assert {json.loads(row[1])["owner_user_id"] for row in history} == {"kat", "dom"}


async def test_calendar_rugby_source_index_follows_legacy_column_migration(db_path: str):
    """Existing calendar source tables must gain rugby fields before their index."""
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DROP INDEX idx_calendar_sources_example_school_rugby_active")
        await db.execute("ALTER TABLE calendar_sources DROP COLUMN config_json")
        await db.execute("ALTER TABLE calendar_sources DROP COLUMN source_kind")
        await db.commit()

    await init_db(db_path)
    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        columns = await (
            await db.execute("PRAGMA table_info(calendar_sources)")
        ).fetchall()
        indexes = await (
            await db.execute("PRAGMA index_list(calendar_sources)")
        ).fetchall()

    assert {"source_kind", "config_json"} <= {row[1] for row in columns}
    assert "idx_calendar_sources_example_school_rugby_active" in {row[1] for row in indexes}


async def test_startup_upgrades_legacy_tables_before_creating_new_indexes(
    db_path: str,
):
    async with aiosqlite.connect(db_path) as db:
        await db.executescript(
            """
            CREATE TABLE present_ideas (
                id TEXT PRIMARY KEY,
                child_id TEXT NOT NULL,
                occasion TEXT NOT NULL,
                event_year INTEGER,
                title TEXT NOT NULL,
                notes TEXT,
                assigned_to TEXT,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            );
            INSERT INTO present_ideas (
                id, child_id, occasion, event_year, title, notes, family_id,
                created_at, updated_at
            ) VALUES (
                'legacy-present', 'child', 'birthday', 2026, 'Wooden train',
                'Keep this note', 'family', '2026-08-01T09:00:00Z',
                '2026-08-02T10:00:00Z'
            );

            CREATE TABLE dog_activities (
                id TEXT PRIMARY KEY,
                activity_type TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                notes TEXT,
                done_by TEXT,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            );
            INSERT INTO dog_activities (
                id, activity_type, started_at, notes, family_id
            ) VALUES (
                'legacy-walk', 'walk', '2026-08-01T07:00:00Z',
                'Keep the walk note', 'family'
            );

            CREATE TABLE birthdays (
                id TEXT PRIMARY KEY,
                person_name TEXT NOT NULL,
                date_of_birth TEXT NOT NULL,
                relationship TEXT,
                reminder_days_before INTEGER,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            );
            INSERT INTO birthdays (
                id, person_name, date_of_birth, relationship, family_id
            ) VALUES (
                'legacy-birthday', 'Aunt Jane', '1982-03-14', 'family', 'family'
            );

            CREATE TABLE homework_spellings (
                id TEXT PRIMARY KEY,
                child_id TEXT NOT NULL,
                word_list TEXT NOT NULL,
                test_date TEXT NOT NULL,
                score INTEGER,
                practice_count INTEGER NOT NULL DEFAULT 0,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            );
            INSERT INTO homework_spellings (
                id, child_id, word_list, test_date, family_id
            ) VALUES (
                'legacy-spellings', 'child', '["house", "mouse"]',
                '2026-08-14', 'family'
            );

            CREATE TABLE artworks (
                id TEXT PRIMARY KEY,
                child_id TEXT NOT NULL,
                title TEXT,
                notes TEXT,
                approx_date TEXT NOT NULL,
                media_type TEXT NOT NULL,
                storage_key TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            );
            INSERT INTO artworks (
                id, child_id, title, approx_date, media_type, storage_key,
                file_size, sha256, family_id
            ) VALUES (
                'legacy-art', 'child', 'Rainbow', '2026-07-01', 'image/jpeg',
                'art/rainbow.jpg', 10, 'art-sha', 'family'
            );

            CREATE TABLE child_photos (
                id TEXT PRIMARY KEY,
                child_id TEXT NOT NULL,
                caption TEXT,
                taken_on TEXT NOT NULL,
                media_type TEXT NOT NULL,
                storage_key TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            );
            INSERT INTO child_photos (
                id, child_id, caption, taken_on, media_type, storage_key,
                file_size, sha256, family_id
            ) VALUES (
                'legacy-photo', 'child', 'First steps', '2026-06-01',
                'image/jpeg', 'photos/steps.jpg', 11, 'photo-sha', 'family'
            );
            """
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        present_columns = {
            row[1]
            for row in await (await db.execute("PRAGMA table_info(present_ideas)")).fetchall()
        }
        present_indexes = {
            row[1]
            for row in await (await db.execute("PRAGMA index_list(present_ideas)")).fetchall()
        }
        present = await (
            await db.execute(
                """
                SELECT title, notes, occasion_key, status, status_updated_at, currency
                FROM present_ideas WHERE id = ?
                """,
                ("legacy-present",),
            )
        ).fetchone()
        dog = await (
            await db.execute(
                "SELECT notes, is_active FROM dog_activities WHERE id = 'legacy-walk'"
            )
        ).fetchone()
        birthday = await (
            await db.execute(
                "SELECT person_name, birth_year, birth_month, birth_day "
                "FROM birthdays WHERE id = 'legacy-birthday'"
            )
        ).fetchone()
        spellings = await (
            await db.execute(
                "SELECT word_list, completed_at FROM homework_spellings "
                "WHERE id = 'legacy-spellings'"
            )
        ).fetchone()
        artwork = await (
            await db.execute(
                "SELECT title, favourite FROM artworks WHERE id = 'legacy-art'"
            )
        ).fetchone()
        photo = await (
            await db.execute(
                "SELECT caption, favourite FROM child_photos WHERE id = 'legacy-photo'"
            )
        ).fetchone()
        migrated_indexes = {
            row[0]
            for row in await (
                await db.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'index'"
                )
            ).fetchall()
        }

    assert {
        "occasion_key",
        "birthday_id",
        "status",
        "status_updated_at",
        "owner_id",
        "deadline",
    } <= present_columns
    assert {
        "idx_present_ideas_occasion_key",
        "idx_present_ideas_birthday",
        "idx_present_ideas_status",
        "idx_present_ideas_deadline",
        "idx_present_ideas_owner",
    } <= present_indexes
    assert {
        "idx_dog_activities_active",
        "idx_birthdays_family_month_day",
        "idx_homework_spellings_due",
        "idx_artworks_family_favourites",
        "idx_child_photos_family_favourites",
    } <= migrated_indexes
    assert present == (
        "Wooden train",
        "Keep this note",
        "birthday",
        "idea",
        "2026-08-02T10:00:00Z",
        "GBP",
    )
    assert dog == ("Keep the walk note", 0)
    assert birthday == ("Aunt Jane", 1982, 3, 14)
    assert spellings == ('["house", "mouse"]', None)
    assert artwork == ("Rainbow", 0)
    assert photo == ("First steps", 0)


async def test_db_backfills_legacy_history_without_overwriting_snapshot_tenancy(
    db_path: str,
):
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.executemany(
            "INSERT INTO families (id, name) VALUES (?, ?)",
            [("history-family-a", "A"), ("history-family-b", "B")],
        )
        await db.executemany(
            """
            INSERT INTO users (id, name, email, password_hash, family_id)
            VALUES (?, ?, ?, 'not-used-in-this-test', ?)
            """,
            [
                ("history-user-a", "A", "demo-person-20@example.invalid", "history-family-a"),
                ("history-user-b", "B", "demo-person-21@example.invalid", "history-family-b"),
            ],
        )
        await db.executemany(
            """
            INSERT INTO record_history (
                id, table_name, record_id, previous_values, changed_by, family_id
            ) VALUES (?, 'tasks', ?, ?, ?, NULL)
            """,
            [
                (
                    "history-from-snapshot",
                    "record-a",
                    '{"family_id":"history-family-a"}',
                    "history-user-b",
                ),
                (
                    "history-from-author",
                    "record-b",
                    '{"title":"pre-tenancy"}',
                    "history-user-b",
                ),
                (
                    "history-conflicting-unknown",
                    "record-c",
                    '{"family_id":"unknown-family"}',
                    "history-user-a",
                ),
            ],
        )
        # A genuinely legacy database predates the repair version stamp.
        await db.execute("PRAGMA user_version = 0")
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        rows = await (
            await db.execute("SELECT id, family_id FROM record_history ORDER BY id")
        ).fetchall()

    family_by_history = dict(rows)
    assert family_by_history["history-from-snapshot"] == "history-family-a"
    assert family_by_history["history-from-author"] == "history-family-b"
    assert family_by_history["history-conflicting-unknown"] is None


async def test_request_connections_are_configured_and_reused(initialized_db: str):
    """Request dependencies should reuse tuned connections instead of reopening SQLite."""
    await close_db_pool()
    set_db_path(initialized_db)

    first_lease = get_db()
    first = await anext(first_lease)
    pragma_values = {}
    for pragma in ("busy_timeout", "synchronous", "temp_store", "cache_size"):
        cursor = await first.execute(f"PRAGMA {pragma}")
        pragma_values[pragma] = (await cursor.fetchone())[0]
    await first_lease.aclose()

    second_lease = get_db()
    second = await anext(second_lease)
    try:
        assert second is first
        assert pragma_values == {
            "busy_timeout": settings.database_busy_timeout_ms,
            "synchronous": 1,
            "temp_store": 2,
            "cache_size": -settings.database_cache_kib,
        }
    finally:
        await second_lease.aclose()
        await close_db_pool()


async def test_request_connection_rolls_back_uncommitted_work(initialized_db: str):
    """A failed request must not leak its transaction into the next pooled lease."""
    await close_db_pool()
    set_db_path(initialized_db)

    first_lease = get_db()
    first = await anext(first_lease)
    await first.execute(
        "INSERT INTO families (id, name) VALUES ('uncommitted-family', 'Temporary')"
    )
    await first_lease.aclose()

    second_lease = get_db()
    second = await anext(second_lease)
    try:
        cursor = await second.execute("SELECT 1 FROM families WHERE id = 'uncommitted-family'")
        assert await cursor.fetchone() is None
    finally:
        await second_lease.aclose()
        await close_db_pool()


async def test_connection_pool_acquisition_has_a_deadline(
    initialized_db: str,
    monkeypatch,
):
    monkeypatch.setattr(settings, "database_pool_acquire_timeout_seconds", 0.01)
    pool = _ConnectionPool(1)
    held, generation = await pool.acquire(initialized_db)
    try:
        with pytest.raises(TimeoutError, match="pool is busy"):
            await pool.acquire(initialized_db)
    finally:
        await pool.release(held, generation)
        await pool.close()


async def test_exhausted_request_pool_returns_controlled_503(
    client,
    adult_a_headers,
    initialized_db: str,
    monkeypatch,
):
    monkeypatch.setattr(settings, "database_pool_acquire_timeout_seconds", 0.01)
    await close_db_pool()
    set_db_path(initialized_db)
    leases = [get_db() for _ in range(settings.database_pool_size)]
    try:
        for lease in leases:
            await anext(lease)
        response = await client.get("/api/tasks/", headers=adult_a_headers)
    finally:
        for lease in leases:
            await lease.aclose()
        await close_db_pool()

    assert response.status_code == 503
    assert response.headers["retry-after"] == "1"
    assert response.json() == {"detail": "HausKlar is busy. Please try again shortly."}


async def test_hot_queries_use_composite_indexes(db_path: str):
    """Keep list and incremental-sync queries off table scans as data grows."""
    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        cursor = await db.execute(
            "EXPLAIN QUERY PLAN SELECT * FROM tasks "
            "WHERE deleted_at IS NULL AND family_id = ? "
            "ORDER BY created_at DESC LIMIT 50",
            ("family",),
        )
        list_plan = " ".join(str(row[3]) for row in await cursor.fetchall())

        cursor = await db.execute(
            "EXPLAIN QUERY PLAN SELECT * FROM tasks WHERE updated_at > ? AND family_id = ?",
            ("2026-01-01T00:00:00Z", "family"),
        )
        sync_plan = " ".join(str(row[3]) for row in await cursor.fetchall())

    assert "idx_tasks_family_created_active" in list_plan
    assert "idx_sync_tasks" in sync_plan


async def test_nap_performance_index_is_added_after_column_migration(db_path: str):
    """Existing databases without sleep_type must initialize before its index is created."""
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DROP TABLE naps")
        await db.execute(
            """
            CREATE TABLE naps (
                id TEXT PRIMARY KEY,
                child_id TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            )
            """
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        columns = await (await db.execute("PRAGMA table_info(naps)")).fetchall()
        indexes = await (await db.execute("PRAGMA index_list(naps)")).fetchall()

    assert "sleep_type" in {row[1] for row in columns}
    assert "idx_naps_family_type_started_active" in {row[1] for row in indexes}


async def test_renewal_finance_index_is_added_after_legacy_column_migration(
    db_path: str,
):
    """A legacy renewals table must be altered before its new index is created."""
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DROP TABLE renewals")
        await db.execute(
            """
            CREATE TABLE renewals (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'other',
                due_date TEXT NOT NULL,
                recurrence_months INTEGER,
                cost_pence INTEGER,
                reminder_days_before INTEGER NOT NULL DEFAULT 21,
                source_document_id TEXT,
                notes TEXT,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            )
            """
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        columns = await (await db.execute("PRAGMA table_info(renewals)")).fetchall()
        indexes = await (await db.execute("PRAGMA index_list(renewals)")).fetchall()

    assert "finance_commitment_id" in {row[1] for row in columns}
    assert "idx_renewals_finance_commitment_active" in {row[1] for row in indexes}


async def test_finance_category_index_is_added_after_legacy_column_migration(
    db_path: str,
):
    """Existing Finance categories must gain system metadata before its index."""
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DROP TABLE finance_categories")
        await db.execute(
            """
            CREATE TABLE finance_categories (
                id TEXT PRIMARY KEY,
                space_id TEXT NOT NULL,
                name TEXT NOT NULL,
                spending_type TEXT NOT NULL DEFAULT 'FLEXIBLE',
                family_id TEXT NOT NULL,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            )
            """
        )
        await db.commit()

    await init_db(db_path)
    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        columns = await (
            await db.execute("PRAGMA table_info(finance_categories)")
        ).fetchall()
        indexes = await (
            await db.execute("PRAGMA index_list(finance_categories)")
        ).fetchall()

    assert {"system_key", "counts_as_spending"} <= {row[1] for row in columns}
    assert "idx_finance_categories_space_system_key_active" in {
        row[1] for row in indexes
    }


async def test_legacy_combined_finance_projection_choice_splits_safely(db_path: str):
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            CREATE TABLE finance_projection_preferences (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                show_money_and_deliveries INTEGER NOT NULL DEFAULT 1,
                family_id TEXT NOT NULL,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            )
            """
        )
        await db.execute(
            """
            INSERT INTO finance_projection_preferences
                (id, user_id, show_money_and_deliveries, family_id)
            VALUES ('legacy-projection-choice', 'adult', 0, 'family')
            """
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        row = await (
            await db.execute(
                """
                SELECT show_money, show_deliveries
                FROM finance_projection_preferences
                WHERE id = 'legacy-projection-choice'
                """
            )
        ).fetchone()
    assert row == (0, 0)


async def test_document_link_indexes_are_created_after_legacy_column_migration(db_path: str):
    """A production database predating document links must start without index errors."""
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            CREATE TABLE calendar_events (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, start_time TEXT NOT NULL,
                end_time TEXT, assigned_to TEXT, family_id TEXT, created_at TEXT,
                updated_at TEXT, created_by TEXT, client_id TEXT,
                client_timestamp TEXT, deleted_at TEXT
            )
            """
        )
        await db.execute(
            """
            CREATE TABLE tasks (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, assigned_to TEXT, due_date TEXT,
                completed_at TEXT, actionable_from TEXT, family_id TEXT, created_at TEXT,
                updated_at TEXT, created_by TEXT, client_id TEXT,
                client_timestamp TEXT, deleted_at TEXT
            )
            """
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        calendar_columns = await (await db.execute("PRAGMA table_info(calendar_events)")).fetchall()
        task_columns = await (await db.execute("PRAGMA table_info(tasks)")).fetchall()
        calendar_indexes = await (await db.execute("PRAGMA index_list(calendar_events)")).fetchall()
        task_indexes = await (await db.execute("PRAGMA index_list(tasks)")).fetchall()

    assert "source_document_id" in {row[1] for row in calendar_columns}
    assert "source_term_date_id" in {row[1] for row in calendar_columns}
    assert "term_boundary" in {row[1] for row in calendar_columns}
    assert "overridden_event_id" in {row[1] for row in calendar_columns}
    assert "source_document_id" in {row[1] for row in task_columns}
    assert "idx_calendar_events_source_document" in {row[1] for row in calendar_indexes}
    assert "idx_calendar_events_source_term_date" in {row[1] for row in calendar_indexes}
    assert "idx_calendar_events_term_boundary_active" in {row[1] for row in calendar_indexes}
    assert "idx_calendar_events_active_override" in {row[1] for row in calendar_indexes}
    assert "idx_tasks_source_document" in {row[1] for row in task_indexes}


async def test_startup_losslessly_backfills_legacy_calendar_document_links(db_path: str):
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute("INSERT INTO families (id, name) VALUES ('family', 'Family')")
        await db.execute(
            """
            INSERT INTO documents
                (id, title, original_filename, storage_key, media_type, file_size,
                 sha256, source, status, family_id, created_at, updated_at, created_by)
            VALUES
                ('document', 'Legacy ticket', 'ticket.pdf', 'legacy/ticket.pdf',
                 'application/pdf', 12, 'legacy-sha', 'file', 'filed', 'family',
                 '2026-08-01T08:00:00Z', '2026-08-01T08:00:00Z', 'adult')
            """
        )
        await db.execute(
            """
            INSERT INTO calendar_events
                (id, title, start_time, source_document_id, family_id,
                 created_at, updated_at, created_by)
            VALUES
                ('event', 'Legacy journey', '2026-08-20T08:00:00Z', 'document',
                 'family', '2026-08-01T08:00:00Z', '2026-08-01T08:00:00Z', 'adult')
            """
        )
        await db.commit()

    # Simulate an installed database that predates calendar_event_documents.
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DROP TABLE calendar_event_documents")
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        rows = await (
            await db.execute(
                """
                SELECT event_id, document_id, role, position, family_id,
                       created_at, created_by
                FROM calendar_event_documents
                """
            )
        ).fetchall()
    assert rows == [
        (
            "event",
            "document",
            "other",
            0,
            "family",
            "2026-08-01T08:00:00Z",
            "adult",
        )
    ]


async def test_startup_adds_practical_fields_to_legacy_routines(db_path: str):
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """CREATE TABLE routine_items (
                   id TEXT PRIMARY KEY, person_id TEXT NOT NULL, name TEXT NOT NULL,
                   color TEXT NOT NULL, days_of_week TEXT NOT NULL,
                   sort_order INTEGER DEFAULT 0, family_id TEXT,
                   created_at TEXT, updated_at TEXT, created_by TEXT,
                   client_id TEXT, client_timestamp TEXT, deleted_at TEXT
               )"""
        )
        await db.execute(
            """CREATE TABLE routine_term_overrides (
                   id TEXT PRIMARY KEY, person_id TEXT NOT NULL UNIQUE,
                   is_active INTEGER NOT NULL, family_id TEXT,
                   created_at TEXT, updated_at TEXT, created_by TEXT,
                   client_id TEXT, client_timestamp TEXT, deleted_at TEXT
               )"""
        )
        await db.execute(
            "INSERT INTO routine_items (id, person_id, name, color, days_of_week) "
            "VALUES ('routine', 'child', 'PE', '#FF6B6B', '[0]')"
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        item = await (
            await db.execute(
                "SELECT calendar_projection, term_only, time_of_day, prep_template_id "
                "FROM routine_items WHERE id = 'routine'"
            )
        ).fetchone()
        override_columns = {
            row[1] for row in await (await db.execute(
                "PRAGMA table_info(routine_term_overrides)"
            )).fetchall()
        }

    assert item == (1, 1, None, None)
    assert "expires_on" in override_columns


async def test_startup_backfills_calendar_boundaries_for_existing_terms(db_path: str):
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute("INSERT INTO families (id, name) VALUES ('term-family', 'Term Family')")
        await db.execute(
            """
            INSERT INTO children (id, name, date_of_birth, family_id)
            VALUES ('term-child', 'Existing Child', '2020-01-01', 'term-family')
            """
        )
        await db.execute(
            """
            INSERT INTO term_dates
                (id, person_id, label, start_date, end_date, family_id)
            VALUES
                ('existing-term', 'term-child', 'Legacy Term',
                 '2026-09-03', '2026-12-18', 'term-family')
            """
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        rows = await (
            await db.execute(
                """
                SELECT title, start_time, end_time, term_boundary, read_only
                FROM calendar_events
                WHERE source_term_date_id = ? AND deleted_at IS NULL
                ORDER BY start_time
                """,
                ("existing-term",),
            )
        ).fetchall()

    assert rows == [
        (
            "Existing Child — First day of Legacy Term",
            "2026-09-03",
            "2026-09-04",
            "first",
            1,
        ),
        (
            "Existing Child — Last day of Legacy Term",
            "2026-12-18",
            "2026-12-19",
            "last",
            1,
        ),
    ]


async def test_inbound_email_leases_are_added_to_legacy_database(db_path: str):
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DROP TABLE inbound_email_messages")
        await db.execute(
            """
            CREATE TABLE inbound_email_messages (
                id TEXT PRIMARY KEY,
                provider_message_id TEXT NOT NULL,
                internet_message_id TEXT,
                from_address TEXT NOT NULL,
                to_address TEXT NOT NULL,
                subject TEXT NOT NULL,
                status TEXT NOT NULL,
                document_ids TEXT,
                error TEXT,
                family_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT
            )
            """
        )
        await db.execute(
            "INSERT INTO inbound_email_messages ("
            "id, provider_message_id, from_address, to_address, subject, status"
            ") VALUES ('legacy', 'message', 'from@test', 'to@test', 'Legacy', 'processing')"
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        columns = await (await db.execute("PRAGMA table_info(inbound_email_messages)")).fetchall()
        legacy = await (
            await db.execute(
                "SELECT status, lease_token, lease_expires_at "
                "FROM inbound_email_messages WHERE id = 'legacy'"
            )
        ).fetchone()

    assert {"lease_token", "lease_expires_at"}.issubset({row[1] for row in columns})
    assert legacy == ("processing", None, None)


async def test_auth_session_columns_and_hashes_are_migrated_safely(db_path: str):
    await init_db(db_path)
    legacy_token = "legacy-refresh-token-secret"
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DROP TABLE refresh_tokens")
        await db.execute(
            """
            CREATE TABLE refresh_tokens (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                token TEXT NOT NULL UNIQUE,
                expires_at TEXT NOT NULL,
                revoked_at TEXT,
                created_at TEXT
            )
            """
        )
        await db.execute(
            "INSERT INTO refresh_tokens (id, user_id, token, expires_at, created_at) "
            "VALUES ('legacy-refresh', 'legacy-user', ?, '2099-01-01T00:00:00+00:00', '2026')",
            (legacy_token,),
        )
        await db.execute("ALTER TABLE users DROP COLUMN auth_version")
        # A genuinely legacy database predates the repair version stamp.
        await db.execute("PRAGMA user_version = 0")
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        user_columns = await (await db.execute("PRAGMA table_info(users)")).fetchall()
        refresh_columns = await (await db.execute("PRAGMA table_info(refresh_tokens)")).fetchall()
        migrated = await (
            await db.execute(
                "SELECT token, rotation_family_id, parent_token_id, replaced_by_id "
                "FROM refresh_tokens WHERE id = 'legacy-refresh'"
            )
        ).fetchone()

    assert "auth_version" in {row[1] for row in user_columns}
    assert {"rotation_family_id", "parent_token_id", "replaced_by_id"}.issubset(
        {row[1] for row in refresh_columns}
    )
    assert migrated == (hash_refresh_token(legacy_token), "legacy-refresh", None, None)


async def test_legacy_family_invite_gets_a_bounded_expiry(db_path: str):
    await init_db(db_path)
    updated_at = "2026-07-10T12:00:00+00:00"
    async with aiosqlite.connect(db_path) as db:
        await db.execute("ALTER TABLE families DROP COLUMN invite_expires_at")
        await db.execute(
            "INSERT INTO families (id, name, invite_code, updated_at) "
            "VALUES ('legacy-invite-family', 'Legacy', 'LEGACY12', ?)",
            (updated_at,),
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        migrated = await (
            await db.execute(
                "SELECT invite_code, invite_expires_at FROM families "
                "WHERE id = 'legacy-invite-family'"
            )
        ).fetchone()

    assert migrated == ("LEGACY12", "2026-07-11T12:00:00+00:00")

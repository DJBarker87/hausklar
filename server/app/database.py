import asyncio
import hashlib
import json
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import aiosqlite
from fastapi import HTTPException

from app.config import settings

_db_path: str = settings.database_path


def _restrict_database_file_permissions(path: str) -> None:
    """Keep the live SQLite database and sidecars owner-readable only."""
    if path == ":memory:" or path.startswith("file:"):
        return
    database_path = Path(path).expanduser().resolve()
    for candidate in (
        database_path,
        Path(f"{database_path}-wal"),
        Path(f"{database_path}-shm"),
    ):
        if candidate.is_file():
            candidate.chmod(0o600)


async def _configure_connection(db: aiosqlite.Connection) -> None:
    """Apply connection-local settings tuned for the NUC deployment."""
    db.row_factory = aiosqlite.Row
    await db.execute(f"PRAGMA busy_timeout={settings.database_busy_timeout_ms}")
    await db.execute("PRAGMA foreign_keys=OFF")
    await db.execute("PRAGMA synchronous=NORMAL")
    await db.execute("PRAGMA temp_store=MEMORY")
    await db.execute(f"PRAGMA cache_size=-{settings.database_cache_kib}")


async def open_db_connection(path: str | None = None) -> aiosqlite.Connection:
    """Open a configured standalone connection for startup tasks and schedulers."""
    db = await aiosqlite.connect(
        path or _db_path,
        timeout=settings.database_busy_timeout_ms / 1000,
    )
    try:
        await _configure_connection(db)
        _restrict_database_file_permissions(path or _db_path)
    except BaseException:
        await db.close()
        raise
    return db


class _ConnectionPool:
    """Small exclusive-lease pool for aiosqlite worker connections."""

    def __init__(self, max_size: int) -> None:
        self._max_size = max_size
        self._condition = asyncio.Condition()
        self._idle: list[aiosqlite.Connection] = []
        self._created = 0
        self._path: str | None = None
        self._generation = 0

    async def acquire(self, path: str) -> tuple[aiosqlite.Connection, int]:
        stale_connections: list[aiosqlite.Connection] = []
        deadline = (
            asyncio.get_running_loop().time() + settings.database_pool_acquire_timeout_seconds
        )

        while True:
            async with self._condition:
                if path != self._path:
                    stale_connections = self._idle
                    self._idle = []
                    self._created = 0
                    self._path = path
                    self._generation += 1
                    self._condition.notify_all()

                generation = self._generation
                if self._idle:
                    db = self._idle.pop()
                    should_create = False
                    break
                if self._created < self._max_size:
                    self._created += 1
                    should_create = True
                    break

                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    raise TimeoutError("Database connection pool is busy")
                try:
                    await asyncio.wait_for(self._condition.wait(), timeout=remaining)
                except TimeoutError as exc:
                    raise TimeoutError("Database connection pool is busy") from exc

        for stale in stale_connections:
            await stale.close()

        if not should_create:
            return db, generation

        try:
            db = await open_db_connection(path)
        except BaseException:
            async with self._condition:
                if generation == self._generation:
                    self._created -= 1
                    self._condition.notify()
            raise
        return db, generation

    async def release(self, db: aiosqlite.Connection, generation: int) -> None:
        try:
            if db.in_transaction:
                await db.rollback()
        except BaseException:
            await self._discard(db, generation)
            raise

        async with self._condition:
            if generation == self._generation:
                self._idle.append(db)
                self._condition.notify()
                return

        await db.close()

    async def _discard(self, db: aiosqlite.Connection, generation: int) -> None:
        try:
            await db.close()
        finally:
            async with self._condition:
                if generation == self._generation:
                    self._created -= 1
                    self._condition.notify()

    async def close(self) -> None:
        async with self._condition:
            connections = self._idle
            self._idle = []
            self._created = 0
            self._path = None
            self._generation += 1
            self._condition.notify_all()

        for db in connections:
            await db.close()


_pool = _ConnectionPool(settings.database_pool_size)


def set_db_path(path: str) -> None:
    """Override the database path (used for testing)."""
    global _db_path
    _db_path = path


def get_db_path() -> str:
    return _db_path


@asynccontextmanager
async def database_lease() -> AsyncIterator[aiosqlite.Connection]:
    """Lease a pooled connection for the smallest practical unit of work."""
    try:
        db, generation = await _pool.acquire(_db_path)
    except TimeoutError as exc:
        raise HTTPException(
            status_code=503,
            detail="HausKlar is busy. Please try again shortly.",
            headers={"Retry-After": "1"},
        ) from exc
    try:
        yield db
    finally:
        await _pool.release(db, generation)


async def get_db() -> AsyncIterator[aiosqlite.Connection]:
    """FastAPI dependency backed by the bounded connection pool."""
    async with database_lease() as db:
        yield db


@asynccontextmanager
async def standalone_db(path: str | None = None) -> AsyncIterator[aiosqlite.Connection]:
    """Yield a configured non-pooled connection and close it on exit."""
    db = await open_db_connection(path)
    try:
        yield db
    finally:
        if db.in_transaction:
            await db.rollback()
        await db.close()


async def close_db_pool() -> None:
    """Close idle pooled connections during application shutdown."""
    await _pool.close()


async def init_db(db_path: str | None = None) -> None:
    """Initialise the database by running schema.sql, then apply migrations."""
    path = db_path or _db_path
    schema_file = Path(__file__).parent / "db" / "schema.sql"
    schema_sql = schema_file.read_text()

    db = await open_db_connection(path)
    try:
        await db.execute("PRAGMA journal_mode=WAL")
        await db.executescript(schema_sql)
        await db.commit()

        # Migrations for existing databases
        await _run_migrations(db)
        await db.execute("PRAGMA optimize")
        _restrict_database_file_permissions(path)
    finally:
        await db.close()


async def documents_fts_available(db) -> bool:
    """True when the documents_fts full-text table exists on this database."""
    cursor = await db.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'documents_fts'"
    )
    return (await cursor.fetchone()) is not None


# Bump when adding a new one-time data repair below; databases at or above
# this version skip the repair blocks entirely on boot.
_ONE_TIME_REPAIR_VERSION = 1


async def _migrate_cycles_to_fitness(db: aiosqlite.Connection) -> None:
    """Copy legacy cycle rows once, preserving their identity and audit metadata."""
    from app.services.fitness.common import append_change

    async def family_for(row) -> str:
        if row["family_id"]:
            return row["family_id"]
        owner = await (
            await db.execute("SELECT family_id FROM users WHERE id = ?", (row["owner_user_id"],))
        ).fetchone()
        if owner is None or not owner["family_id"]:
            raise RuntimeError("Legacy cycle row has no resolvable family")
        return owner["family_id"]

    settings_rows = await (await db.execute("SELECT * FROM cycle_settings")).fetchall()
    for row in settings_rows:
        family_id = await family_for(row)
        inserted = await db.execute(
            "INSERT OR IGNORE INTO health_cycle_settings "
            "(id, owner_user_id, cycle_length_days, show_period_starts, "
            "show_predicted_period, show_estimated_ovulation, "
            "share_period_starts_with_adults, share_predicted_period_with_adults, "
            "share_estimated_ovulation_with_adults, revision, family_id, created_at, "
            "updated_at, created_by, client_id, client_timestamp, deleted_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)",
            (
                row["id"],
                row["owner_user_id"],
                row["cycle_length_days"],
                row["show_period_starts"],
                row["show_predicted_period"],
                row["show_estimated_ovulation"],
                int(bool(row["share_with_adults"]) and bool(row["show_period_starts"])),
                int(bool(row["share_with_adults"]) and bool(row["show_predicted_period"])),
                int(bool(row["share_with_adults"]) and bool(row["show_estimated_ovulation"])),
                family_id,
                row["created_at"],
                row["updated_at"],
                row["created_by"],
                row["client_id"],
                row["client_timestamp"],
                row["deleted_at"],
            ),
        )
        if inserted.rowcount == 1:
            await append_change(
                db,
                entity_type="cycle_settings",
                entity_id=row["id"],
                revision=1,
                operation="delete" if row["deleted_at"] else "upsert",
                user={"id": row["owner_user_id"], "family_id": family_id},
                changed_at=row["updated_at"],
            )

    period_rows = await (await db.execute("SELECT * FROM cycle_period_starts")).fetchall()
    for row in period_rows:
        family_id = await family_for(row)
        inserted = await db.execute(
            "INSERT OR IGNORE INTO health_cycle_period_starts "
            "(id, owner_user_id, started_on, revision, family_id, created_at, "
            "updated_at, created_by, client_id, client_timestamp, deleted_at) "
            "VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)",
            (
                row["id"],
                row["owner_user_id"],
                row["started_on"],
                family_id,
                row["created_at"],
                row["updated_at"],
                row["created_by"],
                row["client_id"],
                row["client_timestamp"],
                row["deleted_at"],
            ),
        )
        if inserted.rowcount == 1:
            await append_change(
                db,
                entity_type="cycle_period_start",
                entity_id=row["id"],
                revision=1,
                operation="delete" if row["deleted_at"] else "upsert",
                user={"id": row["owner_user_id"], "family_id": family_id},
                changed_at=row["updated_at"],
            )


async def _migrate_handoff_pickups_without_adults(
    db: aiosqlite.Connection,
) -> None:
    """Make pickup ownership nullable and remove active adult assignments."""
    from app.services.record_history import save_history

    async def owner_is_required(table: str) -> bool:
        columns = await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
        return any(row[1] == "owner_user_id" and bool(row[3]) for row in columns)

    rebuild = await owner_is_required("term_time_handoffs") or await owner_is_required(
        "term_time_handoff_overrides"
    )
    pickup_rows = await (
        await db.execute(
            "SELECT id, family_id FROM term_time_handoffs "
            "WHERE kind = 'pickup' AND owner_user_id IS NOT NULL "
            "AND deleted_at IS NULL"
        )
    ).fetchall()
    pickup_override_rows = await (
        await db.execute(
            "SELECT override.id, override.family_id "
            "FROM term_time_handoff_overrides AS override "
            "JOIN term_time_handoffs AS handoff ON handoff.id = override.handoff_id "
            "WHERE handoff.kind = 'pickup' AND override.owner_user_id IS NOT NULL "
            "AND override.deleted_at IS NULL"
        )
    ).fetchall()
    if not rebuild and not pickup_rows and not pickup_override_rows:
        return

    await db.commit()
    await db.execute("BEGIN IMMEDIATE")
    try:
        actor = "handoff-owner-migration"
        for row in pickup_rows:
            await save_history(
                db,
                "term_time_handoffs",
                row["id"],
                actor,
                family_id=row["family_id"],
            )
        for row in pickup_override_rows:
            await save_history(
                db,
                "term_time_handoff_overrides",
                row["id"],
                actor,
                family_id=row["family_id"],
            )

        if rebuild:
            for index in (
                "idx_term_time_handoff_weekday_active",
                "idx_term_time_handoff_term_person",
                "idx_term_time_handoff_override_active",
                "idx_term_time_handoff_override_date",
            ):
                await db.execute(f"DROP INDEX IF EXISTS {index}")
            await db.execute(
                "ALTER TABLE term_time_handoff_overrides "
                "RENAME TO term_time_handoff_overrides_with_owner"
            )
            await db.execute(
                "ALTER TABLE term_time_handoffs "
                "RENAME TO term_time_handoffs_with_owner"
            )
            await db.execute(
                """CREATE TABLE term_time_handoffs (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL CHECK (kind IN ('pickup', 'work_departure')),
                    weekday INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),
                    time_of_day TEXT NOT NULL,
                    term_person_id TEXT NOT NULL,
                    owner_user_id TEXT,
                    family_id TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                    created_by TEXT,
                    updated_by TEXT,
                    client_id TEXT,
                    client_timestamp TEXT,
                    deleted_at TEXT
                )"""
            )
            await db.execute(
                """CREATE TABLE term_time_handoff_overrides (
                    id TEXT PRIMARY KEY,
                    handoff_id TEXT NOT NULL,
                    occurrence_date TEXT NOT NULL,
                    time_of_day TEXT NOT NULL,
                    owner_user_id TEXT,
                    is_cancelled INTEGER NOT NULL DEFAULT 0
                        CHECK (is_cancelled IN (0, 1)),
                    family_id TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                    created_by TEXT,
                    updated_by TEXT,
                    client_id TEXT,
                    client_timestamp TEXT,
                    deleted_at TEXT
                )"""
            )
            await db.execute(
                """INSERT INTO term_time_handoffs
                    (id, kind, weekday, time_of_day, term_person_id,
                     owner_user_id, family_id, created_at, updated_at,
                     created_by, updated_by, client_id, client_timestamp, deleted_at)
                    SELECT id, kind, weekday, time_of_day, term_person_id,
                           CASE WHEN kind = 'pickup' THEN NULL ELSE owner_user_id END,
                           family_id, created_at, updated_at, created_by, updated_by,
                           client_id, client_timestamp, deleted_at
                    FROM term_time_handoffs_with_owner"""
            )
            await db.execute(
                """INSERT INTO term_time_handoff_overrides
                    (id, handoff_id, occurrence_date, time_of_day, owner_user_id,
                     is_cancelled, family_id, created_at, updated_at, created_by,
                     updated_by, client_id, client_timestamp, deleted_at)
                    SELECT override.id, override.handoff_id, override.occurrence_date,
                           override.time_of_day,
                           CASE WHEN handoff.kind = 'pickup'
                                THEN NULL ELSE override.owner_user_id END,
                           override.is_cancelled, override.family_id,
                           override.created_at, override.updated_at,
                           override.created_by, override.updated_by,
                           override.client_id, override.client_timestamp,
                           override.deleted_at
                    FROM term_time_handoff_overrides_with_owner AS override
                    LEFT JOIN term_time_handoffs_with_owner AS handoff
                      ON handoff.id = override.handoff_id"""
            )
            await db.execute("DROP TABLE term_time_handoff_overrides_with_owner")
            await db.execute("DROP TABLE term_time_handoffs_with_owner")
        else:
            await db.execute(
                "UPDATE term_time_handoffs SET owner_user_id = NULL "
                "WHERE kind = 'pickup' AND owner_user_id IS NOT NULL "
                "AND deleted_at IS NULL"
            )
            await db.execute(
                "UPDATE term_time_handoff_overrides SET owner_user_id = NULL "
                "WHERE owner_user_id IS NOT NULL AND deleted_at IS NULL "
                "AND handoff_id IN (SELECT id FROM term_time_handoffs "
                "WHERE kind = 'pickup')"
            )

        await db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_term_time_handoff_weekday_active "
            "ON term_time_handoffs(family_id, kind, weekday, term_person_id) "
            "WHERE deleted_at IS NULL"
        )
        await db.execute(
            "CREATE INDEX IF NOT EXISTS idx_term_time_handoff_term_person "
            "ON term_time_handoffs(family_id, term_person_id) WHERE deleted_at IS NULL"
        )
        await db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_term_time_handoff_override_active "
            "ON term_time_handoff_overrides(family_id, handoff_id, occurrence_date) "
            "WHERE deleted_at IS NULL"
        )
        await db.execute(
            "CREATE INDEX IF NOT EXISTS idx_term_time_handoff_override_date "
            "ON term_time_handoff_overrides(family_id, occurrence_date) "
            "WHERE deleted_at IS NULL"
        )
        await db.commit()
    except BaseException:
        await db.rollback()
        raise


async def _run_migrations(db: aiosqlite.Connection) -> None:
    """Apply incremental migrations for columns added after initial schema."""
    cursor = await db.execute("PRAGMA user_version")
    run_one_time_repairs = (await cursor.fetchone())[0] < _ONE_TIME_REPAIR_VERSION

    cursor = await db.execute("PRAGMA table_info(families)")
    family_columns = {row[1] for row in await cursor.fetchall()}
    if "invite_expires_at" not in family_columns:
        await db.execute("ALTER TABLE families ADD COLUMN invite_expires_at TEXT")
    cursor = await db.execute(
        "SELECT id, updated_at FROM families "
        "WHERE invite_code IS NOT NULL AND invite_expires_at IS NULL"
    )
    for family_id, updated_at in await cursor.fetchall():
        try:
            updated = datetime.fromisoformat(str(updated_at).replace("Z", "+00:00"))
            if updated.tzinfo is None:
                updated = updated.replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            updated = datetime.now(timezone.utc) - timedelta(days=1)
        await db.execute(
            "UPDATE families SET invite_expires_at = ? WHERE id = ?",
            ((updated + timedelta(hours=24)).isoformat(), family_id),
        )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(users)")
    user_columns = {row[1] for row in await cursor.fetchall()}
    for column in ("ai_consent_version", "ai_consent_at", "ai_consent_revoked_at"):
        if column not in user_columns:
            await db.execute(f"ALTER TABLE users ADD COLUMN {column} TEXT")
    if "finance_enabled" in user_columns:
        await db.execute("ALTER TABLE users DROP COLUMN finance_enabled")
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_commitments)")
    finance_commitment_columns = {row[1] for row in await cursor.fetchall()}
    finance_commitment_projection_migrations = {
        "payment_handling": "TEXT NOT NULL DEFAULT 'UNSPECIFIED'",
        "show_in_calendar": "INTEGER NOT NULL DEFAULT 0",
        "show_in_tasks": "INTEGER NOT NULL DEFAULT 0",
        "responsible_user_id": "TEXT",
    }
    for column, declaration in finance_commitment_projection_migrations.items():
        if column not in finance_commitment_columns:
            await db.execute(f"ALTER TABLE finance_commitments ADD COLUMN {column} {declaration}")
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(renewals)")
    renewal_columns = {row[1] for row in await cursor.fetchall()}
    renewal_migrations = {
        "finance_commitment_id": "TEXT",
        "provider": "TEXT",
        "reference": "TEXT",
        "action_url": "TEXT",
        "comparison_url": "TEXT",
        "contact_url": "TEXT",
        "responsible_user_id": "TEXT",
        "reminders_enabled": "INTEGER NOT NULL DEFAULT 1",
        "escalate_after_days": "INTEGER DEFAULT 3",
        "show_in_calendar": "INTEGER NOT NULL DEFAULT 0",
        "show_in_tasks": "INTEGER NOT NULL DEFAULT 0",
        "task_completed_at": "TEXT",
        "task_completed_by": "TEXT",
    }
    for column, declaration in renewal_migrations.items():
        if column not in renewal_columns:
            await db.execute(f"ALTER TABLE renewals ADD COLUMN {column} {declaration}")
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_renewals_finance_commitment_active "
        "ON renewals(finance_commitment_id) "
        "WHERE finance_commitment_id IS NOT NULL AND deleted_at IS NULL"
    )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_projection_preferences)")
    projection_preference_columns = {row[1] for row in await cursor.fetchall()}
    added_projection_columns = False
    if "show_money" not in projection_preference_columns:
        await db.execute(
            "ALTER TABLE finance_projection_preferences "
            "ADD COLUMN show_money INTEGER NOT NULL DEFAULT 1"
        )
        added_projection_columns = True
    if "show_deliveries" not in projection_preference_columns:
        await db.execute(
            "ALTER TABLE finance_projection_preferences "
            "ADD COLUMN show_deliveries INTEGER NOT NULL DEFAULT 1"
        )
        added_projection_columns = True
    if added_projection_columns and "show_money_and_deliveries" in projection_preference_columns:
        await db.execute(
            "UPDATE finance_projection_preferences "
            "SET show_money = show_money_and_deliveries, "
            "show_deliveries = show_money_and_deliveries"
        )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_accounts)")
    finance_account_columns = {row[1] for row in await cursor.fetchall()}
    if "purpose" not in finance_account_columns:
        await db.execute(
            """
            ALTER TABLE finance_accounts
            ADD COLUMN purpose TEXT NOT NULL DEFAULT 'OPERATING_CURRENT'
                CHECK (purpose IN (
                    'OPERATING_CURRENT', 'SAVINGS', 'CREDIT_CARD', 'GOAL',
                    'IGNORED', 'INVESTMENT_LIKE'
                ))
            """
        )
        await db.execute(
            """
            UPDATE finance_accounts
            SET purpose = CASE account_type
                WHEN 'SAVINGS' THEN 'SAVINGS'
                WHEN 'CREDIT_CARD' THEN 'CREDIT_CARD'
                WHEN 'INVESTMENT' THEN 'INVESTMENT_LIKE'
                WHEN 'CRYPTO' THEN 'INVESTMENT_LIKE'
                ELSE 'OPERATING_CURRENT'
            END
            """
        )
        await db.commit()
    finance_account_migrations = {
        "card_paid_in_full": "INTEGER NOT NULL DEFAULT 0",
        "card_settlement_account_id": "TEXT",
        "card_statement_close_day": "INTEGER",
        "card_repayment_day": "INTEGER",
        "history_synced_from_date": "TEXT",
        "provider_presence_status": "TEXT NOT NULL DEFAULT 'ACTIVE'",
        "provider_omitted_at": "TEXT",
        "provider_previous_settings_json": "TEXT",
        "provider_resource_type": "TEXT NOT NULL DEFAULT 'ACCOUNT'",
    }
    for column, declaration in finance_account_migrations.items():
        if column not in finance_account_columns:
            await db.execute(f"ALTER TABLE finance_accounts ADD COLUMN {column} {declaration}")
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_connections)")
    finance_connection_columns = {row[1] for row in await cursor.fetchall()}
    finance_connection_sync_migrations = {
        "callback_state_hash": "TEXT",
        "sync_lease_token": "TEXT",
        "sync_lease_expires_at": "TEXT",
        "next_retry_at": "TEXT",
        "consecutive_sync_failures": "INTEGER NOT NULL DEFAULT 0",
        "operation_generation": "INTEGER NOT NULL DEFAULT 0",
    }
    for column, declaration in finance_connection_sync_migrations.items():
        if column not in finance_connection_columns:
            await db.execute(f"ALTER TABLE finance_connections ADD COLUMN {column} {declaration}")
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_connections_callback_state "
        "ON finance_connections(callback_state_hash) "
        "WHERE callback_state_hash IS NOT NULL AND deleted_at IS NULL"
    )
    await db.commit()

    # Bank categories are reduced to bounded, provider-neutral metadata before
    # entering the immutable source ledger. Existing rows remain untouched;
    # their canonical transactions can still be conservatively classified from
    # the stored merchant description.
    cursor = await db.execute("PRAGMA table_info(finance_source_transactions)")
    finance_source_transaction_columns = {row[1] for row in await cursor.fetchall()}
    for column, declaration in {
        "merchant_category_code": "TEXT",
        "bank_code": "TEXT",
        "bank_sub_code": "TEXT",
    }.items():
        if column not in finance_source_transaction_columns:
            await db.execute(
                f"ALTER TABLE finance_source_transactions ADD COLUMN {column} {declaration}"
            )

    cursor = await db.execute("PRAGMA table_info(finance_categories)")
    finance_category_columns = {row[1] for row in await cursor.fetchall()}
    if "system_key" not in finance_category_columns:
        await db.execute("ALTER TABLE finance_categories ADD COLUMN system_key TEXT")
    if "counts_as_spending" not in finance_category_columns:
        await db.execute(
            "ALTER TABLE finance_categories ADD COLUMN counts_as_spending "
            "INTEGER NOT NULL DEFAULT 1 CHECK (counts_as_spending IN (0, 1))"
        )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS "
        "idx_finance_categories_space_system_key_active "
        "ON finance_categories(space_id, system_key) "
        "WHERE system_key IS NOT NULL AND deleted_at IS NULL"
    )
    from app.services.finance.categorisation import backfill_uncategorised_transactions

    await backfill_uncategorised_transactions(db)
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_purchase_sources)")
    finance_purchase_source_columns = {row[1] for row in await cursor.fetchall()}
    finance_email_source_migrations = {
        "email_alias_id": "TEXT",
        "email_enrollment_id": "TEXT",
        "provider_message_id": "TEXT",
        "internet_message_id": "TEXT",
        "visible_sender": "TEXT",
        "email_subject": "TEXT",
        "authentication_json": "TEXT",
    }
    for column, declaration in finance_email_source_migrations.items():
        if column not in finance_purchase_source_columns:
            await db.execute(
                f"ALTER TABLE finance_purchase_sources ADD COLUMN {column} {declaration}"
            )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_purchase_lines)")
    finance_purchase_line_columns = {row[1] for row in await cursor.fetchall()}
    if "shipment_reference" not in finance_purchase_line_columns:
        await db.execute("ALTER TABLE finance_purchase_lines ADD COLUMN shipment_reference TEXT")
    await db.commit()

    # Capture confirmation receipts were added after the initial review-card
    # table. Existing installs need the same nullable receipt fields as fresh
    # databases so an exact retry remains safe after the draft payload is cleared.
    cursor = await db.execute("PRAGMA table_info(finance_capture_drafts)")
    finance_capture_draft_columns = {row[1] for row in await cursor.fetchall()}
    finance_capture_receipt_migrations = {
        "confirmed_action_kind": "TEXT",
        "confirmed_action_id": "TEXT",
        "confirmation_digest": "TEXT",
        "confirmed_result_json": "TEXT",
        "confirmed_at": "TEXT",
    }
    for column, declaration in finance_capture_receipt_migrations.items():
        if column not in finance_capture_draft_columns:
            await db.execute(
                f"ALTER TABLE finance_capture_drafts ADD COLUMN {column} {declaration}"
            )
    await db.commit()

    # Sharing copy provenance gained accounting semantics after the table was
    # introduced. Keep repeated startup safe for any database initialised by an
    # earlier Finance build.
    cursor = await db.execute("PRAGMA table_info(finance_share_copy_links)")
    finance_share_copy_columns = {row[1] for row in await cursor.fetchall()}
    if "accounting_treatment" not in finance_share_copy_columns:
        await db.execute(
            """
            ALTER TABLE finance_share_copy_links
            ADD COLUMN accounting_treatment TEXT NOT NULL DEFAULT 'CASEY'
                CHECK (accounting_treatment IN (
                    'CASEY', 'NEUTRAL_TRANSFER', 'REFUND', 'REIMBURSEMENT'
                ))
            """
        )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_recurring_series)")
    finance_recurring_columns = {row[1] for row in await cursor.fetchall()}
    finance_recurring_migrations = {
        "detection_key": "TEXT",
        "working_day_adjustment": "TEXT",
    }
    for column, declaration in finance_recurring_migrations.items():
        if column not in finance_recurring_columns:
            await db.execute(
                f"ALTER TABLE finance_recurring_series ADD COLUMN {column} {declaration}"
            )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_recurring_detection_key_active "
        "ON finance_recurring_series(space_id, detection_key) "
        "WHERE detection_key IS NOT NULL AND deleted_at IS NULL"
    )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_material_questions)")
    finance_question_columns = {row[1] for row in await cursor.fetchall()}
    finance_question_migrations = {
        "action_kind": "TEXT",
        "action_target_id": "TEXT",
    }
    for column, declaration in finance_question_migrations.items():
        if column not in finance_question_columns:
            await db.execute(
                f"ALTER TABLE finance_material_questions ADD COLUMN {column} {declaration}"
            )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_plans)")
    finance_plan_columns = {row[1] for row in await cursor.fetchall()}
    if "currency" not in finance_plan_columns:
        await db.execute(
            "ALTER TABLE finance_plans ADD COLUMN currency TEXT NOT NULL DEFAULT 'GBP'"
        )
        plan_rows = await (
            await db.execute("SELECT id, family_id, input_snapshot_json FROM finance_plans")
        ).fetchall()
        for plan_row in plan_rows:
            currency = None
            try:
                value = json.loads(plan_row["input_snapshot_json"]).get("currency")
                if isinstance(value, str) and len(value.strip()) == 3:
                    currency = value.strip().upper()
            except (TypeError, json.JSONDecodeError):
                pass
            if currency is None:
                default_row = await (
                    await db.execute(
                        "SELECT default_currency FROM finance_settings "
                        "WHERE family_id = ? AND deleted_at IS NULL LIMIT 1",
                        (plan_row["family_id"],),
                    )
                ).fetchone()
                currency = default_row[0] if default_row else "GBP"
            await db.execute(
                "UPDATE finance_plans SET currency = ? WHERE id = ?",
                (currency, plan_row["id"]),
            )
    finance_plan_migrations = {
        "effort_level": "TEXT NOT NULL DEFAULT 'MEDIUM'",
        "answer_basis": "TEXT NOT NULL DEFAULT 'ESTIMATED'",
        "confidence_bps": "INTEGER NOT NULL DEFAULT 5000",
        "forecast_coverage_end": "TEXT",
        "required_monthly_minor": "INTEGER NOT NULL DEFAULT 0",
        "planned_monthly_saving_minor": "INTEGER NOT NULL DEFAULT 0",
        "projected_amount_at_target_minor": "INTEGER NOT NULL DEFAULT 0",
        "goal_shortfall_at_target_minor": "INTEGER NOT NULL DEFAULT 0",
        "assumptions_json": "TEXT NOT NULL DEFAULT '[]'",
    }
    for column, declaration in finance_plan_migrations.items():
        if column not in finance_plan_columns:
            await db.execute(f"ALTER TABLE finance_plans ADD COLUMN {column} {declaration}")
    await db.execute(
        "UPDATE finance_plans SET effort_level = CASE strategy "
        "WHEN 'MINIMAL_DISRUPTION' THEN 'EASY' "
        "WHEN 'TARGET_DATE' THEN 'MEDIUM' "
        "WHEN 'AGGRESSIVE' THEN 'HARD' ELSE effort_level END"
    )
    await db.execute(
        "UPDATE finance_plans SET planned_monthly_saving_minor = monthly_change_minor "
        "WHERE planned_monthly_saving_minor = 0 AND monthly_change_minor > 0"
    )
    # The first coaching release allowed one active plan per space. Savings goals
    # now coexist, while replacement remains unique within a single goal. Both
    # statements are deliberately idempotent for repeated container starts.
    await db.execute("DROP INDEX IF EXISTS idx_finance_plan_one_active")
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_plan_one_active_per_goal "
        "ON finance_plans(space_id, goal_id) "
        "WHERE status = 'ACTIVE' AND deleted_at IS NULL"
    )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_report_preferences)")
    finance_report_preference_columns = {row[1] for row in await cursor.fetchall()}
    finance_report_preference_migrations = {
        "notification_channel": "TEXT NOT NULL DEFAULT 'IN_APP'",
        "notification_mode": "TEXT NOT NULL DEFAULT 'ACTION_ONLY'",
        "show_more_by_default": "INTEGER NOT NULL DEFAULT 0",
        "quiet_hours_start": "TEXT",
        "quiet_hours_end": "TEXT",
        "underfunded_commitment_threshold_minor": "INTEGER NOT NULL DEFAULT 5000",
        "goal_movement_threshold_minor": "INTEGER NOT NULL DEFAULT 5000",
        "missed_payday_alerts": "INTEGER NOT NULL DEFAULT 1",
        "selected_return_deadline_alerts": "INTEGER NOT NULL DEFAULT 1",
        "tone": "TEXT NOT NULL DEFAULT 'BALANCED'",
        "default_spend_account_id": "TEXT",
        "extra_cash_buffer_minor": "INTEGER NOT NULL DEFAULT 0",
        "writing_mode": "TEXT NOT NULL DEFAULT 'LOCAL'",
        "allow_dated_estimates": "INTEGER NOT NULL DEFAULT 1",
        "ordinary_purchase_alerts": "INTEGER NOT NULL DEFAULT 0",
        "group_related_alerts": "INTEGER NOT NULL DEFAULT 1",
    }
    for column, declaration in finance_report_preference_migrations.items():
        if column not in finance_report_preference_columns:
            await db.execute(
                f"ALTER TABLE finance_report_preferences ADD COLUMN {column} {declaration}"
            )
    await db.execute(
        "UPDATE finance_report_preferences SET ordinary_purchase_alerts = 0, "
        "group_related_alerts = 1"
    )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_coaching_reports)")
    finance_coaching_report_columns = {row[1] for row in await cursor.fetchall()}
    if "source_watermark" not in finance_coaching_report_columns:
        await db.execute("ALTER TABLE finance_coaching_reports ADD COLUMN source_watermark TEXT")
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(finance_payday_actions)")
    finance_payday_action_columns = {row[1] for row in await cursor.fetchall()}
    finance_payday_action_migrations = {
        "answer_mode": "TEXT NOT NULL DEFAULT 'CURRENT_EXACT'",
        "data_through_at": "TEXT",
    }
    for column, declaration in finance_payday_action_migrations.items():
        if column not in finance_payday_action_columns:
            await db.execute(
                f"ALTER TABLE finance_payday_actions ADD COLUMN {column} {declaration}"
            )
    await db.commit()

    # Packages 42-43 were developed against local Finance databases in stages.
    # Preserve those databases when the final reviewed-source and confidence
    # columns are introduced; new installs already receive them from schema.sql.
    cursor = await db.execute("PRAGMA table_info(finance_retailer_research_results)")
    retailer_result_columns = {row[1] for row in await cursor.fetchall()}
    if "source_label" not in retailer_result_columns:
        await db.execute(
            "ALTER TABLE finance_retailer_research_results "
            "ADD COLUMN source_label TEXT NOT NULL DEFAULT "
            "'Reviewed retailer result (legacy source label unavailable)'"
        )
    cursor = await db.execute("PRAGMA table_info(finance_product_comparisons)")
    product_comparison_columns = {row[1] for row in await cursor.fetchall()}
    if "currency" not in product_comparison_columns:
        await db.execute(
            "ALTER TABLE finance_product_comparisons "
            "ADD COLUMN currency TEXT NOT NULL DEFAULT 'GBP'"
        )
        await db.execute(
            """
            UPDATE finance_product_comparisons
            SET currency = COALESCE(
                (SELECT result.currency FROM finance_retailer_research_results result
                 WHERE result.id = finance_product_comparisons.research_result_id),
                currency
            )
            """
        )
    if "confidence_bps" not in product_comparison_columns:
        await db.execute(
            "ALTER TABLE finance_product_comparisons "
            "ADD COLUMN confidence_bps INTEGER NOT NULL DEFAULT 0"
        )

    cursor = await db.execute("PRAGMA table_info(finance_retailer_research_requests)")
    retailer_request_columns = {row[1] for row in await cursor.fetchall()}
    if "normalized_item_id" not in retailer_request_columns:
        # Staged requests created before item binding cannot safely be matched
        # to an item after the fact. Preserve the audit row but cancel it.
        await db.execute(
            "ALTER TABLE finance_retailer_research_requests ADD COLUMN normalized_item_id TEXT"
        )
        await db.execute(
            "UPDATE finance_retailer_research_requests "
            "SET status = 'CANCELLED' WHERE normalized_item_id IS NULL"
        )

    cursor = await db.execute("PRAGMA table_info(finance_asset_import_previews)")
    asset_preview_columns = {row[1] for row in await cursor.fetchall()}
    asset_preview_migrations = {
        "account_wrapper": "TEXT NOT NULL DEFAULT 'OTHER'",
        "cash_value_minor": "INTEGER NOT NULL DEFAULT 0",
        "activities_json": "TEXT NOT NULL DEFAULT '[]'",
    }
    for column, declaration in asset_preview_migrations.items():
        if column not in asset_preview_columns:
            await db.execute(
                f"ALTER TABLE finance_asset_import_previews ADD COLUMN {column} {declaration}"
            )

    # SQLite cannot widen a CHECK constraint in place. Rebuild this small root
    # table once so existing installations can store the broker-independent
    # securities portfolio alongside HL reports and public crypto addresses.
    source_schema = await (
        await db.execute(
            "SELECT sql FROM sqlite_master "
            "WHERE type = 'table' AND name = 'finance_asset_sources'"
        )
    ).fetchone()
    if source_schema is not None and "MANUAL_PORTFOLIO" not in (source_schema[0] or ""):
        await db.execute("DROP TABLE IF EXISTS finance_asset_sources_portfolio_migration")
        await db.execute(
            """
            CREATE TABLE finance_asset_sources_portfolio_migration (
                id TEXT PRIMARY KEY,
                space_id TEXT NOT NULL,
                source_kind TEXT NOT NULL CHECK (source_kind IN (
                    'HL_REPORT', 'MANUAL_PORTFOLIO',
                    'SOLANA_PUBLIC', 'HYPERLIQUID_PUBLIC'
                )),
                label TEXT NOT NULL,
                public_address TEXT,
                status TEXT NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'PAUSED')),
                family_id TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT
                    (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT
                    (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT,
                CHECK (
                    (source_kind IN ('HL_REPORT', 'MANUAL_PORTFOLIO')
                        AND public_address IS NULL)
                    OR (source_kind IN ('SOLANA_PUBLIC', 'HYPERLIQUID_PUBLIC')
                        AND public_address IS NOT NULL)
                )
            )
            """
        )
        await db.execute(
            """
            INSERT INTO finance_asset_sources_portfolio_migration
                (id, space_id, source_kind, label, public_address, status,
                 family_id, created_at, updated_at, created_by, client_id,
                 client_timestamp, deleted_at)
            SELECT id, space_id, source_kind, label, public_address, status,
                   family_id, created_at, updated_at, created_by, client_id,
                   client_timestamp, deleted_at
            FROM finance_asset_sources
            """
        )
        await db.execute("DROP TABLE finance_asset_sources")
        await db.execute(
            "ALTER TABLE finance_asset_sources_portfolio_migration "
            "RENAME TO finance_asset_sources"
        )
        await db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_asset_public_address "
            "ON finance_asset_sources(space_id, source_kind, public_address) "
            "WHERE public_address IS NOT NULL AND deleted_at IS NULL"
        )
        await db.execute(
            "CREATE INDEX IF NOT EXISTS idx_finance_asset_sources_space "
            "ON finance_asset_sources(space_id, status, label) WHERE deleted_at IS NULL"
        )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_manual_portfolio_space "
        "ON finance_asset_sources(space_id) "
        "WHERE source_kind = 'MANUAL_PORTFOLIO' AND deleted_at IS NULL"
    )

    cursor = await db.execute("PRAGMA table_info(finance_positions)")
    position_columns = {row[1] for row in await cursor.fetchall()}
    position_migrations = {
        "include_in_net_worth": "INTEGER NOT NULL DEFAULT 1",
        "instrument_id_kind": "TEXT",
        "instrument_id": "TEXT",
        "quote_symbol": "TEXT",
        "quote_currency": "TEXT",
        "cost_basis_minor": (
            "INTEGER CHECK (cost_basis_minor IS NULL OR cost_basis_minor >= 0)"
        ),
        "cost_basis_currency": (
            "TEXT CHECK (cost_basis_currency IS NULL OR "
            "(length(cost_basis_currency) = 3 "
            "AND cost_basis_currency = upper(cost_basis_currency)))"
        ),
    }
    for column, declaration in position_migrations.items():
        if column not in position_columns:
            await db.execute(f"ALTER TABLE finance_positions ADD COLUMN {column} {declaration}")
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(calendar_events)")
    calendar_columns = {row[1] for row in await cursor.fetchall()}
    if "affected_member_ids" not in calendar_columns:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN affected_member_ids TEXT")
        await db.commit()

    cursor = await db.execute("PRAGMA table_info(reminder_preferences)")
    reminder_columns = {row[1] for row in await cursor.fetchall()}
    if "evening_summary_enabled" not in reminder_columns:
        await db.execute(
            "ALTER TABLE reminder_preferences ADD COLUMN evening_summary_enabled INTEGER NOT NULL DEFAULT 1"
        )
    if "evening_summary_time" not in reminder_columns:
        await db.execute(
            "ALTER TABLE reminder_preferences ADD COLUMN evening_summary_time TEXT NOT NULL DEFAULT '19:00'"
        )
    await db.commit()

    # Add medicine_name column to medicine_doses (for ad-hoc "other" medicines)
    cursor = await db.execute("PRAGMA table_info(medicine_doses)")
    columns = {row[1] for row in await cursor.fetchall()}
    if "medicine_name" not in columns:
        await db.execute("ALTER TABLE medicine_doses ADD COLUMN medicine_name TEXT")
        await db.commit()
    if "safety_warnings_json" not in columns:
        await db.execute("ALTER TABLE medicine_doses ADD COLUMN safety_warnings_json TEXT")
        await db.commit()

    # Create task_assignments table (idempotent — schema.sql handles CREATE IF NOT EXISTS)
    # Backfill from existing tasks.assigned_to → junction rows
    cursor = await db.execute(
        """
        SELECT t.id, t.assigned_to, t.created_by,
               CASE WHEN u.id IS NOT NULL THEN 'user'
                    WHEN c.id IS NOT NULL THEN 'child'
                    ELSE 'user' END AS assignee_type
        FROM tasks t
        LEFT JOIN task_assignments ta
          ON ta.task_id = t.id
         AND ta.assignee_id = t.assigned_to
         AND ta.deleted_at IS NULL
        LEFT JOIN users u ON u.id = t.assigned_to
        LEFT JOIN children c ON c.id = t.assigned_to
        WHERE t.assigned_to IS NOT NULL
          AND t.deleted_at IS NULL
          AND ta.id IS NULL
        """
    )
    tasks_with_assignee = await cursor.fetchall()
    if tasks_with_assignee:
        await db.executemany(
            "INSERT INTO task_assignments (id, task_id, assignee_id, assignee_type, created_by) "
            "VALUES (?, ?, ?, ?, ?)",
            [(str(uuid.uuid4()), row[0], row[1], row[3], row[2]) for row in tasks_with_assignee],
        )
        await db.commit()

    # Add actionable_from column to tasks
    cursor = await db.execute("PRAGMA table_info(tasks)")
    task_columns = {row[1] for row in await cursor.fetchall()}
    if "actionable_from" not in task_columns:
        await db.execute("ALTER TABLE tasks ADD COLUMN actionable_from TEXT")
        await db.commit()

    # Add sleep_type to naps (nap | bedtime)
    cursor = await db.execute("PRAGMA table_info(naps)")
    nap_cols = {row[1] for row in await cursor.fetchall()}
    if "sleep_type" not in nap_cols:
        await db.execute("ALTER TABLE naps ADD COLUMN sleep_type TEXT NOT NULL DEFAULT 'nap'")
        await db.commit()
    await db.execute("CREATE INDEX IF NOT EXISTS idx_naps_sleep_type ON naps(sleep_type)")
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_naps_family_type_started_active "
        "ON naps(family_id, sleep_type, started_at DESC) WHERE deleted_at IS NULL"
    )

    cursor = await db.execute("PRAGMA table_info(dog_activities)")
    dog_activity_cols = {row[1] for row in await cursor.fetchall()}
    if "is_active" not in dog_activity_cols:
        await db.execute(
            "ALTER TABLE dog_activities ADD COLUMN is_active INTEGER NOT NULL DEFAULT 0"
        )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_dog_activities_active "
        "ON dog_activities(family_id) "
        "WHERE deleted_at IS NULL AND is_active = 1"
    )

    # Birthdays can be useful even when the person's birth year is not known.
    cursor = await db.execute("PRAGMA table_info(birthdays)")
    birthday_cols = {row[1] for row in await cursor.fetchall()}
    if "birth_year" not in birthday_cols:
        await db.execute("ALTER TABLE birthdays ADD COLUMN birth_year INTEGER")
    if "birth_month" not in birthday_cols:
        await db.execute("ALTER TABLE birthdays ADD COLUMN birth_month INTEGER")
    if "birth_day" not in birthday_cols:
        await db.execute("ALTER TABLE birthdays ADD COLUMN birth_day INTEGER")
    await db.execute(
        "UPDATE birthdays SET "
        "birth_year = COALESCE(birth_year, CAST(substr(date_of_birth, 1, 4) AS INTEGER)), "
        "birth_month = COALESCE(birth_month, CAST(substr(date_of_birth, 6, 2) AS INTEGER)), "
        "birth_day = COALESCE(birth_day, CAST(substr(date_of_birth, 9, 2) AS INTEGER)) "
        "WHERE length(date_of_birth) = 10"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_birthdays_family_month_day "
        "ON birthdays(family_id, birth_month, birth_day) WHERE deleted_at IS NULL"
    )

    # Keep the original artwork while allowing the gallery copy and keepsake
    # details to evolve without destructive edits.
    cursor = await db.execute("PRAGMA table_info(artworks)")
    artwork_cols = {row[1] for row in await cursor.fetchall()}
    artwork_additions = {
        "medium": "TEXT",
        "story": "TEXT",
        "child_quote": "TEXT",
        "school_year": "TEXT",
        "favourite": "INTEGER NOT NULL DEFAULT 0",
        "include_in_yearbook": "INTEGER NOT NULL DEFAULT 1",
        "yearbook_position": "INTEGER",
        "original_media_type": "TEXT",
        "original_storage_key": "TEXT",
        "original_file_size": "INTEGER",
        "rotation_degrees": "INTEGER NOT NULL DEFAULT 0",
        "enhanced": "INTEGER NOT NULL DEFAULT 0",
    }
    for column, definition in artwork_additions.items():
        if column not in artwork_cols:
            await db.execute(f"ALTER TABLE artworks ADD COLUMN {column} {definition}")
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_artworks_family_favourites "
        "ON artworks(family_id, favourite DESC, approx_date DESC) WHERE deleted_at IS NULL"
    )

    # Child photos follow the same keepsake contract as artwork: the bounded
    # gallery copy may evolve, while the exact uploaded original remains safe.
    cursor = await db.execute("PRAGMA table_info(child_photos)")
    child_photo_cols = {row[1] for row in await cursor.fetchall()}
    child_photo_additions = {
        "location": "TEXT",
        "story": "TEXT",
        "favourite": "INTEGER NOT NULL DEFAULT 0",
        "include_in_yearbook": "INTEGER NOT NULL DEFAULT 1",
        "yearbook_position": "INTEGER",
        "original_media_type": "TEXT",
        "original_storage_key": "TEXT",
        "original_file_size": "INTEGER",
    }
    for column, definition in child_photo_additions.items():
        if column not in child_photo_cols:
            await db.execute(f"ALTER TABLE child_photos ADD COLUMN {column} {definition}")
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_child_photos_family_favourites "
        "ON child_photos(family_id, favourite DESC, taken_on DESC) WHERE deleted_at IS NULL"
    )

    # Weekly routines retain practical context while remaining compatible with
    # existing rows. Calendar projection and term-only match the historic
    # behaviour, so upgrades do not unexpectedly change the family plan.
    cursor = await db.execute("PRAGMA table_info(routine_items)")
    routine_item_cols = {row[1] for row in await cursor.fetchall()}
    routine_item_additions = {
        "time_of_day": "TEXT",
        "location": "TEXT",
        "preparation_note": "TEXT",
        "prep_template_id": "TEXT",
        "reminder_minutes": "INTEGER",
        "calendar_projection": "INTEGER NOT NULL DEFAULT 1",
        "term_only": "INTEGER NOT NULL DEFAULT 1",
    }
    for column, definition in routine_item_additions.items():
        if column not in routine_item_cols:
            await db.execute(f"ALTER TABLE routine_items ADD COLUMN {column} {definition}")

    # Imported school dates remain editable. Once a family adjusts an imported
    # range the scraper treats it as their durable truth instead of restoring
    # the broad school-wide dates on the next refresh.
    cursor = await db.execute("PRAGMA table_info(term_dates)")
    term_date_cols = {row[1] for row in await cursor.fetchall()}
    if "user_overridden" not in term_date_cols:
        await db.execute(
            "ALTER TABLE term_dates ADD COLUMN user_overridden "
            "INTEGER NOT NULL DEFAULT 0 CHECK (user_overridden IN (0, 1))"
        )

    # A weekday may have a pickup row for each child and a work-departure row
    # for each adult. The former index allowed only one family-wide row.
    await _migrate_handoff_pickups_without_adults(db)
    await db.execute("DROP INDEX IF EXISTS idx_term_time_handoff_weekday_active")
    await db.execute(
        "CREATE UNIQUE INDEX idx_term_time_handoff_weekday_active "
        "ON term_time_handoffs(family_id, kind, weekday, term_person_id) "
        "WHERE deleted_at IS NULL"
    )
    await db.commit()

    cursor = await db.execute("PRAGMA table_info(routine_term_overrides)")
    routine_override_cols = {row[1] for row in await cursor.fetchall()}
    if "expires_on" not in routine_override_cols:
        await db.execute("ALTER TABLE routine_term_overrides ADD COLUMN expires_on TEXT")

    # Multi-tenancy: add families table and family_id to all data tables
    cursor = await db.execute("PRAGMA table_info(users)")
    user_cols = {row[1] for row in await cursor.fetchall()}
    if "family_id" not in user_cols:
        default_family_id = "00000000-0000-0000-0000-000000000100"
        now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

        # Create families table
        await db.execute(
            "CREATE TABLE IF NOT EXISTS families ("
            "id TEXT PRIMARY KEY, name TEXT NOT NULL, invite_code TEXT UNIQUE, "
            f"created_at TEXT NOT NULL DEFAULT ({now}), "
            f"updated_at TEXT NOT NULL DEFAULT ({now}), "
            "deleted_at TEXT)"
        )
        await db.execute(
            "CREATE INDEX IF NOT EXISTS idx_families_invite ON families(invite_code) WHERE invite_code IS NOT NULL"
        )

        # Insert default family
        await db.execute(
            "INSERT OR IGNORE INTO families (id, name) VALUES (?, ?)",
            (default_family_id, "Example Family"),
        )

        # Add family_id to all data tables and backfill
        tables_needing_family_id = [
            "users",
            "children",
            "calendar_events",
            "tasks",
            "task_assignments",
            "medicine_types",
            "medicine_doses",
            "naps",
            "dog_activities",
            "birthdays",
            "meals",
            "meal_plans",
            "shopping_items",
            "health_data",
            "homework_reading",
            "homework_spellings",
            "growth_records",
            "record_history",
            "sync_queue",
            "routine_items",
            "term_dates",
            "routine_term_overrides",
            "holiday_dates",
            "illnesses",
            "temperature_readings",
            "star_charts",
            "star_chart_stars",
            "star_chart_balances",
            "star_chart_balance_transactions",
            "meal_ratings",
            "grocery_items",
            "purchase_batches",
            "purchases",
            "consumption_events",
        ]
        for table in tables_needing_family_id:
            await db.execute(f"ALTER TABLE {table} ADD COLUMN family_id TEXT")
            await db.execute(f"UPDATE {table} SET family_id = ?", (default_family_id,))
            await db.execute(f"CREATE INDEX IF NOT EXISTS idx_{table}_family ON {table}(family_id)")

        await db.commit()

    # meals additions
    cursor = await db.execute("PRAGMA table_info(meals)")
    meal_cols = {row[1] for row in await cursor.fetchall()}
    if "prep_minutes" not in meal_cols:
        await db.execute("ALTER TABLE meals ADD COLUMN prep_minutes INTEGER")
        await db.commit()
    if "source" not in meal_cols:
        await db.execute("ALTER TABLE meals ADD COLUMN source TEXT")
        await db.commit()
    meal_additions = {
        "servings": "INTEGER",
        "allergy_notes": "TEXT",
        "preference_notes": "TEXT",
        "not_for_us": "INTEGER NOT NULL DEFAULT 0",
    }
    for column, definition in meal_additions.items():
        if column not in meal_cols:
            await db.execute(f"ALTER TABLE meals ADD COLUMN {column} {definition}")
    await db.commit()

    # meal_plans additions
    cursor = await db.execute("PRAGMA table_info(meal_plans)")
    meal_plan_cols = {row[1] for row in await cursor.fetchall()}
    if "notes" not in meal_plan_cols:
        await db.execute("ALTER TABLE meal_plans ADD COLUMN notes TEXT")
        await db.commit()
    if "tired_household" not in meal_plan_cols:
        await db.execute(
            "ALTER TABLE meal_plans ADD COLUMN tired_household INTEGER NOT NULL DEFAULT 0"
        )
        await db.commit()

    # calendar_events additions
    cursor = await db.execute("PRAGMA table_info(calendar_events)")
    calendar_cols = {row[1] for row in await cursor.fetchall()}
    if "event_type" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN event_type TEXT DEFAULT 'other'")
        await db.commit()
    if "exertion" not in calendar_cols:
        await db.execute(
            "ALTER TABLE calendar_events ADD COLUMN exertion INTEGER NOT NULL DEFAULT 0"
        )
        await db.commit()
    if "color" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN color TEXT")
    if "rugby_source_venue" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN rugby_source_venue TEXT")
    if "rugby_venue_override" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN rugby_venue_override TEXT")
    if "source_document_id" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN source_document_id TEXT")
        await db.commit()
    if "calendar_source_id" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN calendar_source_id TEXT")
    if "external_uid" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN external_uid TEXT")
    if "external_instance_key" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN external_instance_key TEXT")
    if "source_term_date_id" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN source_term_date_id TEXT")
    if "term_boundary" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN term_boundary TEXT")
    if "read_only" not in calendar_cols:
        await db.execute(
            "ALTER TABLE calendar_events ADD COLUMN read_only INTEGER NOT NULL DEFAULT 0"
        )
    if "overridden_event_id" not in calendar_cols:
        await db.execute("ALTER TABLE calendar_events ADD COLUMN overridden_event_id TEXT")
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_events_event_type ON calendar_events(event_type)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_events_source_document "
        "ON calendar_events(source_document_id)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_events_calendar_source "
        "ON calendar_events(calendar_source_id)"
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_events_external_instance_active "
        "ON calendar_events(calendar_source_id, external_instance_key) "
        "WHERE calendar_source_id IS NOT NULL AND deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_events_source_term_date "
        "ON calendar_events(source_term_date_id)"
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_events_term_boundary_active "
        "ON calendar_events(source_term_date_id, term_boundary) "
        "WHERE source_term_date_id IS NOT NULL AND term_boundary IS NOT NULL "
        "AND deleted_at IS NULL"
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_events_active_override "
        "ON calendar_events(family_id, overridden_event_id) "
        "WHERE overridden_event_id IS NOT NULL AND deleted_at IS NULL"
    )
    cursor = await db.execute("PRAGMA table_info(calendar_sources)")
    calendar_source_cols = {row[1] for row in await cursor.fetchall()}
    if "source_kind" not in calendar_source_cols:
        await db.execute(
            "ALTER TABLE calendar_sources ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'ics'"
        )
    if "config_json" not in calendar_source_cols:
        await db.execute("ALTER TABLE calendar_sources ADD COLUMN config_json TEXT")
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_sources_example_school_rugby_active "
        "ON calendar_sources(family_id, source_kind) "
        "WHERE source_kind = 'school_rugby' AND deleted_at IS NULL"
    )
    # Explicit per-occurrence exceptions allow safe edits and deletions of a
    # generated recurrence without materialising or rewriting the whole series.
    # schema.sql creates this on new installs; keep the normal upgrade path
    # self-contained for existing installations too.
    await db.execute(
        """
        CREATE TABLE IF NOT EXISTS calendar_event_exceptions (
            id TEXT PRIMARY KEY,
            series_id TEXT NOT NULL,
            occurrence_start TEXT NOT NULL,
            action TEXT NOT NULL CHECK (action IN ('cancelled', 'replacement')),
            replacement_event_id TEXT,
            family_id TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            created_by TEXT,
            client_id TEXT,
            client_timestamp TEXT,
            deleted_at TEXT
        )
        """
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_event_exceptions_active "
        "ON calendar_event_exceptions(family_id, series_id, occurrence_start) "
        "WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_event_exceptions_series "
        "ON calendar_event_exceptions(family_id, series_id)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_event_exceptions_replacement "
        "ON calendar_event_exceptions(replacement_event_id)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_event_exceptions_deleted "
        "ON calendar_event_exceptions(deleted_at)"
    )
    await db.execute(
        """
        CREATE TABLE IF NOT EXISTS calendar_event_documents (
            id TEXT PRIMARY KEY,
            event_id TEXT NOT NULL,
            document_id TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'other'
                CHECK (role IN ('ticket', 'booking', 'school_letter', 'insurance', 'other')),
            position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
            family_id TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            created_by TEXT,
            client_id TEXT,
            client_timestamp TEXT,
            deleted_at TEXT
        )
        """
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_event_documents_active "
        "ON calendar_event_documents(family_id, event_id, document_id) "
        "WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_event_documents_event "
        "ON calendar_event_documents(family_id, event_id, position)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_event_documents_document "
        "ON calendar_event_documents(family_id, document_id)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_calendar_event_documents_deleted "
        "ON calendar_event_documents(deleted_at)"
    )
    # Preserve every installed singular link before clients begin using the
    # ordered many-document relation. Re-running startup is idempotent.
    legacy_event_documents = await (
        await db.execute(
            """
            SELECT ce.id, ce.source_document_id, ce.family_id, ce.created_at,
                   ce.updated_at, ce.created_by, ce.client_id, ce.client_timestamp
            FROM calendar_events ce
            WHERE ce.source_document_id IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM calendar_event_documents ced
                  WHERE ced.event_id = ce.id
                    AND ced.family_id IS ce.family_id
                    AND ced.document_id = ce.source_document_id
                    AND ced.deleted_at IS NULL
              )
            """
        )
    ).fetchall()
    for event in legacy_event_documents:
        await db.execute(
            """
            INSERT INTO calendar_event_documents
                (id, event_id, document_id, role, position, family_id,
                 created_at, updated_at, created_by, client_id, client_timestamp)
            VALUES (?, ?, ?, 'other', 0, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                event["id"],
                event["source_document_id"],
                event["family_id"],
                event["created_at"],
                event["updated_at"],
                event["created_by"],
                event["client_id"],
                event["client_timestamp"],
            ),
        )
    cursor = await db.execute("PRAGMA table_info(tasks)")
    task_cols = {row[1] for row in await cursor.fetchall()}
    if "source_document_id" not in task_cols:
        await db.execute("ALTER TABLE tasks ADD COLUMN source_document_id TEXT")
    if "source_event_id" not in task_cols:
        await db.execute("ALTER TABLE tasks ADD COLUMN source_event_id TEXT")
    if "prep_occurrence_id" not in task_cols:
        await db.execute("ALTER TABLE tasks ADD COLUMN prep_occurrence_id TEXT")
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_tasks_source_document ON tasks(source_document_id)"
    )
    await db.execute("CREATE INDEX IF NOT EXISTS idx_tasks_source_event ON tasks(source_event_id)")
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_tasks_prep_occurrence ON tasks(prep_occurrence_id)"
    )
    if {
        "family_id",
        "priority",
        "due_date",
        "created_at",
        "completed_at",
        "deleted_at",
    }.issubset(task_cols):
        await db.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_family_attention_active "
            "ON tasks(family_id, priority DESC, (due_date IS NULL), due_date, created_at DESC) "
            "WHERE deleted_at IS NULL AND completed_at IS NULL"
        )
    await db.commit()

    # Add must_change_password column to users
    cursor = await db.execute("PRAGMA table_info(users)")
    user_cols2 = {row[1] for row in await cursor.fetchall()}
    if "must_change_password" not in user_cols2:
        await db.execute(
            "ALTER TABLE users ADD COLUMN must_change_password INTEGER NOT NULL DEFAULT 0"
        )
        await db.commit()
    if "auth_version" not in user_cols2:
        await db.execute("ALTER TABLE users ADD COLUMN auth_version INTEGER NOT NULL DEFAULT 0")
        await db.commit()

    # Refresh tokens are stored only as hashes. Each pre-lineage token becomes
    # its own rotation family because historical parentage cannot be inferred.
    cursor = await db.execute("PRAGMA table_info(refresh_tokens)")
    refresh_token_cols = {row[1] for row in await cursor.fetchall()}
    if "rotation_family_id" not in refresh_token_cols:
        await db.execute("ALTER TABLE refresh_tokens ADD COLUMN rotation_family_id TEXT")
    if "parent_token_id" not in refresh_token_cols:
        await db.execute("ALTER TABLE refresh_tokens ADD COLUMN parent_token_id TEXT")
    if "replaced_by_id" not in refresh_token_cols:
        await db.execute("ALTER TABLE refresh_tokens ADD COLUMN replaced_by_id TEXT")
    if run_one_time_repairs:
        await db.execute(
            "UPDATE refresh_tokens SET rotation_family_id = id "
            "WHERE rotation_family_id IS NULL OR rotation_family_id = ''"
        )
        cursor = await db.execute("SELECT id, token FROM refresh_tokens")
        for token_id, stored_token in await cursor.fetchall():
            is_sha256 = (
                isinstance(stored_token, str)
                and len(stored_token) == 64
                and all(character in "0123456789abcdef" for character in stored_token.lower())
            )
            if not is_sha256:
                await db.execute(
                    "UPDATE refresh_tokens SET token = ? WHERE id = ?",
                    (hashlib.sha256(str(stored_token).encode("utf-8")).hexdigest(), token_id),
                )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_refresh_tokens_rotation_family "
        "ON refresh_tokens(rotation_family_id)"
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_refresh_tokens_rotation_family_active "
        "ON refresh_tokens(rotation_family_id) WHERE revoked_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_refresh_tokens_parent ON refresh_tokens(parent_token_id)"
    )
    await db.commit()

    # presents additions
    cursor = await db.execute("PRAGMA table_info(present_ideas)")
    present_cols = {row[1] for row in await cursor.fetchall()}
    if "event_year" not in present_cols:
        await db.execute("ALTER TABLE present_ideas ADD COLUMN event_year INTEGER")
        await db.execute(
            "CREATE INDEX IF NOT EXISTS idx_present_ideas_event_year ON present_ideas(event_year)"
        )
    await db.execute(
        "UPDATE present_ideas "
        "SET event_year = CAST(strftime('%Y', COALESCE(created_at, 'now')) AS INTEGER) "
        "WHERE event_year IS NULL"
    )
    present_column_migrations = {
        "occasion_key": "TEXT",
        "birthday_id": "TEXT",
        "status": "TEXT NOT NULL DEFAULT 'idea'",
        "status_updated_at": "TEXT",
        "owner_id": "TEXT",
        "url": "TEXT",
        "retailer": "TEXT",
        "budget_minor": "INTEGER",
        "price_minor": "INTEGER",
        "currency": "TEXT NOT NULL DEFAULT 'GBP'",
        "deadline": "TEXT",
        "hiding_location": "TEXT",
        "recipient_can_see": "INTEGER NOT NULL DEFAULT 0",
    }
    for column, definition in present_column_migrations.items():
        if column not in present_cols:
            await db.execute(f"ALTER TABLE present_ideas ADD COLUMN {column} {definition}")
    await db.execute(
        "UPDATE present_ideas SET occasion_key = occasion WHERE occasion_key IS NULL"
    )
    await db.execute(
        "UPDATE present_ideas SET status = 'idea' WHERE status IS NULL OR status = ''"
    )
    await db.execute(
        "UPDATE present_ideas SET status_updated_at = COALESCE(updated_at, created_at) "
        "WHERE status_updated_at IS NULL"
    )
    await db.execute(
        "UPDATE present_ideas SET currency = 'GBP' WHERE currency IS NULL OR currency = ''"
    )
    for index_sql in (
        "CREATE INDEX IF NOT EXISTS idx_present_ideas_event_year ON present_ideas(event_year)",
        "CREATE INDEX IF NOT EXISTS idx_present_ideas_occasion_key ON present_ideas(occasion_key)",
        "CREATE INDEX IF NOT EXISTS idx_present_ideas_birthday ON present_ideas(birthday_id)",
        "CREATE INDEX IF NOT EXISTS idx_present_ideas_status ON present_ideas(status)",
        "CREATE INDEX IF NOT EXISTS idx_present_ideas_deadline ON present_ideas(deadline)",
        "CREATE INDEX IF NOT EXISTS idx_present_ideas_owner ON present_ideas(owner_id)",
    ):
        await db.execute(index_sql)
    await db.execute(
        """
        CREATE TABLE IF NOT EXISTS present_status_history (
            id TEXT PRIMARY KEY,
            idea_id TEXT NOT NULL,
            from_status TEXT,
            to_status TEXT NOT NULL,
            changed_at TEXT NOT NULL,
            family_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            created_by TEXT,
            client_id TEXT,
            client_timestamp TEXT,
            deleted_at TEXT
        )
        """
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_present_status_history_idea "
        "ON present_status_history(idea_id, changed_at)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_present_status_history_family "
        "ON present_status_history(family_id)"
    )
    await db.commit()

    # Family settings (HA integration config)
    await db.execute(
        "CREATE TABLE IF NOT EXISTS family_settings ("
        "family_id TEXT NOT NULL, "
        "setting_key TEXT NOT NULL, "
        "setting_value TEXT, "
        "updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "updated_by TEXT, "
        "PRIMARY KEY (family_id, setting_key))"
    )
    await db.commit()

    # Forwarded documents can carry machine-inferred filing metadata. Null means
    # the value was entered or reviewed by a person; a score records an unreviewed
    # inference so clients can keep uncertain items out of bulk filing.
    cursor = await db.execute("PRAGMA table_info(documents)")
    document_cols = {row[1] for row in await cursor.fetchall()}
    if "category_confidence" not in document_cols:
        await db.execute("ALTER TABLE documents ADD COLUMN category_confidence REAL")
    if "document_date_confidence" not in document_cols:
        await db.execute("ALTER TABLE documents ADD COLUMN document_date_confidence REAL")
    await db.execute(
        """
        UPDATE documents
        SET category_confidence = CASE WHEN category = 'other' THEN 0.25 ELSE 0.92 END,
            document_date_confidence = 0.35
        WHERE source = 'share' AND notes LIKE 'Forwarded by %'
          AND category_confidence IS NULL AND document_date_confidence IS NULL
        """
    )
    await db.commit()

    # Full-text index over documents so assistant and inbox searches avoid
    # LIKE scans of complete OCR text. External-content table + sync triggers.
    try:
        await db.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5("
            "title, extracted_text, content='documents', content_rowid='rowid')"
        )
    except aiosqlite.OperationalError:
        # SQLite built without FTS5; document searches fall back to LIKE.
        pass
    else:
        await db.execute(
            "CREATE TRIGGER IF NOT EXISTS documents_fts_after_insert "
            "AFTER INSERT ON documents BEGIN "
            "INSERT INTO documents_fts(rowid, title, extracted_text) "
            "VALUES (new.rowid, new.title, new.extracted_text); END"
        )
        await db.execute(
            "CREATE TRIGGER IF NOT EXISTS documents_fts_after_delete "
            "AFTER DELETE ON documents BEGIN "
            "INSERT INTO documents_fts(documents_fts, rowid, title, extracted_text) "
            "VALUES ('delete', old.rowid, old.title, old.extracted_text); END"
        )
        await db.execute(
            "CREATE TRIGGER IF NOT EXISTS documents_fts_after_update "
            "AFTER UPDATE ON documents BEGIN "
            "INSERT INTO documents_fts(documents_fts, rowid, title, extracted_text) "
            "VALUES ('delete', old.rowid, old.title, old.extracted_text); "
            "INSERT INTO documents_fts(rowid, title, extracted_text) "
            "VALUES (new.rowid, new.title, new.extracted_text); END"
        )
        cursor = await db.execute(
            "SELECT EXISTS(SELECT 1 FROM documents) AND NOT EXISTS(SELECT 1 FROM documents_fts)"
        )
        if (await cursor.fetchone())[0]:
            await db.execute("INSERT INTO documents_fts(documents_fts) VALUES ('rebuild')")
        await db.commit()

    # Inbound email workers use expiring, fenced leases so provider retries can
    # recover crashed work without allowing an older worker to commit later.
    cursor = await db.execute("PRAGMA table_info(inbound_email_messages)")
    inbound_email_cols = {row[1] for row in await cursor.fetchall()}
    if "lease_token" not in inbound_email_cols:
        await db.execute("ALTER TABLE inbound_email_messages ADD COLUMN lease_token TEXT")
    if "lease_expires_at" not in inbound_email_cols:
        await db.execute("ALTER TABLE inbound_email_messages ADD COLUMN lease_expires_at TEXT")
    await db.commit()

    if run_one_time_repairs:
        # Older history writers did not tag snapshots with their family. Prefer
        # the snapshot's own family_id, then fall back to its authenticated
        # author only when the snapshot has no conflicting family attribution.
        await db.execute(
            """
            UPDATE record_history
            SET family_id = CASE
                WHEN json_valid(previous_values)
                THEN json_extract(previous_values, '$.family_id')
            END
            WHERE family_id IS NULL
              AND CASE
                  WHEN json_valid(previous_values)
                  THEN json_extract(previous_values, '$.family_id')
              END IN (SELECT id FROM families)
            """
        )
        await db.execute(
            """
            UPDATE record_history
            SET family_id = (
                SELECT users.family_id
                FROM users
                WHERE users.id = record_history.changed_by
                  AND users.family_id IS NOT NULL
                LIMIT 1
            )
            WHERE family_id IS NULL
              AND CASE
                  WHEN json_valid(previous_values)
                  THEN json_extract(previous_values, '$.family_id')
              END IS NULL
              AND EXISTS (
                  SELECT 1
                  FROM users
                  WHERE users.id = record_history.changed_by
                    AND users.family_id IS NOT NULL
              )
            """
        )
        await db.commit()

        # Repair legacy double-tap races before enforcing active-cell uniqueness.
        now = datetime.now(timezone.utc).isoformat()
        cursor = await db.execute(
            """
            SELECT duplicate.id
            FROM star_chart_stars duplicate
            WHERE duplicate.deleted_at IS NULL
              AND EXISTS (
                  SELECT 1 FROM star_chart_stars keeper
                  WHERE keeper.deleted_at IS NULL
                    AND keeper.chart_id = duplicate.chart_id
                    AND keeper.row_index = duplicate.row_index
                    AND keeper.col_index = duplicate.col_index
                    AND (
                        keeper.created_at < duplicate.created_at
                        OR (keeper.created_at = duplicate.created_at AND keeper.id < duplicate.id)
                    )
              )
            """
        )
        duplicate_star_ids = [row[0] for row in await cursor.fetchall()]
        if duplicate_star_ids:
            await db.executemany(
                "UPDATE star_chart_stars SET deleted_at = ?, updated_at = ? WHERE id = ?",
                [(now, now, star_id) for star_id in duplicate_star_ids],
            )

        cursor = await db.execute(
            """
            SELECT duplicate.id, duplicate.child_id, duplicate.family_id,
                   duplicate.amount_pence
            FROM star_chart_balance_transactions duplicate
            WHERE duplicate.reason = 'chart_completed'
              AND duplicate.chart_id IS NOT NULL
              AND duplicate.deleted_at IS NULL
              AND EXISTS (
                  SELECT 1 FROM star_chart_balance_transactions keeper
                  WHERE keeper.reason = 'chart_completed'
                    AND keeper.chart_id = duplicate.chart_id
                    AND keeper.deleted_at IS NULL
                    AND (
                        keeper.created_at < duplicate.created_at
                        OR (keeper.created_at = duplicate.created_at AND keeper.id < duplicate.id)
                    )
              )
            """
        )
        for transaction_id, child_id, family_id, amount_pence in await cursor.fetchall():
            await db.execute(
                "UPDATE star_chart_balance_transactions "
                "SET deleted_at = ?, updated_at = ? WHERE id = ?",
                (now, now, transaction_id),
            )
            await db.execute(
                "UPDATE star_chart_balances "
                "SET balance_pence = balance_pence - ?, updated_at = ? "
                "WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL",
                (amount_pence, now, child_id, family_id),
            )

        cursor = await db.execute(
            """
            SELECT c.id, c.child_id, c.family_id
            FROM star_charts c
            WHERE c.completed_at IS NOT NULL AND c.deleted_at IS NULL
              AND (
                  SELECT COUNT(*) FROM star_chart_stars s
                  WHERE s.chart_id = c.id AND s.deleted_at IS NULL
              ) < c.grid_rows * c.grid_columns
            """
        )
        for chart_id, child_id, family_id in await cursor.fetchall():
            amount_cursor = await db.execute(
                "SELECT COALESCE(SUM(amount_pence), 0) "
                "FROM star_chart_balance_transactions "
                "WHERE chart_id = ? AND reason = 'chart_completed' AND deleted_at IS NULL",
                (chart_id,),
            )
            reversal = (await amount_cursor.fetchone())[0]
            await db.execute(
                "UPDATE star_charts SET completed_at = NULL, updated_at = ? WHERE id = ?",
                (now, chart_id),
            )
            await db.execute(
                "UPDATE star_chart_balance_transactions SET deleted_at = ?, updated_at = ? "
                "WHERE chart_id = ? AND reason = 'chart_completed' AND deleted_at IS NULL",
                (now, now, chart_id),
            )
            if reversal:
                await db.execute(
                    "UPDATE star_chart_balances "
                    "SET balance_pence = balance_pence - ?, updated_at = ? "
                    "WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL",
                    (reversal, now, child_id, family_id),
                )

    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_star_chart_cell_active "
        "ON star_chart_stars(chart_id, row_index, col_index) "
        "WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_star_chart_completion_transaction_active "
        "ON star_chart_balance_transactions(chart_id) "
        "WHERE reason = 'chart_completed' AND deleted_at IS NULL"
    )

    # Optional sex (male | female | null) on children, used by WHO growth centiles.
    cursor = await db.execute("PRAGMA table_info(children)")
    child_cols = {row[1] for row in await cursor.fetchall()}
    if "sex" not in child_cols:
        await db.execute("ALTER TABLE children ADD COLUMN sex TEXT")
    if "avatar_url" not in child_cols:
        await db.execute("ALTER TABLE children ADD COLUMN avatar_url TEXT")
    await db.commit()

    # Menstrual-cycle tracking moved under Fitness. INSERT OR IGNORE makes the
    # copy idempotent while each newly copied row receives a Fitness change-log
    # entry for existing clients beginning at cursor zero.
    await _migrate_cycles_to_fitness(db)
    await db.commit()

    # Fitness activity/import columns were added after the first private Fitness
    # schema landed. Keep existing NUC databases compatible with schema.sql.
    cursor = await db.execute("PRAGMA table_info(health_activities)")
    fitness_activity_cols = {row[1] for row in await cursor.fetchall()}
    fitness_activity_migrations = {
        "sub_sport_key": "TEXT",
        "parent_activity_id": "TEXT",
        "leg_index": "INTEGER",
        "workout_version_id": "TEXT",
        "primary_source_record_id": "TEXT",
        "primary_stream_asset_id": "TEXT",
        "local_calendar_date": "TEXT",
        "elapsed_duration_s": "REAL",
        "timer_duration_s": "REAL",
        "moving_duration_s": "REAL",
        "distance_m": "REAL",
        "energy_kcal": "REAL",
        "energy_estimation_method": "TEXT",
        "energy_estimation_weight_kg": "REAL",
        "energy_estimation_weight_measured_at_utc": "TEXT",
        "energy_estimation_met": "REAL",
        "measurement_quality": "TEXT NOT NULL DEFAULT 'measured'",
        "import_state": "TEXT NOT NULL DEFAULT 'not_imported'",
        "parser_version": "TEXT",
        "workout_classification": "TEXT",
        "classification_source": "TEXT",
        "phase_id": "TEXT",
        "route_preview_json": "TEXT",
    }
    for column, declaration in fitness_activity_migrations.items():
        if column not in fitness_activity_cols:
            await db.execute(f"ALTER TABLE health_activities ADD COLUMN {column} {declaration}")

    # A simple run can have a pace target without requiring a distance or a
    # structured workout definition. Keep that everyday intent first-class.
    cursor = await db.execute("PRAGMA table_info(health_planned_sessions)")
    planned_session_cols = {row[1] for row in await cursor.fetchall()}
    if "expected_pace_s_per_km" not in planned_session_cols:
        await db.execute(
            "ALTER TABLE health_planned_sessions ADD COLUMN expected_pace_s_per_km REAL"
        )

    cursor = await db.execute("PRAGMA table_info(health_workout_versions)")
    fitness_workout_cols = {row[1] for row in await cursor.fetchall()}
    if "accepted_at" not in fitness_workout_cols:
        await db.execute("ALTER TABLE health_workout_versions ADD COLUMN accepted_at TEXT")
    if "accepted_by" not in fitness_workout_cols:
        await db.execute("ALTER TABLE health_workout_versions ADD COLUMN accepted_by TEXT")

    cursor = await db.execute("PRAGMA table_info(health_user_settings)")
    fitness_settings_cols = {row[1] for row in await cursor.fetchall()}
    for column, declaration in {
        "show_planned": "INTEGER NOT NULL DEFAULT 1 CHECK (show_planned IN (0,1))",
        "show_completed": "INTEGER NOT NULL DEFAULT 0 CHECK (show_completed IN (0,1))",
        "heart_rate_zone_boundaries_bpm_json": "TEXT NOT NULL DEFAULT '[120,140,155,170]'",
        "coach_personality_preset": "TEXT NOT NULL DEFAULT 'balanced_supportive'",
        "coach_directness": "INTEGER NOT NULL DEFAULT 3",
        "coach_challenge_bias": "TEXT NOT NULL DEFAULT 'balanced'",
        "coach_detail_level": "TEXT NOT NULL DEFAULT 'standard'",
        "coach_custom_instruction": "TEXT",
        "coach_memory_enabled": "INTEGER NOT NULL DEFAULT 0",
        "coach_memory_enabled_at": "TEXT",
        "breakfast_time": "TEXT NOT NULL DEFAULT '08:00'",
        "lunch_time": "TEXT NOT NULL DEFAULT '12:30'",
        "dinner_time": "TEXT NOT NULL DEFAULT '18:30'",
    }.items():
        if column not in fitness_settings_cols:
            await db.execute(f"ALTER TABLE health_user_settings ADD COLUMN {column} {declaration}")

    await db.execute(
        "CREATE TABLE IF NOT EXISTS health_fitness_workspace_preferences ("
        "id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, "
        "enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0,1)), "
        "pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)), "
        "show_nutrition_today INTEGER NOT NULL DEFAULT 0 "
        "CHECK (show_nutrition_today IN (0,1)), "
        "revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1), "
        "family_id TEXT NOT NULL, "
        "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "created_by TEXT, client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"
    )
    cursor = await db.execute("PRAGMA table_info(health_fitness_workspace_preferences)")
    fitness_workspace_cols = {row[1] for row in await cursor.fetchall()}
    if "show_nutrition_today" not in fitness_workspace_cols:
        await db.execute(
            "ALTER TABLE health_fitness_workspace_preferences ADD COLUMN "
            "show_nutrition_today INTEGER NOT NULL DEFAULT 0 "
            "CHECK (show_nutrition_today IN (0,1))"
        )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_health_fitness_workspace_owner_active "
        "ON health_fitness_workspace_preferences(owner_user_id) WHERE deleted_at IS NULL"
    )

    await db.execute(
        "CREATE TABLE IF NOT EXISTS health_fitness_reminders ("
        "id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, title TEXT NOT NULL, "
        "remind_at_utc TEXT NOT NULL, notes TEXT, planned_session_id TEXT, "
        "status TEXT NOT NULL DEFAULT 'active' "
        "CHECK (status IN ('active','completed')), "
        "revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1), "
        "family_id TEXT NOT NULL, "
        "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "created_by TEXT, client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_health_fitness_reminders_owner_time "
        "ON health_fitness_reminders(owner_user_id, remind_at_utc) "
        "WHERE deleted_at IS NULL AND status = 'active'"
    )

    await db.execute(
        "CREATE TABLE IF NOT EXISTS health_onboarding_profiles ("
        "id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, "
        "status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','skipped','complete')), "
        "main_outcome TEXT, availability_json TEXT NOT NULL DEFAULT '[]', "
        "activities_json TEXT NOT NULL DEFAULT '[]', equipment_json TEXT NOT NULL DEFAULT '[]', "
        "food_preferences_json TEXT NOT NULL DEFAULT '[]', "
        "source_connections_json TEXT NOT NULL DEFAULT '[]', coach_style TEXT, "
        "use_family_calendar INTEGER NOT NULL DEFAULT 0 CHECK (use_family_calendar IN (0,1)), "
        "use_household_meals INTEGER NOT NULL DEFAULT 0 CHECK (use_household_meals IN (0,1)), "
        "use_weather INTEGER NOT NULL DEFAULT 0 CHECK (use_weather IN (0,1)), "
        "memory_enabled INTEGER NOT NULL DEFAULT 0 CHECK (memory_enabled IN (0,1)), "
        "preview_id TEXT, preview_json TEXT, preview_hash TEXT, previewed_at TEXT, "
        "confirmed_at TEXT, goal_id TEXT, session_ids_json TEXT NOT NULL DEFAULT '[]', "
        "revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1), family_id TEXT NOT NULL, "
        "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "created_by TEXT, client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"
    )
    cursor = await db.execute("PRAGMA table_info(health_onboarding_profiles)")
    onboarding_profile_cols = {row[1] for row in await cursor.fetchall()}
    for column in ("use_family_calendar", "use_household_meals", "use_weather"):
        if column not in onboarding_profile_cols:
            await db.execute(
                f"ALTER TABLE health_onboarding_profiles ADD COLUMN {column} "
                f"INTEGER NOT NULL DEFAULT 0 CHECK ({column} IN (0,1))"
            )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_health_onboarding_owner_active "
        "ON health_onboarding_profiles(owner_user_id) WHERE deleted_at IS NULL"
    )

    await db.execute(
        "CREATE TABLE IF NOT EXISTS health_household_meal_recipe_links ("
        "id TEXT PRIMARY KEY, meal_id TEXT NOT NULL, recipe_version_id TEXT NOT NULL, "
        "revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1), family_id TEXT NOT NULL, "
        "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
        "created_by TEXT, client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_health_household_meal_link_active "
        "ON health_household_meal_recipe_links(family_id, meal_id) "
        "WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_health_household_meal_link_recipe "
        "ON health_household_meal_recipe_links(family_id, recipe_version_id) "
        "WHERE deleted_at IS NULL"
    )

    cursor = await db.execute("PRAGMA table_info(health_source_records)")
    fitness_source_cols = {row[1] for row in await cursor.fetchall()}
    for column, declaration in {
        "sample_type": "TEXT",
        "source_name": "TEXT",
        "product_type": "TEXT",
        "device_json": "TEXT",
        "metadata_json": "TEXT",
        "domain_entity_type": "TEXT",
        "domain_entity_id": "TEXT",
    }.items():
        if column not in fitness_source_cols:
            await db.execute(f"ALTER TABLE health_source_records ADD COLUMN {column} {declaration}")

    cursor = await db.execute("PRAGMA table_info(health_intervals_connections)")
    intervals_connection_cols = {row[1] for row in await cursor.fetchall()}
    for column, declaration in {
        "activity_import_enabled": (
            "INTEGER NOT NULL DEFAULT 0 CHECK (activity_import_enabled IN (0,1))"
        ),
        "activity_import_since": "TEXT",
        "last_activity_import_at": "TEXT",
        "last_activity_import_error_code": "TEXT",
    }.items():
        if column not in intervals_connection_cols:
            await db.execute(
                f"ALTER TABLE health_intervals_connections ADD COLUMN {column} {declaration}"
            )

    cursor = await db.execute("PRAGMA table_info(health_body_measurements)")
    body_measurement_cols = {row[1] for row in await cursor.fetchall()}
    if "manual_canonical_override" not in body_measurement_cols:
        await db.execute(
            "ALTER TABLE health_body_measurements ADD COLUMN "
            "manual_canonical_override INTEGER NOT NULL DEFAULT 0 "
            "CHECK (manual_canonical_override IN (0,1))"
        )

    # Fitness Nutrition completion: existing databases predate private label
    # references and canonical meal-template quantities. These named migrations
    # keep their rows usable without re-creating or guessing nutrition records.
    cursor = await db.execute("PRAGMA table_info(health_food_versions)")
    food_version_cols = {row[1] for row in await cursor.fetchall()}
    if "effective_from" not in food_version_cols:
        await db.execute("ALTER TABLE health_food_versions ADD COLUMN effective_from TEXT")
    if "label_asset_id" not in food_version_cols:
        await db.execute("ALTER TABLE health_food_versions ADD COLUMN label_asset_id TEXT")

    cursor = await db.execute("PRAGMA table_info(health_recipes)")
    recipe_cols = {row[1] for row in await cursor.fetchall()}
    if "active" not in recipe_cols:
        await db.execute("ALTER TABLE health_recipes ADD COLUMN active INTEGER NOT NULL DEFAULT 1")

    cursor = await db.execute("PRAGMA table_info(health_meal_templates)")
    meal_template_cols = {row[1] for row in await cursor.fetchall()}
    if "active" not in meal_template_cols:
        await db.execute(
            "ALTER TABLE health_meal_templates ADD COLUMN active INTEGER NOT NULL DEFAULT 1"
        )

    cursor = await db.execute("PRAGMA table_info(health_meal_template_items)")
    template_item_cols = {row[1] for row in await cursor.fetchall()}
    added_template_canonical_amount = "canonical_amount" not in template_item_cols
    added_template_canonical_unit = "canonical_unit" not in template_item_cols
    if added_template_canonical_amount:
        await db.execute(
            "ALTER TABLE health_meal_template_items "
            "ADD COLUMN canonical_amount REAL NOT NULL DEFAULT 1"
        )
        await db.execute("UPDATE health_meal_template_items SET canonical_amount = amount")
    if added_template_canonical_unit:
        await db.execute(
            "ALTER TABLE health_meal_template_items "
            "ADD COLUMN canonical_unit TEXT NOT NULL DEFAULT 'serving'"
        )
        await db.execute("UPDATE health_meal_template_items SET canonical_unit = unit")

    cursor = await db.execute("PRAGMA table_info(health_food_log_entries)")
    food_log_cols = {row[1] for row in await cursor.fetchall()}
    for column in ("source_meal_plan_id", "household_meal_link_id"):
        if column not in food_log_cols:
            await db.execute(f"ALTER TABLE health_food_log_entries ADD COLUMN {column} TEXT")
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_health_food_log_owner_meal_plan "
        "ON health_food_log_entries(owner_user_id, source_meal_plan_id) "
        "WHERE source_meal_plan_id IS NOT NULL AND deleted_at IS NULL"
    )

    # Strength history records the setup label and comparison modes that were
    # actually used. Setup edits and merges must not reinterpret old sessions.
    cursor = await db.execute("PRAGMA table_info(health_strength_session_exercises)")
    session_exercise_cols = {row[1] for row in await cursor.fetchall()}
    for column in (
        "exercise_setup_name_snapshot",
        "load_entry_mode_snapshot",
        "rep_count_mode_snapshot",
        "unilateral_mode_snapshot",
    ):
        if column not in session_exercise_cols:
            await db.execute(
                f"ALTER TABLE health_strength_session_exercises ADD COLUMN {column} TEXT"
            )
    await db.execute(
        "UPDATE health_strength_session_exercises AS se SET "
        "exercise_setup_name_snapshot = COALESCE(exercise_setup_name_snapshot, "
        "(SELECT s.name FROM health_exercise_setups s WHERE s.id = se.exercise_setup_id), "
        "'Historical setup'), "
        "load_entry_mode_snapshot = COALESCE(load_entry_mode_snapshot, "
        "(SELECT COALESCE(s.load_entry_mode, e.load_entry_mode) "
        " FROM health_exercise_setups s JOIN health_exercises e ON e.id = s.exercise_id "
        " WHERE s.id = se.exercise_setup_id), 'total_external'), "
        "rep_count_mode_snapshot = COALESCE(rep_count_mode_snapshot, "
        "(SELECT COALESCE(s.rep_count_mode, e.rep_count_mode) "
        " FROM health_exercise_setups s JOIN health_exercises e ON e.id = s.exercise_id "
        " WHERE s.id = se.exercise_setup_id), 'total'), "
        "unilateral_mode_snapshot = COALESCE(unilateral_mode_snapshot, "
        "(SELECT COALESCE(s.unilateral_mode, e.unilateral_mode) "
        " FROM health_exercise_setups s JOIN health_exercises e ON e.id = s.exercise_id "
        " WHERE s.id = se.exercise_setup_id), 'bilateral')"
    )

    # SQLite cannot widen a CHECK constraint with ALTER COLUMN. Rebuild only
    # older strength-group tables whose SQL does not yet allow the explicit
    # body-issue stop state.
    group_sql_row = await (
        await db.execute(
            "SELECT sql FROM sqlite_master WHERE type = 'table' "
            "AND name = 'health_strength_set_groups'"
        )
    ).fetchone()
    if group_sql_row and "stopped_for_body_issue" not in (group_sql_row[0] or ""):
        await db.execute(
            "ALTER TABLE health_strength_set_groups RENAME TO health_strength_set_groups_old"
        )
        await db.execute(
            "CREATE TABLE health_strength_set_groups ("
            "id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, activity_id TEXT NOT NULL, "
            "session_exercise_id TEXT NOT NULL, planned_set_id TEXT, sequence INTEGER NOT NULL, "
            "training_role TEXT NOT NULL CHECK (training_role IN "
            "('warmup','working','backoff','technique','test','other')), "
            "structure_type TEXT NOT NULL CHECK (structure_type IN "
            "('straight','drop','rest_pause','cluster','other')), "
            "status TEXT NOT NULL CHECK (status IN "
            "('planned','in_progress','completed','partial','skipped','aborted')), "
            "is_amrap INTEGER NOT NULL DEFAULT 0, failure_state TEXT NOT NULL DEFAULT 'none' "
            "CHECK (failure_state IN "
            "('none','technical','muscular','stopped_for_body_issue','unknown')), "
            "started_at_utc TEXT, completed_at_utc TEXT, notes TEXT, "
            "revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1), family_id TEXT NOT NULL, "
            "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
            "updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
            "created_by TEXT, client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"
        )
        await db.execute(
            "INSERT INTO health_strength_set_groups SELECT * FROM health_strength_set_groups_old"
        )
        await db.execute("DROP TABLE health_strength_set_groups_old")
        await db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strength_group_sequence "
            "ON health_strength_set_groups(owner_user_id, session_exercise_id, sequence) "
            "WHERE deleted_at IS NULL"
        )
    await db.commit()

    # Homework keeps the everyday screen compact while retaining the teacher
    # sheet, optional link, completion state and real per-word practice history.
    # Existing installs predate these fields and the session table.
    cursor = await db.execute("PRAGMA table_info(homework_spellings)")
    homework_spelling_cols = {row[1] for row in await cursor.fetchall()}
    for column, declaration in {
        "completed_at": "TEXT",
        "notes": "TEXT",
        "link_url": "TEXT",
        "source_document_id": "TEXT",
    }.items():
        if column not in homework_spelling_cols:
            await db.execute(f"ALTER TABLE homework_spellings ADD COLUMN {column} {declaration}")
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_homework_spellings_due "
        "ON homework_spellings(family_id, completed_at, test_date) "
        "WHERE deleted_at IS NULL"
    )
    await db.execute(
        """
        CREATE TABLE IF NOT EXISTS homework_spelling_sessions (
            id TEXT PRIMARY KEY,
            spellings_id TEXT NOT NULL,
            child_id TEXT NOT NULL,
            practised_at TEXT NOT NULL,
            attempts_json TEXT NOT NULL,
            correct_count INTEGER NOT NULL,
            total_count INTEGER NOT NULL,
            family_id TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            created_by TEXT,
            client_id TEXT,
            client_timestamp TEXT,
            deleted_at TEXT
        )
        """
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_homework_spelling_sessions_list "
        "ON homework_spelling_sessions(family_id, spellings_id, practised_at DESC) "
        "WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_homework_spelling_sessions_child "
        "ON homework_spelling_sessions(family_id, child_id, practised_at DESC) "
        "WHERE deleted_at IS NULL"
    )
    await db.commit()

    # Ad-hoc vaccinations (for example chickenpox) keep their user-entered
    # label alongside the routine-schedule key. New databases get this from
    # schema.sql; this migration preserves existing installations.
    cursor = await db.execute("PRAGMA table_info(child_vaccinations)")
    vaccination_cols = {row[1] for row in await cursor.fetchall()}
    if "vaccine_name" not in vaccination_cols:
        await db.execute("ALTER TABLE child_vaccinations ADD COLUMN vaccine_name TEXT")
    await db.commit()

    # Booking-scoped caregiver handovers. Access bootstrap/session values are
    # never stored directly, only their one-way hashes.
    await db.execute(
        """CREATE TABLE IF NOT EXISTS caregiver_handovers (
            id TEXT PRIMARY KEY, address TEXT, wifi_name TEXT, wifi_password TEXT,
            emergency_instructions TEXT, house_instructions TEXT, dog_instructions TEXT,
            family_id TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            created_by TEXT, client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"""
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_caregiver_handover_family_active "
        "ON caregiver_handovers(family_id) WHERE deleted_at IS NULL"
    )
    await db.execute(
        """CREATE TABLE IF NOT EXISTS caregiver_child_profiles (
            id TEXT PRIMARY KEY, handover_id TEXT NOT NULL, child_id TEXT NOT NULL,
            care_notes TEXT, allergies TEXT, food TEXT, comfort TEXT, toileting TEXT,
            bedtime TEXT, family_id TEXT NOT NULL, created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL, created_by TEXT, client_id TEXT,
            client_timestamp TEXT, deleted_at TEXT)"""
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_caregiver_child_family_active "
        "ON caregiver_child_profiles(family_id, child_id) WHERE deleted_at IS NULL"
    )
    await db.execute(
        """CREATE TABLE IF NOT EXISTS caregiver_contacts (
            id TEXT PRIMARY KEY, handover_id TEXT NOT NULL, name TEXT NOT NULL,
            phone TEXT NOT NULL, relationship TEXT, priority INTEGER NOT NULL DEFAULT 0,
            family_id TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            created_by TEXT, client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"""
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_caregiver_contacts_handover "
        "ON caregiver_contacts(family_id, handover_id, priority) WHERE deleted_at IS NULL"
    )
    await db.execute(
        """CREATE TABLE IF NOT EXISTS caregiver_bookings (
            id TEXT PRIMARY KEY, handover_id TEXT NOT NULL, label TEXT NOT NULL,
            starts_at TEXT NOT NULL, expires_at TEXT NOT NULL, child_ids TEXT NOT NULL,
            bootstrap_hash TEXT NOT NULL, bootstrap_used_at TEXT, session_hash TEXT,
            last_accessed_at TEXT, revoked_at TEXT, family_id TEXT NOT NULL,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL, created_by TEXT,
            client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"""
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_caregiver_booking_bootstrap "
        "ON caregiver_bookings(bootstrap_hash)"
    )
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_caregiver_booking_session "
        "ON caregiver_bookings(session_hash) WHERE session_hash IS NOT NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_caregiver_booking_family_window "
        "ON caregiver_bookings(family_id, starts_at, expires_at) WHERE deleted_at IS NULL"
    )
    await db.commit()

    # Short-lived, content-free usage facts. Collection is off until the adult
    # explicitly enables it; request and response content never enters this table.
    await db.execute(
        """CREATE TABLE IF NOT EXISTS adoption_events (
            id TEXT PRIMARY KEY, user_id TEXT NOT NULL, module TEXT NOT NULL,
            action TEXT NOT NULL, outcome TEXT NOT NULL,
            entry_source TEXT NOT NULL CHECK (entry_source IN ('ios', 'web', 'unknown')),
            effort TEXT NOT NULL CHECK (effort IN ('quick', 'standard', 'involved')),
            app_version TEXT NOT NULL,
            event_kind TEXT NOT NULL DEFAULT 'server_action',
            surface TEXT NOT NULL DEFAULT 'server', workflow TEXT,
            workflow_run_id TEXT, duration_bucket TEXT NOT NULL DEFAULT 'unknown',
            interaction_count INTEGER, connectivity TEXT NOT NULL DEFAULT 'unknown',
            failure_class TEXT, family_id TEXT NOT NULL,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL, created_by TEXT,
            client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"""
    )
    cursor = await db.execute("PRAGMA table_info(adoption_events)")
    adoption_event_columns = {row[1] for row in await cursor.fetchall()}
    adoption_event_migrations = {
        "event_kind": "TEXT NOT NULL DEFAULT 'server_action'",
        "surface": "TEXT NOT NULL DEFAULT 'server'",
        "workflow": "TEXT",
        "workflow_run_id": "TEXT",
        "duration_bucket": "TEXT NOT NULL DEFAULT 'unknown'",
        "interaction_count": "INTEGER",
        "connectivity": "TEXT NOT NULL DEFAULT 'unknown'",
        "failure_class": "TEXT",
    }
    for column, declaration in adoption_event_migrations.items():
        if column not in adoption_event_columns:
            await db.execute(
                f"ALTER TABLE adoption_events ADD COLUMN {column} {declaration}"
            )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_adoption_owner_time "
        "ON adoption_events(user_id, created_at DESC) WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_adoption_family_shared_time "
        "ON adoption_events(family_id, module, created_at DESC) WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_adoption_retention "
        "ON adoption_events(created_at) WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_adoption_owner_interaction_time "
        "ON adoption_events(user_id, event_kind, created_at DESC) "
        "WHERE deleted_at IS NULL"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_adoption_owner_workflow_time "
        "ON adoption_events(user_id, workflow, created_at DESC) "
        "WHERE deleted_at IS NULL AND workflow IS NOT NULL"
    )

    # Builds before the opt-in boundary recorded events when no preference row
    # existed. Soft-delete those legacy facts once; only an explicit true setting
    # is valid consent for retained or future collection.
    consent_migration_at = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE adoption_events SET deleted_at = ?, updated_at = ? "
        "WHERE deleted_at IS NULL AND NOT EXISTS ("
        "SELECT 1 FROM family_settings "
        "WHERE family_settings.family_id = adoption_events.family_id "
        "AND family_settings.setting_key = 'usage_history:' || adoption_events.user_id "
        "AND LOWER(TRIM(family_settings.setting_value)) IN ('true', '1')"
        ")",
        (consent_migration_at, consent_migration_at),
    )
    await db.commit()

    # Library loan tasks retain completion independently from the upstream
    # read-only catalogue. New installs receive these columns from schema.sql.
    cursor = await db.execute("PRAGMA table_info(library_loans)")
    library_loan_cols = {row[1] for row in await cursor.fetchall()}
    for column in ("task_completed_at", "task_completed_by"):
        if column not in library_loan_cols:
            await db.execute(f"ALTER TABLE library_loans ADD COLUMN {column} TEXT")
    await db.commit()

    # Existing term rows gain their generated boundary events on first startup;
    # subsequent startups are no-ops unless a previous write was interrupted.
    from app.services.term_calendar import reconcile_term_boundary_events

    await reconcile_term_boundary_events(db, actor_id="term-calendar-migration")
    await db.commit()

    if run_one_time_repairs:
        await db.execute(f"PRAGMA user_version = {_ONE_TIME_REPAIR_VERSION}")
    await db.commit()

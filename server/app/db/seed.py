"""Create a deterministic, wholly fictional local demo household."""

import asyncio
import os
from datetime import datetime, timedelta, timezone

import aiosqlite

from app.auth import hash_password
from app.config import settings
from app.database import get_db_path, init_db

EXAMPLE_FAMILY_ID = "10000000-0000-4000-8000-000000000001"
PRIMARY_ADULT_ID = "10000000-0000-4000-8000-000000000002"
SECONDARY_ADULT_ID = "10000000-0000-4000-8000-000000000003"
CHILD_ONE_ID = "10000000-0000-4000-8000-000000000004"
CHILD_TWO_ID = "10000000-0000-4000-8000-000000000005"


def _timestamp(offset_days: int = 0, hour: int = 9) -> str:
    anchor = datetime(2030, 1, 15, hour, tzinfo=timezone.utc) + timedelta(days=offset_days)
    return anchor.isoformat().replace("+00:00", "Z")


async def seed() -> None:
    if settings.app_env.strip().lower() not in {"development", "demo"}:
        raise RuntimeError("The fictional demo seed is available only in development or demo mode")
    password = os.environ.get("DEMO_PASSWORD", "")
    if len(password) < 12:
        raise RuntimeError("DEMO_PASSWORD must contain at least 12 characters")

    db_path = get_db_path()
    await init_db(db_path)
    now = _timestamp()
    db = await aiosqlite.connect(db_path)
    try:
        rows = await (await db.execute("SELECT id FROM families WHERE deleted_at IS NULL")).fetchall()
        if rows and any(row[0] != EXAMPLE_FAMILY_ID for row in rows):
            raise RuntimeError("Refusing to seed a database containing a non-demo family")
        await db.execute("BEGIN")
        await db.execute(
            "INSERT OR IGNORE INTO families (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
            (EXAMPLE_FAMILY_ID, "Example Household", now, now),
        )
        password_hash = hash_password(password)
        for user_id, name, email, role, priority in [
            (PRIMARY_ADULT_ID, "Alex Example", "adult-a@example.invalid", "admin", 5),
            (SECONDARY_ADULT_ID, "Morgan Example", "adult-b@example.invalid", "user", 10),
        ]:
            await db.execute(
                "INSERT OR IGNORE INTO users (id, name, email, password_hash, role, priority, family_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (user_id, name, email, password_hash, role, priority, EXAMPLE_FAMILY_ID, now, now),
            )
        for child_id, name, dob in [
            (CHILD_ONE_ID, "Child One", "2022-04-12"),
            (CHILD_TWO_ID, "Child Two", "2024-08-03"),
        ]:
            await db.execute(
                "INSERT OR IGNORE INTO children (id, name, date_of_birth, notes, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (child_id, name, dob, "Fictional demo profile", EXAMPLE_FAMILY_ID, now, now, PRIMARY_ADULT_ID),
            )
        for event_id, title, start, end, assigned in [
            ("20000000-0000-4000-8000-000000000001", "Library visit", _timestamp(0, 16), _timestamp(0, 17), SECONDARY_ADULT_ID),
            ("20000000-0000-4000-8000-000000000002", "Family picnic", _timestamp(2, 12), _timestamp(2, 14), PRIMARY_ADULT_ID),
        ]:
            await db.execute(
                "INSERT OR IGNORE INTO calendar_events (id, title, start_time, end_time, assigned_to, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (event_id, title, start, end, assigned, EXAMPLE_FAMILY_ID, now, now, PRIMARY_ADULT_ID),
            )
        for task_id, title, assigned, category in [
            ("30000000-0000-4000-8000-000000000001", "Return library books", SECONDARY_ADULT_ID, "admin"),
            ("30000000-0000-4000-8000-000000000002", "Pack picnic blanket", PRIMARY_ADULT_ID, "household"),
        ]:
            await db.execute(
                "INSERT OR IGNORE INTO tasks (id, title, assigned_to, due_date, category, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (task_id, title, assigned, _timestamp(1), category, EXAMPLE_FAMILY_ID, now, now, PRIMARY_ADULT_ID),
            )
        await db.execute(
            "INSERT OR IGNORE INTO meals (id, name, description, tags, ingredients, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("40000000-0000-4000-8000-000000000001", "Riley pasta", "Simple fictional demo meal", '["quick"]', '[{"name":"pasta","quantity":"1 pack","category":"pantry"}]', EXAMPLE_FAMILY_ID, now, now, PRIMARY_ADULT_ID),
        )
        await db.execute(
            "INSERT OR IGNORE INTO shopping_items (id, name, quantity, category, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("60000000-0000-4000-8000-000000000001", "Oat milk", "1 carton", "grocery", EXAMPLE_FAMILY_ID, now, now, SECONDARY_ADULT_ID),
        )
        for item_id, name, category in [
            ("61000000-0000-4000-8000-000000000001", "Pasta", "pantry"),
            ("61000000-0000-4000-8000-000000000002", "Apples", "produce"),
        ]:
            await db.execute(
                "INSERT OR IGNORE INTO grocery_items (id, name, category, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (item_id, name, category, EXAMPLE_FAMILY_ID, now, now, PRIMARY_ADULT_ID),
            )
        await db.execute(
            "INSERT OR IGNORE INTO routine_items (id, person_id, name, color, days_of_week, time_of_day, term_only, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)",
            ("62000000-0000-4000-8000-000000000001", CHILD_ONE_ID, "Pack reading book", "#4F7668", "[0,1,2,3,4]", "08:00", EXAMPLE_FAMILY_ID, now, now, PRIMARY_ADULT_ID),
        )
        await db.execute(
            "INSERT OR IGNORE INTO dog_profiles (id, name, breed, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("63000000-0000-4000-8000-000000000001", "Pixel", "Fictional mixed breed", EXAMPLE_FAMILY_ID, now, now, PRIMARY_ADULT_ID),
        )
        document_id = "64000000-0000-4000-8000-000000000001"
        await db.execute(
            "INSERT OR IGNORE INTO documents (id, title, original_filename, media_type, storage_key, file_size, sha256, source, category, status, extracted_text, notes, family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, 'text', 'household', 'filed', ?, ?, ?, ?, ?, ?)",
            (document_id, "Community event note", "fictional-demo-note.txt", "text/plain", "demo/fictional-demo-note.txt", 24, "0000000000000000000000000000000000000000000000000000000000000000", "Fictional content for the public demo.", "No external file or OCR source.", EXAMPLE_FAMILY_ID, now, now, PRIMARY_ADULT_ID),
        )
        await db.execute(
            "UPDATE tasks SET source_document_id = ? WHERE id = ? AND family_id = ?",
            (document_id, "30000000-0000-4000-8000-000000000002", EXAMPLE_FAMILY_ID),
        )
        await db.commit()
        print("Fictional demo data is ready for adult-a@example.invalid")
    except Exception:
        await db.rollback()
        raise
    finally:
        await db.close()


if __name__ == "__main__":
    asyncio.run(seed())

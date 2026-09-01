import json
import uuid
from datetime import datetime, timezone


async def save_history(
    db,
    table_name: str,
    record_id: str,
    changed_by: str,
    *,
    family_id: str,
    excluded_fields: set[str] | None = None,
) -> None:
    """Capture the current state of a record before it is modified.

    Inserts a snapshot of the row into record_history so that every UPDATE
    and DELETE has a recoverable audit trail.
    """
    if not family_id:
        raise ValueError("Record history requires a family_id")
    cursor = await db.execute(
        f"SELECT * FROM {table_name} WHERE id = ? AND family_id = ?",
        (record_id, family_id),
    )
    row = await cursor.fetchone()

    if row is None:
        # Nothing to capture — the record does not exist yet.
        return

    previous_values = dict(row)
    for field in excluded_fields or set():
        previous_values.pop(field, None)
    previous_values = json.dumps(previous_values)

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO record_history (id, table_name, record_id, previous_values, changed_by, changed_at, family_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            table_name,
            record_id,
            previous_values,
            changed_by,
            now,
            family_id,
        ),
    )

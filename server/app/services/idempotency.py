"""Shared transaction and replay checks for client-generated create IDs."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager


IDEMPOTENT_CREATE_TABLES = frozenset(
    {
        "calendar_events",
        "cycle_period_starts",
        "cycle_settings",
        "tasks",
        "medicine_types",
        "medicine_doses",
        "naps",
        "shopping_items",
    }
)


class CreateReplayConflictError(ValueError):
    """A client-generated record ID was reused for a different operation."""


@asynccontextmanager
async def serialized_create(db) -> AsyncIterator[None]:
    """Serialize a direct create; reuse the enclosing sync transaction if present."""
    owns_transaction = not db.in_transaction
    if owns_transaction:
        await db.execute("BEGIN IMMEDIATE")
    try:
        yield
        if owns_transaction:
            await db.commit()
    except BaseException:
        if owns_transaction and db.in_transaction:
            await db.rollback()
        raise


async def existing_create_row(
    db,
    *,
    table_name: str,
    record_id: str,
    family_id: str,
    user_id: str,
):
    """Return an owned active row, rejecting cross-user or tombstoned ID reuse."""
    if table_name not in IDEMPOTENT_CREATE_TABLES:
        raise ValueError("Create replay table is not supported")
    cursor = await db.execute(
        f"SELECT * FROM {table_name} WHERE id = ?",
        (record_id,),
    )
    row = await cursor.fetchone()
    if row is None:
        return None
    if (
        row["family_id"] != family_id
        or row["created_by"] != user_id
        or row["deleted_at"] is not None
    ):
        raise CreateReplayConflictError(
            "Create operation ID was already used for a different request"
        )
    return row


def reject_create_mismatch(matches: bool) -> None:
    if not matches:
        raise CreateReplayConflictError(
            "Create operation ID was already used for a different request"
        )

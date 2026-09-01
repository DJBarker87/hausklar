"""Finance spaces and household settings."""

import uuid
from datetime import datetime, timezone

from app.models.finance import FinanceSettingsResponse, FinanceSpaceResponse
from app.services.finance.dates import DEFAULT_HOUSEHOLD_TIMEZONE, household_zone
from app.services.idempotency import serialized_create

DEFAULT_CURRENCY = "GBP"


class FinanceAccessDeniedError(PermissionError):
    """The authenticated account is not attached to an active family."""


class FinanceScopeError(ValueError):
    """The requested Finance view does not match the authenticated adult's spaces."""


def require_finance_access(user: dict) -> None:
    """Require the family boundary used by every Finance space."""
    if not user.get("family_id"):
        raise FinanceAccessDeniedError("Finance requires an active family account")


async def require_finance_space(db, *, user: dict, space_id: str) -> dict:
    """Return an allowed space without revealing whether any other space exists."""
    require_finance_access(user)

    async def visible_space():
        return await (
            await db.execute(
                """
                SELECT * FROM finance_spaces
                WHERE id = ? AND family_id = ? AND deleted_at IS NULL
                  AND (
                      (kind = 'personal' AND owner_user_id = ?)
                      OR (kind = 'household' AND owner_user_id IS NULL)
                  )
                """,
                (space_id, user["family_id"], user["id"]),
            )
        ).fetchone()

    # Established families take the ordinary read-only path. Lazy foundation
    # creation is retained for first use, but a missing/guessed space is the
    # only case that may need to enter the serialized initializer.
    row = await visible_space()
    if row is None:
        await _ensure_finance_rows(db, user=user)
        row = await visible_space()
    if row is None:
        raise FinanceAccessDeniedError("Finance space is not available")
    return dict(row)


async def _ensure_finance_rows(db, *, user: dict) -> None:
    require_finance_access(user)
    user_id = user["id"]
    family_id = user["family_id"]
    now = datetime.now(timezone.utc).isoformat()

    async def foundation_ids():
        return await (
            await db.execute(
                """
                SELECT
                    (SELECT id FROM finance_spaces
                     WHERE kind = 'personal' AND owner_user_id = ?
                       AND family_id = ? AND deleted_at IS NULL) AS personal_id,
                    (SELECT id FROM finance_spaces
                     WHERE kind = 'household' AND family_id = ?
                       AND deleted_at IS NULL) AS household_id,
                    (SELECT id FROM finance_settings
                     WHERE family_id = ? AND deleted_at IS NULL) AS settings_id
                """,
                (user_id, family_id, family_id, family_id),
            )
        ).fetchone()

    # Do not acquire SQLite's RESERVED writer lock for the overwhelmingly
    # common case where first-use provisioning has already completed.
    existing = await foundation_ids()
    if all(existing[key] is not None for key in ("personal_id", "household_id", "settings_id")):
        return

    async with serialized_create(db):
        # Recheck under the writer lock so concurrent first-use requests remain
        # idempotent without relying on catching uniqueness errors.
        existing = await foundation_ids()
        if existing["personal_id"] is None:
            await db.execute(
                """
                INSERT INTO finance_spaces
                    (id, kind, owner_user_id, family_id, created_at, updated_at, created_by)
                VALUES (?, 'personal', ?, ?, ?, ?, ?)
                """,
                (str(uuid.uuid4()), user_id, family_id, now, now, user_id),
            )

        if existing["household_id"] is None:
            await db.execute(
                """
                INSERT INTO finance_spaces
                    (id, kind, owner_user_id, family_id, created_at, updated_at, created_by)
                VALUES (?, 'household', NULL, ?, ?, ?, ?)
                """,
                (str(uuid.uuid4()), family_id, now, now, user_id),
            )

        if existing["settings_id"] is None:
            await db.execute(
                """
                INSERT INTO finance_settings
                    (id, household_timezone, default_currency, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    DEFAULT_HOUSEHOLD_TIMEZONE,
                    DEFAULT_CURRENCY,
                    family_id,
                    now,
                    now,
                    user_id,
                ),
            )


async def accessible_finance_spaces(db, *, user: dict) -> list[FinanceSpaceResponse]:
    """Return only the caller's personal space and their household space."""
    require_finance_access(user)

    async def visible_spaces():
        return await (
            await db.execute(
                """
                SELECT id, kind
                FROM finance_spaces
                WHERE family_id = ? AND deleted_at IS NULL
                  AND (
                      (kind = 'personal' AND owner_user_id = ?)
                      OR (kind = 'household' AND owner_user_id IS NULL)
                  )
                ORDER BY CASE kind WHEN 'personal' THEN 0 ELSE 1 END, id
                """,
                (user["family_id"], user["id"]),
            )
        ).fetchall()

    rows = await visible_spaces()
    if {row["kind"] for row in rows} != {"personal", "household"}:
        await _ensure_finance_rows(db, user=user)
        rows = await visible_spaces()
    return [
        FinanceSpaceResponse(
            id=row["id"],
            kind=row["kind"],
            name="My finances" if row["kind"] == "personal" else "Household",
            is_default=row["kind"] == "personal",
        )
        for row in rows
    ]


async def resolve_finance_scope_spaces(
    db,
    *,
    user: dict,
    scope: str,
    selected_space_id: str | None = None,
) -> tuple[str, ...]:
    """Bind a named Finance view to spaces derived from the authenticated user.

    ``mine`` is a visibility view over the caller's personal records and the
    household records.  It is deliberately not a pooled planning scope: callers
    that calculate safe-to-spend, goals, reserves or budgets must continue to
    calculate each returned space separately.  ``household`` contains only the
    household space.  A supplied space ID is validated as a view selector, never
    used as authority.
    """
    spaces = await accessible_finance_spaces(db, user=user)
    personal = next((space for space in spaces if space.kind == "personal"), None)
    household = next((space for space in spaces if space.kind == "household"), None)
    if personal is None or household is None:
        raise FinanceScopeError("Finance spaces are incomplete")

    if scope == "mine":
        if selected_space_id is not None and selected_space_id != personal.id:
            raise FinanceScopeError("My finances requires the caller's personal space")
        return personal.id, household.id
    if scope == "household":
        if selected_space_id is not None and selected_space_id != household.id:
            raise FinanceScopeError("Household requires the household space")
        return (household.id,)
    raise FinanceScopeError("Finance scope is invalid")


async def get_finance_settings(db, *, user: dict) -> FinanceSettingsResponse:
    """Return shared household defaults and only the caller-visible space IDs."""
    require_finance_access(user)

    async def settings_rows():
        row = await (
            await db.execute(
                """
                SELECT id, household_timezone, default_currency, created_at, updated_at
                FROM finance_settings
                WHERE family_id = ? AND deleted_at IS NULL
                """,
                (user["family_id"],),
            )
        ).fetchone()
        personal = await (
            await db.execute(
                """
                SELECT id FROM finance_spaces
                WHERE family_id = ? AND kind = 'personal' AND owner_user_id = ?
                  AND deleted_at IS NULL
                """,
                (user["family_id"], user["id"]),
            )
        ).fetchone()
        household = await (
            await db.execute(
                """
                SELECT id FROM finance_spaces
                WHERE family_id = ? AND kind = 'household' AND owner_user_id IS NULL
                  AND deleted_at IS NULL
                """,
                (user["family_id"],),
            )
        ).fetchone()
        return row, personal, household

    row, personal, household = await settings_rows()
    if row is None or personal is None or household is None:
        await _ensure_finance_rows(db, user=user)
        row, personal, household = await settings_rows()
    if row is None or personal is None or household is None:
        raise RuntimeError("Finance foundation records are incomplete")

    # Fail closed if an invalid IANA timezone somehow reaches persisted data.
    household_zone(row["household_timezone"])
    return FinanceSettingsResponse(
        id=row["id"],
        household_timezone=row["household_timezone"],
        default_currency=row["default_currency"],
        personal_space_id=personal["id"],
        household_space_id=household["id"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )

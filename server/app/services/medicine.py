"""Medicine safety logic — SAFETY-CRITICAL module.

All time calculations use given_at (actual administration time), never created_at.
Backdated doses are validated against doses that existed in the relevant time window.
Warnings are always returned, never silently blocked.
"""

import json
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone

from app.models.medicine import MedicineDoseCreate, SafetyWarning
from app.services.family_people import family_child_exists


class MedicineDoseError(ValueError):
    """Base class for a rejected medicine dose write."""


class MedicineDoseNotFoundError(MedicineDoseError):
    """The requested medicine type does not exist in this family."""


class MedicineDoseConflictError(MedicineDoseError):
    """A client operation UUID was reused for a different write."""


def normalise_dose_timestamp(value: str | datetime) -> datetime:
    """Return a dose candidate as a timezone-aware UTC datetime."""
    if isinstance(value, datetime):
        parsed = value
    else:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


async def check_dose_safety(
    db,
    medicine_type_id: str,
    child_id: str,
    given_at: str | datetime,
    family_id: str | None = None,
    exclude_dose_id: str | None = None,
) -> tuple[bool, list[SafetyWarning]]:
    """Check whether a proposed dose is safe to administer.

    Returns (is_safe, warnings) where is_safe is True only when warnings is empty.

    Safety checks performed:
    1. "too_soon" — Is the proposed given_at less than min_hours_between_doses
       after the most recent prior dose (by given_at) for this medicine+child?
    2. "max_reached" — Have max_doses_24h doses already been recorded in the
       24-hour rolling window ending at the proposed given_at?
    """
    # ------------------------------------------------------------------
    # Fetch the medicine type configuration
    # ------------------------------------------------------------------
    family_filter = " AND family_id = ?" if family_id else ""
    exclusion_filter = " AND id != ?" if exclude_dose_id else ""

    def dose_query_params(*values: object) -> tuple[object, ...]:
        params = list(values)
        if family_id:
            params.append(family_id)
        if exclude_dose_id:
            params.append(exclude_dose_id)
        return tuple(params)

    cursor = await db.execute(
        "SELECT min_hours_between_doses, max_doses_24h "
        f"FROM medicine_types WHERE id = ? AND deleted_at IS NULL{family_filter}",
        (medicine_type_id, family_id) if family_id else (medicine_type_id,),
    )
    med_type = await cursor.fetchone()
    if med_type is None:
        # If the medicine type doesn't exist we can't check safety — caller
        # should handle with a 404 before reaching here, but be defensive.
        return (True, [])

    min_hours = med_type["min_hours_between_doses"]
    max_doses = med_type["max_doses_24h"]

    # Fetch once; the deterministic evaluator below performs all previous,
    # next and rolling-window checks without three additional round trips.
    cursor = await db.execute(
        f"""
        SELECT given_at FROM medicine_doses
        WHERE medicine_type_id = ?
          AND child_id = ?
          AND deleted_at IS NULL
          {family_filter}
          {exclusion_filter}
        """,
        dose_query_params(medicine_type_id, child_id),
    )
    return evaluate_dose_safety(
        min_hours_between_doses=min_hours,
        max_doses_24h=max_doses,
        existing_given_at=(row["given_at"] for row in await cursor.fetchall()),
        given_at=given_at,
    )


def evaluate_dose_safety(
    *,
    min_hours_between_doses: float,
    max_doses_24h: int,
    existing_given_at: Iterable[str | datetime],
    given_at: str | datetime,
) -> tuple[bool, list[SafetyWarning]]:
    """Evaluate the canonical medicine rules over already-loaded dose times."""
    warnings: list[SafetyWarning] = []
    proposed_at = normalise_dose_timestamp(given_at)
    doses: list[datetime] = []
    for value in existing_given_at:
        try:
            doses.append(normalise_dose_timestamp(value))
        except (AttributeError, TypeError, ValueError):
            continue
    doses.sort()

    # Including an equal timestamp ensures distinct simultaneous writes still
    # warn, while an idempotent replay is removed by the caller's exclusion.
    previous = [dose for dose in doses if dose <= proposed_at]
    if previous:
        last_given = previous[-1]
        hours_since = (proposed_at - last_given).total_seconds() / 3600.0
        if hours_since < min_hours_between_doses:
            next_safe = last_given + timedelta(hours=min_hours_between_doses)
            warnings.append(
                SafetyWarning(
                    type="too_soon",
                    message=(
                        f"Only {hours_since:.1f}h since last dose. Minimum interval is "
                        f"{min_hours_between_doses}h."
                    ),
                    next_safe_at=next_safe.isoformat(),
                )
            )

    following = [dose for dose in doses if dose > proposed_at]
    if following:
        next_given = following[0]
        hours_until_next = (next_given - proposed_at).total_seconds() / 3600.0
        if hours_until_next < min_hours_between_doses:
            # Only add if we haven't already flagged too_soon from the
            # previous-dose direction.
            already_flagged = any(w.type == "too_soon" for w in warnings)
            if not already_flagged:
                next_safe = proposed_at + timedelta(hours=min_hours_between_doses)
                warnings.append(
                    SafetyWarning(
                        type="too_soon",
                        message=(
                            f"A dose already exists {hours_until_next:.1f}h after "
                            f"this time. Minimum interval is {min_hours_between_doses}h."
                        ),
                        next_safe_at=next_safe.isoformat(),
                    )
                )

    # ------------------------------------------------------------------
    # 2. "Child One reached" check — every rolling 24-hour window containing
    # the proposed dose. Looking only backwards misses a backdated dose that
    # bridges earlier and later records into an over-limit window.
    # ------------------------------------------------------------------
    nearby_doses: list[datetime] = []
    lower_bound = proposed_at - timedelta(hours=24)
    upper_bound = proposed_at + timedelta(hours=24)
    for dose_time in doses:
        if lower_bound <= dose_time <= upper_bound:
            nearby_doses.append(dose_time)

    candidate_window_ends = [proposed_at]
    candidate_window_ends.extend(
        dose_time for dose_time in nearby_doses if proposed_at <= dose_time <= upper_bound
    )
    count = max(
        sum(
            window_end - timedelta(hours=24) <= dose_time <= window_end
            for dose_time in nearby_doses
        )
        for window_end in candidate_window_ends
    )

    if count >= max_doses_24h:
        warnings.append(
            SafetyWarning(
                type="max_reached",
                message=(
                    f"A 24-hour window containing this dose already has {count} dose(s). "
                    f"Maximum is {max_doses_24h}."
                ),
                next_safe_at=None,
            )
        )

    is_safe = len(warnings) == 0
    return (is_safe, warnings)


def _is_exact_replay(
    row,
    body: MedicineDoseCreate,
    *,
    family_id: str,
    user_id: str,
) -> bool:
    return (
        row["family_id"] == family_id
        and row["created_by"] == user_id
        and row["deleted_at"] is None
        and row["medicine_type_id"] == body.medicine_type_id
        and row["child_id"] == body.child_id
        and row["given_at"] == body.given_at
        and row["dose_amount"] == body.dose_amount
        and row["medicine_name"] == body.medicine_name
        and row["notes"] == body.notes
    )


async def _warnings_for_replay(
    db,
    row,
    *,
    family_id: str,
) -> list[SafetyWarning]:
    stored = row["safety_warnings_json"]
    if stored is not None:
        try:
            decoded = json.loads(stored)
            return [SafetyWarning.model_validate(item) for item in decoded]
        except (TypeError, ValueError):
            # Rows written before warning snapshots were introduced are handled
            # by the same safety calculation, excluding the replayed row.
            pass
    if row["medicine_type_id"] is None:
        return []
    _is_safe, warnings = await check_dose_safety(
        db,
        row["medicine_type_id"],
        row["child_id"],
        row["given_at"],
        family_id=family_id,
        exclude_dose_id=row["id"],
    )
    return warnings


async def create_or_replay_medicine_dose(
    db,
    body: MedicineDoseCreate,
    *,
    dose_id: str,
    user: dict,
    client_id: str | None,
    client_timestamp: str | None,
) -> tuple[dict, list[SafetyWarning], bool]:
    """Atomically safety-check and insert a dose, or return an exact replay.

    A new direct API write starts an IMMEDIATE transaction here. Sync starts the
    same transaction before its item savepoints, so direct and offline writes
    cannot both safety-check against the same stale snapshot.
    """
    if not body.medicine_type_id and not body.medicine_name:
        raise MedicineDoseError("Either medicine_type_id or medicine_name is required")

    family_id = user.get("family_id")
    user_id = user.get("id")
    if not family_id or not user_id:
        raise MedicineDoseError("A family and user are required")

    owns_transaction = not db.in_transaction
    if owns_transaction:
        await db.execute("BEGIN IMMEDIATE")

    try:
        cursor = await db.execute(
            "SELECT * FROM medicine_doses WHERE id = ?",
            (dose_id,),
        )
        existing = await cursor.fetchone()
        if existing is not None:
            if not _is_exact_replay(
                existing,
                body,
                family_id=family_id,
                user_id=user_id,
            ):
                raise MedicineDoseConflictError(
                    "Dose operation ID was already used for a different request"
                )
            warnings = await _warnings_for_replay(
                db,
                existing,
                family_id=family_id,
            )
            result = (dict(existing), warnings, True)
        else:
            if not await family_child_exists(db, family_id, body.child_id):
                raise MedicineDoseError("Child is not in this family")

            warnings: list[SafetyWarning] = []
            if body.medicine_type_id:
                cursor = await db.execute(
                    """
                    SELECT id, child_id FROM medicine_types
                    WHERE id = ? AND deleted_at IS NULL AND family_id = ?
                    """,
                    (body.medicine_type_id, family_id),
                )
                medicine_type = await cursor.fetchone()
                if medicine_type is None:
                    raise MedicineDoseNotFoundError("Medicine type not found")
                if medicine_type["child_id"] != body.child_id:
                    raise MedicineDoseError(
                        "Medicine type does not belong to this child"
                    )
                _is_safe, warnings = await check_dose_safety(
                    db,
                    body.medicine_type_id,
                    body.child_id,
                    body.given_at,
                    family_id=family_id,
                )

            now = datetime.now(timezone.utc).isoformat()
            warning_snapshot = json.dumps(
                [warning.model_dump(mode="json") for warning in warnings],
                separators=(",", ":"),
            )
            await db.execute(
                """
                INSERT INTO medicine_doses
                    (id, medicine_type_id, child_id, given_at, given_by,
                     dose_amount, medicine_name, notes, family_id, created_at,
                     updated_at, created_by, client_id, client_timestamp,
                     safety_warnings_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    dose_id,
                    body.medicine_type_id,
                    body.child_id,
                    body.given_at,
                    user["name"],
                    body.dose_amount,
                    body.medicine_name,
                    body.notes,
                    family_id,
                    now,
                    now,
                    user_id,
                    client_id,
                    client_timestamp,
                    warning_snapshot,
                ),
            )
            cursor = await db.execute(
                "SELECT * FROM medicine_doses WHERE id = ?",
                (dose_id,),
            )
            created = await cursor.fetchone()
            if created is None:
                raise RuntimeError("Medicine dose insert did not return a row")
            result = (dict(created), warnings, False)

        if owns_transaction:
            await db.commit()
        return result
    except BaseException:
        if owns_transaction and db.in_transaction:
            await db.rollback()
        raise

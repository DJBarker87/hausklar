"""Persisted Finance knowledge, commitments, goals, and forecast snapshots."""

import hashlib
import json
import uuid
from dataclasses import asdict
from datetime import date, datetime, timezone

from app.models.finance import (
    FinanceCommitmentCreate,
    FinanceCommitmentResponse,
    FinanceCommitmentUpdate,
    FinanceFactCreate,
    FinanceFactResponse,
    FinanceFactUpdate,
    FinanceForecastAccountDayResponse,
    FinanceForecastDayResponse,
    FinanceForecastEventResponse,
    FinanceForecastGenerate,
    FinanceForecastOverviewDayResponse,
    FinanceForecastOverviewResponse,
    FinanceForecastResponse,
    FinanceGoalCreate,
    FinanceGoalResponse,
    FinanceGoalUpdate,
    FinancePreferenceCreate,
    FinancePreferenceResponse,
    FinancePreferenceUpdate,
    FinanceReserveCreate,
    FinanceReserveResponse,
    FinanceReserveUpdate,
)
from app.services.finance.forecast import (
    canonical_snapshot_json,
    run_forecast,
)
from app.services.finance.foundation import (
    require_finance_access,
    require_finance_space,
)
from app.services.finance.saved_forecast import build_saved_forecast
from app.services.idempotency import serialized_create
from app.services.record_history import save_history


class FinancePlanningError(ValueError):
    """Base class for safe planning failures."""


class FinancePlanningNotFoundError(FinancePlanningError):
    """An authorized planning record was not found."""


class FinancePlanningConflictError(FinancePlanningError):
    """A planning write conflicts with an existing logical record."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json_list(values: list[str]) -> str:
    return json.dumps(values, separators=(",", ":"), ensure_ascii=True)


async def _authorised_row(db, *, table: str, record_id: str, user: dict):
    if table not in {
        "finance_facts",
        "finance_preferences",
        "finance_commitments",
        "finance_reserves",
        "finance_goals",
        "finance_forecast_snapshots",
    }:
        raise ValueError("Unsupported Finance planning table")
    require_finance_access(user)
    row = await (
        await db.execute(
            f"""
            SELECT record.* FROM {table} record
            JOIN finance_spaces space
              ON space.id = record.space_id
             AND space.family_id = record.family_id
             AND space.deleted_at IS NULL
            WHERE record.id = ? AND record.family_id = ? AND record.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            """,
            (record_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinancePlanningNotFoundError("Finance planning record not found")
    return dict(row)


async def _validate_account_ids(
    db,
    *,
    space_id: str,
    family_id: str,
    account_ids: list[str],
    currency: str | None = None,
) -> None:
    unique_ids = set(account_ids)
    if not unique_ids:
        return
    placeholders = ",".join("?" for _ in unique_ids)
    rows = await (
        await db.execute(
            f"""
            SELECT id, currency FROM finance_accounts
            WHERE id IN ({placeholders}) AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            """,
            [*sorted(unique_ids), space_id, family_id],
        )
    ).fetchall()
    if {row["id"] for row in rows} != unique_ids:
        raise FinancePlanningNotFoundError("Finance funding account not found")
    if currency is not None and any(row["currency"] != currency for row in rows):
        raise FinancePlanningError("Finance funding accounts must use the record currency")


def _fact_response(row: dict) -> FinanceFactResponse:
    return FinanceFactResponse(
        id=row["id"],
        space_id=row["space_id"],
        fact_key=row["fact_key"],
        version=row["version"],
        statement=row["statement"],
        evidence_refs=json.loads(row["evidence_json"]),
        status=row["status"],
        supersedes_id=row["supersedes_id"],
        confirmed_at=row["confirmed_at"],
        expired_at=row["expired_at"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def _preference_response(row: dict) -> FinancePreferenceResponse:
    return FinancePreferenceResponse(
        id=row["id"],
        space_id=row["space_id"],
        preference_key=row["preference_key"],
        version=row["version"],
        statement=row["statement"],
        value_kind=row["value_kind"],
        evidence_refs=json.loads(row["evidence_json"]),
        status=row["status"],
        supersedes_id=row["supersedes_id"],
        confirmed_at=row["confirmed_at"],
        expired_at=row["expired_at"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


async def _create_knowledge(
    db,
    *,
    user: dict,
    space_id: str,
    table: str,
    key_column: str,
    key: str,
    statement: str,
    evidence_refs: list[str],
    value_kind: str | None = None,
):
    await require_finance_space(db, user=user, space_id=space_id)
    existing = await (
        await db.execute(
            f"""
            SELECT id FROM {table}
            WHERE space_id = ? AND {key_column} = ? AND status <> 'EXPIRED'
              AND deleted_at IS NULL
            ORDER BY version DESC LIMIT 1
            """,
            (space_id, key),
        )
    ).fetchone()
    if existing is not None:
        raise FinancePlanningConflictError("Use the update route to create a new version")
    version_row = await (
        await db.execute(
            f"SELECT COALESCE(MAX(version), 0) FROM {table} WHERE space_id = ? AND {key_column} = ?",
            (space_id, key),
        )
    ).fetchone()
    version = version_row[0] + 1
    identifier = str(uuid.uuid4())
    now = _now()
    columns = (
        f"id, space_id, {key_column}, version, statement, evidence_json, status, "
        "family_id, created_at, updated_at, created_by"
    )
    values: list[object] = [
        identifier,
        space_id,
        key,
        version,
        statement,
        _json_list(evidence_refs),
        "PROPOSED",
        user["family_id"],
        now,
        now,
        user["id"],
    ]
    placeholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"
    if value_kind is not None:
        columns += ", value_kind"
        placeholders += ", ?"
        values.append(value_kind)
    async with serialized_create(db):
        await db.execute(
            f"INSERT INTO {table} ({columns}) VALUES ({placeholders})",
            values,
        )
    row = await (await db.execute(f"SELECT * FROM {table} WHERE id = ?", (identifier,))).fetchone()
    return dict(row)


async def create_fact(
    db, *, user: dict, space_id: str, body: FinanceFactCreate
) -> FinanceFactResponse:
    row = await _create_knowledge(
        db,
        user=user,
        space_id=space_id,
        table="finance_facts",
        key_column="fact_key",
        key=body.fact_key,
        statement=body.statement,
        evidence_refs=body.evidence_refs,
    )
    return _fact_response(row)


async def create_preference(
    db, *, user: dict, space_id: str, body: FinancePreferenceCreate
) -> FinancePreferenceResponse:
    row = await _create_knowledge(
        db,
        user=user,
        space_id=space_id,
        table="finance_preferences",
        key_column="preference_key",
        key=body.preference_key,
        statement=body.statement,
        evidence_refs=body.evidence_refs,
        value_kind=body.value_kind,
    )
    return _preference_response(row)


async def _update_knowledge(
    db,
    *,
    user: dict,
    table: str,
    key_column: str,
    record_id: str,
    statement: str,
    evidence_refs: list[str],
    value_kind: str | None = None,
):
    previous = await _authorised_row(db, table=table, record_id=record_id, user=user)
    latest = await (
        await db.execute(
            f"SELECT MAX(version) FROM {table} WHERE space_id = ? AND {key_column} = ?",
            (previous["space_id"], previous[key_column]),
        )
    ).fetchone()
    if previous["version"] != latest[0]:
        raise FinancePlanningConflictError("Only the latest knowledge version can be updated")
    identifier = str(uuid.uuid4())
    now = _now()
    columns = (
        f"id, space_id, {key_column}, version, statement, evidence_json, status, "
        "supersedes_id, family_id, created_at, updated_at, created_by"
    )
    values: list[object] = [
        identifier,
        previous["space_id"],
        previous[key_column],
        previous["version"] + 1,
        statement,
        _json_list(evidence_refs),
        "PROPOSED",
        previous["id"],
        user["family_id"],
        now,
        now,
        user["id"],
    ]
    placeholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"
    if value_kind is not None:
        columns += ", value_kind"
        placeholders += ", ?"
        values.append(value_kind)
    async with serialized_create(db):
        await save_history(
            db,
            table,
            previous["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            f"""
            UPDATE {table} SET status = 'EXPIRED', expired_at = ?, updated_at = ?
            WHERE id = ? AND space_id = ? AND deleted_at IS NULL
            """,
            (now, now, previous["id"], previous["space_id"]),
        )
        await db.execute(
            f"INSERT INTO {table} ({columns}) VALUES ({placeholders})",
            values,
        )
    row = await (await db.execute(f"SELECT * FROM {table} WHERE id = ?", (identifier,))).fetchone()
    return dict(row)


async def update_fact(
    db, *, user: dict, fact_id: str, body: FinanceFactUpdate
) -> FinanceFactResponse:
    return _fact_response(
        await _update_knowledge(
            db,
            user=user,
            table="finance_facts",
            key_column="fact_key",
            record_id=fact_id,
            statement=body.statement,
            evidence_refs=body.evidence_refs,
        )
    )


async def update_preference(
    db, *, user: dict, preference_id: str, body: FinancePreferenceUpdate
) -> FinancePreferenceResponse:
    return _preference_response(
        await _update_knowledge(
            db,
            user=user,
            table="finance_preferences",
            key_column="preference_key",
            record_id=preference_id,
            statement=body.statement,
            evidence_refs=body.evidence_refs,
            value_kind=body.value_kind,
        )
    )


async def _set_knowledge_status(
    db,
    *,
    user: dict,
    table: str,
    record_id: str,
    status: str,
):
    row = await _authorised_row(db, table=table, record_id=record_id, user=user)
    if row["status"] == "EXPIRED" and status != "EXPIRED":
        raise FinancePlanningConflictError("Expired knowledge cannot be reconfirmed")
    now = _now()
    async with serialized_create(db):
        await save_history(db, table, record_id, user["id"], family_id=user["family_id"])
        await db.execute(
            f"""
            UPDATE {table}
            SET status = ?, confirmed_at = CASE WHEN ? = 'CONFIRMED' THEN ? ELSE confirmed_at END,
                expired_at = CASE WHEN ? = 'EXPIRED' THEN ? ELSE expired_at END,
                updated_at = ?
            WHERE id = ? AND space_id = ? AND deleted_at IS NULL
            """,
            (status, status, now, status, now, now, record_id, row["space_id"]),
        )
    row.update(
        {
            "status": status,
            "confirmed_at": now if status == "CONFIRMED" else row["confirmed_at"],
            "expired_at": now if status == "EXPIRED" else row["expired_at"],
            "updated_at": now,
        }
    )
    return row


async def set_fact_status(db, *, user: dict, fact_id: str, status: str) -> FinanceFactResponse:
    return _fact_response(
        await _set_knowledge_status(
            db,
            user=user,
            table="finance_facts",
            record_id=fact_id,
            status=status,
        )
    )


async def set_preference_status(
    db, *, user: dict, preference_id: str, status: str
) -> FinancePreferenceResponse:
    return _preference_response(
        await _set_knowledge_status(
            db,
            user=user,
            table="finance_preferences",
            record_id=preference_id,
            status=status,
        )
    )


async def list_facts(
    db, *, user: dict, space_id: str, include_expired: bool
) -> list[FinanceFactResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_expired else "AND status <> 'EXPIRED'"
    rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_facts WHERE space_id = ? AND family_id = ?
              AND deleted_at IS NULL {clause}
            ORDER BY fact_key, version DESC
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_fact_response(dict(row)) for row in rows]


async def list_preferences(
    db, *, user: dict, space_id: str, include_expired: bool
) -> list[FinancePreferenceResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_expired else "AND status <> 'EXPIRED'"
    rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_preferences WHERE space_id = ? AND family_id = ?
              AND deleted_at IS NULL {clause}
            ORDER BY preference_key, version DESC
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_preference_response(dict(row)) for row in rows]


def _required_commitment_minor(row: dict) -> int:
    if row["amount_mode"] == "EXACT":
        return row["exact_minor"]
    if row["amount_mode"] == "RANGE":
        return row["high_minor"]
    return row["expected_minor"]


async def _validate_commitment_projection(
    db,
    *,
    user: dict,
    space: dict,
    body: FinanceCommitmentCreate,
) -> None:
    if (body.show_in_calendar or body.show_in_tasks) and space["kind"] != "household":
        raise FinancePlanningError(
            "Personal commitments cannot be shown in Calendar or Tasks"
        )
    if body.responsible_user_id is None:
        return
    adult = await (
        await db.execute(
            """
            SELECT id FROM users
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (body.responsible_user_id, user["family_id"]),
        )
    ).fetchone()
    if adult is None:
        raise FinancePlanningError("The responsible adult must be an active family member")


async def _reconcile_commitment_occurrences(
    db,
    *,
    commitment_id: str,
    reviewed_dates: list[date],
    commitment_status: str,
    user: dict,
    reset_moved_task_completion: bool = False,
) -> None:
    """Keep one stable projected occurrence for every reviewed date."""
    now = _now()
    desired_status = "ACTIVE" if commitment_status == "ACTIVE" else (
        "PAUSED" if commitment_status == "PAUSED" else "CANCELLED"
    )
    existing_rows = [
        dict(row)
        for row in await (
            await db.execute(
                """
                SELECT * FROM finance_commitment_occurrences
                WHERE commitment_id = ? AND family_id = ? AND deleted_at IS NULL
                ORDER BY due_date, created_at, id
                """,
                (commitment_id, user["family_id"]),
            )
        ).fetchall()
    ]
    desired = [value.isoformat() for value in reviewed_dates]
    remaining_rows = list(existing_rows)
    remaining_dates: list[str] = []

    # Exact date matches preserve completion and projection IDs.
    for due_date in desired:
        match = next((row for row in remaining_rows if row["due_date"] == due_date), None)
        if match is None:
            remaining_dates.append(due_date)
            continue
        remaining_rows.remove(match)
        await save_history(
            db,
            "finance_commitment_occurrences",
            match["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_commitment_occurrences
            SET status = ?, updated_at = ? WHERE id = ?
            """,
            (desired_status, now, match["id"]),
        )

    # A moved reviewed date updates the old occurrence rather than replacing it.
    while remaining_dates and remaining_rows:
        due_date = remaining_dates.pop(0)
        occurrence = remaining_rows.pop(0)
        await save_history(
            db,
            "finance_commitment_occurrences",
            occurrence["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_commitment_occurrences
            SET due_date = ?, status = ?,
                task_completed_at = CASE WHEN ? THEN NULL ELSE task_completed_at END,
                task_completed_by = CASE WHEN ? THEN NULL ELSE task_completed_by END,
                updated_at = ? WHERE id = ?
            """,
            (
                due_date,
                desired_status,
                int(reset_moved_task_completion),
                int(reset_moved_task_completion),
                now,
                occurrence["id"],
            ),
        )

    for due_date in remaining_dates:
        occurrence_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO finance_commitment_occurrences
                (id, commitment_id, due_date, calendar_projection_id,
                 task_projection_id, status, family_id, created_at, updated_at,
                 created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                occurrence_id,
                commitment_id,
                due_date,
                f"finance-calendar-{occurrence_id}",
                f"finance-task-{occurrence_id}",
                desired_status,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )

    for occurrence in remaining_rows:
        await save_history(
            db,
            "finance_commitment_occurrences",
            occurrence["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_commitment_occurrences
            SET status = 'CANCELLED', updated_at = ? WHERE id = ?
            """,
            (now, occurrence["id"]),
        )


async def _commitment_response(db, row: dict, *, as_of: date) -> FinanceCommitmentResponse:
    reviewed_dates = [date.fromisoformat(value) for value in json.loads(row["reviewed_dates_json"])]
    next_due = next((value for value in reviewed_dates if value >= as_of), None)
    required = _required_commitment_minor(row)
    remaining = max(0, required - row["already_reserved_minor"])
    if remaining == 0:
        funding_status = "FUNDED"
    else:
        salary = await (
            await db.execute(
                """
                SELECT next_expected_date FROM finance_recurring_series
                WHERE space_id = ? AND series_type = 'SALARY' AND status = 'CONFIRMED'
                  AND next_expected_date IS NOT NULL AND next_expected_date >= ?
                  AND deleted_at IS NULL
                ORDER BY next_expected_date LIMIT 1
                """,
                (row["space_id"], as_of.isoformat()),
            )
        ).fetchone()
        if next_due is not None and (
            next_due <= as_of
            or (salary is not None and next_due < date.fromisoformat(salary["next_expected_date"]))
        ):
            funding_status = "UNDERFUNDED"
        elif row["already_reserved_minor"] > 0:
            funding_status = "PARTLY_FUNDED"
        else:
            funding_status = "UNFUNDED"
    return FinanceCommitmentResponse(
        id=row["id"],
        space_id=row["space_id"],
        name=row["name"],
        amount_mode=row["amount_mode"],
        exact_minor=row["exact_minor"],
        expected_minor=row["expected_minor"],
        low_minor=row["low_minor"],
        high_minor=row["high_minor"],
        currency=row["currency"],
        recurrence=row["recurrence"],
        reviewed_dates=reviewed_dates,
        next_due_date=next_due,
        priority=row["priority"],
        funding_account_id=row["funding_account_id"],
        already_reserved_minor=row["already_reserved_minor"],
        required_minor=required,
        remaining_minor=remaining,
        funding_status=funding_status,
        status=row["status"],
        payment_handling=row["payment_handling"],
        show_in_calendar=bool(row["show_in_calendar"]),
        show_in_tasks=bool(row["show_in_tasks"]),
        responsible_user_id=row["responsible_user_id"],
        notes=row["notes"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def _normalised_commitment_values(body: FinanceCommitmentCreate) -> dict:
    values = body.model_dump()
    if body.amount_mode == "EXACT":
        values.update(expected_minor=None, low_minor=None, high_minor=None)
    elif body.amount_mode == "RANGE":
        values["exact_minor"] = None
    else:
        values["exact_minor"] = None
    return values


async def create_commitment(
    db, *, user: dict, space_id: str, body: FinanceCommitmentCreate
) -> FinanceCommitmentResponse:
    space = await require_finance_space(db, user=user, space_id=space_id)
    await _validate_commitment_projection(db, user=user, space=space, body=body)
    if body.funding_account_id:
        await _validate_account_ids(
            db,
            space_id=space_id,
            family_id=user["family_id"],
            account_ids=[body.funding_account_id],
            currency=body.currency,
        )
    values = _normalised_commitment_values(body)
    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_commitments
                (id, space_id, name, amount_mode, exact_minor, expected_minor,
                 low_minor, high_minor, currency, recurrence, reviewed_dates_json,
                 priority, funding_account_id, already_reserved_minor, status,
                 payment_handling, show_in_calendar, show_in_tasks,
                 responsible_user_id, notes, family_id, created_at, updated_at,
                 created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                values["name"],
                values["amount_mode"],
                values["exact_minor"],
                values["expected_minor"],
                values["low_minor"],
                values["high_minor"],
                values["currency"],
                values["recurrence"],
                _json_list([value.isoformat() for value in values["reviewed_dates"]]),
                values["priority"],
                values["funding_account_id"],
                values["already_reserved_minor"],
                values["status"],
                values["payment_handling"],
                int(values["show_in_calendar"]),
                int(values["show_in_tasks"]),
                values["responsible_user_id"],
                values["notes"],
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        await _reconcile_commitment_occurrences(
            db,
            commitment_id=identifier,
            reviewed_dates=values["reviewed_dates"],
            commitment_status=values["status"],
            user=user,
        )
    row = await (
        await db.execute("SELECT * FROM finance_commitments WHERE id = ?", (identifier,))
    ).fetchone()
    return await _commitment_response(db, dict(row), as_of=date.today())


async def list_commitments(
    db,
    *,
    user: dict,
    space_id: str,
    as_of: date,
    exclude_own_shared_copies: bool = False,
) -> list[FinanceCommitmentResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_commitments
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY status, created_at, id
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    if exclude_own_shared_copies:
        from app.services.finance.sharing import own_household_copy_ids

        excluded = await own_household_copy_ids(
            db, user=user, household_space_id=space_id, record_type="commitment"
        )
        rows = [row for row in rows if row["id"] not in excluded]
    return [await _commitment_response(db, dict(row), as_of=as_of) for row in rows]


async def update_commitment(
    db,
    *,
    user: dict,
    commitment_id: str,
    body: FinanceCommitmentUpdate,
    allow_linked_date_update: bool = False,
    reset_moved_task_completion: bool = False,
) -> FinanceCommitmentResponse:
    row = await _authorised_row(db, table="finance_commitments", record_id=commitment_id, user=user)
    current = {
        "name": row["name"],
        "amount_mode": row["amount_mode"],
        "exact_minor": row["exact_minor"],
        "expected_minor": row["expected_minor"],
        "low_minor": row["low_minor"],
        "high_minor": row["high_minor"],
        "currency": row["currency"],
        "recurrence": row["recurrence"],
        "reviewed_dates": json.loads(row["reviewed_dates_json"]),
        "priority": row["priority"],
        "funding_account_id": row["funding_account_id"],
        "already_reserved_minor": row["already_reserved_minor"],
        "status": row["status"],
        "payment_handling": row["payment_handling"],
        "show_in_calendar": bool(row["show_in_calendar"]),
        "show_in_tasks": bool(row["show_in_tasks"]),
        "responsible_user_id": row["responsible_user_id"],
        "notes": row["notes"],
    }
    if body.reviewed_dates is not None and not allow_linked_date_update:
        linked = await (
            await db.execute(
                """
                SELECT 1 FROM renewals
                WHERE finance_commitment_id = ? AND deleted_at IS NULL
                """,
                (commitment_id,),
            )
        ).fetchone()
        if linked is not None:
            raise FinancePlanningConflictError(
                "Change this date from its Finance renewal"
            )
    current.update(body.model_dump(exclude_unset=True))
    validated = FinanceCommitmentCreate(**current)
    values = _normalised_commitment_values(validated)
    space = await require_finance_space(db, user=user, space_id=row["space_id"])
    await _validate_commitment_projection(db, user=user, space=space, body=validated)
    if validated.funding_account_id:
        await _validate_account_ids(
            db,
            space_id=row["space_id"],
            family_id=user["family_id"],
            account_ids=[validated.funding_account_id],
            currency=validated.currency,
        )
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_commitments",
            commitment_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_commitments
            SET name = ?, amount_mode = ?, exact_minor = ?, expected_minor = ?,
                low_minor = ?, high_minor = ?, currency = ?, recurrence = ?,
                reviewed_dates_json = ?, priority = ?, funding_account_id = ?,
                already_reserved_minor = ?, status = ?, payment_handling = ?,
                show_in_calendar = ?, show_in_tasks = ?, responsible_user_id = ?,
                notes = ?, updated_at = ?
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                values["name"],
                values["amount_mode"],
                values["exact_minor"],
                values["expected_minor"],
                values["low_minor"],
                values["high_minor"],
                values["currency"],
                values["recurrence"],
                _json_list([value.isoformat() for value in values["reviewed_dates"]]),
                values["priority"],
                values["funding_account_id"],
                values["already_reserved_minor"],
                values["status"],
                values["payment_handling"],
                int(values["show_in_calendar"]),
                int(values["show_in_tasks"]),
                values["responsible_user_id"],
                values["notes"],
                now,
                commitment_id,
                row["space_id"],
                user["family_id"],
            ),
        )
        await _reconcile_commitment_occurrences(
            db,
            commitment_id=commitment_id,
            reviewed_dates=values["reviewed_dates"],
            commitment_status=values["status"],
            user=user,
            reset_moved_task_completion=reset_moved_task_completion,
        )
    updated = await (
        await db.execute("SELECT * FROM finance_commitments WHERE id = ?", (commitment_id,))
    ).fetchone()
    return await _commitment_response(db, dict(updated), as_of=date.today())


async def delete_commitment(db, *, user: dict, commitment_id: str) -> None:
    row = await _authorised_row(db, table="finance_commitments", record_id=commitment_id, user=user)
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_commitments",
            commitment_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_commitments SET deleted_at = ?, updated_at = ?
            WHERE id = ? AND space_id = ? AND deleted_at IS NULL
            """,
            (now, now, commitment_id, row["space_id"]),
        )
        occurrences = await (
            await db.execute(
                """
                SELECT id FROM finance_commitment_occurrences
                WHERE commitment_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (commitment_id, user["family_id"]),
            )
        ).fetchall()
        for occurrence in occurrences:
            await save_history(
                db,
                "finance_commitment_occurrences",
                occurrence["id"],
                user["id"],
                family_id=user["family_id"],
            )
        await db.execute(
            """
            UPDATE finance_commitment_occurrences
            SET status = 'CANCELLED', updated_at = ?
            WHERE commitment_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (now, commitment_id, user["family_id"]),
        )


def _reserve_response(row: dict) -> FinanceReserveResponse:
    target = row["target_minor"]
    allocated = row["allocated_minor"]
    if target is None:
        remaining = None
        funding_status = "UNTARGETED"
    elif allocated == 0 and target > 0:
        remaining = target
        funding_status = "UNFUNDED"
    elif allocated < target:
        remaining = target - allocated
        funding_status = "PARTLY_FUNDED"
    elif allocated == target:
        remaining = 0
        funding_status = "FUNDED"
    else:
        remaining = 0
        funding_status = "OVERFUNDED"
    return FinanceReserveResponse(
        id=row["id"],
        space_id=row["space_id"],
        name=row["name"],
        allocated_minor=allocated,
        target_minor=target,
        remaining_minor=remaining,
        funding_status=funding_status,
        currency=row["currency"],
        linked_account_id=row["linked_account_id"],
        status=row["status"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


async def _validate_reserve(db, *, user: dict, space_id: str, body: FinanceReserveCreate) -> None:
    if body.linked_account_id:
        await _validate_account_ids(
            db,
            space_id=space_id,
            family_id=user["family_id"],
            account_ids=[body.linked_account_id],
            currency=body.currency,
        )


async def create_reserve(
    db, *, user: dict, space_id: str, body: FinanceReserveCreate
) -> FinanceReserveResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    await _validate_reserve(db, user=user, space_id=space_id, body=body)
    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_reserves
                (id, space_id, name, allocated_minor, target_minor, currency,
                 linked_account_id, status, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                body.name,
                body.allocated_minor,
                body.target_minor,
                body.currency,
                body.linked_account_id,
                body.status,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    row = await (
        await db.execute("SELECT * FROM finance_reserves WHERE id = ?", (identifier,))
    ).fetchone()
    return _reserve_response(dict(row))


async def list_reserves(
    db,
    *,
    user: dict,
    space_id: str,
    exclude_own_shared_copies: bool = False,
) -> list[FinanceReserveResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_reserves
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY status, created_at, id
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    if exclude_own_shared_copies:
        from app.services.finance.sharing import own_household_copy_ids

        excluded = await own_household_copy_ids(
            db, user=user, household_space_id=space_id, record_type="reserve"
        )
        rows = [row for row in rows if row["id"] not in excluded]
    return [_reserve_response(dict(row)) for row in rows]


async def update_reserve(
    db, *, user: dict, reserve_id: str, body: FinanceReserveUpdate
) -> FinanceReserveResponse:
    row = await _authorised_row(db, table="finance_reserves", record_id=reserve_id, user=user)
    current = {
        "name": row["name"],
        "allocated_minor": row["allocated_minor"],
        "target_minor": row["target_minor"],
        "currency": row["currency"],
        "linked_account_id": row["linked_account_id"],
        "status": row["status"],
    }
    current.update(body.model_dump(exclude_unset=True))
    validated = FinanceReserveCreate(**current)
    await _validate_reserve(db, user=user, space_id=row["space_id"], body=validated)
    now = _now()
    async with serialized_create(db):
        await save_history(
            db, "finance_reserves", reserve_id, user["id"], family_id=user["family_id"]
        )
        await db.execute(
            """
            UPDATE finance_reserves
            SET name = ?, allocated_minor = ?, target_minor = ?, currency = ?,
                linked_account_id = ?, status = ?, updated_at = ?
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                validated.name,
                validated.allocated_minor,
                validated.target_minor,
                validated.currency,
                validated.linked_account_id,
                validated.status,
                now,
                reserve_id,
                row["space_id"],
                user["family_id"],
            ),
        )
    updated = await (
        await db.execute("SELECT * FROM finance_reserves WHERE id = ?", (reserve_id,))
    ).fetchone()
    return _reserve_response(dict(updated))


async def delete_reserve(db, *, user: dict, reserve_id: str) -> None:
    row = await _authorised_row(db, table="finance_reserves", record_id=reserve_id, user=user)
    now = _now()
    async with serialized_create(db):
        await save_history(
            db, "finance_reserves", reserve_id, user["id"], family_id=user["family_id"]
        )
        await db.execute(
            """
            UPDATE finance_reserves SET deleted_at = ?, updated_at = ?
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (now, now, reserve_id, row["space_id"], user["family_id"]),
        )


def _goal_response(row: dict, *, as_of: date) -> FinanceGoalResponse:
    remaining = max(0, row["target_minor"] - row["currently_allocated_minor"])
    if remaining == 0 or row["status"] == "ACHIEVED":
        feasibility = "ACHIEVED"
        shortfall = None
    elif date.fromisoformat(row["deadline"]) <= as_of:
        feasibility = "INFEASIBLE"
        shortfall = remaining
    else:
        feasibility = "UNASSESSED"
        shortfall = None
    return FinanceGoalResponse(
        id=row["id"],
        space_id=row["space_id"],
        name=row["name"],
        target_minor=row["target_minor"],
        deadline=row["deadline"],
        currently_allocated_minor=row["currently_allocated_minor"],
        remaining_minor=remaining,
        currency=row["currency"],
        priority=row["priority"],
        allowed_funding_sources=json.loads(row["allowed_funding_sources_json"]),
        emergency_buffer_minor=row["emergency_buffer_minor"],
        feasibility=feasibility,
        shortfall_minor=shortfall,
        status=row["status"],
        notes=row["notes"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


async def _validate_goal(db, *, user: dict, space_id: str, body: FinanceGoalCreate) -> None:
    await _validate_account_ids(
        db,
        space_id=space_id,
        family_id=user["family_id"],
        account_ids=body.allowed_funding_sources,
        currency=body.currency,
    )
    if body.status == "ACHIEVED" and body.currently_allocated_minor < body.target_minor:
        raise FinancePlanningError("An achieved goal must be fully allocated")


async def create_goal(
    db, *, user: dict, space_id: str, body: FinanceGoalCreate
) -> FinanceGoalResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    await _validate_goal(db, user=user, space_id=space_id, body=body)
    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_goals
                (id, space_id, name, target_minor, deadline, currently_allocated_minor,
                 currency, priority, allowed_funding_sources_json, emergency_buffer_minor,
                 status, notes, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                body.name,
                body.target_minor,
                body.deadline.isoformat(),
                body.currently_allocated_minor,
                body.currency,
                body.priority,
                _json_list(body.allowed_funding_sources),
                body.emergency_buffer_minor,
                body.status,
                body.notes,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    row = await (
        await db.execute("SELECT * FROM finance_goals WHERE id = ?", (identifier,))
    ).fetchone()
    return _goal_response(dict(row), as_of=date.today())


async def list_goals(
    db,
    *,
    user: dict,
    space_id: str,
    as_of: date,
    exclude_own_shared_copies: bool = False,
) -> list[FinanceGoalResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_goals
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY status, deadline, id
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    if exclude_own_shared_copies:
        from app.services.finance.sharing import own_household_copy_ids

        excluded = await own_household_copy_ids(
            db, user=user, household_space_id=space_id, record_type="goal"
        )
        rows = [row for row in rows if row["id"] not in excluded]
    return [_goal_response(dict(row), as_of=as_of) for row in rows]


async def update_goal(
    db, *, user: dict, goal_id: str, body: FinanceGoalUpdate
) -> FinanceGoalResponse:
    row = await _authorised_row(db, table="finance_goals", record_id=goal_id, user=user)
    current = {
        "name": row["name"],
        "target_minor": row["target_minor"],
        "deadline": row["deadline"],
        "currently_allocated_minor": row["currently_allocated_minor"],
        "currency": row["currency"],
        "priority": row["priority"],
        "allowed_funding_sources": json.loads(row["allowed_funding_sources_json"]),
        "emergency_buffer_minor": row["emergency_buffer_minor"],
        "status": row["status"],
        "notes": row["notes"],
    }
    current.update(body.model_dump(exclude_unset=True))
    validated = FinanceGoalCreate(**current)
    await _validate_goal(db, user=user, space_id=row["space_id"], body=validated)
    now = _now()
    async with serialized_create(db):
        await save_history(db, "finance_goals", goal_id, user["id"], family_id=user["family_id"])
        await db.execute(
            """
            UPDATE finance_goals
            SET name = ?, target_minor = ?, deadline = ?, currently_allocated_minor = ?,
                currency = ?, priority = ?, allowed_funding_sources_json = ?,
                emergency_buffer_minor = ?, status = ?, notes = ?, updated_at = ?
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                validated.name,
                validated.target_minor,
                validated.deadline.isoformat(),
                validated.currently_allocated_minor,
                validated.currency,
                validated.priority,
                _json_list(validated.allowed_funding_sources),
                validated.emergency_buffer_minor,
                validated.status,
                validated.notes,
                now,
                goal_id,
                row["space_id"],
                user["family_id"],
            ),
        )
    updated = await (
        await db.execute("SELECT * FROM finance_goals WHERE id = ?", (goal_id,))
    ).fetchone()
    return _goal_response(dict(updated), as_of=date.today())


async def delete_goal(db, *, user: dict, goal_id: str) -> None:
    row = await _authorised_row(db, table="finance_goals", record_id=goal_id, user=user)
    now = _now()
    async with serialized_create(db):
        await save_history(db, "finance_goals", goal_id, user["id"], family_id=user["family_id"])
        await db.execute(
            "UPDATE finance_goals SET deleted_at = ?, updated_at = ? WHERE id = ? AND space_id = ?",
            (now, now, goal_id, row["space_id"]),
        )


def _limiting_event_json(limiting_event) -> str | None:
    if limiting_event is None:
        return None
    payload = asdict(limiting_event)
    payload["day"] = limiting_event.day.isoformat()
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def _persisted_forecast_input(
    *,
    canonical_engine_input: str,
    data_through_at: str | None,
    event_provenance: tuple[tuple[str, str], ...],
    data_status: str,
    input_notes: tuple[str, ...],
    unsafe_safe_to_spend_routes: tuple[str, ...],
    card_routes: tuple[tuple[str, str, int, int], ...],
) -> tuple[str, str]:
    payload = {
        "data_through_at": data_through_at,
        "data_status": data_status,
        "card_routes": [
            {
                "card_account_id": card_id,
                "repayment_day": repayment_day,
                "settlement_account_id": settlement_id,
                "statement_close_day": close_day,
            }
            for card_id, settlement_id, close_day, repayment_day in card_routes
        ],
        "engine_input": json.loads(canonical_engine_input),
        "event_provenance": [
            {"event_id": event_id, "provenance": provenance}
            for event_id, provenance in event_provenance
        ],
        "input_notes": list(input_notes),
        "source": "SAVED",
        "unsafe_safe_to_spend_routes": list(unsafe_safe_to_spend_routes),
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return canonical, hashlib.sha256(canonical.encode("utf-8")).hexdigest()


async def _generate_forecast_id(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceForecastGenerate,
) -> str:
    await require_finance_space(db, user=user, space_id=space_id)
    settings = await (
        await db.execute(
            "SELECT household_timezone FROM finance_settings WHERE family_id = ? AND deleted_at IS NULL",
            (user["family_id"],),
        )
    ).fetchone()
    if settings is None:
        raise FinancePlanningError("Finance settings are not available")
    saved = await build_saved_forecast(
        db,
        user=user,
        space_id=space_id,
        request=body,
        timezone_name=settings["household_timezone"],
    )
    snapshot = saved.snapshot
    account_ids = [account.id for account in snapshot.accounts]
    await _validate_account_ids(
        db,
        space_id=space_id,
        family_id=user["family_id"],
        account_ids=account_ids,
        currency=snapshot.currency,
    )
    canonical_input = canonical_snapshot_json(snapshot)
    data_through = (
        saved.data_through_at.astimezone(timezone.utc).isoformat()
        if saved.data_through_at
        else None
    )
    persisted_input, persisted_digest = _persisted_forecast_input(
        canonical_engine_input=canonical_input,
        data_through_at=data_through,
        event_provenance=saved.event_provenance,
        data_status=saved.data_status,
        input_notes=saved.input_notes,
        unsafe_safe_to_spend_routes=saved.unsafe_safe_to_spend_routes,
        card_routes=saved.card_routes,
    )
    existing = await (
        await db.execute(
            """
            SELECT id FROM finance_forecast_snapshots
            WHERE space_id = ? AND input_snapshot_digest = ? AND engine_version = ?
              AND deleted_at IS NULL
            """,
            (space_id, persisted_digest, snapshot.engine_version),
        )
    ).fetchone()
    if existing is not None:
        return existing["id"]

    # The deterministic engine and row serialisation can be relatively expensive
    # for a ten-year horizon. Keep both outside SQLite's single-writer section.
    result = run_forecast(snapshot)
    snapshot_id: str
    now = _now()
    provenance_by_id = dict(saved.event_provenance)
    event_rows = [
        (
            str(uuid.uuid4()),
            space_id,
            "",  # Filled with the winning snapshot ID inside the transaction.
            event.id,
            event.day.isoformat(),
            event.account_id,
            event.destination_account_id,
            event.amount.minor_units,
            event.amount.currency,
            event.kind,
            event.sequence,
            provenance_by_id[event.id],
            user["family_id"],
            now,
            now,
            user["id"],
        )
        for event in snapshot.events
    ]
    day_rows = [
        (
            str(uuid.uuid4()),
            space_id,
            "",  # Filled with the winning snapshot ID inside the transaction.
            day.day.isoformat(),
            json.dumps(
                [asdict(account) for account in day.accounts],
                sort_keys=True,
                separators=(",", ":"),
            ),
            day.household_liquid_minor,
            day.household_free_minor,
            int(day.constraints_passed_through_day),
            user["family_id"],
            now,
            now,
            user["id"],
        )
        for day in result.days
    ]
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT id FROM finance_forecast_snapshots
                WHERE space_id = ? AND input_snapshot_digest = ? AND engine_version = ?
                  AND deleted_at IS NULL
                """,
                (space_id, persisted_digest, result.engine_version),
            )
        ).fetchone()
        if existing is not None:
            snapshot_id = existing["id"]
        else:
            snapshot_id = str(uuid.uuid4())
            await db.execute(
                """
                INSERT INTO finance_forecast_snapshots
                    (id, space_id, input_snapshot_digest, engine_version,
                     household_timezone, currency, start_date, end_date,
                     household_buffer_minor, canonical_input_json, passed,
                     limiting_event_json, minimum_household_free_minor,
                     minimum_household_free_date, data_through_at, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    snapshot_id,
                    space_id,
                    persisted_digest,
                    result.engine_version,
                    snapshot.timezone,
                    snapshot.currency,
                    snapshot.start_date.isoformat(),
                    snapshot.end_date.isoformat(),
                    snapshot.household_buffer_minor,
                    persisted_input,
                    int(result.passed),
                    _limiting_event_json(result.limiting_event),
                    result.minimum_household_free_minor,
                    result.minimum_household_free_date.isoformat(),
                    data_through,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
            if event_rows:
                await db.executemany(
                    """
                    INSERT INTO finance_forecast_events
                        (id, space_id, snapshot_id, event_key, event_date, account_id,
                         destination_account_id, amount_minor, currency, event_kind,
                         sequence, provenance, family_id, created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [row[:2] + (snapshot_id,) + row[3:] for row in event_rows],
                )
            if day_rows:
                await db.executemany(
                    """
                    INSERT INTO finance_forecast_days
                        (id, space_id, snapshot_id, forecast_date,
                         account_balances_json, household_liquid_minor,
                         household_free_minor, constraints_passed_through_day,
                         family_id, created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [row[:2] + (snapshot_id,) + row[3:] for row in day_rows],
                )
    return snapshot_id


async def generate_forecast(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceForecastGenerate,
) -> FinanceForecastResponse:
    snapshot_id = await _generate_forecast_id(
        db,
        user=user,
        space_id=space_id,
        body=body,
    )
    return await read_forecast(db, user=user, forecast_id=snapshot_id)


def compact_forecast(forecast: FinanceForecastResponse) -> FinanceForecastOverviewResponse:
    """Drop only repeated account-day detail; all displayed headline maths stays exact."""
    return FinanceForecastOverviewResponse(
        **forecast.model_dump(exclude={"days"}),
        opening_accounts=forecast.days[0].accounts if forecast.days else [],
        days=[
            FinanceForecastOverviewDayResponse(
                day=day.day,
                household_liquid_minor=day.household_liquid_minor,
                household_free_minor=day.household_free_minor,
                constraints_passed_through_day=day.constraints_passed_through_day,
            )
            for day in forecast.days
        ],
    )


async def generate_forecast_overview(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceForecastGenerate,
) -> FinanceForecastOverviewResponse:
    snapshot_id = await _generate_forecast_id(
        db,
        user=user,
        space_id=space_id,
        body=body,
    )
    return await read_forecast_overview(db, user=user, forecast_id=snapshot_id)


async def read_forecast(db, *, user: dict, forecast_id: str) -> FinanceForecastResponse:
    snapshot = await _authorised_row(
        db,
        table="finance_forecast_snapshots",
        record_id=forecast_id,
        user=user,
    )
    event_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_forecast_events
            WHERE snapshot_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY event_date, sequence, event_key
            """,
            (forecast_id, snapshot["space_id"], user["family_id"]),
        )
    ).fetchall()
    day_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_forecast_days
            WHERE snapshot_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY forecast_date
            """,
            (forecast_id, snapshot["space_id"], user["family_id"]),
        )
    ).fetchall()
    try:
        persisted_input = json.loads(snapshot["canonical_input_json"])
    except (TypeError, json.JSONDecodeError):
        persisted_input = {}
    return FinanceForecastResponse(
        id=snapshot["id"],
        space_id=snapshot["space_id"],
        input_snapshot_digest=snapshot["input_snapshot_digest"],
        engine_version=snapshot["engine_version"],
        household_timezone=snapshot["household_timezone"],
        currency=snapshot["currency"],
        start_date=snapshot["start_date"],
        end_date=snapshot["end_date"],
        household_buffer_minor=snapshot["household_buffer_minor"],
        passed=bool(snapshot["passed"]),
        limiting_event=(
            json.loads(snapshot["limiting_event_json"]) if snapshot["limiting_event_json"] else None
        ),
        minimum_household_free_minor=snapshot["minimum_household_free_minor"],
        minimum_household_free_date=snapshot["minimum_household_free_date"],
        data_through_at=snapshot["data_through_at"],
        source=("SAVED" if persisted_input.get("source") == "SAVED" else "LEGACY_EXPLICIT"),
        data_status=persisted_input.get(
            "data_status",
            "CURRENT" if snapshot["data_through_at"] else "PARTIAL",
        ),
        input_notes=persisted_input.get("input_notes", []),
        events=[
            FinanceForecastEventResponse(
                event_id=row["event_key"],
                day=row["event_date"],
                account_id=row["account_id"],
                amount_minor=row["amount_minor"],
                currency=row["currency"],
                kind=row["event_kind"],
                destination_account_id=row["destination_account_id"],
                sequence=row["sequence"],
                provenance=row["provenance"],
            )
            for row in event_rows
        ],
        days=[
            FinanceForecastDayResponse(
                day=row["forecast_date"],
                accounts=[
                    FinanceForecastAccountDayResponse(**account)
                    for account in json.loads(row["account_balances_json"])
                ],
                household_liquid_minor=row["household_liquid_minor"],
                household_free_minor=row["household_free_minor"],
                constraints_passed_through_day=bool(row["constraints_passed_through_day"]),
            )
            for row in day_rows
        ],
        created_at=snapshot["created_at"],
    )


async def read_forecast_overview(
    db,
    *,
    user: dict,
    forecast_id: str,
) -> FinanceForecastOverviewResponse:
    """Read chart-ready forecast rows without decoding every account on every day."""
    snapshot = await _authorised_row(
        db,
        table="finance_forecast_snapshots",
        record_id=forecast_id,
        user=user,
    )
    event_rows = await (
        await db.execute(
            """
            SELECT event_key, event_date, account_id, destination_account_id,
                   amount_minor, currency, event_kind, sequence, provenance
            FROM finance_forecast_events
            WHERE snapshot_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY event_date, sequence, event_key
            """,
            (forecast_id, snapshot["space_id"], user["family_id"]),
        )
    ).fetchall()
    day_rows = await (
        await db.execute(
            """
            SELECT forecast_date, household_liquid_minor, household_free_minor,
                   constraints_passed_through_day,
                   CASE WHEN ROW_NUMBER() OVER (ORDER BY forecast_date) = 1
                        THEN account_balances_json END AS opening_accounts_json
            FROM finance_forecast_days
            WHERE snapshot_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY forecast_date
            """,
            (forecast_id, snapshot["space_id"], user["family_id"]),
        )
    ).fetchall()
    try:
        persisted_input = json.loads(snapshot["canonical_input_json"])
    except (TypeError, json.JSONDecodeError):
        persisted_input = {}
    opening_accounts = (
        [
            FinanceForecastAccountDayResponse(**account)
            for account in json.loads(day_rows[0]["opening_accounts_json"])
        ]
        if day_rows
        else []
    )
    return FinanceForecastOverviewResponse(
        id=snapshot["id"],
        space_id=snapshot["space_id"],
        input_snapshot_digest=snapshot["input_snapshot_digest"],
        engine_version=snapshot["engine_version"],
        household_timezone=snapshot["household_timezone"],
        currency=snapshot["currency"],
        start_date=snapshot["start_date"],
        end_date=snapshot["end_date"],
        household_buffer_minor=snapshot["household_buffer_minor"],
        passed=bool(snapshot["passed"]),
        limiting_event=(
            json.loads(snapshot["limiting_event_json"])
            if snapshot["limiting_event_json"]
            else None
        ),
        minimum_household_free_minor=snapshot["minimum_household_free_minor"],
        minimum_household_free_date=snapshot["minimum_household_free_date"],
        data_through_at=snapshot["data_through_at"],
        source=("SAVED" if persisted_input.get("source") == "SAVED" else "LEGACY_EXPLICIT"),
        data_status=persisted_input.get(
            "data_status",
            "CURRENT" if snapshot["data_through_at"] else "PARTIAL",
        ),
        input_notes=persisted_input.get("input_notes", []),
        events=[
            FinanceForecastEventResponse(
                event_id=row["event_key"],
                day=row["event_date"],
                account_id=row["account_id"],
                amount_minor=row["amount_minor"],
                currency=row["currency"],
                kind=row["event_kind"],
                destination_account_id=row["destination_account_id"],
                sequence=row["sequence"],
                provenance=row["provenance"],
            )
            for row in event_rows
        ],
        opening_accounts=opening_accounts,
        days=[
            FinanceForecastOverviewDayResponse(
                day=row["forecast_date"],
                household_liquid_minor=row["household_liquid_minor"],
                household_free_minor=row["household_free_minor"],
                constraints_passed_through_day=bool(
                    row["constraints_passed_through_day"]
                ),
            )
            for row in day_rows
        ],
        created_at=snapshot["created_at"],
    )

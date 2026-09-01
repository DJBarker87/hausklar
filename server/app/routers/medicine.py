"""Medicine tracking API endpoints.

SAFETY-CRITICAL: All dose endpoints include safety checks using given_at timestamps.
Warnings are always returned to the caller — doses are never silently blocked.
"""

import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.medicine import (
    DoseWithWarnings,
    MedicineDoseCreate,
    MedicineDoseResponse,
    MedicineDoseUpdate,
    MedicineTypeCreate,
    MedicineTypeResponse,
    MedicineTypeUpdate,
    SafetyCheckResponse,
    SafetyWarning,
)
from app.services.create_records import create_or_replay_medicine_type
from app.services.medicine import (
    MedicineDoseConflictError,
    MedicineDoseError,
    MedicineDoseNotFoundError,
    check_dose_safety,
    create_or_replay_medicine_dose,
)
from app.services.idempotency import CreateReplayConflictError
from app.services.family_people import family_child_exists
from app.services.record_history import save_history

router = APIRouter()


def _stored_warnings(row) -> list[SafetyWarning]:
    raw = dict(row).get("safety_warnings_json")
    if not raw:
        return []
    try:
        return [SafetyWarning.model_validate(item) for item in json.loads(raw)]
    except (TypeError, ValueError):
        return []


def _dose_response(row, warnings: list[SafetyWarning] | None = None) -> MedicineDoseResponse:
    return MedicineDoseResponse(
        **dict(row),
        warnings=warnings if warnings is not None else _stored_warnings(row),
    )


# ---------------------------------------------------------------------------
# Medicine Types
# ---------------------------------------------------------------------------


@router.get("/types", response_model=list[MedicineTypeResponse])
async def list_medicine_types(
    child_id: str | None = Query(None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List all medicine types, optionally filtered by child_id."""
    if child_id:
        cursor = await db.execute(
            "SELECT * FROM medicine_types WHERE child_id = ? AND deleted_at IS NULL AND family_id = ?",
            (child_id, current_user["family_id"]),
        )
    else:
        cursor = await db.execute(
            "SELECT * FROM medicine_types WHERE deleted_at IS NULL AND family_id = ?",
            (current_user["family_id"],),
        )
    rows = await cursor.fetchall()
    return [MedicineTypeResponse(**dict(row)) for row in rows]


@router.post("/types", response_model=MedicineTypeResponse, status_code=status.HTTP_201_CREATED)
async def create_medicine_type(
    body: MedicineTypeCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a new medicine type."""
    try:
        row, _replayed = await create_or_replay_medicine_type(
            db,
            body,
            record_id=str(body.id),
            user=current_user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    except CreateReplayConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return MedicineTypeResponse(**row)


@router.put("/types/{type_id}", response_model=MedicineTypeResponse)
async def update_medicine_type(
    type_id: str,
    body: MedicineTypeUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update an existing medicine type. Saves history before modifying."""
    cursor = await db.execute(
        "SELECT * FROM medicine_types WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (type_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Medicine type not found",
        )

    # Save history before modifying
    await save_history(
        db,
        "medicine_types",
        type_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    # Build SET clause from provided fields only
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No fields to update",
        )
    if body.child_id and not await family_child_exists(
        db,
        current_user["family_id"],
        body.child_id,
    ):
        raise HTTPException(status_code=400, detail="Child is not in this family")

    now = datetime.now(timezone.utc).isoformat()
    updates["updated_at"] = now

    set_clause = ", ".join(f"{key} = ?" for key in updates)
    values = list(updates.values()) + [type_id, current_user["family_id"]]

    await db.execute(
        f"UPDATE medicine_types SET {set_clause} WHERE id = ? AND family_id = ?",
        values,
    )
    await db.commit()

    cursor = await db.execute(
        "SELECT * FROM medicine_types WHERE id = ?",
        (type_id,),
    )
    row = await cursor.fetchone()
    return MedicineTypeResponse(**dict(row))


@router.delete("/types/{type_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_medicine_type(
    type_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Archive a medicine while retaining its name on every past dose."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT * FROM medicine_types "
            "WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
            (type_id, current_user["family_id"]),
        )
        existing = await cursor.fetchone()
        if not existing:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Medicine type not found",
            )

        await save_history(
            db,
            "medicine_types",
            type_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        cursor = await db.execute(
            "SELECT id FROM medicine_doses "
            "WHERE medicine_type_id = ? AND family_id = ? AND medicine_name IS NULL",
            (type_id, current_user["family_id"]),
        )
        dose_ids = [row["id"] for row in await cursor.fetchall()]
        for dose_id in dose_ids:
            await save_history(
                db,
                "medicine_doses",
                dose_id,
                current_user["id"],
                family_id=current_user["family_id"],
            )

        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            "UPDATE medicine_doses SET medicine_name = ?, updated_at = ? "
            "WHERE medicine_type_id = ? AND family_id = ? AND medicine_name IS NULL",
            (existing["name"], now, type_id, current_user["family_id"]),
        )
        await db.execute(
            "UPDATE medicine_types SET deleted_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (now, now, type_id, current_user["family_id"]),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


# ---------------------------------------------------------------------------
# Medicine Doses
# ---------------------------------------------------------------------------


@router.get("/doses", response_model=list[MedicineDoseResponse])
async def list_doses(
    child_id: str | None = Query(None),
    medicine_type_id: str | None = Query(None),
    date: str | None = Query(None, description="Filter by date portion of given_at (YYYY-MM-DD)"),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List medicine doses with optional filters, ordered by given_at DESC."""
    conditions = ["deleted_at IS NULL"]
    params: list = []

    conditions.append("family_id = ?")
    params.append(current_user["family_id"])

    if child_id:
        conditions.append("child_id = ?")
        params.append(child_id)

    if medicine_type_id:
        conditions.append("medicine_type_id = ?")
        params.append(medicine_type_id)

    if date:
        # Match the date portion of the given_at ISO-8601 timestamp
        conditions.append("given_at LIKE ?")
        params.append(f"{date}%")

    where = " AND ".join(conditions)
    params.extend([limit, offset])

    cursor = await db.execute(
        f"""
        SELECT * FROM medicine_doses
        WHERE {where}
        ORDER BY given_at DESC
        LIMIT ? OFFSET ?
        """,
        params,
    )
    rows = await cursor.fetchall()
    return [_dose_response(row) for row in rows]


@router.post("/doses", response_model=DoseWithWarnings, status_code=status.HTTP_201_CREATED)
async def create_dose(
    body: MedicineDoseCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Log a medicine dose.

    SAFETY: Runs check_dose_safety BEFORE creating when a medicine type is
    provided. The dose is ALWAYS created (never silently blocked) but warnings
    are included in the response so the caller can inform the user.

    For ad-hoc "other" medicines (no medicine_type_id), safety checks are
    skipped and medicine_name is stored instead.
    """
    try:
        row, warnings, _replayed = await create_or_replay_medicine_dose(
            db,
            body,
            dose_id=str(body.id),
            user=current_user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    except MedicineDoseNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except MedicineDoseConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except MedicineDoseError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    dose = _dose_response(row, warnings)

    return DoseWithWarnings(dose=dose, warnings=warnings)


@router.patch("/doses/{dose_id}", response_model=DoseWithWarnings)
async def update_dose(
    dose_id: str,
    body: MedicineDoseUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Correct a recorded dose and recalculate warnings at its actual time."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT * FROM medicine_doses "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (dose_id, current_user["family_id"]),
        )
        existing = await cursor.fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Dose not found")

        updates: dict[str, str | None] = {}
        if body.given_at is not None:
            updates["given_at"] = body.given_at
        if body.clear_dose_amount:
            updates["dose_amount"] = None
        elif body.dose_amount is not None:
            updates["dose_amount"] = body.dose_amount.strip() or None
        if body.medicine_name is not None:
            updates["medicine_name"] = body.medicine_name.strip()
        if body.clear_notes:
            updates["notes"] = None
        elif body.notes is not None:
            updates["notes"] = body.notes.strip() or None
        if not updates:
            raise HTTPException(status_code=400, detail="No fields to update")

        await save_history(
            db,
            "medicine_doses",
            dose_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        candidate_time = updates.get("given_at", existing["given_at"])
        warnings: list[SafetyWarning] = []
        if existing["medicine_type_id"]:
            _safe, warnings = await check_dose_safety(
                db,
                existing["medicine_type_id"],
                existing["child_id"],
                candidate_time,
                family_id=current_user["family_id"],
                exclude_dose_id=dose_id,
            )
        updates["safety_warnings_json"] = json.dumps(
            [warning.model_dump(mode="json") for warning in warnings],
            separators=(",", ":"),
        )
        updates["updated_at"] = datetime.now(timezone.utc).isoformat()
        set_clause = ", ".join(f"{key} = ?" for key in updates)
        await db.execute(
            f"UPDATE medicine_doses SET {set_clause} WHERE id = ? AND family_id = ?",
            [*updates.values(), dose_id, current_user["family_id"]],
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    cursor = await db.execute("SELECT * FROM medicine_doses WHERE id = ?", (dose_id,))
    row = await cursor.fetchone()
    dose = _dose_response(row, warnings)
    return DoseWithWarnings(dose=dose, warnings=warnings)


@router.delete("/doses/{dose_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_dose(
    dose_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT id FROM medicine_doses "
        "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (dose_id, current_user["family_id"]),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=404, detail="Dose not found")
    await save_history(
        db,
        "medicine_doses",
        dose_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE medicine_doses SET deleted_at = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, dose_id, current_user["family_id"]),
    )
    await db.commit()


@router.post("/doses/{dose_id}/restore", response_model=DoseWithWarnings)
async def restore_dose(
    dose_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT * FROM medicine_doses "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NOT NULL",
            (dose_id, current_user["family_id"]),
        )
        existing = await cursor.fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Dose not found")
        await save_history(
            db,
            "medicine_doses",
            dose_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        warnings: list[SafetyWarning] = []
        if existing["medicine_type_id"]:
            _safe, warnings = await check_dose_safety(
                db,
                existing["medicine_type_id"],
                existing["child_id"],
                existing["given_at"],
                family_id=current_user["family_id"],
                exclude_dose_id=dose_id,
            )
        now = datetime.now(timezone.utc).isoformat()
        warning_json = json.dumps(
            [warning.model_dump(mode="json") for warning in warnings],
            separators=(",", ":"),
        )
        await db.execute(
            "UPDATE medicine_doses SET deleted_at = NULL, updated_at = ?, "
            "safety_warnings_json = ? WHERE id = ? AND family_id = ?",
            (now, warning_json, dose_id, current_user["family_id"]),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    cursor = await db.execute("SELECT * FROM medicine_doses WHERE id = ?", (dose_id,))
    row = await cursor.fetchone()
    dose = _dose_response(row, warnings)
    return DoseWithWarnings(dose=dose, warnings=warnings)


@router.get("/check/{medicine_type_id}/{child_id}", response_model=SafetyCheckResponse)
async def safety_check(
    medicine_type_id: str,
    child_id: str,
    given_at: datetime | None = Query(
        None,
        description="Candidate administration time as an ISO-8601 timestamp; defaults to now",
    ),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Check a candidate dose time without creating a dose."""
    # Verify the medicine type exists
    if not await family_child_exists(db, current_user["family_id"], child_id):
        raise HTTPException(status_code=404, detail="Child not found")
    cursor = await db.execute(
        "SELECT id, child_id FROM medicine_types WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (medicine_type_id, current_user["family_id"]),
    )
    medicine_type = await cursor.fetchone()
    if not medicine_type:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Medicine type not found",
        )
    if medicine_type["child_id"] != child_id:
        raise HTTPException(status_code=400, detail="Medicine type does not belong to this child")

    candidate_at = given_at or datetime.now(timezone.utc)
    if candidate_at.tzinfo is None:
        candidate_at = candidate_at.replace(tzinfo=timezone.utc)
    candidate_at = candidate_at.astimezone(timezone.utc)
    is_safe, warnings = await check_dose_safety(
        db,
        medicine_type_id,
        child_id,
        candidate_at,
        family_id=current_user["family_id"],
    )

    # Determine the earliest next_safe_at across all warnings
    next_safe_at = None
    for w in warnings:
        if w.next_safe_at is not None:
            if next_safe_at is None or w.next_safe_at > next_safe_at:
                next_safe_at = w.next_safe_at

    return SafetyCheckResponse(
        safe=is_safe,
        warnings=warnings,
        next_safe_at=next_safe_at,
    )

"""Illness tracking API endpoints."""

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.illness import (
    IllnessCreate,
    IllnessDetailResponse,
    IllnessResponse,
    IllnessUpdate,
    TemperatureReadingCreate,
    TemperatureReadingResponse,
    TemperatureReadingUpdate,
    parse_illness_datetime,
)
from app.services.illness import auto_associate_illness, get_active_illness, get_illness_detail
from app.services.family_people import family_child_exists
from app.services.record_history import save_history

router = APIRouter()


# ---------------------------------------------------------------------------
# Illness CRUD — /active/{child_id} and /temperature BEFORE /{illness_id}
# ---------------------------------------------------------------------------


@router.post("/", response_model=IllnessResponse, status_code=status.HTTP_201_CREATED)
async def create_illness(
    body: IllnessCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Record an illness. Ongoing illnesses are unique per child; completed
    historical sick-day records can be added at any time."""
    if not await family_child_exists(db, current_user["family_id"], body.child_id):
        raise HTTPException(status_code=400, detail="Child is not in this family")
    illness_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    owns_transaction = body.ended_at is None and not db.in_transaction
    if owns_transaction:
        # Serialize the active check and insert so two devices cannot create
        # competing ongoing illnesses for the same child.
        await db.execute("BEGIN IMMEDIATE")
    try:
        if body.ended_at is None:
            active = await get_active_illness(
                db, body.child_id, family_id=current_user["family_id"]
            )
            if active:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Child already has an active illness",
                )

        await db.execute(
            """
            INSERT INTO illnesses (id, child_id, started_at, ended_at, notes, family_id,
                created_at, updated_at, created_by, client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                illness_id,
                body.child_id,
                body.started_at,
                body.ended_at,
                body.notes,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    cursor = await db.execute("SELECT * FROM illnesses WHERE id = ?", (illness_id,))
    row = await cursor.fetchone()
    return IllnessResponse(**dict(row))


@router.get("/", response_model=list[IllnessResponse])
async def list_illnesses(
    child_id: str | None = Query(None),
    active: bool | None = Query(None),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List illnesses with optional filters."""
    conditions = ["deleted_at IS NULL"]
    params: list = []

    conditions.append("family_id = ?")
    params.append(current_user["family_id"])

    if child_id:
        conditions.append("child_id = ?")
        params.append(child_id)

    if active is True:
        conditions.append("ended_at IS NULL")
    elif active is False:
        conditions.append("ended_at IS NOT NULL")

    where = " AND ".join(conditions)
    params.extend([limit, offset])

    cursor = await db.execute(
        f"SELECT * FROM illnesses WHERE {where} ORDER BY started_at DESC LIMIT ? OFFSET ?",
        params,
    )
    rows = await cursor.fetchall()
    return [IllnessResponse(**dict(row)) for row in rows]


@router.get("/active/{child_id}", response_model=IllnessResponse)
async def get_active_illness_endpoint(
    child_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Get the active illness for a child. 404 if none."""
    illness = await get_active_illness(db, child_id, family_id=current_user["family_id"])
    if not illness:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No active illness for this child",
        )
    return IllnessResponse(**illness)


@router.post("/temperature", response_model=TemperatureReadingResponse, status_code=status.HTTP_201_CREATED)
async def log_temperature(
    body: TemperatureReadingCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Log a temperature reading. Auto-associates active illness if illness_id omitted."""
    if not await family_child_exists(db, current_user["family_id"], body.child_id):
        raise HTTPException(status_code=400, detail="Child is not in this family")
    illness_id = body.illness_id
    if illness_id is not None:
        cursor = await db.execute(
            """
            SELECT id FROM illnesses
            WHERE id = ? AND child_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (illness_id, body.child_id, current_user["family_id"]),
        )
        if not await cursor.fetchone():
            raise HTTPException(status_code=400, detail="Illness does not belong to this child")
    if illness_id is None:
        illness_id = await auto_associate_illness(db, body.child_id, family_id=current_user["family_id"])

    if body.value_celsius < 30.0 or body.value_celsius > 45.0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Temperature must be between 30.0 and 45.0°C",
        )

    reading_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    await db.execute(
        """
        INSERT INTO temperature_readings (id, child_id, illness_id, value_celsius, recorded_at,
            notes, family_id, created_at, updated_at, created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (reading_id, body.child_id, illness_id, body.value_celsius, body.recorded_at,
         body.notes, current_user["family_id"], now, now, current_user["id"], body.client_id, body.client_timestamp),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM temperature_readings WHERE id = ?", (reading_id,))
    row = await cursor.fetchone()
    return TemperatureReadingResponse(**dict(row))


@router.get("/temperature", response_model=list[TemperatureReadingResponse])
async def list_temperature_readings(
    child_id: str | None = Query(None),
    illness_id: str | None = Query(None),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List temperature readings with optional filters."""
    conditions = ["deleted_at IS NULL"]
    params: list = []

    conditions.append("family_id = ?")
    params.append(current_user["family_id"])

    if child_id:
        conditions.append("child_id = ?")
        params.append(child_id)

    if illness_id:
        conditions.append("illness_id = ?")
        params.append(illness_id)

    where = " AND ".join(conditions)
    params.extend([limit, offset])

    cursor = await db.execute(
        f"SELECT * FROM temperature_readings WHERE {where} ORDER BY recorded_at DESC LIMIT ? OFFSET ?",
        params,
    )
    rows = await cursor.fetchall()
    return [TemperatureReadingResponse(**dict(row)) for row in rows]


@router.put("/temperature/{reading_id}", response_model=TemperatureReadingResponse)
async def update_temperature_reading(
    reading_id: str,
    body: TemperatureReadingUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Correct a temperature reading while retaining its previous version."""
    cursor = await db.execute(
        "SELECT * FROM temperature_readings WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (reading_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Temperature reading not found",
        )

    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No fields to update",
        )
    if "value_celsius" in updates and not 30.0 <= updates["value_celsius"] <= 45.0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Temperature must be between 30.0 and 45.0°C",
        )

    await save_history(
        db,
        "temperature_readings",
        reading_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    updates["updated_at"] = datetime.now(timezone.utc).isoformat()
    set_clause = ", ".join(f"{key} = ?" for key in updates)
    values = list(updates.values()) + [reading_id, current_user["family_id"]]
    await db.execute(
        f"UPDATE temperature_readings SET {set_clause} WHERE id = ? AND family_id = ?",
        values,
    )
    await db.commit()

    cursor = await db.execute(
        "SELECT * FROM temperature_readings WHERE id = ?", (reading_id,)
    )
    row = await cursor.fetchone()
    return TemperatureReadingResponse(**dict(row))


@router.delete("/temperature/{reading_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_temperature_reading(
    reading_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a temperature reading."""
    cursor = await db.execute(
        "SELECT * FROM temperature_readings WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (reading_id, current_user["family_id"]),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Temperature reading not found")

    await save_history(
        db,
        "temperature_readings",
        reading_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE temperature_readings SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, reading_id, current_user["family_id"]),
    )
    await db.commit()


# ---------------------------------------------------------------------------
# /{illness_id} routes — AFTER /active and /temperature
# ---------------------------------------------------------------------------


@router.get("/{illness_id}", response_model=IllnessResponse)
async def get_illness(
    illness_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Get a single illness by id."""
    cursor = await db.execute(
        "SELECT * FROM illnesses WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (illness_id, current_user["family_id"]),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Illness not found")
    return IllnessResponse(**dict(row))


@router.put("/{illness_id}", response_model=IllnessResponse)
async def update_illness(
    illness_id: str,
    body: IllnessUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update an illness (end it by setting ended_at, edit notes)."""
    cursor = await db.execute(
        "SELECT * FROM illnesses WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (illness_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Illness not found")

    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="No fields to update")

    effective_start = updates.get("started_at", existing["started_at"])
    effective_end = updates.get("ended_at", existing["ended_at"])
    if effective_end is not None and parse_illness_datetime(
        effective_end
    ) < parse_illness_datetime(effective_start):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="End date cannot be before start date",
        )

    if "ended_at" in updates:
        ended_at = updates["ended_at"]
        if ended_at is None:
            active = await get_active_illness(
                db,
                existing["child_id"],
                family_id=current_user["family_id"],
            )
            if active is not None and active["id"] != illness_id:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Child already has an active illness",
                )

    await save_history(
        db,
        "illnesses",
        illness_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    updates["updated_at"] = now

    set_clause = ", ".join(f"{key} = ?" for key in updates)
    values = list(updates.values()) + [illness_id, current_user["family_id"]]

    await db.execute(f"UPDATE illnesses SET {set_clause} WHERE id = ? AND family_id = ?", values)
    await db.commit()

    cursor = await db.execute("SELECT * FROM illnesses WHERE id = ?", (illness_id,))
    row = await cursor.fetchone()
    return IllnessResponse(**dict(row))


@router.delete("/{illness_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_illness(
    illness_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete an illness."""
    cursor = await db.execute(
        "SELECT * FROM illnesses WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (illness_id, current_user["family_id"]),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Illness not found")

    await save_history(
        db,
        "illnesses",
        illness_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE illnesses SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, illness_id, current_user["family_id"]),
    )
    await db.commit()


@router.get("/{illness_id}/detail", response_model=IllnessDetailResponse)
async def illness_detail(
    illness_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Get full illness detail: readings, doses, next dose times (graph data)."""
    detail = await get_illness_detail(db, illness_id, family_id=current_user["family_id"])
    if detail is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Illness not found")
    return detail

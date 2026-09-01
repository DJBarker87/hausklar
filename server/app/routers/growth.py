import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.growth import GrowthChartData, GrowthRecordCreate, GrowthRecordResponse, GrowthRecordUpdate
from app.services.record_history import save_history
from app.services.family_people import family_child_exists

router = APIRouter()


def _row_to_response(row: dict) -> GrowthRecordResponse:
    """Convert a database row into a GrowthRecordResponse."""
    return GrowthRecordResponse(**dict(row))


@router.get("/", response_model=list[GrowthRecordResponse])
async def list_growth_records(
    child_id: str | None = Query(None),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List growth records, optionally filtered by child_id."""
    query = "SELECT * FROM growth_records WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]

    if child_id is not None:
        query += " AND child_id = ?"
        params.append(child_id)

    query += " ORDER BY date DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_row_to_response(row) for row in rows]


@router.post("/", response_model=GrowthRecordResponse, status_code=status.HTTP_201_CREATED)
async def create_growth_record(
    body: GrowthRecordCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a new growth record."""
    if not await family_child_exists(db, current_user["family_id"], body.child_id):
        raise HTTPException(status_code=400, detail="Child is not in this family")
    record_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    await db.execute(
        """
        INSERT INTO growth_records
            (id, child_id, date, height_cm, weight_kg, head_circumference_cm,
             notes, created_at, updated_at, created_by, client_id, client_timestamp, family_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            record_id,
            body.child_id,
            body.date,
            body.height_cm,
            body.weight_kg,
            body.head_circumference_cm,
            body.notes,
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
            current_user["family_id"],
        ),
    )
    await db.commit()

    cursor = await db.execute(
        "SELECT * FROM growth_records WHERE id = ?", (record_id,)
    )
    row = await cursor.fetchone()
    return _row_to_response(row)


@router.put("/{record_id}", response_model=GrowthRecordResponse)
async def update_growth_record(
    record_id: str,
    body: GrowthRecordUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update an existing growth record. Saves previous values to record_history."""
    cursor = await db.execute(
        "SELECT * FROM growth_records WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (record_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Growth record not found",
        )

    # Record history before modifying
    await save_history(
        db,
        "growth_records",
        record_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    updates = body.model_dump(exclude_unset=True)
    if not updates:
        return _row_to_response(existing)
    if body.child_id and not await family_child_exists(
        db,
        current_user["family_id"],
        body.child_id,
    ):
        raise HTTPException(status_code=400, detail="Child is not in this family")

    now = datetime.now(timezone.utc).isoformat()
    updates["updated_at"] = now

    set_clause = ", ".join(f"{col} = ?" for col in updates)
    values = list(updates.values()) + [record_id, current_user["family_id"]]

    await db.execute(
        f"UPDATE growth_records SET {set_clause} WHERE id = ? AND family_id = ?",
        values,
    )
    await db.commit()

    cursor = await db.execute(
        "SELECT * FROM growth_records WHERE id = ?", (record_id,)
    )
    row = await cursor.fetchone()
    return _row_to_response(row)


@router.delete("/{record_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_growth_record(
    record_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a growth record by setting deleted_at."""
    cursor = await db.execute(
        "SELECT * FROM growth_records WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (record_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Growth record not found",
        )

    # Record history before deleting
    await save_history(
        db,
        "growth_records",
        record_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE growth_records SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, record_id, current_user["family_id"]),
    )
    await db.commit()


@router.get("/chart/{child_id}", response_model=GrowthChartData)
async def growth_chart(
    child_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return all growth records for a child along with child info for charting."""
    # Fetch child info
    cursor = await db.execute(
        "SELECT id, name, date_of_birth FROM children WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (child_id, current_user["family_id"]),
    )
    child = await cursor.fetchone()
    if not child:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Child not found",
        )

    # Fetch all growth records for this child
    cursor = await db.execute(
        "SELECT * FROM growth_records WHERE child_id = ? AND deleted_at IS NULL AND family_id = ? ORDER BY date ASC",
        (child_id, current_user["family_id"]),
    )
    rows = await cursor.fetchall()

    return GrowthChartData(
        records=[_row_to_response(row) for row in rows],
        child_name=child["name"],
        child_dob=child["date_of_birth"],
    )

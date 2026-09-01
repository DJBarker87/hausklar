"""Children endpoint — establish and list children for the family."""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status

from app.auth import get_current_user
from app.database import get_db
from app.models.children import ChildCreate, ChildResponse

router = APIRouter()


@router.post("/", response_model=ChildResponse, status_code=status.HTTP_201_CREATED)
async def create_child(
    body: ChildCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Add a child to the household after the adult has reviewed the details."""
    child_id = str(body.id)
    existing = await (
        await db.execute(
            "SELECT id, name, date_of_birth FROM children WHERE id = ? AND family_id = ?",
            (child_id, current_user["family_id"]),
        )
    ).fetchone()
    if existing:
        if (
            existing["name"] == body.name
            and existing["date_of_birth"] == body.date_of_birth.isoformat()
        ):
            return ChildResponse(**dict(existing))
        raise HTTPException(status_code=409, detail="That child ID is already in use")
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """INSERT INTO children (
               id, name, date_of_birth, notes, family_id, created_at, updated_at,
               created_by, client_id, client_timestamp
           ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            child_id, body.name, body.date_of_birth.isoformat(), body.notes,
            current_user["family_id"], now, now, current_user["id"],
            body.client_id, body.client_timestamp,
        ),
    )
    await db.commit()
    return ChildResponse(
        id=child_id,
        name=body.name,
        date_of_birth=body.date_of_birth.isoformat(),
    )


@router.get("/", response_model=list[ChildResponse])
async def list_children(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return all children (not soft-deleted)."""
    cursor = await db.execute(
        "SELECT id, name, date_of_birth FROM children WHERE deleted_at IS NULL AND family_id = ? ORDER BY date_of_birth ASC",
        (current_user["family_id"],),
    )
    rows = await cursor.fetchall()
    return [ChildResponse(**dict(row)) for row in rows]

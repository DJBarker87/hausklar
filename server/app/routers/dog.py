import json
import uuid
from datetime import date as calendar_date
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import ValidationError

from app.auth import get_current_user
from app.database import get_db
from app.models.dog import (
    DogActivityCreate,
    DogActivityResponse,
    DogActivityUpdate,
    DogDocumentLinkCreate,
    DogDocumentLinkResponse,
    DogProfileResponse,
    DogProfileUpdate,
    DogStatusResponse,
    DogVaccinationCreate,
    DogVaccinationResponse,
    DogVaccinationUpdate,
    DogWeightCreate,
    DogWeightResponse,
    DogWeightUpdate,
)
from app.services.record_history import save_history

router = APIRouter()
DEFAULT_FAMILY_TIMEZONE = "Europe/London"
DOG_PROFILE_DEFAULTS = {
    "name": "Dog",
    "date_of_birth": None,
    "breed": None,
    "microchip_number": None,
    "insurance_provider": None,
    "insurance_policy_number": None,
    "vet_name": None,
    "vet_phone": None,
    "allergies": None,
    "medicine_notes": None,
    "breakfast_window_start": "07:00",
    "breakfast_window_end": "09:00",
    "walk_window_start": "10:00",
    "walk_window_end": "14:00",
    "dinner_window_start": "17:00",
    "dinner_window_end": "19:00",
}


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _family_zone(timezone_name: str) -> ZoneInfo:
    try:
        return ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=422, detail="Unknown timezone") from exc


def _local_day_bounds(day: calendar_date, zone: ZoneInfo) -> tuple[str, str]:
    local_start = datetime.combine(day, time.min, tzinfo=zone)
    local_end = local_start + timedelta(days=1)
    return (
        local_start.astimezone(timezone.utc).isoformat(),
        local_end.astimezone(timezone.utc).isoformat(),
    )


def _validate_care_windows(profile: dict) -> None:
    for label in ("breakfast", "walk", "dinner"):
        start = datetime.strptime(profile[f"{label}_window_start"], "%H:%M").time()
        end = datetime.strptime(profile[f"{label}_window_end"], "%H:%M").time()
        if end <= start:
            raise HTTPException(
                status_code=422,
                detail=f"{label.capitalize()} end time must be after its start time",
            )


async def _dog_profile(db, family_id: str) -> dict:
    cursor = await db.execute(
        "SELECT * FROM dog_profiles WHERE family_id = ? AND deleted_at IS NULL",
        (family_id,),
    )
    row = await cursor.fetchone()
    if row:
        return dict(row)
    return {"id": None, **DOG_PROFILE_DEFAULTS, "created_at": None, "updated_at": None}


def _care_state(
    *,
    completed: bool,
    now: datetime,
    start_value: str,
    end_value: str,
) -> str:
    if completed:
        return "done"
    local_time = now.timetz().replace(tzinfo=None)
    start = datetime.strptime(start_value, "%H:%M").time()
    end = datetime.strptime(end_value, "%H:%M").time()
    if local_time < start:
        return "upcoming"
    if local_time <= end:
        return "due"
    return "overdue"


async def _save_history(
    db,
    record_id: str,
    previous: dict,
    changed_by: str | None,
    *,
    family_id: str,
) -> None:
    """Insert a snapshot of the previous values into record_history."""
    await db.execute(
        """
        INSERT INTO record_history (
            id, table_name, record_id, previous_values, changed_by, changed_at, family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            "dog_activities",
            record_id,
            json.dumps(previous),
            changed_by,
            datetime.now(timezone.utc).isoformat(),
            family_id,
        ),
    )


@router.get("/profile", response_model=DogProfileResponse)
async def get_profile(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return the shared pet record and the family's chosen care times."""
    return DogProfileResponse(**await _dog_profile(db, current_user["family_id"]))


@router.put("/profile", response_model=DogProfileResponse)
async def update_profile(
    body: DogProfileUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create or update the family's single dog profile."""
    family_id = current_user["family_id"]
    existing = await _dog_profile(db, family_id)
    updates = body.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is None:
        raise HTTPException(status_code=422, detail="Dog name cannot be empty")
    for field in (
        "breakfast_window_start",
        "breakfast_window_end",
        "walk_window_start",
        "walk_window_end",
        "dinner_window_start",
        "dinner_window_end",
    ):
        if field in updates and updates[field] is None:
            raise HTTPException(status_code=422, detail="Care times cannot be empty")
    candidate = {**existing, **updates}
    _validate_care_windows(candidate)
    now = _utc_now().isoformat()

    if existing["id"]:
        await save_history(
            db,
            "dog_profiles",
            existing["id"],
            current_user["id"],
            family_id=family_id,
        )
        updates["updated_at"] = now
        if updates:
            set_clause = ", ".join(f"{field} = ?" for field in updates)
            await db.execute(
                f"UPDATE dog_profiles SET {set_clause} WHERE id = ? AND family_id = ?",
                (*updates.values(), existing["id"], family_id),
            )
        profile_id = existing["id"]
    else:
        profile_id = str(uuid.uuid4())
        stored = {**DOG_PROFILE_DEFAULTS, **updates}
        await db.execute(
            """
            INSERT INTO dog_profiles (
                id, name, date_of_birth, breed, microchip_number,
                insurance_provider, insurance_policy_number, vet_name, vet_phone,
                allergies, medicine_notes, breakfast_window_start,
                breakfast_window_end, walk_window_start, walk_window_end,
                dinner_window_start, dinner_window_end, family_id, created_at,
                updated_at, created_by, client_id, client_timestamp
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                profile_id,
                stored["name"],
                stored["date_of_birth"],
                stored["breed"],
                stored["microchip_number"],
                stored["insurance_provider"],
                stored["insurance_policy_number"],
                stored["vet_name"],
                stored["vet_phone"],
                stored["allergies"],
                stored["medicine_notes"],
                stored["breakfast_window_start"],
                stored["breakfast_window_end"],
                stored["walk_window_start"],
                stored["walk_window_end"],
                stored["dinner_window_start"],
                stored["dinner_window_end"],
                family_id,
                now,
                now,
                current_user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )
    await db.commit()
    cursor = await db.execute(
        "SELECT * FROM dog_profiles WHERE id = ? AND family_id = ?",
        (profile_id, family_id),
    )
    return DogProfileResponse(**dict(await cursor.fetchone()))


@router.get("/weights", response_model=list[DogWeightResponse])
async def list_weights(
    offset: int = 0,
    limit: int = 50,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if offset < 0 or limit < 1 or limit > 200:
        raise HTTPException(status_code=422, detail="Invalid pagination")
    cursor = await db.execute(
        "SELECT * FROM dog_weights WHERE family_id = ? AND deleted_at IS NULL "
        "ORDER BY measured_on DESC, created_at DESC LIMIT ? OFFSET ?",
        (current_user["family_id"], limit, offset),
    )
    return [DogWeightResponse(**dict(row)) for row in await cursor.fetchall()]


@router.post("/weights", response_model=DogWeightResponse, status_code=status.HTTP_201_CREATED)
async def create_weight(
    body: DogWeightCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    weight_id = str(uuid.uuid4())
    now = _utc_now().isoformat()
    await db.execute(
        """
        INSERT INTO dog_weights (
            id, measured_on, weight_kg, notes, family_id, created_at, updated_at,
            created_by, client_id, client_timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            weight_id,
            body.measured_on,
            body.weight_kg,
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
    cursor = await db.execute("SELECT * FROM dog_weights WHERE id = ?", (weight_id,))
    return DogWeightResponse(**dict(await cursor.fetchone()))


@router.patch("/weights/{weight_id}", response_model=DogWeightResponse)
async def update_weight(
    weight_id: str,
    body: DogWeightUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    cursor = await db.execute(
        "SELECT * FROM dog_weights WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (weight_id, family_id),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Weight record not found")
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        return DogWeightResponse(**dict(existing))
    await save_history(
        db, "dog_weights", weight_id, current_user["id"], family_id=family_id
    )
    updates["updated_at"] = _utc_now().isoformat()
    set_clause = ", ".join(f"{field} = ?" for field in updates)
    await db.execute(
        f"UPDATE dog_weights SET {set_clause} WHERE id = ? AND family_id = ?",
        (*updates.values(), weight_id, family_id),
    )
    await db.commit()
    cursor = await db.execute("SELECT * FROM dog_weights WHERE id = ?", (weight_id,))
    return DogWeightResponse(**dict(await cursor.fetchone()))


@router.delete("/weights/{weight_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_weight(
    weight_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    cursor = await db.execute(
        "SELECT id FROM dog_weights WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (weight_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=404, detail="Weight record not found")
    await save_history(
        db, "dog_weights", weight_id, current_user["id"], family_id=family_id
    )
    now = _utc_now().isoformat()
    await db.execute(
        "UPDATE dog_weights SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, weight_id, family_id),
    )
    await db.commit()


@router.post("/weights/{weight_id}/restore", response_model=DogWeightResponse)
async def restore_weight(
    weight_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    cursor = await db.execute(
        "SELECT id FROM dog_weights WHERE id = ? AND family_id = ? AND deleted_at IS NOT NULL",
        (weight_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=404, detail="Weight record not found")
    now = _utc_now().isoformat()
    await db.execute(
        "UPDATE dog_weights SET deleted_at = NULL, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, weight_id, family_id),
    )
    await db.commit()
    cursor = await db.execute("SELECT * FROM dog_weights WHERE id = ?", (weight_id,))
    return DogWeightResponse(**dict(await cursor.fetchone()))


def _dog_document_response(row) -> DogDocumentLinkResponse:
    data = dict(row)
    data["download_url"] = f"/api/documents/{data['document_id']}/content"
    return DogDocumentLinkResponse(**data)


@router.get("/documents", response_model=list[DogDocumentLinkResponse])
async def list_documents(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        """
        SELECT link.id, link.document_id, link.role, document.title,
               document.original_filename, document.media_type, document.file_size
        FROM dog_document_links link
        JOIN documents document ON document.id = link.document_id
          AND document.family_id = link.family_id
          AND document.deleted_at IS NULL
          AND document.status != 'archived'
        WHERE link.family_id = ? AND link.deleted_at IS NULL
        ORDER BY link.created_at DESC
        """,
        (current_user["family_id"],),
    )
    return [_dog_document_response(row) for row in await cursor.fetchall()]


@router.post("/documents", response_model=DogDocumentLinkResponse, status_code=201)
async def link_document(
    body: DogDocumentLinkCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    cursor = await db.execute(
        "SELECT id FROM documents WHERE id = ? AND family_id = ? "
        "AND deleted_at IS NULL AND status != 'archived'",
        (body.document_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=404, detail="Document not found")
    cursor = await db.execute(
        "SELECT * FROM dog_document_links WHERE family_id = ? AND document_id = ?",
        (family_id, body.document_id),
    )
    existing = await cursor.fetchone()
    now = _utc_now().isoformat()
    if existing:
        link_id = existing["id"]
        await db.execute(
            "UPDATE dog_document_links SET role = ?, deleted_at = NULL, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (body.role, now, link_id, family_id),
        )
    else:
        link_id = str(uuid.uuid4())
        await db.execute(
            "INSERT INTO dog_document_links "
            "(id, document_id, role, family_id, created_at, updated_at, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                link_id,
                body.document_id,
                body.role,
                family_id,
                now,
                now,
                current_user["id"],
            ),
        )
    await db.commit()
    cursor = await db.execute(
        """
        SELECT link.id, link.document_id, link.role, document.title,
               document.original_filename, document.media_type, document.file_size
        FROM dog_document_links link
        JOIN documents document ON document.id = link.document_id
        WHERE link.id = ? AND link.family_id = ?
        """,
        (link_id, family_id),
    )
    return _dog_document_response(await cursor.fetchone())


@router.delete("/documents/{link_id}", status_code=status.HTTP_204_NO_CONTENT)
async def unlink_document(
    link_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    cursor = await db.execute(
        "SELECT id FROM dog_document_links WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (link_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=404, detail="Document link not found")
    now = _utc_now().isoformat()
    await db.execute(
        "UPDATE dog_document_links SET deleted_at = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, link_id, family_id),
    )
    await db.commit()


@router.get("/vaccinations", response_model=list[DogVaccinationResponse])
async def list_vaccinations(
    offset: int = 0,
    limit: int = 50,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List the family dog's vaccination history, newest first."""
    if offset < 0 or limit < 1 or limit > 200:
        raise HTTPException(status_code=422, detail="Invalid pagination")
    cursor = await db.execute(
        """SELECT * FROM dog_vaccinations
           WHERE family_id = ? AND deleted_at IS NULL
           ORDER BY given_on DESC, created_at DESC LIMIT ? OFFSET ?""",
        (current_user["family_id"], limit, offset),
    )
    return [DogVaccinationResponse(**dict(row)) for row in await cursor.fetchall()]


@router.post(
    "/vaccinations",
    response_model=DogVaccinationResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_vaccination(
    body: DogVaccinationCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Add a structured vaccination record for the family dog."""
    vaccination_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """INSERT INTO dog_vaccinations (
               id, vaccine_name, given_on, next_due_on, notes, family_id,
               created_at, updated_at, created_by, client_id, client_timestamp
           ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            vaccination_id,
            body.vaccine_name,
            body.given_on,
            body.next_due_on,
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
    cursor = await db.execute(
        "SELECT * FROM dog_vaccinations WHERE id = ? AND family_id = ?",
        (vaccination_id, current_user["family_id"]),
    )
    return DogVaccinationResponse(**dict(await cursor.fetchone()))


@router.patch("/vaccinations/{vaccination_id}", response_model=DogVaccinationResponse)
async def update_vaccination(
    vaccination_id: str,
    body: DogVaccinationUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    cursor = await db.execute(
        "SELECT * FROM dog_vaccinations WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (vaccination_id, family_id),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Vaccination not found")
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        return DogVaccinationResponse(**dict(existing))
    candidate = {**dict(existing), **updates}
    try:
        DogVaccinationCreate(
            vaccine_name=candidate["vaccine_name"],
            given_on=candidate["given_on"],
            next_due_on=candidate["next_due_on"],
            notes=candidate["notes"],
        )
    except ValidationError as exc:
        message = str(exc.errors()[0].get("ctx", {}).get("error", "Invalid vaccination"))
        raise HTTPException(status_code=422, detail=message) from exc
    await save_history(
        db,
        "dog_vaccinations",
        vaccination_id,
        current_user["id"],
        family_id=family_id,
    )
    updates["updated_at"] = _utc_now().isoformat()
    set_clause = ", ".join(f"{field} = ?" for field in updates)
    await db.execute(
        f"UPDATE dog_vaccinations SET {set_clause} WHERE id = ? AND family_id = ?",
        (*updates.values(), vaccination_id, family_id),
    )
    await db.commit()
    cursor = await db.execute(
        "SELECT * FROM dog_vaccinations WHERE id = ? AND family_id = ?",
        (vaccination_id, family_id),
    )
    return DogVaccinationResponse(**dict(await cursor.fetchone()))


@router.delete("/vaccinations/{vaccination_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_vaccination(
    vaccination_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a dog vaccination, retaining its change history."""
    family_id = current_user["family_id"]
    cursor = await db.execute(
        """SELECT id FROM dog_vaccinations
           WHERE id = ? AND family_id = ? AND deleted_at IS NULL""",
        (vaccination_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Vaccination not found")
    await save_history(
        db,
        "dog_vaccinations",
        vaccination_id,
        current_user["id"],
        family_id=family_id,
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """UPDATE dog_vaccinations SET deleted_at = ?, updated_at = ?
           WHERE id = ? AND family_id = ?""",
        (now, now, vaccination_id, family_id),
    )
    await db.commit()


@router.post(
    "/vaccinations/{vaccination_id}/restore",
    response_model=DogVaccinationResponse,
)
async def restore_vaccination(
    vaccination_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    cursor = await db.execute(
        "SELECT id FROM dog_vaccinations WHERE id = ? AND family_id = ? "
        "AND deleted_at IS NOT NULL",
        (vaccination_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=404, detail="Vaccination not found")
    now = _utc_now().isoformat()
    await db.execute(
        "UPDATE dog_vaccinations SET deleted_at = NULL, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, vaccination_id, family_id),
    )
    await db.commit()
    cursor = await db.execute(
        "SELECT * FROM dog_vaccinations WHERE id = ? AND family_id = ?",
        (vaccination_id, family_id),
    )
    return DogVaccinationResponse(**dict(await cursor.fetchone()))


@router.get("/activities", response_model=list[DogActivityResponse])
async def list_activities(
    type: str | None = None,
    date: str | None = None,
    timezone_name: str = Query(
        DEFAULT_FAMILY_TIMEZONE,
        alias="timezone",
        min_length=1,
        max_length=100,
    ),
    offset: int = 0,
    limit: int = 50,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List dog activities with optional filters. Excludes soft-deleted records."""
    query = "SELECT * FROM dog_activities WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]

    if type is not None:
        query += " AND activity_type = ?"
        params.append(type)

    if date is not None:
        try:
            requested_day = calendar_date.fromisoformat(date)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail="Date must use YYYY-MM-DD") from exc
        if requested_day.isoformat() != date:
            raise HTTPException(status_code=422, detail="Date must use YYYY-MM-DD")
        day_start, day_end = _local_day_bounds(
            requested_day,
            _family_zone(timezone_name),
        )
        query += (
            " AND julianday(started_at) >= julianday(?)"
            " AND julianday(started_at) < julianday(?)"
        )
        params.extend([day_start, day_end])

    query += " ORDER BY julianday(started_at) DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [DogActivityResponse(**dict(row)) for row in rows]


@router.post("/activities", response_model=DogActivityResponse, status_code=status.HTTP_201_CREATED)
async def create_activity(
    body: DogActivityCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a new dog activity."""
    activity_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    if body.is_active:
        cursor = await db.execute(
            "SELECT id FROM dog_activities WHERE family_id = ? AND is_active = 1 "
            "AND deleted_at IS NULL",
            (current_user["family_id"],),
        )
        if await cursor.fetchone():
            raise HTTPException(status_code=409, detail="A walk is already in progress")

    await db.execute(
        """
        INSERT INTO dog_activities (
            id, activity_type, started_at, ended_at, notes, is_active, done_by,
            created_at, updated_at, created_by, client_id, client_timestamp, family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            activity_id,
            body.activity_type,
            body.started_at,
            body.ended_at,
            body.notes,
            body.is_active,
            current_user["id"],
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
            current_user["family_id"],
        ),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM dog_activities WHERE id = ?", (activity_id,))
    row = await cursor.fetchone()
    return DogActivityResponse(**dict(row))


@router.put("/activities/{activity_id}", response_model=DogActivityResponse)
async def update_activity(
    activity_id: str,
    body: DogActivityUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update an existing dog activity. Saves previous values to record_history."""
    cursor = await db.execute(
        "SELECT * FROM dog_activities WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (activity_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Activity not found")

    updates = body.model_dump(exclude_unset=True)
    if not updates:
        return DogActivityResponse(**dict(existing))

    resulting_start = updates.get("started_at", existing["started_at"])
    resulting_end = updates.get("ended_at", existing["ended_at"])
    resulting_type = updates.get("activity_type", existing["activity_type"])
    resulting_active = updates.get("is_active", bool(existing["is_active"]))
    if resulting_end is not None:
        start_time = datetime.fromisoformat(resulting_start.replace("Z", "+00:00"))
        end_time = datetime.fromisoformat(resulting_end.replace("Z", "+00:00"))
        if end_time < start_time:
            raise HTTPException(status_code=422, detail="End time cannot be before start time")
        resulting_active = False
        updates["is_active"] = False
    if resulting_active and resulting_type != "walk":
        raise HTTPException(status_code=422, detail="Only a walk can be tracked live")
    if resulting_active:
        cursor = await db.execute(
            "SELECT id FROM dog_activities WHERE family_id = ? AND is_active = 1 "
            "AND id != ? AND deleted_at IS NULL",
            (current_user["family_id"], activity_id),
        )
        if await cursor.fetchone():
            raise HTTPException(status_code=409, detail="A walk is already in progress")

    await _save_history(
        db,
        activity_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    updates["updated_at"] = now

    set_clause = ", ".join(f"{key} = ?" for key in updates)
    values = list(updates.values()) + [activity_id, current_user["family_id"]]

    await db.execute(
        f"UPDATE dog_activities SET {set_clause} WHERE id = ? AND family_id = ?",
        values,
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM dog_activities WHERE id = ?", (activity_id,))
    row = await cursor.fetchone()
    return DogActivityResponse(**dict(row))


@router.delete("/activities/{activity_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_activity(
    activity_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a dog activity by setting deleted_at."""
    cursor = await db.execute(
        "SELECT * FROM dog_activities WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (activity_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Activity not found")

    # Save history before modifying
    await _save_history(
        db,
        activity_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE dog_activities SET deleted_at = ?, is_active = 0, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, activity_id, current_user["family_id"]),
    )
    await db.commit()


@router.post("/activities/{activity_id}/restore", response_model=DogActivityResponse)
async def restore_activity(
    activity_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Restore a recently removed dog activity."""
    cursor = await db.execute(
        "SELECT * FROM dog_activities "
        "WHERE id = ? AND deleted_at IS NOT NULL AND family_id = ?",
        (activity_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Activity not found")
    await _save_history(
        db,
        activity_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE dog_activities SET deleted_at = NULL, is_active = 0, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, activity_id, current_user["family_id"]),
    )
    await db.commit()
    cursor = await db.execute(
        "SELECT * FROM dog_activities WHERE id = ? AND family_id = ?",
        (activity_id, current_user["family_id"]),
    )
    return DogActivityResponse(**dict(await cursor.fetchone()))


@router.get("/status", response_model=DogStatusResponse)
async def get_status(
    timezone_name: str = Query(
        DEFAULT_FAMILY_TIMEZONE,
        alias="timezone",
        min_length=1,
        max_length=100,
    ),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return today's dog status: walked and fed booleans plus last walk/feed."""
    zone = _family_zone(timezone_name)
    local_now = _utc_now().astimezone(zone)
    today = local_now.date()
    day_start, day_end = _local_day_bounds(today, zone)
    cursor = await db.execute(
        """
        WITH ranked AS (
            SELECT dog_activities.*,
                   MAX(CASE
                           WHEN julianday(started_at) >= julianday(?)
                            AND julianday(started_at) < julianday(?)
                            AND (activity_type != 'walk' OR is_active = 0)
                           THEN 1 ELSE 0
                       END) OVER (PARTITION BY activity_type) AS occurred_today,
                   ROW_NUMBER() OVER (
                       PARTITION BY activity_type ORDER BY julianday(started_at) DESC
                   ) AS recency_rank
            FROM dog_activities
            WHERE activity_type IN ('walk', 'feed_breakfast', 'feed_dinner')
              AND deleted_at IS NULL
              AND family_id = ?
        )
        SELECT * FROM ranked WHERE recency_rank = 1
        """,
        (day_start, day_end, current_user["family_id"]),
    )
    latest_by_type = {row["activity_type"]: dict(row) for row in await cursor.fetchall()}

    active_cursor = await db.execute(
        "SELECT * FROM dog_activities WHERE family_id = ? AND activity_type = 'walk' "
        "AND is_active = 1 AND deleted_at IS NULL ORDER BY started_at DESC LIMIT 1",
        (current_user["family_id"],),
    )
    active_walk_row = await active_cursor.fetchone()
    profile = await _dog_profile(db, current_user["family_id"])

    def latest(activity_type: str) -> DogActivityResponse | None:
        stored_row = latest_by_type.get(activity_type)
        if stored_row is None:
            return None
        row = stored_row.copy()
        row.pop("occurred_today", None)
        row.pop("recency_rank", None)
        return DogActivityResponse(**row)

    def occurred_today(activity_type: str) -> bool:
        row = latest_by_type.get(activity_type)
        return bool(row and row["occurred_today"])

    return DogStatusResponse(
        walked_today=occurred_today("walk"),
        fed_breakfast_today=occurred_today("feed_breakfast"),
        fed_dinner_today=occurred_today("feed_dinner"),
        last_walk=latest("walk"),
        last_feed_breakfast=latest("feed_breakfast"),
        last_feed_dinner=latest("feed_dinner"),
        active_walk=DogActivityResponse(**dict(active_walk_row)) if active_walk_row else None,
        dog_name=profile["name"],
        walk_state=_care_state(
            completed=occurred_today("walk"),
            now=local_now,
            start_value=profile["walk_window_start"],
            end_value=profile["walk_window_end"],
        ),
        breakfast_state=_care_state(
            completed=occurred_today("feed_breakfast"),
            now=local_now,
            start_value=profile["breakfast_window_start"],
            end_value=profile["breakfast_window_end"],
        ),
        dinner_state=_care_state(
            completed=occurred_today("feed_dinner"),
            now=local_now,
            start_value=profile["dinner_window_start"],
            end_value=profile["dinner_window_end"],
        ),
    )

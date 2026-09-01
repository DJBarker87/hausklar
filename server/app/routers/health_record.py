"""Children's health-record API — milestones, vaccinations, growth centiles and
a GP-ready illness summary. Records and reminders only, not medical advice."""

import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.health_record import (
    GrowthCentilesResponse,
    MilestoneAchieveRequest,
    MilestonesResponse,
    SexUpdateRequest,
    SummaryResponse,
    VaccinationRecordRequest,
    VaccinationsResponse,
)
from app.services.health_record import (
    GROWTH_DISCLAIMER,
    MILESTONE_DISCLAIMER,
    SUMMARY_DISCLAIMER,
    VACCINATION_DISCLAIMER,
    _parse_date,
    age_in_months,
    build_summary,
    get_family_child,
    growth_centiles,
    list_milestones,
    list_vaccinations,
    milestone_exists,
    vaccine_exists,
    vaccine_applies_to_dob,
)
from app.services.record_history import save_history

router = APIRouter()


async def _require_child(db, family_id: str, child_id: str) -> dict:
    """Fetch the child within the family or raise 404 (also hides other families)."""
    child = await get_family_child(db, family_id, child_id)
    if child is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Child not found")
    return child


# ---------------------------------------------------------------------------
# Developmental milestones
# ---------------------------------------------------------------------------


@router.get("/{child_id}/milestones", response_model=MilestonesResponse)
async def get_milestones(
    child_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Reference milestones merged with this child's achieved status."""
    child = await _require_child(db, current_user["family_id"], child_id)
    return MilestonesResponse(
        child_id=child_id,
        child_name=child["name"],
        age_months=age_in_months(_parse_date(child["date_of_birth"])),
        milestones=await list_milestones(db, current_user["family_id"], child),
        disclaimer=MILESTONE_DISCLAIMER,
    )


@router.post("/{child_id}/milestones", response_model=MilestonesResponse)
async def achieve_milestone(
    child_id: str,
    body: MilestoneAchieveRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Mark a milestone achieved (idempotent upsert per child + milestone)."""
    child = await _require_child(db, current_user["family_id"], child_id)
    if not milestone_exists(body.milestone_key):
        raise HTTPException(status_code=400, detail="Unknown milestone")

    family_id = current_user["family_id"]
    now = datetime.now(timezone.utc).isoformat()
    cursor = await db.execute(
        """SELECT id FROM child_milestones
           WHERE child_id = ? AND milestone_key = ? AND family_id = ? AND deleted_at IS NULL""",
        (child_id, body.milestone_key, family_id),
    )
    existing = await cursor.fetchone()
    if existing:
        await save_history(db, "child_milestones", existing["id"], current_user["id"], family_id=family_id)
        await db.execute(
            "UPDATE child_milestones SET achieved_on = ?, note = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (body.achieved_on, body.note, now, existing["id"], family_id),
        )
    else:
        await db.execute(
            """INSERT INTO child_milestones
               (id, child_id, milestone_key, achieved_on, note, family_id,
                created_at, updated_at, created_by, client_id, client_timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (str(uuid.uuid4()), child_id, body.milestone_key, body.achieved_on, body.note,
             family_id, now, now, current_user["id"], body.client_id, body.client_timestamp),
        )
    await db.commit()

    return MilestonesResponse(
        child_id=child_id,
        child_name=child["name"],
        age_months=age_in_months(_parse_date(child["date_of_birth"])),
        milestones=await list_milestones(db, family_id, child),
        disclaimer=MILESTONE_DISCLAIMER,
    )


@router.delete("/{child_id}/milestones/{milestone_key}", status_code=status.HTTP_204_NO_CONTENT)
async def unmark_milestone(
    child_id: str,
    milestone_key: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete an achieved milestone."""
    family_id = current_user["family_id"]
    await _require_child(db, family_id, child_id)
    cursor = await db.execute(
        """SELECT id FROM child_milestones
           WHERE child_id = ? AND milestone_key = ? AND family_id = ? AND deleted_at IS NULL""",
        (child_id, milestone_key, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Milestone not marked")

    await save_history(db, "child_milestones", row["id"], current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE child_milestones SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, row["id"], family_id),
    )
    await db.commit()


# ---------------------------------------------------------------------------
# Vaccinations
# ---------------------------------------------------------------------------


@router.get("/{child_id}/vaccinations", response_model=VaccinationsResponse)
async def get_vaccinations(
    child_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """The routine schedule with due dates and status computed from the child's DOB."""
    child = await _require_child(db, current_user["family_id"], child_id)
    return VaccinationsResponse(
        child_id=child_id,
        child_name=child["name"],
        age_months=age_in_months(_parse_date(child["date_of_birth"])),
        vaccinations=await list_vaccinations(db, current_user["family_id"], child),
        disclaimer=VACCINATION_DISCLAIMER,
    )


@router.post("/{child_id}/vaccinations", response_model=VaccinationsResponse)
async def record_vaccination(
    child_id: str,
    body: VaccinationRecordRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Record a routine dose or a named additional vaccination.

    Routine doses remain idempotent by schedule key. Additional vaccinations
    receive a server-generated key so repeated doses can each be preserved.
    """
    child = await _require_child(db, current_user["family_id"], child_id)
    if body.vaccine_key is not None:
        if not vaccine_exists(body.vaccine_key):
            raise HTTPException(status_code=400, detail="Unknown vaccine")
        if not vaccine_applies_to_dob(
            body.vaccine_key, _parse_date(child["date_of_birth"])
        ):
            raise HTTPException(
                status_code=400,
                detail="Vaccine is not in this child's default schedule; add it as an additional vaccination",
            )

    vaccine_key = body.vaccine_key or f"custom:{uuid.uuid4()}"
    vaccine_name = body.vaccine_name if body.vaccine_key is None else None

    family_id = current_user["family_id"]
    now = datetime.now(timezone.utc).isoformat()
    cursor = await db.execute(
        """SELECT id FROM child_vaccinations
           WHERE child_id = ? AND vaccine_key = ? AND family_id = ? AND deleted_at IS NULL""",
        (child_id, vaccine_key, family_id),
    )
    existing = await cursor.fetchone()
    if existing:
        await save_history(db, "child_vaccinations", existing["id"], current_user["id"], family_id=family_id)
        await db.execute(
            "UPDATE child_vaccinations SET given_on = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (body.given_on, now, existing["id"], family_id),
        )
    else:
        await db.execute(
            """INSERT INTO child_vaccinations
               (id, child_id, vaccine_key, vaccine_name, given_on, family_id,
                created_at, updated_at, created_by, client_id, client_timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (str(uuid.uuid4()), child_id, vaccine_key, vaccine_name, body.given_on, family_id,
             now, now, current_user["id"], body.client_id, body.client_timestamp),
        )
    await db.commit()

    return VaccinationsResponse(
        child_id=child_id,
        child_name=child["name"],
        age_months=age_in_months(_parse_date(child["date_of_birth"])),
        vaccinations=await list_vaccinations(db, family_id, child),
        disclaimer=VACCINATION_DISCLAIMER,
    )


@router.delete("/{child_id}/vaccinations/{vaccine_key}", status_code=status.HTTP_204_NO_CONTENT)
async def unrecord_vaccination(
    child_id: str,
    vaccine_key: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a recorded vaccination."""
    family_id = current_user["family_id"]
    await _require_child(db, family_id, child_id)
    cursor = await db.execute(
        """SELECT id FROM child_vaccinations
           WHERE child_id = ? AND vaccine_key = ? AND family_id = ? AND deleted_at IS NULL""",
        (child_id, vaccine_key, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Vaccination not recorded")

    await save_history(db, "child_vaccinations", row["id"], current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE child_vaccinations SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, row["id"], family_id),
    )
    await db.commit()


# ---------------------------------------------------------------------------
# Growth centiles
# ---------------------------------------------------------------------------


@router.patch("/{child_id}/sex")
async def set_child_sex(
    child_id: str,
    body: SexUpdateRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Set (or clear) a child's sex so growth centiles can be computed."""
    family_id = current_user["family_id"]
    await _require_child(db, family_id, child_id)
    await save_history(db, "children", child_id, current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE children SET sex = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (body.sex, now, child_id, family_id),
    )
    await db.commit()
    return {"child_id": child_id, "sex": body.sex}


@router.get("/{child_id}/growth-centiles", response_model=GrowthCentilesResponse)
async def get_growth_centiles(
    child_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Per-measurement WHO centiles plus reference bands for charting."""
    child = await _require_child(db, current_user["family_id"], child_id)
    result = await growth_centiles(db, current_user["family_id"], child)
    return GrowthCentilesResponse(
        child_id=child_id,
        child_name=child["name"],
        sex=child.get("sex"),
        measurements=result["measurements"],
        weight_reference=result["weight_reference"],
        height_reference=result["height_reference"],
        disclaimer=GROWTH_DISCLAIMER,
        note=result["note"],
    )


# ---------------------------------------------------------------------------
# GP-ready illness summary
# ---------------------------------------------------------------------------


@router.get("/{child_id}/summary", response_model=SummaryResponse)
async def get_summary(
    child_id: str,
    since: str | None = Query(None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """A shareable illness/temperature/medicine timeline for the window."""
    child = await _require_child(db, current_user["family_id"], child_id)
    now = datetime.now(timezone.utc)
    if since is None:
        since = (now.date() - timedelta(days=90)).isoformat()
    elif _parse_date(since) is None:
        raise HTTPException(status_code=400, detail="Invalid since date (use YYYY-MM-DD)")

    summary = await build_summary(db, current_user["family_id"], child, since, now.isoformat())
    return SummaryResponse(
        child_id=child_id,
        child_name=child["name"],
        since=since,
        until=now.date().isoformat(),
        illnesses=summary["illnesses"],
        temperatures=summary["temperatures"],
        medicine_doses=summary["medicine_doses"],
        report=summary["report"],
        disclaimer=SUMMARY_DISCLAIMER,
    )

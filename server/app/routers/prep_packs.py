"""Reusable preparation packs suggested from upcoming calendar events."""

import json
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.prep_pack import (
    PrepPackAction,
    PrepPackTemplateCreate,
    PrepPackTemplateUpdate,
)
from app.services.family_people import family_people_exist
from app.services.prep_packs import (
    apply_pack,
    dismiss_pack,
    list_templates,
    suggestions,
    template_response,
)
from app.services.record_history import save_history

router = APIRouter()


@router.get("/templates")
async def get_templates(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await list_templates(db, current_user["family_id"])


@router.post("/templates", status_code=status.HTTP_201_CREATED)
async def create_template(
    body: PrepPackTemplateCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    if body.assigned_to and not await family_people_exist(db, family_id, [body.assigned_to]):
        raise HTTPException(status_code=400, detail="Assignee is not in this family")
    now = datetime.now(timezone.utc).isoformat()
    template_id = str(uuid.uuid4())
    await db.execute(
        """INSERT INTO event_prep_templates
           (id, name, match_terms, items, lead_hours, assigned_to, enabled,
            family_id, created_at, updated_at, created_by, client_id)
           VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)""",
        (
            template_id,
            body.name.strip(),
            json.dumps(body.match_terms),
            json.dumps(body.items),
            body.lead_hours,
            body.assigned_to,
            family_id,
            now,
            now,
            current_user["id"],
            f"prep-template:{template_id}",
        ),
    )
    await db.commit()
    row = await (
        await db.execute("SELECT * FROM event_prep_templates WHERE id = ?", (template_id,))
    ).fetchone()
    return template_response(row)


@router.patch("/templates/{template_id}")
async def update_template(
    template_id: str,
    body: PrepPackTemplateUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    row = await (
        await db.execute(
            "SELECT * FROM event_prep_templates WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (template_id, family_id),
        )
    ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Preparation pack not found")
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(status_code=422, detail="No preparation pack changes supplied")
    if updates.get("assigned_to") and not await family_people_exist(
        db, family_id, [updates["assigned_to"]]
    ):
        raise HTTPException(status_code=400, detail="Assignee is not in this family")
    if "match_terms" in updates:
        updates["match_terms"] = json.dumps(updates["match_terms"])
    if "items" in updates:
        updates["items"] = json.dumps(updates["items"])
    if "enabled" in updates:
        updates["enabled"] = int(updates["enabled"])
    if "name" in updates:
        updates["name"] = updates["name"].strip()
    await save_history(
        db, "event_prep_templates", template_id, current_user["id"], family_id=family_id
    )
    now = datetime.now(timezone.utc).isoformat()
    clause = ", ".join(f"{key} = ?" for key in updates)
    await db.execute(
        f"UPDATE event_prep_templates SET {clause}, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        [*updates.values(), now, template_id, family_id],
    )
    await db.commit()
    updated = await (
        await db.execute("SELECT * FROM event_prep_templates WHERE id = ?", (template_id,))
    ).fetchone()
    return template_response(updated)


@router.delete("/templates/{template_id}", status_code=204)
async def delete_template(
    template_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    row = await (
        await db.execute(
            "SELECT id FROM event_prep_templates WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (template_id, family_id),
        )
    ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Preparation pack not found")
    await save_history(
        db, "event_prep_templates", template_id, current_user["id"], family_id=family_id
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE event_prep_templates SET deleted_at = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, template_id, family_id),
    )
    await db.commit()
    return Response(status_code=204)


@router.get("/suggestions")
async def get_suggestions(
    timezone_name: str = Query("Europe/London", alias="timezone", max_length=50),
    horizon_days: int = Query(7, ge=1, le=14),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await suggestions(
        db,
        family_id=current_user["family_id"],
        timezone_name=timezone_name,
        horizon_days=horizon_days,
    )


@router.post("/apply")
async def apply_suggestion(
    body: PrepPackAction,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await apply_pack(
            db, family_id=current_user["family_id"], user=current_user, action=body
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.post("/dismiss")
async def dismiss_suggestion(
    body: PrepPackAction,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await dismiss_pack(
            db, family_id=current_user["family_id"], user=current_user, action=body
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc

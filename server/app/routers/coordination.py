from datetime import datetime, timedelta

from fastapi import APIRouter, Depends

from app.auth import get_current_user
from app.database import get_db
from app.models.coordination import (
    LoadAssignmentRequest,
    ShareDraftCreate,
    ShareDraftCreated,
    ShareDraftResponse,
    TomorrowAcknowledgement,
    TomorrowCard,
)
from app.services.coordination import (
    assign_load,
    claim_share_draft,
    create_share_draft,
    record_action,
    tomorrow_card,
)

router = APIRouter()


@router.get("/tomorrow", response_model=TomorrowCard)
async def get_tomorrow(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    return await tomorrow_card(db, current_user)


@router.post("/tomorrow/ack", status_code=204)
async def acknowledge_tomorrow(
    body: TomorrowAcknowledgement,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await record_action(db, current_user, action_kind="tomorrow_ack", target_date=body.target_date)


@router.post("/load/{task_id}/later", status_code=204)
async def defer_load_prompt(task_id: str, current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    cursor = await db.execute(
        "SELECT 1 FROM tasks WHERE id=? AND family_id=? AND deleted_at IS NULL",
        (task_id, current_user["family_id"]),
    )
    if not await cursor.fetchone():
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="Task not found")
    target = (datetime.now().astimezone().date() + timedelta(days=1)).isoformat()
    await record_action(db, current_user, action_kind="load_later", target_date=target, entity_id=task_id)


@router.post("/load/{task_id}/assign", status_code=204)
async def assign_load_prompt(
    task_id: str,
    body: LoadAssignmentRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await assign_load(db, current_user, task_id=task_id, assignee_id=body.assignee_id)


@router.post("/shares", response_model=ShareDraftCreated, status_code=201)
async def add_share(body: ShareDraftCreate, current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    identifier = await create_share_draft(db, current_user, text=body.text, title=body.title, url=body.url)
    return {"id": identifier}


@router.get("/shares/{draft_id}", response_model=ShareDraftResponse)
async def get_share(draft_id: str, current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    return {"id": draft_id, "text": await claim_share_draft(db, current_user, draft_id)}

"""Family insight endpoints — School Brain gap-detection findings."""

import re
import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request

from app.auth import get_current_user
from app.database import get_db
from app.middleware.rate_limit import RateLimiter, extract_client_ip
from app.services.ai_consent import require_ai_consent
from app.services.school_brain import generate_insights
from app.services.second_brain import detect_logistics

router = APIRouter()
refresh_limiter = RateLimiter(max_attempts=3, window_seconds=3_600)


def _suggested_task_title(kind: str, message: str, detail: str | None) -> str | None:
    """Turn a preparation gap into a short, deterministic one-tap task."""
    if kind != "prep":
        return None
    text = f"{message} {detail or ''}".lower()
    if "swim" in text:
        return "Pack swim kit and towels"
    if "football" in text:
        return "Pack football kit and water bottle"
    if re.search(r"\bp\.?e\.?\b", text):
        return "Pack PE kit and water bottle"
    if "rain" in text or "wellies" in text:
        return "Pack coats and wellies"
    activity = re.split(r"\b(?:is|are|starts?|tomorrow|today)\b", message, maxsplit=1)[0]
    activity = activity.strip(" .,:;–—-")[:80]
    return f"Prepare for {activity}" if activity else "Pack what is needed"


def _insight_response(row) -> dict:
    item = dict(row)
    item["suggested_task_title"] = _suggested_task_title(
        item["kind"], item["message"], item.get("detail")
    )
    return item


@router.get("/")
async def list_insights(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Active insights for the family, soonest target date first."""
    cursor = await db.execute(
        """SELECT id, kind, message, detail, target_date, source_document_id, created_at
           FROM family_insights
           WHERE family_id = ? AND status = 'active' AND deleted_at IS NULL
             AND (target_date IS NULL OR target_date >= ?)
           ORDER BY target_date IS NULL, target_date, created_at DESC
           LIMIT 20""",
        (current_user["family_id"], date.today().isoformat()),
    )
    return [_insight_response(row) for row in await cursor.fetchall()]


@router.post("/refresh")
async def refresh_insights(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """Manually run the School Brain and logistics check for this family."""
    require_ai_consent(current_user)
    key = f"insights-refresh:{current_user['id']}:{extract_client_ip(request)}"
    refresh_limiter.ensure_allowed(
        key, detail_prefix="Too many insight refresh requests"  # gitleaks:allow
    )
    refresh_limiter.record_failure(key)
    # Logistics is deterministic and always runs; School Brain needs the bridge.
    logistics = await detect_logistics(current_user["family_id"])
    gaps = await generate_insights(current_user["family_id"])
    return [*logistics, *gaps]


@router.post("/{insight_id}/dismiss")
async def dismiss_insight(
    insight_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Dismiss an active insight so it stops appearing for the family."""
    cursor = await db.execute(
        "SELECT status FROM family_insights WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (insight_id, current_user["family_id"]),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Insight not found")
    if row["status"] != "active":
        raise HTTPException(status_code=409, detail="Insight is already dismissed")
    await db.execute(
        "UPDATE family_insights SET status = 'dismissed', updated_at = ? WHERE id = ?",
        (datetime.now(timezone.utc).isoformat(), insight_id),
    )
    await db.commit()
    return {"status": "dismissed"}


@router.post("/{insight_id}/add-task")
async def add_insight_task(
    insight_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create the suggested preparation task exactly once and retire the notice."""
    family_id = current_user["family_id"]
    client_id = f"insight-prep:{insight_id}"
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT id, title FROM tasks "
            "WHERE family_id = ? AND client_id = ? AND deleted_at IS NULL",
            (family_id, client_id),
        )
        existing = await cursor.fetchone()
        if existing:
            await db.commit()
            return {"status": "task_added", "task_id": existing["id"], "title": existing["title"]}

        cursor = await db.execute(
            "SELECT kind, message, detail, target_date FROM family_insights "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (insight_id, family_id),
        )
        insight = await cursor.fetchone()
        if not insight:
            raise HTTPException(status_code=404, detail="Insight not found")
        title = _suggested_task_title(insight["kind"], insight["message"], insight["detail"])
        if not title:
            raise HTTPException(status_code=422, detail="This notice does not have a suggested task")

        now = datetime.now(timezone.utc).isoformat()
        task_id = str(uuid.uuid4())
        due_date = insight["target_date"]
        await db.execute(
            """INSERT INTO tasks
               (id, title, description, due_date, category, priority, family_id,
                created_at, updated_at, created_by, client_id)
               VALUES (?, ?, ?, ?, 'household', 2, ?, ?, ?, ?, ?)""",
            (
                task_id,
                title,
                f"Added from HausKlar notice: {insight['message']}",
                due_date,
                family_id,
                now,
                now,
                current_user["id"],
                client_id,
            ),
        )
        await db.execute(
            "UPDATE family_insights SET status = 'dismissed', updated_at = ? WHERE id = ?",
            (now, insight_id),
        )
        await db.commit()
        return {"status": "task_added", "task_id": task_id, "title": title}
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

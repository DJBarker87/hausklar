"""Recipient-first gift planning endpoints."""

import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.presents import (
    ChildPresentsResponse,
    PresentDuplicateCheck,
    PresentDuplicateMatch,
    PresentDuplicateResponse,
    PresentIdeaCreate,
    PresentIdeaResponse,
    PresentIdeaScoreUpsert,
    PresentIdeaUpdate,
    PresentOccasionBoardResponse,
    PresentOccasionBucket,
    PresentOccasionChildColumn,
    PresentScoreResponse,
    PresentStatus,
    PresentStatusHistoryResponse,
    PresentStatusUpdate,
)
from app.services.record_history import save_history

router = APIRouter()

DEFAULT_OCCASIONS = ("christmas", "birthday", "easter")
PRESENT_STATUSES = (
    "idea",
    "shortlist",
    "assigned",
    "bought",
    "arrived",
    "wrapped",
    "stashed",
    "given",
)

IDEA_SELECT = """
    SELECT p.*,
           COALESCE(NULLIF(p.occasion_key, ''), p.occasion) AS response_occasion,
           c.name AS recipient_name,
           owner.name AS owner_name
    FROM present_ideas p
    LEFT JOIN children c ON c.id = p.child_id AND c.deleted_at IS NULL
    LEFT JOIN users owner ON owner.id = p.owner_id AND owner.deleted_at IS NULL
"""


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _current_year() -> int:
    return datetime.now(timezone.utc).year


def _validate_year(year: int) -> None:
    if year < 2000 or year > 2100:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="year must be between 2000 and 2100",
        )


def _legacy_occasion(occasion: str) -> str:
    """Remain writable on installations whose old column still has a CHECK constraint."""
    return occasion if occasion in DEFAULT_OCCASIONS else "birthday"


def _build_idea_response(
    idea_row: dict,
    scores: list[PresentScoreResponse],
    history: list[PresentStatusHistoryResponse] | None = None,
) -> PresentIdeaResponse:
    values = [score.score for score in scores]
    average = (sum(values) / len(values)) if values else None
    return PresentIdeaResponse(
        id=idea_row["id"],
        child_id=idea_row["child_id"],
        recipient_name=idea_row.get("recipient_name"),
        title=idea_row["title"],
        occasion=idea_row.get("response_occasion") or idea_row["occasion"],
        event_year=idea_row["event_year"],
        birthday_id=idea_row.get("birthday_id"),
        status=idea_row.get("status") or "idea",
        status_updated_at=idea_row.get("status_updated_at"),
        owner_id=idea_row.get("owner_id"),
        owner_name=idea_row.get("owner_name"),
        notes=idea_row.get("notes"),
        assigned_to=idea_row.get("assigned_to"),
        url=idea_row.get("url"),
        retailer=idea_row.get("retailer"),
        budget_minor=idea_row.get("budget_minor"),
        price_minor=idea_row.get("price_minor"),
        currency=idea_row.get("currency") or "GBP",
        deadline=idea_row.get("deadline"),
        hiding_location=idea_row.get("hiding_location"),
        recipient_can_see=bool(idea_row.get("recipient_can_see", 0)),
        created_at=idea_row["created_at"],
        updated_at=idea_row["updated_at"],
        created_by=idea_row.get("created_by"),
        client_id=idea_row.get("client_id"),
        client_timestamp=idea_row.get("client_timestamp"),
        scores=scores,
        average_score=average,
        status_history=history or [],
    )


async def _assert_child_in_family(db, child_id: str, family_id: str) -> None:
    cursor = await db.execute(
        "SELECT id FROM children WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (child_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Child not found")


async def _assert_owner_in_family(db, owner_id: str | None, family_id: str) -> None:
    if owner_id is None:
        return
    cursor = await db.execute(
        "SELECT id FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (owner_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Gift owner not found")


async def _assert_birthday_in_family(db, birthday_id: str | None, family_id: str) -> None:
    if birthday_id is None:
        return
    cursor = await db.execute(
        "SELECT id FROM birthdays WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (birthday_id, family_id),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Birthday not found")


async def _get_idea_or_404(
    db,
    idea_id: str,
    family_id: str,
    current_user_id: str | None = None,
    *,
    include_deleted: bool = False,
) -> dict:
    deleted_clause = "" if include_deleted else "AND p.deleted_at IS NULL"
    cursor = await db.execute(
        f"""
        {IDEA_SELECT}
        WHERE p.id = ? AND p.family_id = ? {deleted_clause}
        """,
        (idea_id, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Present idea not found")
    result = dict(row)
    if (
        current_user_id is not None
        and result["child_id"] == current_user_id
        and not result.get("recipient_can_see")
    ):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Present idea not found")
    return result


async def _fetch_scores_for_ideas(
    db, idea_ids: list[str], family_id: str
) -> dict[str, list[PresentScoreResponse]]:
    scores_by_idea: dict[str, list[PresentScoreResponse]] = {
        idea_id: [] for idea_id in idea_ids
    }
    if not idea_ids:
        return scores_by_idea

    placeholders = ", ".join("?" for _ in idea_ids)
    cursor = await db.execute(
        f"""
        SELECT s.*, u.name AS user_name
        FROM present_idea_scores s
        LEFT JOIN users u ON u.id = s.user_id
        WHERE s.idea_id IN ({placeholders})
          AND s.family_id = ?
          AND s.deleted_at IS NULL
        ORDER BY s.updated_at DESC
        """,
        [*idea_ids, family_id],
    )
    for row in await cursor.fetchall():
        score = PresentScoreResponse(
            user_id=row["user_id"],
            user_name=row["user_name"],
            score=row["score"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            client_id=row["client_id"],
            client_timestamp=row["client_timestamp"],
        )
        scores_by_idea[row["idea_id"]].append(score)
    return scores_by_idea


async def _fetch_history_for_ideas(
    db, idea_ids: list[str], family_id: str
) -> dict[str, list[PresentStatusHistoryResponse]]:
    history_by_idea: dict[str, list[PresentStatusHistoryResponse]] = {
        idea_id: [] for idea_id in idea_ids
    }
    if not idea_ids:
        return history_by_idea

    placeholders = ", ".join("?" for _ in idea_ids)
    cursor = await db.execute(
        f"""
        SELECT h.*, u.name AS changed_by_name
        FROM present_status_history h
        LEFT JOIN users u ON u.id = h.created_by
        WHERE h.idea_id IN ({placeholders})
          AND h.family_id = ?
          AND h.deleted_at IS NULL
        ORDER BY h.changed_at ASC
        """,
        [*idea_ids, family_id],
    )
    for row in await cursor.fetchall():
        item = PresentStatusHistoryResponse(
            id=row["id"],
            from_status=row["from_status"],
            to_status=row["to_status"],
            changed_at=row["changed_at"],
            changed_by=row["created_by"],
            changed_by_name=row["changed_by_name"],
        )
        history_by_idea[row["idea_id"]].append(item)
    return history_by_idea


async def _responses_for_rows(db, rows: list, family_id: str) -> list[PresentIdeaResponse]:
    dictionaries = [dict(row) for row in rows]
    idea_ids = [row["id"] for row in dictionaries]
    scores = await _fetch_scores_for_ideas(db, idea_ids, family_id)
    histories = await _fetch_history_for_ideas(db, idea_ids, family_id)
    return [
        _build_idea_response(
            row,
            scores.get(row["id"], []),
            histories.get(row["id"], []),
        )
        for row in dictionaries
    ]


async def _response_for_id(
    db, idea_id: str, family_id: str, current_user_id: str
) -> PresentIdeaResponse:
    row = await _get_idea_or_404(db, idea_id, family_id, current_user_id)
    return (await _responses_for_rows(db, [row], family_id))[0]


async def _record_status_change(
    db,
    *,
    idea_id: str,
    from_status: str | None,
    to_status: str,
    family_id: str,
    user_id: str,
    changed_at: str,
    client_id: str | None = None,
    client_timestamp: str | None = None,
) -> None:
    await db.execute(
        """
        INSERT INTO present_status_history
            (id, idea_id, from_status, to_status, changed_at, family_id,
             created_at, updated_at, created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            idea_id,
            from_status,
            to_status,
            changed_at,
            family_id,
            changed_at,
            changed_at,
            user_id,
            client_id,
            client_timestamp,
        ),
    )


async def _duplicate_matches(
    db,
    *,
    child_id: str,
    title: str,
    url: str | None,
    family_id: str,
    current_user_id: str,
    exclude_id: str | None = None,
) -> list[PresentDuplicateMatch]:
    comparisons = ["LOWER(TRIM(title)) = LOWER(TRIM(?))"]
    values: list[object] = [title]
    if url:
        comparisons.append("LOWER(TRIM(url)) = LOWER(TRIM(?))")
        values.append(url)
    exclude_clause = ""
    if exclude_id:
        exclude_clause = "AND id != ?"
        values.append(exclude_id)
    values.extend([child_id, family_id, current_user_id])
    cursor = await db.execute(
        f"""
        SELECT id, title,
               COALESCE(NULLIF(occasion_key, ''), occasion) AS response_occasion,
               event_year, status
        FROM present_ideas
        WHERE ({' OR '.join(comparisons)})
          {exclude_clause}
          AND child_id = ?
          AND family_id = ?
          AND deleted_at IS NULL
          AND status != 'given'
          AND (recipient_can_see = 1 OR child_id != ?)
        ORDER BY updated_at DESC
        LIMIT 5
        """,
        values,
    )
    return [
        PresentDuplicateMatch(
            id=row["id"],
            title=row["title"],
            occasion=row["response_occasion"],
            event_year=row["event_year"],
            status=row["status"],
        )
        for row in await cursor.fetchall()
    ]


@router.get("/occasion/{occasion}", response_model=PresentOccasionBoardResponse)
async def list_occasion_board(
    occasion: str,
    year: int | None = Query(None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Compatibility board for one occasion/year, grouped into recipients."""
    occasion = occasion.strip()
    if not occasion:
        raise HTTPException(status_code=400, detail="occasion must not be blank")
    active_year = year or _current_year()
    _validate_year(active_year)
    family_id = current_user["family_id"]

    child_cursor = await db.execute(
        """
        SELECT id, name, date_of_birth FROM children
        WHERE family_id = ? AND deleted_at IS NULL
        ORDER BY date_of_birth ASC
        """,
        (family_id,),
    )
    child_rows = await child_cursor.fetchall()
    child_ids = [row["id"] for row in child_rows]
    ideas_by_child: dict[str, list[PresentIdeaResponse]] = {
        child_id: [] for child_id in child_ids
    }

    if child_ids:
        placeholders = ", ".join("?" for _ in child_ids)
        cursor = await db.execute(
            f"""
            {IDEA_SELECT}
            WHERE p.child_id IN ({placeholders})
              AND COALESCE(NULLIF(p.occasion_key, ''), p.occasion) = ?
              AND p.event_year = ?
              AND p.family_id = ?
              AND p.deleted_at IS NULL
              AND (p.recipient_can_see = 1 OR p.child_id != ?)
            ORDER BY p.created_at DESC
            """,
            [*child_ids, occasion, active_year, family_id, current_user["id"]],
        )
        ideas = await _responses_for_rows(db, await cursor.fetchall(), family_id)
        for idea in ideas:
            ideas_by_child[idea.child_id].append(idea)

    return PresentOccasionBoardResponse(
        occasion=occasion,
        year=active_year,
        children=[
            PresentOccasionChildColumn(
                child_id=row["id"],
                child_name=row["name"],
                ideas=ideas_by_child.get(row["id"], []),
            )
            for row in child_rows
        ],
    )


@router.get("/ideas", response_model=list[PresentIdeaResponse])
async def list_present_ideas(
    child_id: str | None = Query(None),
    birthday_id: str | None = Query(None),
    occasion: str | None = Query(None, min_length=1, max_length=100),
    year: int | None = Query(None),
    present_status: PresentStatus | None = Query(None, alias="status"),
    include_given: bool = Query(False),
    offset: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List gifts recipient-first, with optional birthday/occasion/lifecycle filters."""
    family_id = current_user["family_id"]
    if child_id:
        await _assert_child_in_family(db, child_id, family_id)
    if birthday_id:
        await _assert_birthday_in_family(db, birthday_id, family_id)
    if year is not None:
        _validate_year(year)

    clauses = [
        "p.family_id = ?",
        "p.deleted_at IS NULL",
        "(p.recipient_can_see = 1 OR p.child_id != ?)",
    ]
    values: list[object] = [family_id, current_user["id"]]
    if child_id:
        clauses.append("p.child_id = ?")
        values.append(child_id)
    if birthday_id:
        clauses.append("p.birthday_id = ?")
        values.append(birthday_id)
    if occasion:
        clauses.append("COALESCE(NULLIF(p.occasion_key, ''), p.occasion) = ?")
        values.append(occasion.strip())
    if year is not None:
        clauses.append("p.event_year = ?")
        values.append(year)
    if present_status:
        clauses.append("p.status = ?")
        values.append(present_status)
    elif not include_given:
        clauses.append("p.status != 'given'")
    values.extend([limit, offset])

    cursor = await db.execute(
        f"""
        {IDEA_SELECT}
        WHERE {' AND '.join(clauses)}
        ORDER BY
            CASE p.status
                WHEN 'idea' THEN 0 WHEN 'shortlist' THEN 1 WHEN 'assigned' THEN 2
                WHEN 'bought' THEN 3 WHEN 'arrived' THEN 4 WHEN 'wrapped' THEN 5
                WHEN 'stashed' THEN 6 ELSE 7 END,
            CASE WHEN p.deadline IS NULL THEN 1 ELSE 0 END,
            p.deadline ASC,
            p.updated_at DESC
        LIMIT ? OFFSET ?
        """,
        values,
    )
    return await _responses_for_rows(db, await cursor.fetchall(), family_id)


@router.post("/ideas/check-duplicate", response_model=PresentDuplicateResponse)
async def check_present_duplicate(
    body: PresentDuplicateCheck,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    await _assert_child_in_family(db, body.child_id, family_id)
    return PresentDuplicateResponse(
        matches=await _duplicate_matches(
            db,
            child_id=body.child_id,
            title=body.title,
            url=body.url,
            family_id=family_id,
            current_user_id=current_user["id"],
            exclude_id=body.exclude_id,
        )
    )


@router.post("/ideas", response_model=PresentIdeaResponse, status_code=status.HTTP_201_CREATED)
async def create_present_idea(
    body: PresentIdeaCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Capture a gift idea; logistics can be added only when they become useful."""
    family_id = current_user["family_id"]
    await _assert_child_in_family(db, body.child_id, family_id)
    await _assert_owner_in_family(db, body.owner_id, family_id)
    await _assert_birthday_in_family(db, body.birthday_id, family_id)
    event_year = body.event_year or _current_year()
    _validate_year(event_year)

    matches = await _duplicate_matches(
        db,
        child_id=body.child_id,
        title=body.title,
        url=body.url,
        family_id=family_id,
        current_user_id=current_user["id"],
    )
    if matches and not body.allow_duplicate:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A similar active gift already exists for this recipient",
        )

    now = _utc_now_iso()
    idea_id = str(uuid.uuid4())
    await db.execute(
        """
        INSERT INTO present_ideas
            (id, child_id, occasion, occasion_key, event_year, title, birthday_id,
             status, status_updated_at, owner_id, notes, assigned_to, url, retailer,
             budget_minor, price_minor, currency, deadline, hiding_location,
             recipient_can_see, family_id, created_at, updated_at, created_by,
             client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            idea_id,
            body.child_id,
            _legacy_occasion(body.occasion),
            body.occasion,
            event_year,
            body.title,
            body.birthday_id,
            body.status,
            now,
            body.owner_id,
            body.notes,
            body.assigned_to,
            body.url,
            body.retailer,
            body.budget_minor,
            body.price_minor,
            body.currency,
            body.deadline,
            body.hiding_location,
            int(body.recipient_can_see),
            family_id,
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )
    await _record_status_change(
        db,
        idea_id=idea_id,
        from_status=None,
        to_status=body.status,
        family_id=family_id,
        user_id=current_user["id"],
        changed_at=now,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    await db.commit()
    return await _response_for_id(db, idea_id, family_id, current_user["id"])


@router.get("/ideas/{idea_id}", response_model=PresentIdeaResponse)
async def get_present_idea(
    idea_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _response_for_id(
        db, idea_id, current_user["family_id"], current_user["id"]
    )


@router.put("/ideas/{idea_id}", response_model=PresentIdeaResponse)
async def update_present_idea(
    idea_id: str,
    body: PresentIdeaUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Edit or correct any gift detail, including an earlier lifecycle state."""
    family_id = current_user["family_id"]
    existing = await _get_idea_or_404(
        db, idea_id, family_id, current_user["id"]
    )
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        return await _response_for_id(db, idea_id, family_id, current_user["id"])

    for required in ("title", "occasion", "event_year", "status", "currency"):
        if required in updates and updates[required] is None:
            raise HTTPException(status_code=422, detail=f"{required} may not be null")
    if updates.get("event_year") is not None:
        _validate_year(updates["event_year"])
    if "owner_id" in updates:
        await _assert_owner_in_family(db, updates["owner_id"], family_id)
    if "birthday_id" in updates:
        await _assert_birthday_in_family(db, updates["birthday_id"], family_id)

    await save_history(
        db, "present_ideas", idea_id, current_user["id"], family_id=family_id
    )
    now = _utc_now_iso()
    old_status = existing.get("status") or "idea"
    new_status = updates.get("status", old_status)
    if "occasion" in updates:
        updates["occasion_key"] = updates["occasion"]
        updates["occasion"] = _legacy_occasion(updates["occasion"])
    if new_status != old_status:
        updates["status_updated_at"] = now
        await _record_status_change(
            db,
            idea_id=idea_id,
            from_status=old_status,
            to_status=new_status,
            family_id=family_id,
            user_id=current_user["id"],
            changed_at=now,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    updates["updated_at"] = now
    set_clause = ", ".join(f"{key} = ?" for key in updates)
    values = [
        int(bool(value)) if key == "recipient_can_see" else value
        for key, value in updates.items()
    ]
    values.extend([idea_id, family_id])
    await db.execute(
        f"UPDATE present_ideas SET {set_clause} WHERE id = ? AND family_id = ?",
        values,
    )
    await db.commit()
    return await _response_for_id(db, idea_id, family_id, current_user["id"])


@router.patch("/ideas/{idea_id}/status", response_model=PresentIdeaResponse)
async def update_present_status(
    idea_id: str,
    body: PresentStatusUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Advance or correct a gift lifecycle state and retain the transition history."""
    return await update_present_idea(
        idea_id,
        PresentIdeaUpdate(status=body.status),
        current_user,
        db,
    )


@router.delete("/ideas/{idea_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_present_idea(
    idea_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete an idea; clients can offer immediate Undo via restore."""
    family_id = current_user["family_id"]
    await _get_idea_or_404(db, idea_id, family_id, current_user["id"])
    now = _utc_now_iso()
    await save_history(
        db, "present_ideas", idea_id, current_user["id"], family_id=family_id
    )
    await db.execute(
        "UPDATE present_ideas SET deleted_at = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, idea_id, family_id),
    )
    await db.commit()


@router.post("/ideas/{idea_id}/restore", response_model=PresentIdeaResponse)
async def restore_present_idea(
    idea_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    existing = await _get_idea_or_404(
        db,
        idea_id,
        family_id,
        current_user["id"],
        include_deleted=True,
    )
    if existing.get("deleted_at") is not None:
        now = _utc_now_iso()
        await save_history(
            db, "present_ideas", idea_id, current_user["id"], family_id=family_id
        )
        await db.execute(
            "UPDATE present_ideas SET deleted_at = NULL, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (now, idea_id, family_id),
        )
        await db.commit()
    return await _response_for_id(db, idea_id, family_id, current_user["id"])


@router.put("/ideas/{idea_id}/score", response_model=PresentIdeaResponse)
async def upsert_present_idea_score(
    idea_id: str,
    body: PresentIdeaScoreUpsert,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    await _get_idea_or_404(db, idea_id, family_id, current_user["id"])
    if body.score < 1 or body.score > 5:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="score must be between 1 and 5",
        )

    now = _utc_now_iso()
    cursor = await db.execute(
        """
        SELECT id FROM present_idea_scores
        WHERE idea_id = ? AND user_id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (idea_id, current_user["id"], family_id),
    )
    existing = await cursor.fetchone()
    if existing:
        await save_history(
            db,
            "present_idea_scores",
            existing["id"],
            current_user["id"],
            family_id=family_id,
        )
        await db.execute(
            """
            UPDATE present_idea_scores
            SET score = ?, updated_at = ?, client_id = ?, client_timestamp = ?, deleted_at = NULL
            WHERE id = ? AND family_id = ?
            """,
            (
                body.score,
                now,
                body.client_id,
                body.client_timestamp,
                existing["id"],
                family_id,
            ),
        )
    else:
        await db.execute(
            """
            INSERT INTO present_idea_scores
                (id, idea_id, user_id, score, family_id, created_at, updated_at,
                 created_by, client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                idea_id,
                current_user["id"],
                body.score,
                family_id,
                now,
                now,
                current_user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )
    await db.commit()
    return await _response_for_id(db, idea_id, family_id, current_user["id"])


@router.delete("/ideas/{idea_id}/score", response_model=PresentIdeaResponse)
async def delete_present_idea_score(
    idea_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    await _get_idea_or_404(db, idea_id, family_id, current_user["id"])
    cursor = await db.execute(
        """
        SELECT * FROM present_idea_scores
        WHERE idea_id = ? AND user_id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (idea_id, current_user["id"], family_id),
    )
    existing = await cursor.fetchone()
    if existing:
        now = _utc_now_iso()
        await save_history(
            db,
            "present_idea_scores",
            existing["id"],
            current_user["id"],
            family_id=family_id,
        )
        await db.execute(
            "UPDATE present_idea_scores SET deleted_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (now, now, existing["id"], family_id),
        )
        await db.commit()
    return await _response_for_id(db, idea_id, family_id, current_user["id"])


@router.get("/{child_id}", response_model=ChildPresentsResponse)
async def list_child_presents(
    child_id: str,
    year: int | None = Query(None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Compatibility response grouped by occasion for the selected recipient/year."""
    family_id = current_user["family_id"]
    await _assert_child_in_family(db, child_id, family_id)
    active_year = year or _current_year()
    _validate_year(active_year)
    cursor = await db.execute(
        f"""
        {IDEA_SELECT}
        WHERE p.child_id = ?
          AND p.family_id = ?
          AND p.event_year = ?
          AND p.deleted_at IS NULL
          AND (p.recipient_can_see = 1 OR p.child_id != ?)
        ORDER BY p.created_at DESC
        """,
        (child_id, family_id, active_year, current_user["id"]),
    )
    ideas = await _responses_for_rows(db, await cursor.fetchall(), family_id)
    grouped: dict[str, list[PresentIdeaResponse]] = {
        occasion: [] for occasion in DEFAULT_OCCASIONS
    }
    for idea in ideas:
        grouped.setdefault(idea.occasion, []).append(idea)
    occasion_order = [
        *DEFAULT_OCCASIONS,
        *sorted(key for key in grouped if key not in DEFAULT_OCCASIONS),
    ]
    return ChildPresentsResponse(
        child_id=child_id,
        year=active_year,
        occasions=[
            PresentOccasionBucket(occasion=occasion, ideas=grouped[occasion])
            for occasion in occasion_order
        ],
    )


def _preparation_action(status_value: str, title: str) -> str:
    if status_value in {"idea", "shortlist", "assigned"}:
        return f"Buy {title}"
    if status_value == "bought":
        return f"Check delivery for {title}"
    if status_value == "arrived":
        return f"Wrap {title}"
    return f"Hide {title}"


async def upcoming_present_preparation(
    db,
    *,
    family_id: str,
    current_user_id: str,
    reference_date: date,
    horizon_days: int = 14,
    limit: int = 5,
) -> list[dict]:
    """Return only gift logistics that have entered their actionable lead window."""
    horizon = (reference_date + timedelta(days=horizon_days)).isoformat()
    cursor = await db.execute(
        f"""
        {IDEA_SELECT}
        WHERE p.family_id = ?
          AND p.deleted_at IS NULL
          AND p.deadline IS NOT NULL
          AND p.deadline <= ?
          AND p.status NOT IN ('stashed', 'given')
          AND (p.recipient_can_see = 1 OR p.child_id != ?)
        ORDER BY p.deadline ASC, p.updated_at ASC
        LIMIT ?
        """,
        (family_id, horizon, current_user_id, limit),
    )
    result: list[dict] = []
    for row in await cursor.fetchall():
        due = date.fromisoformat(row["deadline"])
        result.append(
            {
                "id": row["id"],
                "child_id": row["child_id"],
                "recipient_name": row["recipient_name"],
                "title": row["title"],
                "deadline": row["deadline"],
                "days_until_due": (due - reference_date).days,
                "status": row["status"],
                "owner_id": row["owner_id"],
                "owner_name": row["owner_name"],
                "action": _preparation_action(row["status"], row["title"]),
            }
        )
    return result

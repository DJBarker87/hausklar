import json
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status

from app.auth import get_current_user
from app.database import get_db
from app.models.homework import (
    ReadingLogCreate,
    ReadingLogResponse,
    ReadingLogUpdate,
    SpellingCompleteRequest,
    SpellingPracticeCreate,
    SpellingsCreate,
    SpellingsResponse,
    SpellingsUpdate,
)
from app.services.family_people import family_child_exists
from app.services.record_history import save_history

router = APIRouter()


SPELLINGS_SELECT = """
    SELECT hs.*,
           document.id AS document_record_id,
           document.title AS document_title,
           document.original_filename AS document_original_filename,
           document.media_type AS document_media_type,
           document.file_size AS document_file_size
    FROM homework_spellings hs
    LEFT JOIN documents document
      ON document.id = hs.source_document_id
     AND document.family_id = hs.family_id
     AND document.deleted_at IS NULL
"""


def _reading_row_to_response(row: dict) -> ReadingLogResponse:
    return ReadingLogResponse(**dict(row))


def _homework_status(test_date: str, completed_at: str | None, *, today: date | None = None) -> str:
    if completed_at:
        return "completed"
    due = date.fromisoformat(test_date)
    reference = today or date.today()
    if due < reference:
        return "overdue"
    if due == reference:
        return "due"
    return "upcoming"


def _practice_from_row(row: dict) -> dict:
    attempts = json.loads(row["attempts_json"])
    return {
        "id": row["id"],
        "practised_at": row["practised_at"],
        "attempts": attempts,
        "correct_count": row["correct_count"],
        "total_count": row["total_count"],
    }


def _word_mastery(word_list: list[str], sessions: list[dict]) -> list[dict]:
    outcomes: dict[str, list[bool]] = defaultdict(list)
    canonical = {word.casefold(): word for word in word_list}
    for session in reversed(sessions):
        for attempt in session["attempts"]:
            key = attempt["word"].casefold()
            if key in canonical:
                outcomes[key].append(bool(attempt["correct"]))

    mastery = []
    for word in word_list:
        results = outcomes[word.casefold()]
        mastered = len(results) >= 2 and all(results[-2:])
        mastery.append(
            {
                "word": word,
                "attempts": len(results),
                "correct_attempts": sum(results),
                "mastered": mastered,
                "needs_practice": not mastered,
            }
        )
    return mastery


def _spellings_row_to_response(row: dict, sessions: list[dict]) -> SpellingsResponse:
    data = dict(row)
    raw_words = data.get("word_list")
    word_list = json.loads(raw_words) if isinstance(raw_words, str) else raw_words
    data["word_list"] = word_list
    data["practice_sessions"] = sessions
    data["mastery"] = _word_mastery(word_list, sessions)
    data["status"] = _homework_status(data["test_date"], data.get("completed_at"))
    document_id = data.get("document_record_id")
    data["source_document"] = (
        {
            "id": document_id,
            "title": data["document_title"],
            "original_filename": data["document_original_filename"],
            "media_type": data["document_media_type"],
            "file_size": data["document_file_size"],
            "download_url": f"/api/documents/{document_id}/content",
        }
        if document_id
        else None
    )
    return SpellingsResponse(**data)


async def _build_spellings_responses(db, rows: list[dict]) -> list[SpellingsResponse]:
    if not rows:
        return []
    ids = [row["id"] for row in rows]
    placeholders = ",".join("?" for _ in ids)
    cursor = await db.execute(
        f"""
        SELECT * FROM homework_spelling_sessions
        WHERE spellings_id IN ({placeholders})
          AND family_id = ? AND deleted_at IS NULL
        ORDER BY practised_at DESC, created_at DESC
        """,
        (*ids, rows[0]["family_id"]),
    )
    grouped: dict[str, list[dict]] = defaultdict(list)
    for session_row in await cursor.fetchall():
        session = dict(session_row)
        grouped[session["spellings_id"]].append(_practice_from_row(session))
    return [_spellings_row_to_response(row, grouped[row["id"]]) for row in rows]


async def _spellings_row(db, spellings_id: str, family_id: str, *, deleted: bool = False):
    condition = "hs.deleted_at IS NOT NULL" if deleted else "hs.deleted_at IS NULL"
    cursor = await db.execute(
        SPELLINGS_SELECT + f" WHERE hs.id = ? AND hs.family_id = ? AND {condition}",
        (spellings_id, family_id),
    )
    return await cursor.fetchone()


async def _spellings_response(db, spellings_id: str, family_id: str) -> SpellingsResponse:
    row = await _spellings_row(db, spellings_id, family_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Spelling list not found")
    return (await _build_spellings_responses(db, [dict(row)]))[0]


async def _validate_source_document(db, source_document_id: str | None, family_id: str) -> None:
    if source_document_id is None:
        return
    row = await (
        await db.execute(
            "SELECT 1 FROM documents WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (source_document_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=422, detail="The selected school document is unavailable")


def _normalise_practised_at(value: str | None) -> str:
    if value is None:
        return datetime.now(timezone.utc).isoformat()
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat()


def _normalise_attempts(body: SpellingPracticeCreate, word_list_json: str) -> list[dict]:
    words = json.loads(word_list_json)
    canonical = {word.casefold(): word for word in words}
    unknown = [attempt.word for attempt in body.attempts if attempt.word.casefold() not in canonical]
    if unknown:
        raise HTTPException(status_code=422, detail=f"Not in this spelling list: {unknown[0]}")
    return [
        {"word": canonical[attempt.word.casefold()], "correct": attempt.correct}
        for attempt in body.attempts
    ]


# ---------------------------------------------------------------------------
# Reading practice
# ---------------------------------------------------------------------------


@router.get("/reading", response_model=list[ReadingLogResponse])
async def list_reading_logs(
    child_id: str | None = None,
    offset: int = 0,
    limit: int = 50,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = "SELECT * FROM homework_reading WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]
    if child_id is not None:
        query += " AND child_id = ?"
        params.append(child_id)
    query += " ORDER BY date DESC, created_at DESC LIMIT ? OFFSET ?"
    params.extend([min(max(limit, 1), 200), max(offset, 0)])
    rows = await (await db.execute(query, params)).fetchall()
    return [_reading_row_to_response(row) for row in rows]


@router.post("/reading", response_model=ReadingLogResponse, status_code=status.HTTP_201_CREATED)
async def create_reading_log(
    body: ReadingLogCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if not await family_child_exists(db, current_user["family_id"], body.child_id):
        raise HTTPException(status_code=400, detail="Child is not in this family")
    log_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO homework_reading (
            id, child_id, book_title, minutes, date, notes,
            created_at, updated_at, created_by, client_id, client_timestamp, family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            log_id, body.child_id, body.book_title, body.minutes, body.date,
            body.notes.strip() if body.notes else None, now, now, current_user["id"],
            body.client_id, body.client_timestamp, current_user["family_id"],
        ),
    )
    await db.commit()
    row = await (await db.execute("SELECT * FROM homework_reading WHERE id = ?", (log_id,))).fetchone()
    return _reading_row_to_response(row)


@router.put("/reading/{log_id}", response_model=ReadingLogResponse)
async def update_reading_log(
    log_id: str,
    body: ReadingLogUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    existing = await (
        await db.execute(
            "SELECT * FROM homework_reading WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
            (log_id, current_user["family_id"]),
        )
    ).fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Reading session not found")
    updates = body.model_dump(exclude_unset=True)
    if "notes" in updates and updates["notes"] is not None:
        updates["notes"] = updates["notes"].strip() or None
    if not updates:
        return _reading_row_to_response(existing)
    await save_history(db, "homework_reading", log_id, current_user["id"], family_id=current_user["family_id"])
    updates["updated_at"] = datetime.now(timezone.utc).isoformat()
    set_clause = ", ".join(f"{key} = ?" for key in updates)
    await db.execute(
        f"UPDATE homework_reading SET {set_clause} WHERE id = ? AND family_id = ?",
        (*updates.values(), log_id, current_user["family_id"]),
    )
    await db.commit()
    row = await (await db.execute("SELECT * FROM homework_reading WHERE id = ?", (log_id,))).fetchone()
    return _reading_row_to_response(row)


@router.delete("/reading/{log_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_reading_log(
    log_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    existing = await (
        await db.execute(
            "SELECT * FROM homework_reading WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
            (log_id, current_user["family_id"]),
        )
    ).fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Reading session not found")
    await save_history(db, "homework_reading", log_id, current_user["id"], family_id=current_user["family_id"])
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE homework_reading SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, log_id, current_user["family_id"]),
    )
    await db.commit()


@router.post("/reading/{log_id}/restore", response_model=ReadingLogResponse)
async def restore_reading_log(
    log_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    existing = await (
        await db.execute(
            "SELECT * FROM homework_reading WHERE id = ? AND deleted_at IS NOT NULL AND family_id = ?",
            (log_id, current_user["family_id"]),
        )
    ).fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Reading session not found")
    await save_history(db, "homework_reading", log_id, current_user["id"], family_id=current_user["family_id"])
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE homework_reading SET deleted_at = NULL, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, log_id, current_user["family_id"]),
    )
    await db.commit()
    row = await (await db.execute("SELECT * FROM homework_reading WHERE id = ?", (log_id,))).fetchone()
    return _reading_row_to_response(row)


# ---------------------------------------------------------------------------
# Spelling work and practice
# ---------------------------------------------------------------------------


@router.get("/spellings", response_model=list[SpellingsResponse])
async def list_spellings(
    child_id: str | None = None,
    offset: int = 0,
    limit: int = 50,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = SPELLINGS_SELECT + " WHERE hs.deleted_at IS NULL AND hs.family_id = ?"
    params: list = [current_user["family_id"]]
    if child_id is not None:
        query += " AND hs.child_id = ?"
        params.append(child_id)
    query += (
        " ORDER BY (hs.completed_at IS NOT NULL) ASC, "
        "CASE WHEN hs.completed_at IS NULL THEN hs.test_date END ASC, hs.test_date DESC "
        "LIMIT ? OFFSET ?"
    )
    params.extend([min(max(limit, 1), 200), max(offset, 0)])
    rows = [dict(row) for row in await (await db.execute(query, params)).fetchall()]
    return await _build_spellings_responses(db, rows)


@router.get("/spellings/{spellings_id}", response_model=SpellingsResponse)
async def get_spellings(
    spellings_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _spellings_response(db, spellings_id, current_user["family_id"])


@router.post("/spellings", response_model=SpellingsResponse, status_code=status.HTTP_201_CREATED)
async def create_spellings(
    body: SpellingsCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    if not await family_child_exists(db, family_id, body.child_id):
        raise HTTPException(status_code=400, detail="Child is not in this family")
    await _validate_source_document(db, body.source_document_id, family_id)
    spellings_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO homework_spellings (
            id, child_id, word_list, test_date, notes, link_url, source_document_id,
            created_at, updated_at, created_by, client_id, client_timestamp, family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            spellings_id, body.child_id, json.dumps(body.word_list), body.test_date,
            body.notes.strip() if body.notes else None, body.link_url, body.source_document_id,
            now, now, current_user["id"], body.client_id, body.client_timestamp, family_id,
        ),
    )
    await db.commit()
    return await _spellings_response(db, spellings_id, family_id)


@router.put("/spellings/{spellings_id}", response_model=SpellingsResponse)
async def update_spellings(
    spellings_id: str,
    body: SpellingsUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    existing = await _spellings_row(db, spellings_id, family_id)
    if not existing:
        raise HTTPException(status_code=404, detail="Spelling list not found")
    update_data = body.model_dump(exclude_unset=True)
    if not update_data:
        return await _spellings_response(db, spellings_id, family_id)
    if "source_document_id" in update_data:
        await _validate_source_document(db, update_data["source_document_id"], family_id)

    effective_words = update_data.get("word_list") or json.loads(existing["word_list"])
    effective_score = update_data.get("score", existing["score"])
    if effective_score is not None and effective_score > len(effective_words):
        raise HTTPException(status_code=422, detail="Score cannot be greater than the number of words")

    updates: dict = {}
    for field, value in update_data.items():
        if field == "word_list" and value is not None:
            updates[field] = json.dumps(value)
        elif field == "practice_count" and value is not None:
            updates[field] = (existing["practice_count"] or 0) + value
        elif field == "notes" and value is not None:
            updates[field] = value.strip() or None
        else:
            updates[field] = value
    if "score" in updates:
        updates["completed_at"] = datetime.now(timezone.utc).isoformat() if updates["score"] is not None else None

    await save_history(db, "homework_spellings", spellings_id, current_user["id"], family_id=family_id)
    updates["updated_at"] = datetime.now(timezone.utc).isoformat()
    set_clause = ", ".join(f"{field} = ?" for field in updates)
    await db.execute(
        f"UPDATE homework_spellings SET {set_clause} WHERE id = ? AND family_id = ?",
        (*updates.values(), spellings_id, family_id),
    )
    await db.commit()
    return await _spellings_response(db, spellings_id, family_id)


@router.post("/spellings/{spellings_id}/practice", response_model=SpellingsResponse)
async def record_spelling_practice(
    spellings_id: str,
    body: SpellingPracticeCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    existing = await _spellings_row(db, spellings_id, family_id)
    if not existing:
        raise HTTPException(status_code=404, detail="Spelling list not found")
    attempts = _normalise_attempts(body, existing["word_list"])
    session_id = str(uuid.uuid4())
    practised_at = _normalise_practised_at(body.practised_at)
    now = datetime.now(timezone.utc).isoformat()
    await save_history(db, "homework_spellings", spellings_id, current_user["id"], family_id=family_id)
    await db.execute(
        """
        INSERT INTO homework_spelling_sessions (
            id, spellings_id, child_id, practised_at, attempts_json,
            correct_count, total_count, family_id, created_at, updated_at, created_by
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            session_id, spellings_id, existing["child_id"], practised_at, json.dumps(attempts),
            sum(attempt["correct"] for attempt in attempts), len(attempts), family_id,
            now, now, current_user["id"],
        ),
    )
    await db.execute(
        "UPDATE homework_spellings SET practice_count = practice_count + 1, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, spellings_id, family_id),
    )
    await db.commit()
    return await _spellings_response(db, spellings_id, family_id)


@router.put("/spellings/{spellings_id}/practice/{session_id}", response_model=SpellingsResponse)
async def correct_spelling_practice(
    spellings_id: str,
    session_id: str,
    body: SpellingPracticeCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    spelling = await _spellings_row(db, spellings_id, family_id)
    session = await (
        await db.execute(
            "SELECT * FROM homework_spelling_sessions WHERE id = ? AND spellings_id = ? "
            "AND family_id = ? AND deleted_at IS NULL",
            (session_id, spellings_id, family_id),
        )
    ).fetchone()
    if not spelling or not session:
        raise HTTPException(status_code=404, detail="Practice session not found")
    attempts = _normalise_attempts(body, spelling["word_list"])
    await save_history(db, "homework_spelling_sessions", session_id, current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE homework_spelling_sessions SET practised_at = ?, attempts_json = ?, "
        "correct_count = ?, total_count = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (
            _normalise_practised_at(body.practised_at or session["practised_at"]),
            json.dumps(attempts), sum(attempt["correct"] for attempt in attempts),
            len(attempts), now, session_id, family_id,
        ),
    )
    await db.execute(
        "UPDATE homework_spellings SET updated_at = ? WHERE id = ? AND family_id = ?",
        (now, spellings_id, family_id),
    )
    await db.commit()
    return await _spellings_response(db, spellings_id, family_id)


@router.delete("/spellings/{spellings_id}/practice/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_spelling_practice(
    spellings_id: str,
    session_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    session = await (
        await db.execute(
            "SELECT * FROM homework_spelling_sessions WHERE id = ? AND spellings_id = ? "
            "AND family_id = ? AND deleted_at IS NULL",
            (session_id, spellings_id, family_id),
        )
    ).fetchone()
    if not session:
        raise HTTPException(status_code=404, detail="Practice session not found")
    await save_history(db, "homework_spelling_sessions", session_id, current_user["id"], family_id=family_id)
    await save_history(db, "homework_spellings", spellings_id, current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE homework_spelling_sessions SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, session_id, family_id),
    )
    await db.execute(
        "UPDATE homework_spellings SET practice_count = MAX(0, practice_count - 1), updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, spellings_id, family_id),
    )
    await db.commit()


@router.post("/spellings/{spellings_id}/complete", response_model=SpellingsResponse)
async def complete_spellings(
    spellings_id: str,
    body: SpellingCompleteRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    existing = await _spellings_row(db, spellings_id, family_id)
    if not existing:
        raise HTTPException(status_code=404, detail="Spelling list not found")
    if body.score is not None and body.score > len(json.loads(existing["word_list"])):
        raise HTTPException(status_code=422, detail="Score cannot be greater than the number of words")
    await save_history(db, "homework_spellings", spellings_id, current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    score = body.score if "score" in body.model_fields_set else existing["score"]
    await db.execute(
        "UPDATE homework_spellings SET completed_at = ?, score = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, score, now, spellings_id, family_id),
    )
    await db.commit()
    return await _spellings_response(db, spellings_id, family_id)


@router.post("/spellings/{spellings_id}/reopen", response_model=SpellingsResponse)
async def reopen_spellings(
    spellings_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    existing = await _spellings_row(db, spellings_id, family_id)
    if not existing:
        raise HTTPException(status_code=404, detail="Spelling list not found")
    if existing["completed_at"] is None:
        return await _spellings_response(db, spellings_id, family_id)
    await save_history(db, "homework_spellings", spellings_id, current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE homework_spellings SET completed_at = NULL, score = NULL, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, spellings_id, family_id),
    )
    await db.commit()
    return await _spellings_response(db, spellings_id, family_id)


@router.delete("/spellings/{spellings_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_spellings(
    spellings_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    existing = await _spellings_row(db, spellings_id, family_id)
    if not existing:
        raise HTTPException(status_code=404, detail="Spelling list not found")
    await save_history(db, "homework_spellings", spellings_id, current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE homework_spellings SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, spellings_id, family_id),
    )
    await db.commit()


@router.post("/spellings/{spellings_id}/restore", response_model=SpellingsResponse)
async def restore_spellings(
    spellings_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    existing = await _spellings_row(db, spellings_id, family_id, deleted=True)
    if not existing:
        raise HTTPException(status_code=404, detail="Spelling list not found")
    await save_history(db, "homework_spellings", spellings_id, current_user["id"], family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE homework_spellings SET deleted_at = NULL, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, spellings_id, family_id),
    )
    await db.commit()
    return await _spellings_response(db, spellings_id, family_id)


async def upcoming_homework(
    db,
    *,
    family_id: str,
    reference_date: date,
    horizon_days: int = 7,
    limit: int = 5,
) -> list[dict]:
    """Small parent-facing projection for Today; no practice detail or provenance."""
    earliest = reference_date - timedelta(days=14)
    latest = reference_date + timedelta(days=horizon_days)
    rows = await (
        await db.execute(
            """
            SELECT hs.id, hs.child_id, c.name AS child_name, hs.test_date,
                   hs.word_list, hs.practice_count
            FROM homework_spellings hs
            JOIN children c ON c.id = hs.child_id AND c.family_id = hs.family_id
            WHERE hs.family_id = ? AND hs.deleted_at IS NULL AND hs.completed_at IS NULL
              AND hs.test_date >= ? AND hs.test_date <= ?
            ORDER BY hs.test_date ASC
            LIMIT ?
            """,
            (family_id, earliest.isoformat(), latest.isoformat(), limit),
        )
    ).fetchall()
    return [
        {
            "id": row["id"],
            "child_id": row["child_id"],
            "child_name": row["child_name"],
            "test_date": row["test_date"],
            "word_count": len(json.loads(row["word_list"])),
            "practice_count": row["practice_count"],
            "status": _homework_status(row["test_date"], None, today=reference_date),
        }
        for row in rows
    ]

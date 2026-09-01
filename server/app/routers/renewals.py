"""Finance-owned household renewals and expiries."""

import calendar
import re
import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.finance import FinanceCommitmentCreate, FinanceCommitmentUpdate
from app.models.renewal import (
    RenewalChecklistItemCreate,
    RenewalChecklistItemResponse,
    RenewalChecklistItemUpdate,
    RenewalCreate,
    RenewalDecisionRequest,
    RenewalDraftRequest,
    RenewalDraftResponse,
    RenewalHistoryItemResponse,
    RenewalResponse,
    RenewalUpdate,
)
from app.services.finance.foundation import (
    FinanceAccessDeniedError,
    get_finance_settings,
    require_finance_access,
)
from app.services.finance.planning import (
    FinancePlanningError,
    create_commitment,
    update_commitment,
)
from app.services.record_history import save_history

router = APIRouter()


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


def _status(due_date: str, reminder_days_before: int, today: date) -> tuple[int, str]:
    due = date.fromisoformat(due_date[:10])
    days_until = (due - today).days
    if days_until < 0:
        return days_until, "overdue"
    if days_until <= reminder_days_before:
        return days_until, "due_soon"
    return days_until, "upcoming"


def _response(
    row: dict,
    today: date,
    *,
    checklist: list[RenewalChecklistItemResponse] | None = None,
    history: list[RenewalHistoryItemResponse] | None = None,
) -> RenewalResponse:
    days_until, renewal_status = _status(
        row["due_date"], row["reminder_days_before"], today
    )
    linked_cost = row.get("commitment_exact_minor")
    if linked_cost is None:
        linked_cost = row.get("commitment_expected_minor")
    history = history or []
    current_cost = linked_cost if row.get("finance_commitment_id") else row["cost_pence"]
    historical_costs = [item.cost_pence for item in history if item.cost_pence is not None]
    if historical_costs and historical_costs[0] == current_cost and len(historical_costs) > 1:
        previous_cost = historical_costs[1]
    else:
        previous_cost = historical_costs[0] if historical_costs else None
    return RenewalResponse(
        id=row["id"],
        title=row["title"],
        category=row["category"],
        due_date=row["due_date"][:10],
        days_until=days_until,
        status=renewal_status,
        recurrence_months=row["recurrence_months"],
        cost_pence=current_cost,
        reminder_days_before=row["reminder_days_before"],
        source_document_id=row["source_document_id"],
        source_document=(
            {
                "id": row["source_document_record_id"],
                "title": row["source_document_title"],
                "original_filename": row["source_document_filename"],
                "media_type": row["source_document_media_type"],
                "file_size": row["source_document_file_size"],
                "download_url": f"/api/documents/{row['source_document_record_id']}/content",
            }
            if row.get("source_document_record_id")
            else None
        ),
        provider=row.get("provider"),
        reference=row.get("reference"),
        action_url=row.get("action_url"),
        comparison_url=row.get("comparison_url"),
        contact_url=row.get("contact_url"),
        finance_commitment_id=row.get("finance_commitment_id"),
        payment_handling=row.get("commitment_payment_handling") or "UNSPECIFIED",
        show_in_calendar=bool(
            row.get("show_in_calendar") or row.get("commitment_show_in_calendar") or 0
        ),
        show_in_tasks=bool(
            row.get("show_in_tasks") or row.get("commitment_show_in_tasks") or 0
        ),
        responsible_user_id=(
            row.get("responsible_user_id")
            or row.get("commitment_responsible_user_id")
        ),
        responsible_user_name=row.get("responsible_user_name"),
        reminders_enabled=bool(row.get("reminders_enabled", 1)),
        escalate_after_days=row.get("escalate_after_days"),
        checklist=checklist or [],
        history=history,
        previous_cost_pence=previous_cost,
        cost_change_pence=(
            current_cost - previous_cost
            if current_cost is not None and previous_cost is not None
            else None
        ),
        notes=row["notes"],
        created_at=row["created_at"],
    )


async def _row(
    db, renewal_id: str, family_id: str, *, include_deleted: bool = False
) -> dict:
    deleted_filter = "" if include_deleted else "AND renewal.deleted_at IS NULL"
    row = await (
        await db.execute(
            f"""
            SELECT renewal.*,
                   commitment.exact_minor AS commitment_exact_minor,
                   commitment.expected_minor AS commitment_expected_minor,
                   commitment.payment_handling AS commitment_payment_handling,
                   commitment.show_in_calendar AS commitment_show_in_calendar,
                   commitment.show_in_tasks AS commitment_show_in_tasks,
                   commitment.responsible_user_id AS commitment_responsible_user_id,
                   commitment.status AS commitment_status,
                   document.id AS source_document_record_id,
                   document.title AS source_document_title,
                   document.original_filename AS source_document_filename,
                   document.media_type AS source_document_media_type,
                   document.file_size AS source_document_file_size,
                   responsible.name AS responsible_user_name
            FROM renewals renewal
            LEFT JOIN finance_commitments commitment
              ON commitment.id = renewal.finance_commitment_id
             AND commitment.family_id = renewal.family_id
             AND commitment.deleted_at IS NULL
            LEFT JOIN documents document
              ON document.id = renewal.source_document_id
             AND document.family_id = renewal.family_id
             AND document.deleted_at IS NULL
            LEFT JOIN users responsible
              ON responsible.id = COALESCE(
                    renewal.responsible_user_id,
                    commitment.responsible_user_id
                 )
             AND responsible.family_id = renewal.family_id
             AND responsible.deleted_at IS NULL
            WHERE renewal.id = ? AND renewal.family_id = ?
              {deleted_filter}
            """,
            (renewal_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Renewal not found")
    return dict(row)


async def _checklist(db, *, renewal_id: str, family_id: str) -> list[RenewalChecklistItemResponse]:
    rows = await (
        await db.execute(
            """
            SELECT id, title, checked_at, position
            FROM renewal_checklist_items
            WHERE renewal_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY position, created_at
            """,
            (renewal_id, family_id),
        )
    ).fetchall()
    return [RenewalChecklistItemResponse(**dict(row)) for row in rows]


async def _history(db, *, renewal_id: str, family_id: str) -> list[RenewalHistoryItemResponse]:
    rows = await (
        await db.execute(
            """
            SELECT id, outcome, due_date, decided_at, cost_pence, next_due_date, notes
            FROM renewal_outcomes
            WHERE renewal_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY decided_at DESC, created_at DESC
            LIMIT 20
            """,
            (renewal_id, family_id),
        )
    ).fetchall()
    return [RenewalHistoryItemResponse(**dict(row)) for row in rows]


async def _checklist_row(db, *, item_id: str, renewal_id: str, family_id: str) -> dict:
    row = await (
        await db.execute(
            """
            SELECT item.* FROM renewal_checklist_items item
            JOIN renewals renewal
              ON renewal.id = item.renewal_id
             AND renewal.family_id = item.family_id
             AND renewal.deleted_at IS NULL
            WHERE item.id = ? AND item.renewal_id = ? AND item.family_id = ?
              AND item.deleted_at IS NULL
            """,
            (item_id, renewal_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Checklist item not found")
    return dict(row)


async def _full_response(db, row: dict, today: date | None = None) -> RenewalResponse:
    family_id = row["family_id"]
    return _response(
        row,
        today or date.today(),
        checklist=await _checklist(db, renewal_id=row["id"], family_id=family_id),
        history=await _history(db, renewal_id=row["id"], family_id=family_id),
    )


async def _validate_responsible_user(
    db, *, responsible_user_id: str | None, family_id: str
) -> None:
    if responsible_user_id is None:
        return
    row = await (
        await db.execute(
            """
            SELECT 1 FROM users
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (responsible_user_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=422, detail="Choose an adult in this family")


def _commitment_recurrence(recurrence_months: int | None) -> str:
    if recurrence_months is None:
        return "ONE_OFF"
    if recurrence_months == 1:
        return "MONTHLY"
    if recurrence_months == 12:
        return "ANNUAL"
    return "CUSTOM"


async def _validate_source_document(
    db, *, source_document_id: str | None, family_id: str
) -> None:
    if source_document_id is None:
        return
    row = await (
        await db.execute(
            """
            SELECT 1 FROM documents
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (source_document_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=422,
            detail="The attached document is not available to this family",
        )


def _draft_date(text: str) -> str | None:
    candidates: list[tuple[str, str]] = []
    candidates.extend((value, "%Y-%m-%d") for value in re.findall(r"\b20\d{2}-\d{1,2}-\d{1,2}\b", text))
    candidates.extend((value, "%d/%m/%Y") for value in re.findall(r"\b\d{1,2}/\d{1,2}/20\d{2}\b", text))
    candidates.extend((value, "%d-%m-%Y") for value in re.findall(r"\b\d{1,2}-\d{1,2}-20\d{2}\b", text))
    named = re.findall(
        r"\b\d{1,2}\s+(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+20\d{2}\b",
        text,
        flags=re.IGNORECASE,
    )
    candidates.extend((value, "%d %B %Y") for value in named)
    candidates.extend((value, "%d %b %Y") for value in named)
    parsed: list[date] = []
    for value, pattern in candidates:
        try:
            parsed.append(datetime.strptime(value, pattern).date())
        except ValueError:
            continue
    if not parsed:
        return None
    today = date.today()
    future = [item for item in parsed if item >= today]
    return min(future or parsed).isoformat()


def _draft_from_text(
    text: str,
    *,
    document_id: str | None,
    document_title: str | None,
) -> RenewalDraftResponse:
    cleaned = text.strip()
    lower = cleaned.lower()
    category = "other"
    for candidate, terms in {
        "vehicle": ("mot", "vehicle", "car registration"),
        "insurance": ("insurance", "policy", "premium"),
        "document": ("passport", "driving licence", "identity document"),
        "subscription": ("subscription", "renews automatically"),
        "utility": ("energy", "electricity", "gas tariff", "broadband"),
        "membership": ("membership", "member number"),
        "medical": ("medical", "prescription", "health plan"),
    }.items():
        if any(term in lower for term in terms):
            category = candidate
            break

    due_date = _draft_date(cleaned)
    cost_match = re.search(r"£\s*([0-9][0-9,]*(?:\.\d{1,2})?)", cleaned)
    cost_pence = None
    if cost_match:
        try:
            cost_pence = round(float(cost_match.group(1).replace(",", "")) * 100)
        except ValueError:
            pass
    reference_match = re.search(
        r"(?:policy|reference|account|membership|member)\s*(?:number|no\.?)?\s*(?:#|:)?\s*([A-Z0-9][A-Z0-9\-/ ]{2,40})",
        cleaned,
        flags=re.IGNORECASE,
    )
    provider_match = re.search(
        r"(?:provider|insurer|issued by|company)\s*[:\-]\s*([^\n]{2,100})",
        cleaned,
        flags=re.IGNORECASE,
    )
    url_match = re.search(r"https?://[^\s<>\]\)]+", cleaned)
    recurrence = 12 if any(term in lower for term in ("annual", "annually", "yearly", "every year")) else (1 if "monthly" in lower else None)
    fallback_title = next(
        (line.strip() for line in cleaned.splitlines() if 2 <= len(line.strip()) <= 100),
        None,
    )
    title = (document_title or fallback_title or "").strip() or None
    uncertain = [
        field
        for field, value in {
            "name": title,
            "due date": due_date,
            "provider": provider_match.group(1).strip() if provider_match else None,
            "reference": reference_match.group(1).strip() if reference_match else None,
        }.items()
        if value is None
    ]
    return RenewalDraftResponse(
        title=title,
        category=category,
        due_date=due_date,
        recurrence_months=recurrence,
        cost_pence=cost_pence,
        provider=provider_match.group(1).strip() if provider_match else None,
        reference=reference_match.group(1).strip() if reference_match else None,
        action_url=url_match.group(0).rstrip(".,") if url_match else None,
        source_document_id=document_id,
        uncertain_fields=uncertain,
    )


@router.post("/draft", response_model=RenewalDraftResponse)
async def preview_renewal_draft(
    body: RenewalDraftRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    text = (body.text or "").strip()
    document_title = None
    if body.document_id:
        document = await (
            await db.execute(
                """
                SELECT title, extracted_text FROM documents
                WHERE id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (body.document_id, current_user["family_id"]),
            )
        ).fetchone()
        if document is None:
            raise HTTPException(status_code=404, detail="Document not found")
        document_title = document["title"]
        if not text:
            text = (document["extracted_text"] or "").strip()
    if not text:
        raise HTTPException(
            status_code=422,
            detail="This document has no readable text yet. Enter the details yourself instead.",
        )
    return _draft_from_text(
        text,
        document_id=body.document_id,
        document_title=document_title,
    )


async def _create_linked_commitment(
    db,
    *,
    user: dict,
    renewal_id: str,
    title: str,
    due_date: str,
    recurrence_months: int | None,
    cost_pence: int | None,
    payment_handling: str,
    show_in_calendar: bool,
    show_in_tasks: bool,
    responsible_user_id: str | None,
) -> str:
    if cost_pence is None:
        raise HTTPException(
            status_code=422,
            detail="Enter the renewal cost before including it in Household Finance",
        )
    if payment_handling == "UNSPECIFIED":
        raise HTTPException(
            status_code=422,
            detail="Choose how this renewal is handled",
        )
    settings = await get_finance_settings(db, user=user)
    commitment = await create_commitment(
        db,
        user=user,
        space_id=settings.household_space_id,
        body=FinanceCommitmentCreate(
            name=title,
            amount_mode="EXACT",
            exact_minor=cost_pence,
            recurrence=_commitment_recurrence(recurrence_months),
            reviewed_dates=[date.fromisoformat(due_date[:10])],
            priority="IMPORTANT",
            payment_handling=payment_handling,
            show_in_calendar=show_in_calendar,
            show_in_tasks=show_in_tasks,
            responsible_user_id=responsible_user_id,
        ),
    )
    await db.execute(
        """
        UPDATE renewals SET finance_commitment_id = ?, cost_pence = NULL,
            updated_at = ? WHERE id = ? AND family_id = ?
        """,
        (commitment.id, datetime.now(timezone.utc).isoformat(), renewal_id, user["family_id"]),
    )
    return commitment.id


async def _sync_linked_commitment(
    db,
    *,
    user: dict,
    row: dict,
    title: str,
    due_date: str,
    recurrence_months: int | None,
    cost_pence: int | None,
    payment_handling: str,
    show_in_calendar: bool,
    show_in_tasks: bool,
    responsible_user_id: str | None,
) -> None:
    update: dict[str, object] = {
        "name": title,
        "recurrence": _commitment_recurrence(recurrence_months),
        "reviewed_dates": [date.fromisoformat(due_date[:10])],
        "payment_handling": payment_handling,
        "show_in_calendar": show_in_calendar,
        "show_in_tasks": show_in_tasks,
        "responsible_user_id": responsible_user_id,
    }
    if cost_pence is not None:
        update.update(
            amount_mode="EXACT",
            exact_minor=cost_pence,
            expected_minor=None,
            low_minor=None,
            high_minor=None,
        )
    await update_commitment(
        db,
        user=user,
        commitment_id=row["finance_commitment_id"],
        body=FinanceCommitmentUpdate(**update),
        allow_linked_date_update=True,
    )


@router.get("/", response_model=list[RenewalResponse])
async def list_renewals(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    rows = await (
        await db.execute(
            """
            SELECT renewal.*,
                   commitment.exact_minor AS commitment_exact_minor,
                   commitment.expected_minor AS commitment_expected_minor,
                   commitment.payment_handling AS commitment_payment_handling,
                   commitment.show_in_calendar AS commitment_show_in_calendar,
                   commitment.show_in_tasks AS commitment_show_in_tasks,
                   commitment.responsible_user_id AS commitment_responsible_user_id,
                   commitment.status AS commitment_status,
                   document.id AS source_document_record_id,
                   document.title AS source_document_title,
                   document.original_filename AS source_document_filename,
                   document.media_type AS source_document_media_type,
                   document.file_size AS source_document_file_size,
                   responsible.name AS responsible_user_name
            FROM renewals renewal
            LEFT JOIN finance_commitments commitment
              ON commitment.id = renewal.finance_commitment_id
             AND commitment.family_id = renewal.family_id
             AND commitment.deleted_at IS NULL
            LEFT JOIN documents document
              ON document.id = renewal.source_document_id
             AND document.family_id = renewal.family_id
             AND document.deleted_at IS NULL
            LEFT JOIN users responsible
              ON responsible.id = COALESCE(
                    renewal.responsible_user_id,
                    commitment.responsible_user_id
                 )
             AND responsible.family_id = renewal.family_id
             AND responsible.deleted_at IS NULL
            WHERE renewal.family_id = ? AND renewal.deleted_at IS NULL
            ORDER BY renewal.due_date
            """,
            (current_user["family_id"],),
        )
    ).fetchall()
    today = date.today()
    return [await _full_response(db, dict(row), today) for row in rows]


@router.get("/{renewal_id}", response_model=RenewalResponse)
async def get_renewal(
    renewal_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    return await _full_response(
        db,
        await _row(db, renewal_id, current_user["family_id"]),
    )


@router.post("/", response_model=RenewalResponse, status_code=201)
async def create_renewal(
    body: RenewalCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    if not body.title.strip():
        raise HTTPException(status_code=422, detail="Renewal name cannot be blank")
    await _validate_source_document(
        db,
        source_document_id=body.source_document_id,
        family_id=current_user["family_id"],
    )
    await _validate_responsible_user(
        db,
        responsible_user_id=body.responsible_user_id,
        family_id=current_user["family_id"],
    )
    renewal_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        await db.execute(
            """
            INSERT INTO renewals
                (id, title, category, due_date, recurrence_months, cost_pence,
                 reminder_days_before, source_document_id, finance_commitment_id,
                 provider, reference, action_url, comparison_url, contact_url,
                 responsible_user_id, reminders_enabled, escalate_after_days,
                 show_in_calendar, show_in_tasks, notes, family_id,
                 created_at, updated_at, created_by, client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                renewal_id,
                body.title.strip(),
                body.category,
                body.due_date,
                body.recurrence_months,
                None if body.include_in_household_finance else body.cost_pence,
                body.reminder_days_before,
                body.source_document_id,
                body.provider.strip() if body.provider else None,
                body.reference.strip() if body.reference else None,
                body.action_url,
                body.comparison_url,
                body.contact_url,
                body.responsible_user_id,
                int(body.reminders_enabled),
                body.escalate_after_days,
                int(body.show_in_calendar),
                int(body.show_in_tasks),
                body.notes.strip()[:2_000] if body.notes else None,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )
        for position, raw_title in enumerate(body.checklist):
            title = raw_title.strip()
            if not title:
                continue
            await db.execute(
                """
                INSERT INTO renewal_checklist_items
                    (id, renewal_id, title, position, family_id, created_at,
                     updated_at, created_by, client_id, client_timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    renewal_id,
                    title[:200],
                    position,
                    current_user["family_id"],
                    now,
                    now,
                    current_user["id"],
                    body.client_id,
                    body.client_timestamp,
                ),
            )
        if body.include_in_household_finance:
            await _create_linked_commitment(
                db,
                user=current_user,
                renewal_id=renewal_id,
                title=body.title.strip(),
                due_date=body.due_date,
                recurrence_months=body.recurrence_months,
                cost_pence=body.cost_pence,
                payment_handling=body.payment_handling,
                show_in_calendar=body.show_in_calendar,
                show_in_tasks=body.show_in_tasks,
                responsible_user_id=body.responsible_user_id,
            )
        await db.commit()
    except (FinancePlanningError, ValueError) as exc:
        if db.in_transaction:
            await db.rollback()
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return await _full_response(
        db,
        await _row(db, renewal_id, current_user["family_id"]),
    )


@router.post(
    "/{renewal_id}/checklist",
    response_model=RenewalChecklistItemResponse,
    status_code=201,
)
async def add_checklist_item(
    renewal_id: str,
    body: RenewalChecklistItemCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    await _row(db, renewal_id, current_user["family_id"])
    title = body.title.strip()
    if not title:
        raise HTTPException(status_code=422, detail="Checklist item cannot be blank")
    position = (
        await (
            await db.execute(
                """
                SELECT COALESCE(MAX(position), -1) + 1
                FROM renewal_checklist_items
                WHERE renewal_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (renewal_id, current_user["family_id"]),
            )
        ).fetchone()
    )[0]
    item_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO renewal_checklist_items
            (id, renewal_id, title, position, family_id, created_at,
             updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            item_id,
            renewal_id,
            title,
            position,
            current_user["family_id"],
            now,
            now,
            current_user["id"],
        ),
    )
    await db.commit()
    return RenewalChecklistItemResponse(
        id=item_id,
        title=title,
        position=position,
    )


@router.patch(
    "/{renewal_id}/checklist/{item_id}",
    response_model=RenewalChecklistItemResponse,
)
async def update_checklist_item(
    renewal_id: str,
    item_id: str,
    body: RenewalChecklistItemUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    row = await _checklist_row(
        db,
        item_id=item_id,
        renewal_id=renewal_id,
        family_id=current_user["family_id"],
    )
    supplied = body.model_dump(exclude_unset=True)
    if not supplied:
        raise HTTPException(status_code=422, detail="No checklist change supplied")
    updates: dict[str, object] = {}
    if "title" in supplied:
        title = (body.title or "").strip()
        if not title:
            raise HTTPException(status_code=422, detail="Checklist item cannot be blank")
        updates["title"] = title
    if "checked" in supplied:
        updates["checked_at"] = (
            datetime.now(timezone.utc).isoformat() if body.checked else None
        )
        updates["checked_by"] = current_user["id"] if body.checked else None
    await save_history(
        db,
        "renewal_checklist_items",
        item_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    updates["updated_at"] = datetime.now(timezone.utc).isoformat()
    await db.execute(
        f"UPDATE renewal_checklist_items SET {', '.join(f'{key} = ?' for key in updates)} "
        "WHERE id = ? AND renewal_id = ? AND family_id = ?",
        [*updates.values(), item_id, renewal_id, current_user["family_id"]],
    )
    await db.commit()
    updated = {**row, **updates}
    return RenewalChecklistItemResponse(**updated)


@router.delete("/{renewal_id}/checklist/{item_id}", status_code=204)
async def delete_checklist_item(
    renewal_id: str,
    item_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    await _checklist_row(
        db,
        item_id=item_id,
        renewal_id=renewal_id,
        family_id=current_user["family_id"],
    )
    await save_history(
        db,
        "renewal_checklist_items",
        item_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        UPDATE renewal_checklist_items SET deleted_at = ?, updated_at = ?
        WHERE id = ? AND renewal_id = ? AND family_id = ?
        """,
        (now, now, item_id, renewal_id, current_user["family_id"]),
    )
    await db.commit()
    return Response(status_code=204)


@router.patch("/{renewal_id}", response_model=RenewalResponse)
async def update_renewal(
    renewal_id: str,
    body: RenewalUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    row = await _row(db, renewal_id, current_user["family_id"])
    supplied = body.model_dump(exclude_unset=True)
    if not supplied:
        raise HTTPException(status_code=422, detail="No renewal changes supplied")
    include = supplied.pop("include_in_household_finance", None)
    payment_handling = supplied.pop("payment_handling", None)
    show_in_calendar = supplied.get("show_in_calendar")
    show_in_tasks = supplied.get("show_in_tasks")
    responsible_user_id_supplied = "responsible_user_id" in supplied
    responsible_user_id = supplied.get("responsible_user_id")

    title = (supplied.get("title") or row["title"]).strip()
    if not title:
        raise HTTPException(status_code=422, detail="Renewal name cannot be blank")
    if "source_document_id" in supplied:
        await _validate_source_document(
            db,
            source_document_id=supplied["source_document_id"],
            family_id=current_user["family_id"],
        )
    if responsible_user_id_supplied:
        await _validate_responsible_user(
            db,
            responsible_user_id=responsible_user_id,
            family_id=current_user["family_id"],
        )
    due_date = supplied.get("due_date") or row["due_date"]
    recurrence_months = supplied.get("recurrence_months", row["recurrence_months"])
    cost_supplied = "cost_pence" in supplied
    cost_pence = supplied.get("cost_pence") if cost_supplied else (
        row.get("commitment_exact_minor")
        if row.get("finance_commitment_id")
        else row["cost_pence"]
    )
    handling = payment_handling or row.get("commitment_payment_handling") or "UNSPECIFIED"
    calendar_visible = (
        bool(show_in_calendar)
        if show_in_calendar is not None
        else bool(
            row.get("show_in_calendar")
            or row.get("commitment_show_in_calendar")
            or 0
        )
    )
    tasks_visible = (
        bool(show_in_tasks)
        if show_in_tasks is not None
        else bool(row.get("show_in_tasks") or row.get("commitment_show_in_tasks") or 0)
    )
    responsible = (
        responsible_user_id
        if responsible_user_id_supplied
        else row.get("responsible_user_id") or row.get("commitment_responsible_user_id")
    )

    await db.execute("BEGIN IMMEDIATE")
    try:
        await save_history(
            db,
            "renewals",
            renewal_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        core_updates = {
            key: value
            for key, value in supplied.items()
            if key in {
                "title", "category", "due_date", "recurrence_months",
                "cost_pence", "reminder_days_before", "source_document_id", "notes",
                "provider", "reference", "action_url", "comparison_url", "contact_url",
                "responsible_user_id", "reminders_enabled", "escalate_after_days",
                "show_in_calendar", "show_in_tasks",
            }
        }
        if row.get("finance_commitment_id"):
            core_updates.pop("cost_pence", None)
        if core_updates:
            if "title" in core_updates:
                core_updates["title"] = title
            set_clause = ", ".join(f"{field} = ?" for field in core_updates)
            await db.execute(
                f"UPDATE renewals SET {set_clause}, updated_at = ? WHERE id = ? AND family_id = ?",
                [
                    *core_updates.values(),
                    datetime.now(timezone.utc).isoformat(),
                    renewal_id,
                    current_user["family_id"],
                ],
            )
            if any(
                field in core_updates
                for field in {"due_date", "show_in_tasks", "responsible_user_id"}
            ):
                await db.execute(
                    """
                    UPDATE renewals
                    SET task_completed_at = NULL, task_completed_by = NULL
                    WHERE id = ? AND family_id = ?
                    """,
                    (renewal_id, current_user["family_id"]),
                )

        if row.get("finance_commitment_id") and include is False:
            await update_commitment(
                db,
                user=current_user,
                commitment_id=row["finance_commitment_id"],
                body=FinanceCommitmentUpdate(
                    status="CANCELLED",
                    show_in_calendar=False,
                    show_in_tasks=False,
                ),
                allow_linked_date_update=True,
            )
            await db.execute(
                """
                UPDATE renewals SET finance_commitment_id = NULL, cost_pence = ?,
                    updated_at = ? WHERE id = ? AND family_id = ?
                """,
                (
                    cost_pence,
                    datetime.now(timezone.utc).isoformat(),
                    renewal_id,
                    current_user["family_id"],
                ),
            )
        elif row.get("finance_commitment_id"):
            await _sync_linked_commitment(
                db,
                user=current_user,
                row=row,
                title=title,
                due_date=due_date,
                recurrence_months=recurrence_months,
                cost_pence=cost_pence if cost_supplied else None,
                payment_handling=handling,
                show_in_calendar=calendar_visible,
                show_in_tasks=tasks_visible,
                responsible_user_id=responsible,
            )
        elif include is True:
            await _create_linked_commitment(
                db,
                user=current_user,
                renewal_id=renewal_id,
                title=title,
                due_date=due_date,
                recurrence_months=recurrence_months,
                cost_pence=cost_pence,
                payment_handling=handling,
                show_in_calendar=calendar_visible,
                show_in_tasks=tasks_visible,
                responsible_user_id=responsible,
            )
        elif payment_handling not in (None, "UNSPECIFIED"):
            raise HTTPException(
                status_code=422,
                detail="Include this renewal in Household Finance before choosing how its cost is handled",
            )
        await db.commit()
    except FinancePlanningError as exc:
        if db.in_transaction:
            await db.rollback()
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except ValueError as exc:
        if db.in_transaction:
            await db.rollback()
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return await _full_response(
        db,
        await _row(db, renewal_id, current_user["family_id"]),
    )


def _next_due_date(row: dict, requested: str | None) -> date | None:
    if requested:
        return date.fromisoformat(requested[:10])
    if not row["recurrence_months"]:
        return None
    due = date.fromisoformat(row["due_date"][:10])
    month_index = (due.month - 1) + row["recurrence_months"]
    year = due.year + month_index // 12
    month = month_index % 12 + 1
    return due.replace(
        year=year,
        month=month,
        day=min(due.day, calendar.monthrange(year, month)[1]),
    )


async def _record_decision(
    db,
    *,
    row: dict,
    body: RenewalDecisionRequest,
    user: dict,
) -> RenewalResponse:
    now = datetime.now(timezone.utc).isoformat()
    next_due = _next_due_date(row, body.next_due_date) if body.outcome == "renewed" else None
    current_cost = row.get("commitment_exact_minor")
    if current_cost is None:
        current_cost = row.get("commitment_expected_minor")
    if current_cost is None:
        current_cost = row.get("cost_pence")
    decided_cost = body.cost_pence if body.cost_pence is not None else current_cost
    archive = body.outcome == "not_renewing" or next_due is None

    await db.execute("BEGIN IMMEDIATE")
    try:
        await save_history(
            db,
            "renewals",
            row["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            INSERT INTO renewal_outcomes
                (id, renewal_id, outcome, due_date, decided_at, cost_pence,
                 next_due_date, notes, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                row["id"],
                body.outcome,
                row["due_date"][:10],
                now,
                decided_cost,
                next_due.isoformat() if next_due else None,
                body.notes.strip() if body.notes else None,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        if archive:
            await db.execute(
                """
                UPDATE renewals
                SET cost_pence = COALESCE(?, cost_pence), deleted_at = ?, updated_at = ?
                WHERE id = ? AND family_id = ?
                """,
                (body.cost_pence, now, now, row["id"], user["family_id"]),
            )
        else:
            await db.execute(
                """
                UPDATE renewals
                SET due_date = ?, cost_pence = CASE
                        WHEN finance_commitment_id IS NULL THEN COALESCE(?, cost_pence)
                        ELSE cost_pence END,
                    task_completed_at = NULL, task_completed_by = NULL, updated_at = ?
                WHERE id = ? AND family_id = ?
                """,
                (
                    next_due.isoformat(),
                    body.cost_pence,
                    now,
                    row["id"],
                    user["family_id"],
                ),
            )
            checklist_rows = await (
                await db.execute(
                    """
                    SELECT id FROM renewal_checklist_items
                    WHERE renewal_id = ? AND family_id = ?
                      AND deleted_at IS NULL AND checked_at IS NOT NULL
                    """,
                    (row["id"], user["family_id"]),
                )
            ).fetchall()
            for checklist_row in checklist_rows:
                await save_history(
                    db,
                    "renewal_checklist_items",
                    checklist_row["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
            await db.execute(
                """
                UPDATE renewal_checklist_items
                SET checked_at = NULL, checked_by = NULL, updated_at = ?
                WHERE renewal_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (now, row["id"], user["family_id"]),
            )

        if row.get("finance_commitment_id"):
            finance_update: dict[str, object] = {}
            if archive:
                finance_update["status"] = (
                    "CANCELLED" if body.outcome == "not_renewing" else "COMPLETED"
                )
                finance_update["show_in_calendar"] = False
                finance_update["show_in_tasks"] = False
            else:
                finance_update["reviewed_dates"] = [next_due]
                if body.cost_pence is not None:
                    finance_update.update(
                        amount_mode="EXACT",
                        exact_minor=body.cost_pence,
                        expected_minor=None,
                        low_minor=None,
                        high_minor=None,
                    )
            await update_commitment(
                db,
                user=user,
                commitment_id=row["finance_commitment_id"],
                body=FinanceCommitmentUpdate(**finance_update),
                allow_linked_date_update=True,
                reset_moved_task_completion=not archive,
            )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    updated = await _row(
        db,
        row["id"],
        user["family_id"],
        include_deleted=archive,
    )
    return await _full_response(db, updated)


@router.post("/{renewal_id}/decision", response_model=RenewalResponse)
async def decide_renewal(
    renewal_id: str,
    body: RenewalDecisionRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    row = await _row(db, renewal_id, current_user["family_id"])
    return await _record_decision(db, row=row, body=body, user=current_user)


@router.post("/{renewal_id}/renewed", response_model=RenewalResponse)
async def mark_renewed(
    renewal_id: str,
    body: RenewalDecisionRequest | None = None,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    row = await _row(db, renewal_id, current_user["family_id"])
    decision = body or RenewalDecisionRequest(outcome="renewed")
    return await _record_decision(db, row=row, body=decision, user=current_user)


@router.post("/{renewal_id}/restore", response_model=RenewalResponse)
async def restore_renewal(
    renewal_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    row = await _row(
        db,
        renewal_id,
        current_user["family_id"],
        include_deleted=True,
    )
    if row.get("deleted_at") is None:
        return await _full_response(db, row)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        await save_history(
            db,
            "renewals",
            renewal_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        await db.execute(
            """
            UPDATE renewals SET deleted_at = NULL, updated_at = ?
            WHERE id = ? AND family_id = ?
            """,
            (now, renewal_id, current_user["family_id"]),
        )
        last_outcome = await (
            await db.execute(
                """
                SELECT id, decided_at FROM renewal_outcomes
                WHERE renewal_id = ? AND family_id = ? AND deleted_at IS NULL
                ORDER BY decided_at DESC, created_at DESC LIMIT 1
                """,
                (renewal_id, current_user["family_id"]),
            )
        ).fetchone()
        if last_outcome is not None and last_outcome["decided_at"] == row["deleted_at"]:
            await save_history(
                db,
                "renewal_outcomes",
                last_outcome["id"],
                current_user["id"],
                family_id=current_user["family_id"],
            )
            await db.execute(
                """
                UPDATE renewal_outcomes SET deleted_at = ?, updated_at = ?
                WHERE id = ? AND family_id = ?
                """,
                (now, now, last_outcome["id"], current_user["family_id"]),
            )
        if row.get("finance_commitment_id"):
            await update_commitment(
                db,
                user=current_user,
                commitment_id=row["finance_commitment_id"],
                body=FinanceCommitmentUpdate(
                    status="ACTIVE",
                    show_in_calendar=bool(row.get("show_in_calendar")),
                    show_in_tasks=bool(row.get("show_in_tasks")),
                ),
                allow_linked_date_update=True,
            )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return await _full_response(
        db,
        await _row(db, renewal_id, current_user["family_id"]),
    )


@router.delete("/{renewal_id}", status_code=204)
async def delete_renewal(
    renewal_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    row = await _row(db, renewal_id, current_user["family_id"])
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        await save_history(
            db,
            "renewals",
            renewal_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        await db.execute(
            "UPDATE renewals SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (now, now, renewal_id, current_user["family_id"]),
        )
        if row.get("finance_commitment_id"):
            await update_commitment(
                db,
                user=current_user,
                commitment_id=row["finance_commitment_id"],
                body=FinanceCommitmentUpdate(
                    status="CANCELLED",
                    show_in_calendar=False,
                    show_in_tasks=False,
                ),
                allow_linked_date_update=True,
            )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return Response(status_code=204)

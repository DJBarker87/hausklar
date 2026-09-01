import json
import uuid
from datetime import datetime, timezone

import re

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile, status

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.middleware.rate_limit import reserve_persistent_attempts
from app.models.grocery import (
    CriticalLowStockResponse,
    ConsumptionEventCreate,
    ConsumptionEventResponse,
    ExpiringItemResponse,
    GroceryItemCreate,
    GroceryItemResponse,
    GroceryItemUpdate,
    PurchaseBatchCreate,
    PurchaseBatchResponse,
    FreezerAddRequest,
    FreezerItemResponse,
    ShoppingSuggestionsResponse,
    StockLevelResponse,
    SuggestionsAcceptRequest,
    TescoImportRequest,
    TescoImportResponse,
    TescoHistoryImportResult,
    TescoHistoryPreview,
    TescoHistorySummary,
    UseByPatchRequest,
)
from app.services.grocery import (
    accept_suggestions_to_shopping_items,
    add_freezer_item,
    build_purchase_batch_response,
    build_purchase_batch_responses,
    compute_stock_levels,
    get_critical_low_stock_alerts,
    generate_replenishment_suggestions,
    get_expiring_items,
    list_freezer_items,
    parse_tesco_import,
)
from app.services.record_history import save_history
from app.services import tesco_history

router = APIRouter()
_SHA256 = re.compile(r"^[a-f0-9]{64}$")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


async def _read_tesco_history(file: UploadFile) -> tuple[bytes, str]:
    filename = (file.filename or "tesco-history.json").rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    if not filename.casefold().endswith((".json", ".zip")):
        raise HTTPException(status_code=422, detail="Choose the Tesco JSON file or ZIP archive")
    chunks: list[bytes] = []
    total = 0
    await file.seek(0)
    while chunk := await file.read(1024 * 1024):
        total += len(chunk)
        if total > settings.document_max_upload_bytes:
            raise HTTPException(
                status_code=413,
                detail=(
                    "Tesco report exceeds the "
                    f"{settings.document_max_upload_bytes // (1024 * 1024)} MB upload limit"
                ),
            )
        chunks.append(chunk)
    if not chunks:
        raise HTTPException(status_code=422, detail="The Tesco file is empty")
    return b"".join(chunks), filename[:255]


def _parse_tesco_history(data: bytes, *, filename: str):
    try:
        return tesco_history.parse_history_file(
            data,
            filename=filename,
            max_uncompressed_bytes=settings.document_max_upload_bytes * 2,
        )
    except tesco_history.TescoHistoryError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


async def _tesco_history_preview(db, *, family_id: str, parsed) -> TescoHistoryPreview:
    existing = await (
        await db.execute(
            "SELECT 1 FROM tesco_history_imports WHERE family_id = ? "
            "AND source_sha256 = ? AND deleted_at IS NULL",
            (family_id, parsed.sha256),
        )
    ).fetchone()
    return TescoHistoryPreview(
        filename=parsed.filename,
        sha256=parsed.sha256,
        order_count=len(parsed.orders),
        line_count=parsed.line_count,
        first_purchased_at=parsed.first_purchased_at,
        last_purchased_at=parsed.last_purchased_at,
        sample_items=parsed.sample_items,
        issues=list(parsed.issues),
        already_imported=existing is not None,
        can_confirm=True,
    )


def _item_response(row: dict) -> GroceryItemResponse:
    data = dict(row)
    if data.get("aliases") and isinstance(data["aliases"], str):
        data["aliases"] = json.loads(data["aliases"])
    data["is_use_by_tracked"] = bool(data.get("is_use_by_tracked", 0))
    return GroceryItemResponse(**data)


async def _require_family_items(db, family_id: str, item_ids: list[str]) -> None:
    unique_ids = list(dict.fromkeys(item_ids))
    if not unique_ids:
        return
    placeholders = ",".join("?" for _ in unique_ids)
    cursor = await db.execute(
        f"SELECT id FROM grocery_items WHERE id IN ({placeholders}) "
        "AND family_id = ? AND deleted_at IS NULL",
        [*unique_ids, family_id],
    )
    if len(await cursor.fetchall()) != len(unique_ids):
        raise HTTPException(
            status_code=422,
            detail="One or more grocery items are not available to this family",
        )


@router.get("/tesco-history/summary", response_model=TescoHistorySummary)
async def get_tesco_history_summary(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await tesco_history.history_summary(db, family_id=current_user["family_id"])


@router.post("/tesco-history/preview", response_model=TescoHistoryPreview)
async def preview_tesco_history(
    file: UploadFile = File(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Review a transient Tesco portability report without storing it."""
    try:
        data, filename = await _read_tesco_history(file)
        parsed = _parse_tesco_history(data, filename=filename)
        return await _tesco_history_preview(
            db,
            family_id=current_user["family_id"],
            parsed=parsed,
        )
    finally:
        await file.close()


@router.post(
    "/tesco-history/import",
    response_model=TescoHistoryImportResult,
    status_code=status.HTTP_201_CREATED,
)
async def import_tesco_history(
    file: UploadFile = File(...),
    expected_sha256: str = Form(..., min_length=64, max_length=64),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Store only the reviewed transaction facts; the raw export is discarded."""
    if not _SHA256.fullmatch(expected_sha256):
        raise HTTPException(status_code=422, detail="expected_sha256 must be a SHA-256 digest")
    await reserve_persistent_attempts(
        db,
        [
            (
                f"tesco-history-import:{current_user['family_id']}",
                settings.document_upload_rate_limit_requests,
                3_600,
            )
        ],
        detail_prefix="Too many Tesco history imports",
    )
    try:
        data, filename = await _read_tesco_history(file)
        parsed = _parse_tesco_history(data, filename=filename)
        if parsed.sha256 != expected_sha256:
            raise HTTPException(
                status_code=409,
                detail="The Tesco file changed after review. Preview it again before importing",
            )
        preview = await _tesco_history_preview(
            db,
            family_id=current_user["family_id"],
            parsed=parsed,
        )
        import_id, imported_orders, skipped_orders = await tesco_history.import_history(
            db,
            family_id=current_user["family_id"],
            user_id=current_user["id"],
            parsed=parsed,
        )
        return TescoHistoryImportResult(
            import_id=import_id,
            imported=imported_orders > 0,
            imported_orders=imported_orders,
            skipped_orders=skipped_orders,
            preview=preview,
        )
    finally:
        await file.close()


@router.get("/items", response_model=list[GroceryItemResponse])
async def list_items(
    category: str | None = Query(None),
    is_use_by_tracked: bool | None = Query(None),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = "SELECT * FROM grocery_items WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]

    if category:
        query += " AND category = ?"
        params.append(category)
    if is_use_by_tracked is not None:
        query += " AND is_use_by_tracked = ?"
        params.append(1 if is_use_by_tracked else 0)

    query += " ORDER BY name ASC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    cur = await db.execute(query, params)
    rows = await cur.fetchall()
    return [_item_response(dict(r)) for r in rows]


@router.post("/items", response_model=GroceryItemResponse, status_code=status.HTTP_201_CREATED)
async def create_item(
    body: GroceryItemCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    item_id = str(uuid.uuid4())
    now = _now_iso()
    await db.execute(
        """
        INSERT INTO grocery_items (
            id, name, category, default_unit, aliases, is_use_by_tracked,
            tesco_hint, default_quantity, family_id,
            created_at, updated_at, created_by, client_id, client_timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            item_id,
            body.name,
            body.category,
            body.default_unit,
            json.dumps(body.aliases) if body.aliases is not None else None,
            int(body.is_use_by_tracked),
            body.tesco_hint,
            body.default_quantity,
            current_user["family_id"],
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )
    await db.commit()

    cur = await db.execute("SELECT * FROM grocery_items WHERE id = ?", (item_id,))
    return _item_response(dict(await cur.fetchone()))


@router.put("/items/{item_id}", response_model=GroceryItemResponse)
async def update_item(
    item_id: str,
    body: GroceryItemUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cur = await db.execute(
        "SELECT * FROM grocery_items WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (item_id, current_user["family_id"]),
    )
    existing = await cur.fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Grocery item not found")

    await save_history(db, "grocery_items", item_id, current_user["id"], family_id=current_user["family_id"])

    updates = body.model_dump(exclude_unset=True)
    if not updates:
        return _item_response(dict(existing))

    if "aliases" in updates:
        updates["aliases"] = json.dumps(updates["aliases"]) if updates["aliases"] is not None else None
    if "is_use_by_tracked" in updates:
        updates["is_use_by_tracked"] = int(updates["is_use_by_tracked"])

    updates["updated_at"] = _now_iso()
    set_clause = ", ".join(f"{k} = ?" for k in updates)
    vals = list(updates.values()) + [item_id, current_user["family_id"]]

    await db.execute(
        f"UPDATE grocery_items SET {set_clause} WHERE id = ? AND family_id = ?",
        vals,
    )
    await db.commit()

    cur = await db.execute("SELECT * FROM grocery_items WHERE id = ?", (item_id,))
    return _item_response(dict(await cur.fetchone()))


@router.delete("/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_item(
    item_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cur = await db.execute(
        "SELECT * FROM grocery_items WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (item_id, current_user["family_id"]),
    )
    existing = await cur.fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Grocery item not found")

    await save_history(db, "grocery_items", item_id, current_user["id"], family_id=current_user["family_id"])

    now = _now_iso()
    await db.execute(
        "UPDATE grocery_items SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, item_id, current_user["family_id"]),
    )
    await db.commit()


@router.post("/import", response_model=TescoImportResponse)
async def import_tesco_text(
    body: TescoImportRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    matches = await parse_tesco_import(db, current_user["family_id"], body.raw_text)
    return TescoImportResponse(batch_id=str(uuid.uuid4()), matches=matches)


@router.post("/batches", response_model=PurchaseBatchResponse, status_code=status.HTTP_201_CREATED)
async def create_batch(
    body: PurchaseBatchCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _require_family_items(
        db,
        current_user["family_id"],
        [line.grocery_item_id for line in body.lines],
    )
    now = _now_iso()
    batch_id = str(uuid.uuid4())

    await db.execute(
        """
        INSERT INTO purchase_batches (
            id, purchased_at, source, notes, family_id,
            created_at, updated_at, created_by, client_id, client_timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            batch_id,
            body.purchased_at,
            body.source,
            body.notes,
            current_user["family_id"],
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )

    for line in body.lines:
        await db.execute(
            """
            INSERT INTO purchases (
                id, purchase_batch_id, grocery_item_id, qty, unit,
                raw_name, price_pence, use_by_date, storage,
                family_id, created_at, updated_at, created_by, client_id, client_timestamp
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                batch_id,
                line.grocery_item_id,
                line.qty,
                line.unit,
                line.raw_name,
                line.price_pence,
                line.use_by_date,
                line.storage,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )

    await db.commit()
    data = await build_purchase_batch_response(db, batch_id, current_user["family_id"])
    return PurchaseBatchResponse(**data)


@router.get("/batches", response_model=list[PurchaseBatchResponse])
async def list_batches(
    start: str | None = Query(None),
    end: str | None = Query(None),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = "SELECT * FROM purchase_batches WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]

    if start:
        query += " AND purchased_at >= ?"
        params.append(start)
    if end:
        query += " AND purchased_at <= ?"
        params.append(end)

    query += " ORDER BY purchased_at DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    cur = await db.execute(query, params)
    batches = [dict(r) for r in await cur.fetchall()]

    full_batches = await build_purchase_batch_responses(
        db,
        batches,
        current_user["family_id"],
    )
    return [PurchaseBatchResponse(**batch) for batch in full_batches]


@router.get("/batches/{batch_id}", response_model=PurchaseBatchResponse)
async def get_batch(
    batch_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    data = await build_purchase_batch_response(db, batch_id, current_user["family_id"])
    if not data:
        raise HTTPException(status_code=404, detail="Batch not found")
    return PurchaseBatchResponse(**data)


@router.post("/consumption", response_model=ConsumptionEventResponse, status_code=status.HTTP_201_CREATED)
async def create_consumption(
    body: ConsumptionEventCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _require_family_items(
        db,
        current_user["family_id"],
        [body.grocery_item_id],
    )
    event_id = str(uuid.uuid4())
    now = _now_iso()

    await db.execute(
        """
        INSERT INTO consumption_events (
            id, grocery_item_id, event_at, amount, unit, event_type, source, notes,
            family_id, created_at, updated_at, created_by, client_id, client_timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            event_id,
            body.grocery_item_id,
            body.event_at or now,
            body.amount,
            body.unit,
            body.event_type,
            body.source,
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

    cur = await db.execute("SELECT * FROM consumption_events WHERE id = ?", (event_id,))
    return ConsumptionEventResponse(**dict(await cur.fetchone()))


@router.get("/stock", response_model=list[StockLevelResponse])
async def list_stock(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    levels = await compute_stock_levels(db, current_user["family_id"])
    return [StockLevelResponse(**x) for x in levels]


@router.get("/critical-low", response_model=list[CriticalLowStockResponse])
async def list_critical_low_stock(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    rows = await get_critical_low_stock_alerts(db, current_user["family_id"])
    return [CriticalLowStockResponse(**x) for x in rows]


@router.get("/expiring", response_model=list[ExpiringItemResponse])
async def list_expiring(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    items = await get_expiring_items(db, current_user["family_id"])
    return [ExpiringItemResponse(**x) for x in items]


@router.get("/suggestions", response_model=ShoppingSuggestionsResponse)
async def get_suggestions(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    suggestions = await generate_replenishment_suggestions(db, current_user["family_id"])
    return ShoppingSuggestionsResponse(
        suggestions=suggestions,
        generated_at=_now_iso(),
    )


@router.post("/suggestions/accept")
async def accept_suggestions(
    body: SuggestionsAcceptRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    suggestions = await generate_replenishment_suggestions(db, current_user["family_id"])
    created = await accept_suggestions_to_shopping_items(
        db,
        current_user["family_id"],
        current_user["id"],
        suggestions,
        body.grocery_item_ids,
    )
    return {"created": len(created), "items": created}


@router.patch("/purchases/{purchase_id}/use-by")
async def patch_purchase_use_by(
    purchase_id: str,
    body: UseByPatchRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cur = await db.execute(
        "SELECT * FROM purchases WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (purchase_id, current_user["family_id"]),
    )
    row = await cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Purchase line not found")

    await save_history(db, "purchases", purchase_id, current_user["id"], family_id=current_user["family_id"])

    now = _now_iso()
    await db.execute(
        "UPDATE purchases SET use_by_date = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (body.use_by_date, now, purchase_id, current_user["family_id"]),
    )
    await db.commit()

    cur = await db.execute(
        """
        SELECT p.*, gi.name AS grocery_item_name
        FROM purchases p
        LEFT JOIN grocery_items gi ON p.grocery_item_id = gi.id
        WHERE p.id = ?
        """,
        (purchase_id,),
    )
    return dict(await cur.fetchone())


@router.get("/freezer", response_model=list[FreezerItemResponse])
async def get_freezer_items(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    rows = await list_freezer_items(db, current_user["family_id"])
    return [FreezerItemResponse(**row) for row in rows]


@router.post("/freezer/add", response_model=FreezerItemResponse, status_code=status.HTTP_201_CREATED)
async def post_freezer_add(
    body: FreezerAddRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if not body.name.strip():
        raise HTTPException(status_code=400, detail="Item name is required")
    if body.qty <= 0:
        raise HTTPException(status_code=400, detail="Quantity must be greater than 0")

    row = await add_freezer_item(
        db,
        current_user["family_id"],
        current_user["id"],
        body.name,
        body.qty,
        body.unit,
    )
    return FreezerItemResponse(**row)

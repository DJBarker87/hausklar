"""Star Charts API endpoints."""

import sqlite3
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.star_chart import (
    BalanceAdjust,
    BalanceResponse,
    ChartCompletedResponse,
    StarChartCreate,
    StarChartResponse,
    StarChartUpdate,
    StarCreate,
    StarResponse,
    TransactionResponse,
)
from app.services.record_history import save_history
from app.services.family_people import family_child_exists

router = APIRouter()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _star_response(row) -> StarResponse:
    return StarResponse(
        id=row["id"],
        chart_id=row["chart_id"],
        row_index=row["row_index"],
        col_index=row["col_index"],
        awarded_at=row["awarded_at"],
        created_at=row["created_at"],
    )


async def _stars_by_chart(db, chart_ids: list[str]) -> dict[str, list[StarResponse]]:
    stars = {chart_id: [] for chart_id in chart_ids}
    if not chart_ids:
        return stars

    placeholders = ", ".join("?" for _ in chart_ids)
    cursor = await db.execute(
        f"""
        SELECT * FROM star_chart_stars
        WHERE chart_id IN ({placeholders}) AND deleted_at IS NULL
        ORDER BY chart_id, awarded_at
        """,
        chart_ids,
    )
    for row in await cursor.fetchall():
        stars[row["chart_id"]].append(_star_response(row))
    return stars


def _chart_response(chart_row, stars: list[StarResponse]) -> StarChartResponse:
    chart = dict(chart_row)
    return StarChartResponse(
        **{key: value for key, value in chart.items() if key in StarChartResponse.model_fields},
        stars=stars,
        stars_count=len(stars),
        total_cells=chart["grid_rows"] * chart["grid_columns"],
    )


async def _build_chart_response(db, chart_row) -> StarChartResponse:
    """Build one chart response, including its stars."""
    chart_id = chart_row["id"]
    stars = await _stars_by_chart(db, [chart_id])
    return _chart_response(chart_row, stars[chart_id])


async def _build_chart_responses(db, chart_rows) -> list[StarChartResponse]:
    """Build a page of chart responses with one batched star query."""
    rows = list(chart_rows)
    stars = await _stars_by_chart(db, [row["id"] for row in rows])
    return [_chart_response(row, stars[row["id"]]) for row in rows]


async def _get_or_create_balance(
    db, child_id: str, created_by: str | None = None, family_id: str | None = None
) -> int:
    """Get current balance for a child, creating a row if none exists. Returns balance_pence."""
    cursor = await db.execute(
        "SELECT balance_pence FROM star_chart_balances WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL",
        (child_id, family_id),
    )
    row = await cursor.fetchone()
    if row:
        return row[0]
    # Create balance row
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "INSERT INTO star_chart_balances (id, child_id, balance_pence, family_id, created_at, updated_at, created_by) VALUES (?, ?, 0, ?, ?, ?, ?)",
        (str(uuid.uuid4()), child_id, family_id, now, now, created_by),
    )
    return 0


def _format_balance(pence: int) -> str:
    """Format pence as £X.XX."""
    return f"\u00a3{pence / 100:.2f}"


# ---------------------------------------------------------------------------
# /balance/{child_id} routes — BEFORE /{chart_id}
# ---------------------------------------------------------------------------


@router.get("/balance/{child_id}", response_model=BalanceResponse)
async def get_balance(
    child_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Get current balance for a child."""
    if not await family_child_exists(db, current_user["family_id"], child_id):
        raise HTTPException(status_code=404, detail="Child not found")
    balance = await _get_or_create_balance(
        db, child_id, current_user["id"], current_user["family_id"]
    )
    await db.commit()
    return BalanceResponse(
        child_id=child_id,
        balance_pence=balance,
        balance_display=_format_balance(balance),
    )


@router.post("/balance/{child_id}/adjust", response_model=BalanceResponse)
async def adjust_balance(
    child_id: str,
    body: BalanceAdjust,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Manually adjust a child's balance."""
    if not await family_child_exists(db, current_user["family_id"], child_id):
        raise HTTPException(status_code=404, detail="Child not found")
    if body.reason not in ("manual_adjustment", "payout"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Reason must be manual_adjustment or payout",
        )

    await db.execute("BEGIN IMMEDIATE")
    await _get_or_create_balance(
        db, child_id, current_user["id"], current_user["family_id"]
    )
    now = datetime.now(timezone.utc).isoformat()

    # Idempotency: a retried adjustment (same client_id) must not credit twice.
    if body.client_id:
        cursor = await db.execute(
            "SELECT 1 FROM star_chart_balance_transactions "
            "WHERE family_id = ? AND child_id = ? AND client_id = ? AND deleted_at IS NULL",
            (current_user["family_id"], child_id, body.client_id),
        )
        if await cursor.fetchone():
            cursor = await db.execute(
                "SELECT balance_pence FROM star_chart_balances "
                "WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL",
                (child_id, current_user["family_id"]),
            )
            existing_balance = (await cursor.fetchone())[0]
            await db.rollback()
            return BalanceResponse(
                child_id=child_id,
                balance_pence=existing_balance,
                balance_display=_format_balance(existing_balance),
            )

    cursor = await db.execute(
        "UPDATE star_chart_balances "
        "SET balance_pence = balance_pence + ?, updated_at = ? "
        "WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL "
        "RETURNING balance_pence",
        (body.amount_pence, now, child_id, current_user["family_id"]),
    )
    new_balance = (await cursor.fetchone())[0]

    # Create transaction
    await db.execute(
        """
        INSERT INTO star_chart_balance_transactions
            (id, child_id, amount_pence, reason, notes, family_id, created_at, updated_at, created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            child_id,
            body.amount_pence,
            body.reason,
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

    return BalanceResponse(
        child_id=child_id,
        balance_pence=new_balance,
        balance_display=_format_balance(new_balance),
    )


@router.get("/balance/{child_id}/transactions", response_model=list[TransactionResponse])
async def list_transactions(
    child_id: str,
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List balance transactions for a child."""
    cursor = await db.execute(
        """
        SELECT * FROM star_chart_balance_transactions
        WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL
        ORDER BY created_at DESC LIMIT ? OFFSET ?
        """,
        (child_id, current_user["family_id"], limit, offset),
    )
    rows = await cursor.fetchall()
    return [TransactionResponse(**dict(row)) for row in rows]


# ---------------------------------------------------------------------------
# Chart CRUD — /{chart_id} routes
# ---------------------------------------------------------------------------


@router.get("/", response_model=list[StarChartResponse])
async def list_charts(
    child_id: str | None = Query(None),
    active: bool | None = Query(None),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List star charts with optional filters."""
    conditions = ["deleted_at IS NULL"]
    params: list = []

    conditions.append("family_id = ?")
    params.append(current_user["family_id"])

    if child_id:
        conditions.append("child_id = ?")
        params.append(child_id)

    if active is True:
        conditions.append("completed_at IS NULL")
    elif active is False:
        conditions.append("completed_at IS NOT NULL")

    where = " AND ".join(conditions)
    params.extend([limit, offset])

    cursor = await db.execute(
        f"SELECT * FROM star_charts WHERE {where} ORDER BY created_at DESC LIMIT ? OFFSET ?",
        params,
    )
    rows = await cursor.fetchall()
    return await _build_chart_responses(db, rows)


@router.post("/", response_model=StarChartResponse, status_code=status.HTTP_201_CREATED)
async def create_chart(
    body: StarChartCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a new star chart."""
    if not await family_child_exists(db, current_user["family_id"], body.child_id):
        raise HTTPException(status_code=400, detail="Child is not in this family")
    if body.grid_rows < 1 or body.grid_rows > 20:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="grid_rows must be 1-20"
        )
    if body.grid_columns < 1 or body.grid_columns > 20:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="grid_columns must be 1-20"
        )
    if body.reward_amount_pence < 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="reward_amount_pence must be >= 0"
        )

    chart_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    await db.execute(
        """
        INSERT INTO star_charts (id, child_id, title, grid_rows, grid_columns, reward_amount_pence,
            family_id, created_at, updated_at, created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            chart_id,
            body.child_id,
            body.title,
            body.grid_rows,
            body.grid_columns,
            body.reward_amount_pence,
            current_user["family_id"],
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM star_charts WHERE id = ?", (chart_id,))
    row = await cursor.fetchone()
    return await _build_chart_response(db, row)


@router.get("/{chart_id}", response_model=StarChartResponse)
async def get_chart(
    chart_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Get a single star chart with all stars."""
    cursor = await db.execute(
        "SELECT * FROM star_charts WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (chart_id, current_user["family_id"]),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Star chart not found")
    return await _build_chart_response(db, row)


@router.put("/{chart_id}", response_model=StarChartResponse)
async def update_chart(
    chart_id: str,
    body: StarChartUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update chart settings (only if not completed)."""
    cursor = await db.execute(
        "SELECT * FROM star_charts WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (chart_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Star chart not found")
    if existing["completed_at"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Cannot update a completed chart"
        )

    await save_history(
        db,
        "star_charts",
        chart_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="No fields to update")

    # Validate
    if "grid_rows" in updates and (updates["grid_rows"] < 1 or updates["grid_rows"] > 20):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="grid_rows must be 1-20"
        )
    if "grid_columns" in updates and (updates["grid_columns"] < 1 or updates["grid_columns"] > 20):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="grid_columns must be 1-20"
        )

    now = datetime.now(timezone.utc).isoformat()
    updates["updated_at"] = now

    set_clause = ", ".join(f"{key} = ?" for key in updates)
    values = list(updates.values()) + [chart_id, current_user["family_id"]]
    await db.execute(f"UPDATE star_charts SET {set_clause} WHERE id = ? AND family_id = ?", values)
    await db.commit()

    cursor = await db.execute("SELECT * FROM star_charts WHERE id = ?", (chart_id,))
    row = await cursor.fetchone()
    return await _build_chart_response(db, row)


@router.delete("/{chart_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_chart(
    chart_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a star chart."""
    cursor = await db.execute(
        "SELECT * FROM star_charts WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (chart_id, current_user["family_id"]),
    )
    if not await cursor.fetchone():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Star chart not found")

    await save_history(
        db,
        "star_charts",
        chart_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE star_charts SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, chart_id, current_user["family_id"]),
    )
    await db.commit()


# ---------------------------------------------------------------------------
# Stars
# ---------------------------------------------------------------------------


@router.post("/{chart_id}/stars", status_code=status.HTTP_201_CREATED)
async def place_star(
    chart_id: str,
    body: StarCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Place a star on a chart. If it's the final star, completes the chart and credits balance."""
    await db.execute("BEGIN IMMEDIATE")
    cursor = await db.execute(
        "SELECT * FROM star_charts WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (chart_id, current_user["family_id"]),
    )
    chart = await cursor.fetchone()
    if not chart:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Star chart not found")
    if chart["completed_at"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Chart is already completed"
        )

    # Validate bounds
    if body.row_index < 0 or body.row_index >= chart["grid_rows"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="row_index out of bounds"
        )
    if body.col_index < 0 or body.col_index >= chart["grid_columns"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="col_index out of bounds"
        )

    # Check cell not already filled
    cursor = await db.execute(
        "SELECT 1 FROM star_chart_stars WHERE chart_id = ? AND row_index = ? AND col_index = ? AND deleted_at IS NULL",
        (chart_id, body.row_index, body.col_index),
    )
    if await cursor.fetchone():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Cell already has a star")

    star_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    try:
        await db.execute(
            """
            INSERT INTO star_chart_stars (id, chart_id, row_index, col_index, awarded_at,
                family_id, created_at, updated_at, created_by, client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                star_id,
                chart_id,
                body.row_index,
                body.col_index,
                now,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )
    except sqlite3.IntegrityError as exc:
        await db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Cell already has a star",
        ) from exc

    # Check if chart is now complete
    cursor = await db.execute(
        "SELECT COUNT(*) FROM star_chart_stars WHERE chart_id = ? AND deleted_at IS NULL",
        (chart_id,),
    )
    count = (await cursor.fetchone())[0]
    total_cells = chart["grid_rows"] * chart["grid_columns"]

    if count >= total_cells:
        completion = await db.execute(
            "UPDATE star_charts SET completed_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ? AND completed_at IS NULL",
            (now, now, chart_id, current_user["family_id"]),
        )
        if completion.rowcount != 1:
            await db.rollback()
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Chart was completed by another request",
            )

        # Credit the reward only after this request atomically claims completion.
        child_id = chart["child_id"]
        reward = chart["reward_amount_pence"]
        await _get_or_create_balance(
            db, child_id, current_user["id"], current_user["family_id"]
        )
        await db.execute(
            "UPDATE star_chart_balances "
            "SET balance_pence = balance_pence + ?, updated_at = ? "
            "WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL",
            (reward, now, child_id, current_user["family_id"]),
        )

        # Create transaction
        await db.execute(
            """
            INSERT INTO star_chart_balance_transactions
                (id, child_id, amount_pence, reason, chart_id, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, 'chart_completed', ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                child_id,
                reward,
                chart_id,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
            ),
        )

        await db.commit()

        cursor = await db.execute(
            "SELECT balance_pence FROM star_chart_balances "
            "WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL",
            (child_id, current_user["family_id"]),
        )
        new_balance = (await cursor.fetchone())[0]

        cursor = await db.execute("SELECT * FROM star_charts WHERE id = ?", (chart_id,))
        chart_row = await cursor.fetchone()
        chart_resp = await _build_chart_response(db, chart_row)

        return ChartCompletedResponse(
            chart=chart_resp,
            reward_amount_pence=reward,
            new_balance_pence=new_balance,
            new_balance_display=_format_balance(new_balance),
        )

    await db.commit()

    cursor = await db.execute("SELECT * FROM star_chart_stars WHERE id = ?", (star_id,))
    star_row = await cursor.fetchone()
    return StarResponse(
        id=star_row["id"],
        chart_id=star_row["chart_id"],
        row_index=star_row["row_index"],
        col_index=star_row["col_index"],
        awarded_at=star_row["awarded_at"],
        created_at=star_row["created_at"],
    )


@router.delete("/{chart_id}/stars/{star_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_star(
    chart_id: str,
    star_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Remove a star. If chart was completed, un-complete it."""
    await db.execute("BEGIN IMMEDIATE")
    cursor = await db.execute(
        "SELECT * FROM star_chart_stars WHERE id = ? AND chart_id = ? AND family_id = ? AND deleted_at IS NULL",
        (star_id, chart_id, current_user["family_id"]),
    )
    star = await cursor.fetchone()
    if not star:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Star not found")

    now = datetime.now(timezone.utc).isoformat()

    # Soft-delete the star
    await db.execute(
        "UPDATE star_chart_stars SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, star_id, current_user["family_id"]),
    )

    # Check if chart was completed — if so, un-complete it
    cursor = await db.execute(
        "SELECT completed_at, child_id FROM star_charts "
        "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (chart_id, current_user["family_id"]),
    )
    chart = await cursor.fetchone()
    if chart and chart["completed_at"]:
        completion = await db.execute(
            "UPDATE star_charts SET completed_at = NULL, updated_at = ? "
            "WHERE id = ? AND family_id = ? AND completed_at IS NOT NULL",
            (now, chart_id, current_user["family_id"]),
        )
        if completion.rowcount == 1:
            cursor = await db.execute(
                "SELECT COALESCE(SUM(amount_pence), 0) "
                "FROM star_chart_balance_transactions "
                "WHERE chart_id = ? AND deleted_at IS NULL",
                (chart_id,),
            )
            reversal = (await cursor.fetchone())[0]
            if reversal:
                # A chart may be completed again after an accidental star is removed.
                # Keep the earlier credit in the visible ledger while freeing the
                # one-active-completion guard for the next completion.
                await db.execute(
                    "UPDATE star_chart_balance_transactions "
                    "SET reason = 'manual_adjustment', "
                    "notes = COALESCE(notes, 'Chart completed'), updated_at = ? "
                    "WHERE chart_id = ? AND reason = 'chart_completed' "
                    "AND deleted_at IS NULL",
                    (now, chart_id),
                )
                await db.execute(
                    "UPDATE star_chart_balances "
                    "SET balance_pence = balance_pence - ?, updated_at = ? "
                    "WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL",
                    (reversal, now, chart["child_id"], current_user["family_id"]),
                )
                await db.execute(
                    """
                    INSERT INTO star_chart_balance_transactions
                        (id, child_id, amount_pence, reason, chart_id, notes,
                         family_id, created_at, updated_at, created_by)
                    VALUES (?, ?, ?, 'manual_adjustment', ?, 'Star removed', ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        chart["child_id"],
                        -reversal,
                        chart_id,
                        current_user["family_id"],
                        now,
                        now,
                        current_user["id"],
                    ),
                )

    await db.commit()

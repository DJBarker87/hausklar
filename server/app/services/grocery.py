import json
import re
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

from app.services.callmebot import send_briefing_to_all

CRITICAL_LOW_ITEM_RULES: dict[str, dict[str, float | str]] = {
    "yoghurt": {"threshold": 2.0, "reason": "Breakfast staple running low"},
    "chicken": {"threshold": 1.0, "reason": "Core dinner protein running low"},
    "beef": {"threshold": 1.0, "reason": "Core dinner protein running low"},
    "eggs": {"threshold": 6.0, "reason": "Breakfast and baking staple running low"},
    "diet coke": {"threshold": 4.0, "reason": "Household drinks stock running low"},
}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _today() -> date:
    return datetime.now(timezone.utc).date()


def _normalize_text(value: str) -> str:
    value = value.lower().strip()
    value = re.sub(r"\b\d+(?:\.\d+)?\s?(?:x|kg|g|ml|l|litre|litres|pack|packs|pk|tbsp|tsp)\b", " ", value)
    value = re.sub(r"[^a-z0-9\s]", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value


def _tokens(value: str) -> set[str]:
    return {t for t in _normalize_text(value).split(" ") if t}


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


async def parse_tesco_import(db, family_id: str, raw_text: str) -> list[dict]:
    cursor = await db.execute(
        "SELECT * FROM grocery_items WHERE deleted_at IS NULL AND family_id = ?",
        (family_id,),
    )
    items = [dict(r) for r in await cursor.fetchall()]

    prepared = []
    for item in items:
        aliases = json.loads(item["aliases"]) if item.get("aliases") else []
        names = [item["name"], *aliases]
        prepared.append(
            {
                "id": item["id"],
                "name": item["name"],
                "candidates": {_normalize_text(n) for n in names if n},
                "tokens": [_tokens(n) for n in names if n],
            }
        )

    lines = [ln.strip() for ln in raw_text.splitlines() if ln.strip()]
    matches: list[dict] = []

    for line in lines:
        nline = _normalize_text(line)
        best: dict | None = None

        # Exact canonical/alias match first.
        for item in prepared:
            if nline in item["candidates"]:
                best = {
                    "raw_line": line,
                    "matched_item_id": item["id"],
                    "matched_item_name": item["name"],
                    "confidence": "high",
                    "needs_review": False,
                }
                break

        if best is None:
            line_tokens = _tokens(line)
            best_score = 0.0
            best_item = None
            for item in prepared:
                score = max((_jaccard(line_tokens, tks) for tks in item["tokens"]), default=0.0)
                if score > best_score:
                    best_score = score
                    best_item = item

            if best_item is None or best_score < 0.3:
                best = {
                    "raw_line": line,
                    "matched_item_id": None,
                    "matched_item_name": None,
                    "confidence": "low",
                    "needs_review": True,
                }
            else:
                conf = "medium" if best_score >= 0.6 else "low"
                best = {
                    "raw_line": line,
                    "matched_item_id": best_item["id"],
                    "matched_item_name": best_item["name"],
                    "confidence": conf,
                    "needs_review": conf == "low",
                }

        matches.append(best)

    return matches


async def build_purchase_batch_response(db, batch_id: str, family_id: str) -> dict | None:
    cur = await db.execute(
        "SELECT * FROM purchase_batches WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (batch_id, family_id),
    )
    batch = await cur.fetchone()
    if not batch:
        return None

    return (await build_purchase_batch_responses(db, [dict(batch)], family_id))[0]


async def build_purchase_batch_responses(
    db,
    batches: list[dict],
    family_id: str,
) -> list[dict]:
    """Attach purchase lines to an already-fetched batch page in one query."""
    if not batches:
        return []
    batch_ids = [batch["id"] for batch in batches]
    placeholders = ",".join("?" for _ in batch_ids)
    cur = await db.execute(
        """
        SELECT p.*, gi.name AS grocery_item_name
        FROM purchases p
        LEFT JOIN grocery_items gi
          ON p.grocery_item_id = gi.id AND gi.family_id = p.family_id
        WHERE p.family_id = ? AND p.deleted_at IS NULL
          AND p.purchase_batch_id IN ("""
        + placeholders
        + ") ORDER BY p.purchase_batch_id, p.created_at ASC",
        (family_id, *batch_ids),
    )
    lines_by_batch: dict[str, list[dict]] = {batch_id: [] for batch_id in batch_ids}
    for row in await cur.fetchall():
        line = dict(row)
        lines_by_batch[line["purchase_batch_id"]].append(line)

    return [
        {**batch, "lines": lines_by_batch[batch["id"]]}
        for batch in batches
    ]


async def compute_fifo_remaining_for_item(db, family_id: str, grocery_item_id: str) -> list[dict]:
    cur = await db.execute(
        """
        SELECT p.*
        FROM purchases p
        WHERE p.deleted_at IS NULL AND p.family_id = ? AND p.grocery_item_id = ?
        ORDER BY CASE WHEN p.use_by_date IS NULL THEN 1 ELSE 0 END, p.use_by_date ASC, p.created_at ASC
        """,
        (family_id, grocery_item_id),
    )
    lines = [dict(r) for r in await cur.fetchall()]

    cur = await db.execute(
        """
        SELECT *
        FROM consumption_events
        WHERE deleted_at IS NULL
          AND family_id = ?
          AND grocery_item_id = ?
          AND event_type IN ('consumed', 'wasted', 'spilled')
        ORDER BY event_at ASC, created_at ASC
        """,
        (family_id, grocery_item_id),
    )
    events = [dict(r) for r in await cur.fetchall()]

    remaining_lines = [
        {
            "purchase_id": ln["id"],
            "use_by_date": ln["use_by_date"],
            "remaining": float(ln["qty"]),
            "unit": ln["unit"],
        }
        for ln in lines
    ]

    for evt in events:
        need = float(evt["amount"])
        for line in remaining_lines:
            if need <= 0:
                break
            if line["remaining"] <= 0:
                continue
            take = min(line["remaining"], need)
            line["remaining"] -= take
            need -= take

    return [ln for ln in remaining_lines if ln["remaining"] > 0]


async def compute_stock_levels(db, family_id: str) -> list[dict]:
    cur = await db.execute(
        """
        SELECT gi.*,
               COALESCE((SELECT SUM(qty) FROM purchases p WHERE p.grocery_item_id = gi.id AND p.deleted_at IS NULL AND p.family_id = gi.family_id), 0) AS total_purchased,
               COALESCE((SELECT SUM(amount) FROM consumption_events ce WHERE ce.grocery_item_id = gi.id AND ce.event_type = 'consumed' AND ce.deleted_at IS NULL AND ce.family_id = gi.family_id), 0) AS total_consumed,
               COALESCE((SELECT SUM(amount) FROM consumption_events ce WHERE ce.grocery_item_id = gi.id AND ce.event_type IN ('wasted', 'spilled') AND ce.deleted_at IS NULL AND ce.family_id = gi.family_id), 0) AS total_wasted
        FROM grocery_items gi
        WHERE gi.deleted_at IS NULL AND gi.family_id = ?
        ORDER BY gi.name
        """,
        (family_id,),
    )
    items = [dict(r) for r in await cur.fetchall()]

    out: list[dict] = []
    today = _today()

    for item in items:
        total_purchased = float(item["total_purchased"] or 0)
        total_consumed = float(item["total_consumed"] or 0)
        total_wasted = float(item["total_wasted"] or 0)
        remaining = total_purchased - total_consumed - total_wasted
        if remaining <= 0:
            continue

        earliest_use_by = None
        days_until_expiry = None
        if item.get("is_use_by_tracked"):
            fifo = await compute_fifo_remaining_for_item(db, family_id, item["id"])
            dated = [x for x in fifo if x.get("use_by_date")]
            if dated:
                earliest_use_by = min(x["use_by_date"] for x in dated)
                days_until_expiry = (date.fromisoformat(earliest_use_by) - today).days

        out.append(
            {
                "grocery_item_id": item["id"],
                "item_name": item["name"],
                "category": item.get("category"),
                "total_purchased": total_purchased,
                "total_consumed": total_consumed,
                "total_wasted": total_wasted,
                "remaining": remaining,
                "unit": item.get("default_unit") or "each",
                "earliest_use_by": earliest_use_by,
                "days_until_expiry": days_until_expiry,
            }
        )

    return out


async def get_critical_low_stock_alerts(db, family_id: str) -> list[dict]:
    cur = await db.execute(
        """
        SELECT gi.id, gi.name, COALESCE(gi.default_unit, 'each') AS unit,
               COALESCE((SELECT SUM(qty) FROM purchases p WHERE p.grocery_item_id = gi.id AND p.deleted_at IS NULL AND p.family_id = gi.family_id), 0) AS total_purchased,
               COALESCE((SELECT SUM(amount) FROM consumption_events ce WHERE ce.grocery_item_id = gi.id AND ce.event_type IN ('consumed', 'wasted', 'spilled') AND ce.deleted_at IS NULL AND ce.family_id = gi.family_id), 0) AS total_used
        FROM grocery_items gi
        WHERE gi.deleted_at IS NULL AND gi.family_id = ?
        ORDER BY gi.name
        """,
        (family_id,),
    )
    rows = [dict(r) for r in await cur.fetchall()]

    out: list[dict] = []
    for row in rows:
        name = (row.get("name") or "").lower()
        for key, rule in CRITICAL_LOW_ITEM_RULES.items():
            if key not in name:
                continue
            remaining = float(row.get("total_purchased") or 0) - float(row.get("total_used") or 0)
            threshold = float(rule["threshold"])
            if remaining <= threshold:
                out.append(
                    {
                        "grocery_item_id": row["id"],
                        "item_name": row["name"],
                        "remaining": round(max(0.0, remaining), 3),
                        "unit": row.get("unit") or "each",
                        "threshold": threshold,
                        "reason": str(rule["reason"]),
                    }
                )
            break

    out.sort(key=lambda x: (x["remaining"], x["item_name"]))
    return out


async def get_expiring_items(db, family_id: str) -> list[dict]:
    cur = await db.execute(
        """
        SELECT * FROM grocery_items
        WHERE deleted_at IS NULL AND family_id = ? AND is_use_by_tracked = 1
        ORDER BY name
        """,
        (family_id,),
    )
    tracked = [dict(r) for r in await cur.fetchall()]

    today = _today()
    out: list[dict] = []

    for item in tracked:
        fifo_remaining = await compute_fifo_remaining_for_item(db, family_id, item["id"])
        buckets = defaultdict(float)
        unit = item.get("default_unit") or "each"
        for line in fifo_remaining:
            if line.get("use_by_date"):
                buckets[line["use_by_date"]] += float(line["remaining"])
                unit = line.get("unit") or unit

        for use_by_date, qty in buckets.items():
            days_left = (date.fromisoformat(use_by_date) - today).days
            if days_left > 3:
                continue

            if days_left <= 0:
                alert_level = "expired"
            elif days_left == 1:
                alert_level = "critical"
            else:
                alert_level = "nudge"

            out.append(
                {
                    "grocery_item_id": item["id"],
                    "item_name": item["name"],
                    "use_by_date": use_by_date,
                    "remaining_qty": round(qty, 3),
                    "unit": unit,
                    "days_left": days_left,
                    "alert_level": alert_level,
                }
            )

    out.sort(key=lambda x: (x["days_left"], x["item_name"]))
    return out


async def check_expiring_items(db, family_id: str) -> None:
    """Send expiry alerts only for the household tied to notification credentials."""
    expiring = await get_expiring_items(db, family_id)
    if not expiring:
        return

    lines = ["Food expiry check:"]
    for item in expiring[:10]:
        lines.append(
            f"- {item['item_name']} {item['remaining_qty']} {item['unit']} by {item['use_by_date']} ({item['alert_level']})"
        )
    await send_briefing_to_all("\n".join(lines))


async def generate_replenishment_suggestions(db, family_id: str) -> list[dict]:
    cur = await db.execute(
        "SELECT * FROM grocery_items WHERE deleted_at IS NULL AND family_id = ? ORDER BY name",
        (family_id,),
    )
    items = [dict(r) for r in await cur.fetchall()]

    stock_levels = {
        row["grocery_item_id"]: row
        for row in await compute_stock_levels(db, family_id)
    }

    now = datetime.now(timezone.utc)
    since_8w = (now - timedelta(days=56)).isoformat()

    suggestions: list[dict] = []

    for item in items:
        cur = await db.execute(
            """
            SELECT event_type, COALESCE(SUM(amount), 0) AS total
            FROM consumption_events
            WHERE grocery_item_id = ?
              AND family_id = ?
              AND deleted_at IS NULL
              AND event_at >= ?
            GROUP BY event_type
            """,
            (item["id"], family_id, since_8w),
        )
        totals = {row["event_type"]: float(row["total"] or 0) for row in await cur.fetchall()}

        consumed = totals.get("consumed", 0.0)
        wasted = totals.get("wasted", 0.0) + totals.get("spilled", 0.0)
        weekly_rate = (consumed + wasted) / 8.0
        daily_rate = weekly_rate / 7.0

        remaining = stock_levels.get(item["id"], {}).get("remaining", 0.0)
        if daily_rate <= 0:
            # Keep optional suggestions only for recently purchased items.
            cur = await db.execute(
                """
                SELECT 1
                FROM purchases p
                JOIN purchase_batches pb ON pb.id = p.purchase_batch_id
                WHERE p.grocery_item_id = ?
                  AND p.family_id = ?
                  AND p.deleted_at IS NULL
                  AND pb.deleted_at IS NULL
                ORDER BY COALESCE(pb.purchased_at, p.created_at) DESC
                LIMIT 1
                """,
                (item["id"], family_id),
            )
            has_purchase = await cur.fetchone()
            if not has_purchase:
                continue
            confidence = "optional"
            suggested_qty = float(item.get("default_quantity") or 1.0)
            reason = "No recent usage trend yet"
        else:
            days_to_stockout = remaining / daily_rate if remaining > 0 else 0
            if days_to_stockout < 7:
                confidence = "must_buy"
                reason = "Stock likely to run out before next weekly shop"
            elif days_to_stockout < 10:
                confidence = "likely_low"
                reason = "Stock likely to run low within 10 days"
            else:
                confidence = "optional"
                reason = "Stock looks stable"

            suggested_qty = max(float(item.get("default_quantity") or 1.0), weekly_rate)

            # Waste-based down-adjustment.
            if consumed + wasted > 0 and (wasted / (consumed + wasted)) > 0.2:
                suggested_qty = max(0.5, suggested_qty * 0.8)
                reason += "; reduced due to recent waste"

        if confidence == "optional" and suggested_qty <= 0:
            continue

        suggestions.append(
            {
                "grocery_item_id": item["id"],
                "item_name": item["name"],
                "suggested_qty": round(suggested_qty, 2),
                "unit": item.get("default_unit") or "each",
                "confidence": confidence,
                "reason": reason,
            }
        )

    rank = {"must_buy": 0, "likely_low": 1, "optional": 2}
    suggestions.sort(key=lambda x: (rank.get(x["confidence"], 3), x["item_name"]))
    return suggestions


async def accept_suggestions_to_shopping_items(
    db,
    family_id: str,
    user_id: str,
    suggestions: list[dict],
    grocery_item_ids: list[str] | None,
) -> list[dict]:
    now = _now_iso()
    selected = (
        [s for s in suggestions if s["grocery_item_id"] in set(grocery_item_ids)]
        if grocery_item_ids
        else suggestions
    )

    created: list[dict] = []
    for s in selected:
        item_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO shopping_items (
                id, name, quantity, category, checked, family_id,
                created_at, updated_at, created_by
            ) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)
            """,
            (
                item_id,
                s["item_name"],
                f"{s['suggested_qty']} {s['unit']}",
                "replenishment",
                family_id,
                now,
                now,
                user_id,
            ),
        )
        cur = await db.execute("SELECT * FROM shopping_items WHERE id = ?", (item_id,))
        created.append(dict(await cur.fetchone()))

    await db.commit()
    return created


async def list_freezer_items(db, family_id: str) -> list[dict]:
    cur = await db.execute(
        """
        SELECT
            p.grocery_item_id,
            gi.name AS item_name,
            SUM(p.qty) AS qty,
            COALESCE(MAX(p.unit), gi.default_unit, 'each') AS unit
        FROM purchases p
        JOIN grocery_items gi ON gi.id = p.grocery_item_id
        WHERE p.deleted_at IS NULL
          AND gi.deleted_at IS NULL
          AND p.family_id = ?
          AND gi.family_id = ?
          AND p.storage = 'freezer'
        GROUP BY p.grocery_item_id, gi.name
        HAVING SUM(p.qty) > 0
        ORDER BY gi.name ASC
        """,
        (family_id, family_id),
    )
    return [dict(r) for r in await cur.fetchall()]


async def add_freezer_item(
    db,
    family_id: str,
    user_id: str,
    name: str,
    qty: float,
    unit: str = "each",
) -> dict:
    now = _now_iso()
    normalized = name.strip().lower()

    cur = await db.execute(
        """
        SELECT * FROM grocery_items
        WHERE family_id = ? AND deleted_at IS NULL AND lower(name) = ?
        LIMIT 1
        """,
        (family_id, normalized),
    )
    existing_item = await cur.fetchone()

    if existing_item:
        grocery_item_id = existing_item["id"]
        item_name = existing_item["name"]
    else:
        grocery_item_id = str(uuid.uuid4())
        item_name = name.strip()
        await db.execute(
            """
            INSERT INTO grocery_items (
                id, name, category, default_unit, is_use_by_tracked, default_quantity,
                family_id, created_at, updated_at, created_by
            ) VALUES (?, ?, 'frozen', ?, 0, 1.0, ?, ?, ?, ?)
            """,
            (grocery_item_id, item_name, unit, family_id, now, now, user_id),
        )

    batch_id = str(uuid.uuid4())
    purchase_id = str(uuid.uuid4())
    await db.execute(
        """
        INSERT INTO purchase_batches (
            id, purchased_at, source, notes, family_id, created_at, updated_at, created_by
        ) VALUES (?, ?, 'other', 'Manual freezer add', ?, ?, ?, ?)
        """,
        (batch_id, now, family_id, now, now, user_id),
    )
    await db.execute(
        """
        INSERT INTO purchases (
            id, purchase_batch_id, grocery_item_id, qty, unit, storage,
            family_id, created_at, updated_at, created_by
        ) VALUES (?, ?, ?, ?, ?, 'freezer', ?, ?, ?, ?)
        """,
        (purchase_id, batch_id, grocery_item_id, qty, unit, family_id, now, now, user_id),
    )
    await db.commit()

    return {
        "grocery_item_id": grocery_item_id,
        "item_name": item_name,
        "qty": qty,
        "unit": unit,
    }

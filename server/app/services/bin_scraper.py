"""Bin collection scraper service.

Fetches upcoming bin collection dates from the Local authority council website,
parses the HTML table, and creates tasks in the tasks table.
"""

import html
import logging
import re
import uuid
from datetime import date as date_type, datetime, time as time_type, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from app.config import settings
from app.database import database_lease
from app.services.record_history import save_history

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_CREATED_BY = "bin-scraper"
_HTTP_TIMEOUT = 30.0

# Map service name keywords to short colour keys used in task descriptions.
# The iOS app reads these to render coloured dots.
_BIN_TYPE_MAP: dict[str, str] = {
    "refuse": "black",
    "recycling": "blue",
    "garden": "green",
}
_VALID_BIN_TYPES = frozenset(_BIN_TYPE_MAP.values())

# ---------------------------------------------------------------------------
# Month helpers (shared with term_scraper pattern)
# ---------------------------------------------------------------------------

_MONTH_MAP: dict[str, int] = {
    "january": 1,
    "february": 2,
    "march": 3,
    "april": 4,
    "may": 5,
    "june": 6,
    "july": 7,
    "august": 8,
    "september": 9,
    "october": 10,
    "november": 11,
    "december": 12,
}


def _parse_collection_date(date_str: str) -> str:
    """Parse a date like '12th February 2026' to ISO format '2026-02-12'.

    Handles ordinal suffixes: st, nd, rd, th.
    """
    # Strip ordinal suffix from day number
    cleaned = re.sub(r"(\d+)(st|nd|rd|th)", r"\1", date_str.strip())
    parts = cleaned.split()
    if len(parts) != 3:
        raise ValueError(f"Unexpected date format: {date_str!r}")

    day = int(parts[0])
    month_str = parts[1].lower()
    year = int(parts[2])
    if not 2000 <= year <= 2100:
        raise ValueError(f"Implausible collection year: {year}")

    month = _MONTH_MAP.get(month_str)
    if month is None:
        raise ValueError(f"Unknown month: {month_str!r}")

    # Constructing a date rejects impossible council/source values such as
    # 31 February rather than letting malformed tasks enter the database.
    return date_type(year, month, day).isoformat()


def _classify_bin_type(service_name: str) -> str | None:
    """Map a service name to a bin type, or None if unrecognised."""
    lower = service_name.lower()
    for keyword, bin_type in _BIN_TYPE_MAP.items():
        if keyword in lower:
            return bin_type
    return None


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------


async def fetch_bin_page() -> str:
    """Fetch the Local authority bin collection page.

    Returns:
        The page HTML, or an empty string on failure.
    """
    uprn = settings.bin_collection_uprn.strip()
    if not re.fullmatch(r"\d{6,20}", uprn):
        logger.warning("Bin collection lookup is not configured")
        return ""
    try:
        async with httpx.AsyncClient(
            timeout=_HTTP_TIMEOUT,
            follow_redirects=True,
            headers={"User-Agent": "HausKlar-BinScraper/1.0"},
        ) as client:
            resp = await client.get(
                "https://bins.example.invalid/bincollections",
                params={"uprn": uprn},
            )
            resp.raise_for_status()
            return resp.text
    except httpx.HTTPError:
        logger.warning("Failed to fetch bin collection page")
        return ""
    except Exception:
        logger.error("Unexpected error fetching bin collection page")
        return ""


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

# Match table rows: <td>...service...</td> and <td>...date...</td>
_ROW_PATTERN = re.compile(
    r"<tr[^>]*>\s*<td[^>]*>(.*?)</td>\s*<td[^>]*>(.*?)</td>",
    re.IGNORECASE | re.DOTALL,
)


def _normalise_cell(value: str) -> str:
    """Strip nested markup/entities and collapse council-page whitespace."""
    return " ".join(html.unescape(re.sub(r"<[^>]+>", "", value)).split())


def parse_collections(html: str) -> list[dict]:
    """Parse the bin collection HTML table.

    Args:
        html: Raw HTML from the Local authority bin collection page.

    Returns:
        List of dicts with keys: bin_type, collection_date (ISO format).
    """
    results: list[dict] = []

    for match in _ROW_PATTERN.finditer(html):
        service_raw = _normalise_cell(match.group(1))
        date_raw = _normalise_cell(match.group(2))

        bin_type = _classify_bin_type(service_raw)
        if bin_type is None:
            continue

        try:
            collection_date = _parse_collection_date(date_raw)
        except ValueError as exc:
            logger.warning("Skipping row, bad date %r: %s", date_raw, exc)
            continue

        results.append(
            {
                "bin_type": bin_type,
                "collection_date": collection_date,
            }
        )

    return results


# ---------------------------------------------------------------------------
# Database: refresh tasks
# ---------------------------------------------------------------------------


def _actionable_from(collection_date: str) -> str | None:
    """Return 18:00 Europe/London on the evening before, expressed in UTC."""
    try:
        collection_day = date_type.fromisoformat(collection_date)
    except ValueError:
        return None
    local_evening = datetime.combine(
        collection_day - timedelta(days=1),
        time_type(hour=18),
        tzinfo=ZoneInfo("Europe/London"),
    )
    return local_evening.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _merged_bin_types(existing_description: str | None, parsed_types: list[str]) -> list[str]:
    """Preserve known same-day services when one council row parses partially."""
    merged: list[str] = []
    for value in (existing_description or "").split(","):
        bin_type = value.strip()
        if bin_type in _VALID_BIN_TYPES and bin_type not in merged:
            merged.append(bin_type)
    for bin_type in parsed_types:
        if bin_type in _VALID_BIN_TYPES and bin_type not in merged:
            merged.append(bin_type)
    return merged


async def _replace_bin_tasks(
    db: Any,
    collections: list[dict],
    *,
    family_id: str | None,
) -> dict:
    """Reconcile scraper-owned tasks in one short write transaction.

    Local authority currently publishes only a short rolling horizon. Existing task IDs,
    completion state, and assignments therefore need to survive a successful
    refresh; blindly replacing every row makes completed bins reappear and
    creates substantial soft-delete churn on every deploy.
    """
    now = datetime.now(timezone.utc).isoformat()
    by_date: dict[str, list[str]] = {}
    for col in collections:
        bin_types = by_date.setdefault(col["collection_date"], [])
        if col["bin_type"] not in bin_types:
            bin_types.append(col["bin_type"])

    if not by_date:
        return {"status": "parse_failed", "tasks": 0}

    source_dates = sorted(by_date)
    today = datetime.now(ZoneInfo("Europe/London")).date().isoformat()

    async def retire_task(row: Any) -> None:
        task_id = row["id"]
        if family_id:
            await save_history(
                db,
                "tasks",
                task_id,
                _CREATED_BY,
                family_id=family_id,
            )
            assignment_cursor = await db.execute(
                """SELECT id FROM task_assignments
                   WHERE task_id = ? AND family_id = ? AND deleted_at IS NULL""",
                (task_id, family_id),
            )
            for assignment in await assignment_cursor.fetchall():
                await save_history(
                    db,
                    "task_assignments",
                    assignment["id"],
                    _CREATED_BY,
                    family_id=family_id,
                )
        await db.execute(
            """UPDATE task_assignments
               SET deleted_at = ?, updated_at = ?
               WHERE task_id = ? AND deleted_at IS NULL""",
            (now, now, task_id),
        )
        await db.execute(
            """UPDATE tasks SET deleted_at = ?, updated_at = ?
               WHERE id = ? AND deleted_at IS NULL""",
            (now, now, task_id),
        )

    await db.execute("BEGIN IMMEDIATE")
    try:
        responsibility_query = """
            SELECT ta.assignee_id
            FROM tasks t
            JOIN task_assignments ta
              ON ta.task_id = t.id
             AND ta.family_id = t.family_id
             AND ta.assignee_type = 'user'
             AND ta.deleted_at IS NULL
            JOIN users u
              ON u.id = ta.assignee_id
             AND u.family_id = t.family_id
             AND u.deleted_at IS NULL
            WHERE t.created_by = ?
              AND t.deleted_at IS NULL
        """
        responsibility_params: list[str] = [_CREATED_BY]
        if family_id:
            responsibility_query += " AND t.family_id = ?"
            responsibility_params.append(family_id)
        else:
            responsibility_query += " AND t.family_id IS NULL"
        responsibility_query += (
            " ORDER BY ta.updated_at DESC,ta.created_at DESC,t.due_date DESC,ta.id LIMIT 1"
        )
        cursor = await db.execute(responsibility_query, responsibility_params)
        responsibility = await cursor.fetchone()
        assignee_id = responsibility["assignee_id"] if responsibility else None

        existing_query = """
            SELECT * FROM tasks
            WHERE created_by = ? AND deleted_at IS NULL
        """
        existing_params: list[str] = [_CREATED_BY]
        if family_id:
            existing_query += " AND family_id = ?"
            existing_params.append(family_id)
        else:
            existing_query += " AND family_id IS NULL"
        existing_cursor = await db.execute(existing_query, existing_params)
        existing_rows = await existing_cursor.fetchall()
        existing_by_date: dict[str | None, list[Any]] = {}
        for row in existing_rows:
            existing_by_date.setdefault(row["due_date"], []).append(row)

        created = 0
        updated = 0
        unchanged = 0
        retired = 0
        for collection_date, bin_types in sorted(by_date.items()):
            actionable_from = _actionable_from(collection_date)

            matches = existing_by_date.pop(collection_date, [])
            if matches:
                # If legacy refreshes left duplicates, retain a completed row
                # over an incomplete one so a refresh cannot resurrect work.
                keeper = max(
                    matches,
                    key=lambda row: (
                        row["completed_at"] is not None,
                        row["updated_at"] or "",
                        row["id"],
                    ),
                )
                for duplicate in matches:
                    if duplicate["id"] == keeper["id"]:
                        continue
                    await retire_task(duplicate)
                    retired += 1

                description = ",".join(_merged_bin_types(keeper["description"], bin_types))
                if (
                    keeper["title"] != "Bins"
                    or keeper["description"] != description
                    or keeper["actionable_from"] != actionable_from
                    or keeper["category"] != "bins"
                    or keeper["priority"] != 2
                ):
                    if family_id:
                        await save_history(
                            db,
                            "tasks",
                            keeper["id"],
                            _CREATED_BY,
                            family_id=family_id,
                        )
                    await db.execute(
                        """UPDATE tasks
                           SET title = 'Bins', description = ?, actionable_from = ?,
                               category = 'bins', priority = 2, updated_at = ?
                           WHERE id = ? AND deleted_at IS NULL""",
                        (description, actionable_from, now, keeper["id"]),
                    )
                    updated += 1
                else:
                    unchanged += 1
                continue

            task_id = str(uuid.uuid4())
            await db.execute(
                """
                INSERT INTO tasks
                    (id, title, description, assigned_to, due_date, category, priority,
                     actionable_from, family_id, created_at, updated_at, created_by)
                VALUES (?, 'Bins', ?, ?, ?, 'bins', 2, ?, ?, ?, ?, ?)
                """,
                (
                    task_id,
                    ",".join(bin_types),
                    assignee_id,
                    collection_date,
                    actionable_from,
                    family_id,
                    now,
                    now,
                    _CREATED_BY,
                ),
            )
            if assignee_id:
                await db.execute(
                    """INSERT INTO task_assignments
                       (id,task_id,assignee_id,assignee_type,family_id,
                        created_at,updated_at,created_by)
                       VALUES (?,?,?,'user',?,?,?,?)""",
                    (
                        str(uuid.uuid4()),
                        task_id,
                        assignee_id,
                        family_id,
                        now,
                        now,
                        _CREATED_BY,
                    ),
                )
            created += 1

        # The council page is a rolling window and can occasionally return a
        # partial response. A single fetch provides no safe evidence that an
        # unmatched future collection was cancelled, even when parsed rows
        # surround it. Preserve every today/future row; only retire incomplete
        # scraper work once its due date is in the past.
        for rows in existing_by_date.values():
            for row in rows:
                due_date = row["due_date"]
                if row["completed_at"] is not None:
                    continue
                if due_date and due_date >= today:
                    continue
                await retire_task(row)
                retired += 1
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    logger.info(
        "Bin scraper reconciled %d dates (%d created, %d updated, %d unchanged, %d retired; %s to %s)",
        len(by_date),
        created,
        updated,
        unchanged,
        retired,
        source_dates[0],
        source_dates[-1],
    )
    return {
        "status": "ok",
        "tasks": len(by_date),
        "created": created,
        "updated": updated,
        "unchanged": unchanged,
        "retired": retired,
        "first_date": source_dates[0],
        "last_date": source_dates[-1],
    }


async def _fetch_collections() -> tuple[str, list[dict]]:
    html = await fetch_bin_page()
    if not html:
        return "fetch_failed", []
    collections = parse_collections(html)
    return ("ok", collections) if collections else ("parse_failed", [])


async def refresh_bin_tasks(db: Any, family_id: str | None = None) -> dict:
    """Compatibility entry point for callers that already own a connection."""
    status_value, collections = await _fetch_collections()
    if status_value != "ok":
        return {"status": status_value, "tasks": 0}
    return await _replace_bin_tasks(db, collections, family_id=family_id)


async def refresh_bin_tasks_for_family(*, family_id: str) -> dict:
    """Fetch externally before leasing SQLite for the atomic replacement."""
    status_value, collections = await _fetch_collections()
    if status_value != "ok":
        return {"status": status_value, "tasks": 0}
    async with database_lease() as db:
        return await _replace_bin_tasks(db, collections, family_id=family_id)

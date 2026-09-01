"""Reviewed delivery dates copied from Finance evidence into Calendar."""

from datetime import datetime, timezone
import json
import uuid

from app.models.finance import (
    FinanceCalendarItemCreate,
    FinanceCalendarItemPrefillResponse,
    FinanceCalendarItemResponse,
)
from app.services.finance.delivery_evidence import LABELLED_EMAIL_DELIVERY_ORIGIN
from app.services.finance.foundation import require_finance_access, require_finance_space
from app.services.finance.projections import FinanceProjectionNotFoundError


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


_STRUCTURED_DELIVERY_SOURCES = {
    "tesco_batch",
    "amazon_email",
    "e_receipt",
    "service_invoice",
}


def _issue_codes(source: dict) -> set[str] | None:
    try:
        issues = json.loads(source["issues_json"])
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(issues, list):
        return None
    codes: set[str] = set()
    for issue in issues:
        if not isinstance(issue, dict) or not isinstance(issue.get("code"), str):
            return None
        codes.add(issue["code"])
    return codes


def _delivery_window(payload: dict) -> dict | None:
    candidates: list[dict] = []

    def add(value: object) -> None:
        if isinstance(value, dict):
            candidates.append(value)

    add(payload.get("delivery_window"))
    for key in ("parcel_delivery", "shipment"):
        container = payload.get(key)
        if isinstance(container, dict):
            add(container.get("delivery_window"))
    shipments = payload.get("shipments")
    if isinstance(shipments, list):
        for shipment in shipments:
            if isinstance(shipment, dict):
                add(shipment.get("delivery_window"))
    if not candidates:
        return None
    unique = {
        json.dumps(candidate, sort_keys=True, separators=(",", ":")): candidate
        for candidate in candidates
    }
    return next(iter(unique.values())) if len(unique) == 1 else None


def _trusted_delivery_payload(source: dict, payload: dict) -> bool:
    issue_codes = _issue_codes(source)
    if issue_codes is None:
        return False
    labelled_email = (
        source.get("email_alias_id") is not None
        and payload.get("_delivery_window_origin") == LABELLED_EMAIL_DELIVERY_ORIGIN
    )
    if labelled_email:
        return source["extraction_status"] in {
            "PARSED",
            "UNSUPPORTED",
        } and issue_codes.issubset({"unsupported_source"})
    return (
        source["extraction_status"] == "PARSED"
        and source["source_kind"] in _STRUCTURED_DELIVERY_SOURCES
        and not issue_codes
    )


async def _authorised_source(db, *, user: dict, source_id: str) -> dict:
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT source.* FROM finance_purchase_sources source
            JOIN finance_spaces space
              ON space.id = source.space_id
             AND space.family_id = source.family_id
             AND space.deleted_at IS NULL
            WHERE source.id = ? AND source.family_id = ?
              AND source.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            """,
            (source_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceProjectionNotFoundError("Finance purchase source not found")
    return dict(row)


async def calendar_source_for_destination(
    db,
    *,
    user: dict,
    body: FinanceCalendarItemCreate,
) -> FinanceCalendarItemCreate:
    """Use the original source in-place, or a detail-free source in another space."""
    source = await _authorised_source(db, user=user, source_id=body.source_id)
    await require_finance_space(db, user=user, space_id=body.space_id)
    if source["space_id"] == body.space_id:
        return body

    existing = await (
        await db.execute(
            """
            SELECT link.calendar_source_id
            FROM finance_calendar_source_links link
            JOIN finance_purchase_sources calendar_source
              ON calendar_source.id = link.calendar_source_id
             AND calendar_source.space_id = link.calendar_space_id
             AND calendar_source.family_id = link.family_id
             AND calendar_source.deleted_at IS NULL
            WHERE link.owner_user_id = ? AND link.source_space_id = ?
              AND link.source_id = ? AND link.calendar_space_id = ?
              AND link.family_id = ? AND link.deleted_at IS NULL
            LIMIT 1
            """,
            (
                user["id"],
                source["space_id"],
                body.source_id,
                body.space_id,
                user["family_id"],
            ),
        )
    ).fetchone()
    if existing is not None:
        return body.model_copy(update={"source_id": existing["calendar_source_id"]})

    now = _now()
    calendar_source_id = str(uuid.uuid4())
    await db.execute(
        """
        INSERT INTO finance_purchase_sources
            (id, space_id, external_source_id, source_kind, parser_version,
             extraction_status, confidence_bps, raw_payload_json, issues_json,
             received_at, parsed_at, family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, 'finance-calendar-v1', 'PARSED', 10000, ?, '[]',
                ?, ?, ?, ?, ?, ?)
        """,
        (
            calendar_source_id,
            body.space_id,
            f"calendar-delivery:{calendar_source_id}",
            source["source_kind"],
            json.dumps({"delivery_calendar_copy": True}, separators=(",", ":")),
            now,
            now,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    await db.execute(
        """
        INSERT INTO finance_calendar_source_links
            (id, owner_user_id, source_space_id, source_id, calendar_space_id,
             calendar_source_id, family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            user["id"],
            source["space_id"],
            body.source_id,
            body.space_id,
            calendar_source_id,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    return body.model_copy(update={"source_id": calendar_source_id})


async def list_calendar_items(
    db,
    *,
    user: dict,
    space_id: str | None,
    source_id: str | None,
) -> list[FinanceCalendarItemResponse]:
    """List authorised delivery dates by Calendar destination or evidence source."""
    require_finance_access(user)
    if not space_id and not source_id:
        raise ValueError("Choose a Finance space or evidence source")
    if space_id:
        await require_finance_space(db, user=user, space_id=space_id)

    source_ids: list[str] = []
    if source_id:
        source = await _authorised_source(db, user=user, source_id=source_id)
        source_ids.append(source_id)
        linked = await (
            await db.execute(
                """
                SELECT calendar_source_id FROM finance_calendar_source_links
                WHERE owner_user_id = ? AND source_space_id = ? AND source_id = ?
                  AND family_id = ? AND deleted_at IS NULL
                """,
                (user["id"], source["space_id"], source_id, user["family_id"]),
            )
        ).fetchall()
        source_ids.extend(row["calendar_source_id"] for row in linked)

    clauses = [
        "item.family_id = ?",
        "item.deleted_at IS NULL",
        "((space.kind = 'personal' AND space.owner_user_id = ?) OR "
        "(space.kind = 'household' AND space.owner_user_id IS NULL))",
    ]
    parameters: list[object] = [user["family_id"], user["id"]]
    if space_id:
        clauses.append("item.space_id = ?")
        parameters.append(space_id)
    if source_ids:
        placeholders = ", ".join("?" for _ in source_ids)
        clauses.append(f"item.source_id IN ({placeholders})")
        parameters.extend(source_ids)

    rows = await (
        await db.execute(
            f"""
            SELECT item.* FROM finance_calendar_items item
            JOIN finance_spaces space
              ON space.id = item.space_id AND space.family_id = item.family_id
             AND space.deleted_at IS NULL
            WHERE {' AND '.join(clauses)}
            ORDER BY item.starts_at, item.created_at, item.id
            """,
            parameters,
        )
    ).fetchall()
    linked_ids = set(source_ids[1:]) if source_id else set()
    return [
        FinanceCalendarItemResponse(
            id=row["id"],
            space_id=row["space_id"],
            item_kind=row["item_kind"],
            source_id=(source_id if row["source_id"] in linked_ids else row["source_id"]),
            starts_at=row["starts_at"],
            ends_at=row["ends_at"],
            all_day=bool(row["all_day"]),
            status=row["status"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )
        for row in rows
    ]


async def calendar_item_prefill(
    db,
    *,
    user: dict,
    source_id: str,
) -> FinanceCalendarItemPrefillResponse | None:
    """Return only a typed structured delivery window for adult review."""
    source = await _authorised_source(db, user=user, source_id=source_id)
    try:
        payload = json.loads(source["raw_payload_json"])
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    if not _trusted_delivery_payload(source, payload):
        return None
    window = _delivery_window(payload)
    if not isinstance(window, dict) or not set(window).issubset(
        {"starts_at", "ends_at", "all_day"}
    ):
        return None
    starts_at = window.get("starts_at")
    ends_at = window.get("ends_at")
    all_day = window.get("all_day", False)
    if (
        not isinstance(starts_at, str)
        or ends_at is not None and not isinstance(ends_at, str)
        or not isinstance(all_day, bool)
    ):
        return None
    item_kind = (
        "GROCERY_DELIVERY"
        if source["source_kind"] == "tesco_batch"
        else "PARCEL_DELIVERY"
    )
    try:
        checked = FinanceCalendarItemCreate(
            reviewed=True,
            space_id=source["space_id"],
            item_kind=item_kind,
            source_id=source_id,
            starts_at=starts_at,
            ends_at=ends_at,
            all_day=all_day,
        )
    except ValueError:
        return None
    return FinanceCalendarItemPrefillResponse(
        item_kind=checked.item_kind,
        starts_at=checked.starts_at,
        ends_at=checked.ends_at,
        all_day=checked.all_day,
    )

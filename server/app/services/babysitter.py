"""Authoritative caregiver handovers and least-privilege booking sessions."""

import hashlib
import json
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

from app.config import settings
from app.models.babysitter import (
    CaregiverHandoverResponse,
    CaregiverHandoverUpdate,
    CaregiverReadinessItem,
    CaregiverReadinessResponse,
)
from app.services.calendar_recurrence import expand_calendar_rows
from app.services.record_history import save_history


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _now_iso() -> str:
    return _now().isoformat()


def _clean(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    return cleaned or None


def _hash_token(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _age(date_of_birth: str, *, today=None) -> int:
    born = datetime.strptime(date_of_birth, "%Y-%m-%d").date()
    current = today or _now().date()
    return current.year - born.year - ((current.month, current.day) < (born.month, born.day))


def _ready(value: str | None) -> bool:
    return bool(value and value.strip())


def _readiness(house: dict, children: list[dict], contacts: list[dict]) -> CaregiverReadinessResponse:
    items = [
        CaregiverReadinessItem(
            key="address", label="Home address", ready=_ready(house.get("address"))
        ),
        CaregiverReadinessItem(
            key="wifi_password",
            label="Wi-Fi password",
            ready=_ready(house.get("wifi_password")),
        ),
        CaregiverReadinessItem(
            key="emergency_instructions",
            label="Emergency instructions",
            ready=_ready(house.get("emergency_instructions")),
        ),
        CaregiverReadinessItem(
            key="house_instructions",
            label="House instructions",
            ready=_ready(house.get("house_instructions")),
        ),
        CaregiverReadinessItem(
            key="contacts", label="Emergency contact", ready=bool(contacts)
        ),
    ]
    child_fields = (
        ("care_notes", "Care notes"),
        ("allergies", "Allergies (or none known)"),
        ("food", "Food and drinks"),
        ("comfort", "Comfort and calming"),
        ("toileting", "Toileting"),
        ("bedtime", "Bedtime"),
    )
    for child in children:
        for field, label in child_fields:
            items.append(
                CaregiverReadinessItem(
                    key=f"child:{child['child_id']}:{field}",
                    child_id=child["child_id"],
                    label=f"{child['child_name']}: {label}",
                    ready=_ready(child.get(field)),
                )
            )
    complete = sum(item.ready for item in items)
    return CaregiverReadinessResponse(
        ready=complete == len(items) and bool(children),
        complete_count=complete,
        total_count=len(items),
        items=items,
    )


async def handover_for_family(db, family_id: str) -> CaregiverHandoverResponse:
    handover_row = await (
        await db.execute(
            "SELECT * FROM caregiver_handovers WHERE family_id = ? AND deleted_at IS NULL "
            "ORDER BY created_at LIMIT 1",
            (family_id,),
        )
    ).fetchone()
    handover = dict(handover_row) if handover_row else {}
    handover_id = handover.get("id")

    child_rows = await (
        await db.execute(
            """SELECT c.id AS child_id, c.name AS child_name,
                      p.id, p.care_notes, p.allergies, p.food, p.comfort,
                      p.toileting, p.bedtime
               FROM children c
               LEFT JOIN caregiver_child_profiles p
                 ON p.child_id = c.id AND p.family_id = c.family_id
                AND p.deleted_at IS NULL
               WHERE c.family_id = ? AND c.deleted_at IS NULL
               ORDER BY c.date_of_birth""",
            (family_id,),
        )
    ).fetchall()
    children = [dict(row) for row in child_rows]
    contact_rows = []
    if handover_id:
        contact_rows = await (
            await db.execute(
                "SELECT id, name, phone, relationship, priority "
                "FROM caregiver_contacts WHERE handover_id = ? AND family_id = ? "
                "AND deleted_at IS NULL ORDER BY priority, created_at",
                (handover_id, family_id),
            )
        ).fetchall()
    contacts = [dict(row) for row in contact_rows]
    house = {
        "id": handover_id,
        "address": handover.get("address"),
        "wifi_name": handover.get("wifi_name"),
        "wifi_password": handover.get("wifi_password"),
        "emergency_instructions": handover.get("emergency_instructions"),
        "house_instructions": handover.get("house_instructions"),
        "dog_instructions": handover.get("dog_instructions"),
    }
    return CaregiverHandoverResponse(
        id=handover_id,
        house=house,
        children=children,
        contacts=contacts,
        readiness=_readiness(house, children, contacts),
        updated_at=handover.get("updated_at"),
    )


async def update_handover(
    db,
    *,
    family_id: str,
    user_id: str,
    body: CaregiverHandoverUpdate,
) -> CaregiverHandoverResponse:
    valid_children = {
        row["id"]
        for row in await (
            await db.execute(
                "SELECT id FROM children WHERE family_id = ? AND deleted_at IS NULL",
                (family_id,),
            )
        ).fetchall()
    }
    supplied_children = {child.child_id for child in body.children}
    if not supplied_children.issubset(valid_children):
        raise ValueError("A caregiver profile child is not in this family")

    now = _now_iso()
    existing = await (
        await db.execute(
            "SELECT * FROM caregiver_handovers WHERE family_id = ? AND deleted_at IS NULL "
            "ORDER BY created_at LIMIT 1",
            (family_id,),
        )
    ).fetchone()
    if existing:
        handover_id = existing["id"]
        await save_history(
            db,
            "caregiver_handovers",
            handover_id,
            user_id,
            family_id=family_id,
        )
        await db.execute(
            """UPDATE caregiver_handovers
               SET address = ?, wifi_name = ?, wifi_password = ?,
                   emergency_instructions = ?, house_instructions = ?, dog_instructions = ?,
                   updated_at = ?, client_timestamp = ?
               WHERE id = ? AND family_id = ?""",
            (
                _clean(body.house.address),
                _clean(body.house.wifi_name),
                _clean(body.house.wifi_password),
                _clean(body.house.emergency_instructions),
                _clean(body.house.house_instructions),
                _clean(body.house.dog_instructions),
                now,
                now,
                handover_id,
                family_id,
            ),
        )
    else:
        handover_id = str(uuid.uuid4())
        await db.execute(
            """INSERT INTO caregiver_handovers
               (id, address, wifi_name, wifi_password, emergency_instructions,
                house_instructions, dog_instructions, family_id, created_at, updated_at,
                created_by, client_id, client_timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                handover_id,
                _clean(body.house.address),
                _clean(body.house.wifi_name),
                _clean(body.house.wifi_password),
                _clean(body.house.emergency_instructions),
                _clean(body.house.house_instructions),
                _clean(body.house.dog_instructions),
                family_id,
                now,
                now,
                user_id,
                f"caregiver-handover:{family_id}",
                now,
            ),
        )

    existing_profiles = {
        row["child_id"]: dict(row)
        for row in await (
            await db.execute(
                "SELECT * FROM caregiver_child_profiles WHERE family_id = ? "
                "AND deleted_at IS NULL",
                (family_id,),
            )
        ).fetchall()
    }
    for child in body.children:
        values = (
            _clean(child.care_notes),
            _clean(child.allergies),
            _clean(child.food),
            _clean(child.comfort),
            _clean(child.toileting),
            _clean(child.bedtime),
        )
        if child.child_id in existing_profiles:
            profile = existing_profiles[child.child_id]
            await save_history(
                db,
                "caregiver_child_profiles",
                profile["id"],
                user_id,
                family_id=family_id,
            )
            await db.execute(
                """UPDATE caregiver_child_profiles
                   SET care_notes = ?, allergies = ?, food = ?, comfort = ?, toileting = ?,
                       bedtime = ?, handover_id = ?, updated_at = ?, client_timestamp = ?
                   WHERE id = ? AND family_id = ?""",
                (*values, handover_id, now, now, profile["id"], family_id),
            )
        else:
            profile_id = str(uuid.uuid4())
            await db.execute(
                """INSERT INTO caregiver_child_profiles
                   (id, handover_id, child_id, care_notes, allergies, food, comfort,
                    toileting, bedtime, family_id, created_at, updated_at, created_by,
                    client_id, client_timestamp)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    profile_id,
                    handover_id,
                    child.child_id,
                    *values,
                    family_id,
                    now,
                    now,
                    user_id,
                    f"caregiver-child:{child.child_id}",
                    now,
                ),
            )

    removed_profiles = set(existing_profiles) - supplied_children
    for child_id in removed_profiles:
        profile = existing_profiles[child_id]
        await save_history(
            db,
            "caregiver_child_profiles",
            profile["id"],
            user_id,
            family_id=family_id,
        )
        await db.execute(
            "UPDATE caregiver_child_profiles SET deleted_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (now, now, profile["id"], family_id),
        )

    old_contacts = await (
        await db.execute(
            "SELECT * FROM caregiver_contacts WHERE handover_id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (handover_id, family_id),
        )
    ).fetchall()
    for contact in old_contacts:
        await save_history(
            db,
            "caregiver_contacts",
            contact["id"],
            user_id,
            family_id=family_id,
        )
    await db.execute(
        "UPDATE caregiver_contacts SET deleted_at = ?, updated_at = ? "
        "WHERE handover_id = ? AND family_id = ? AND deleted_at IS NULL",
        (now, now, handover_id, family_id),
    )
    for contact in body.contacts:
        contact_id = str(uuid.uuid4())
        await db.execute(
            """INSERT INTO caregiver_contacts
               (id, handover_id, name, phone, relationship, priority, family_id,
                created_at, updated_at, created_by, client_id, client_timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                contact_id,
                handover_id,
                contact.name,
                contact.phone,
                _clean(contact.relationship),
                contact.priority,
                family_id,
                now,
                now,
                user_id,
                f"caregiver-contact:{contact_id}",
                now,
            ),
        )
    updated = await handover_for_family(db, family_id)
    open_bookings = await (
        await db.execute(
            "SELECT child_ids FROM caregiver_bookings WHERE family_id = ? "
            "AND deleted_at IS NULL AND revoked_at IS NULL AND datetime(expires_at) > datetime(?)",
            (family_id, now),
        )
    ).fetchall()
    for booking in open_bookings:
        selected = set(json.loads(booking["child_ids"]))
        missing = [
            item.label
            for item in updated.readiness.items
            if not item.ready and (item.child_id is None or item.child_id in selected)
        ]
        if missing:
            await db.rollback()
            raise ValueError(
                "An open caregiver booking still needs these details: "
                + ", ".join(missing[:3])
                + ". Revoke the booking before removing them."
            )
    await db.commit()
    return updated


def _booking_status(row: dict, *, now: datetime | None = None) -> str:
    current = now or _now()
    if row.get("revoked_at"):
        return "revoked"
    if datetime.fromisoformat(row["expires_at"]) <= current:
        return "expired"
    if datetime.fromisoformat(row["starts_at"]) > current:
        return "upcoming"
    return "active"


async def _child_names(db, family_id: str, child_ids: list[str]) -> list[str]:
    if not child_ids:
        return []
    placeholders = ", ".join("?" for _ in child_ids)
    rows = await (
        await db.execute(
            f"SELECT id, name FROM children WHERE id IN ({placeholders}) "
            "AND family_id = ? AND deleted_at IS NULL",
            [*child_ids, family_id],
        )
    ).fetchall()
    names = {row["id"]: row["name"] for row in rows}
    return [names[child_id] for child_id in child_ids if child_id in names]


async def booking_response(db, row: dict) -> dict:
    child_ids = json.loads(row["child_ids"])
    return {
        "id": row["id"],
        "label": row["label"],
        "starts_at": row["starts_at"],
        "expires_at": row["expires_at"],
        "child_ids": child_ids,
        "child_names": await _child_names(db, row["family_id"], child_ids),
        "status": _booking_status(row),
        "created_at": row["created_at"],
        "revoked_at": row.get("revoked_at"),
        "last_accessed_at": row.get("last_accessed_at"),
    }


async def list_bookings(db, family_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM caregiver_bookings WHERE family_id = ? AND deleted_at IS NULL "
            "ORDER BY starts_at DESC LIMIT 100",
            (family_id,),
        )
    ).fetchall()
    return [await booking_response(db, dict(row)) for row in rows]


async def create_booking(db, *, family_id: str, user_id: str, body) -> dict:
    now = _now()
    if body.expires_at <= now:
        raise ValueError("Caregiver access must end in the future")
    handover = await handover_for_family(db, family_id)
    known_children = {child.child_id for child in handover.children}
    if not set(body.child_ids).issubset(known_children):
        raise ValueError("A selected child is not in this family")
    required = [
        item
        for item in handover.readiness.items
        if item.child_id is None or item.child_id in body.child_ids
    ]
    missing = [item.label for item in required if not item.ready]
    if missing:
        raise ValueError(f"Complete the handover first: {', '.join(missing[:3])}")
    if handover.id is None:
        raise ValueError("Complete the handover first")

    bootstrap = secrets.token_urlsafe(32)
    booking_id = str(uuid.uuid4())
    created_at = now.isoformat()
    await db.execute(
        """INSERT INTO caregiver_bookings
           (id, handover_id, label, starts_at, expires_at, child_ids, bootstrap_hash,
            family_id, created_at, updated_at, created_by, client_id, client_timestamp)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            booking_id,
            handover.id,
            body.label,
            body.starts_at.isoformat(),
            body.expires_at.isoformat(),
            json.dumps(body.child_ids),
            _hash_token(bootstrap),
            family_id,
            created_at,
            created_at,
            user_id,
            f"caregiver-booking:{booking_id}",
            created_at,
        ),
    )
    await db.commit()
    row = dict(
        await (
            await db.execute("SELECT * FROM caregiver_bookings WHERE id = ?", (booking_id,))
        ).fetchone()
    )
    response = await booking_response(db, row)
    response["share_url"] = (
        f"{settings.web_app_url.rstrip('/')}/?caregiver=1#invite={quote(bootstrap)}"
    )
    return response


async def revoke_booking(db, *, family_id: str, user_id: str, booking_id: str) -> bool:
    row = await (
        await db.execute(
            "SELECT * FROM caregiver_bookings WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (booking_id, family_id),
        )
    ).fetchone()
    if not row:
        return False
    await save_history(
        db, "caregiver_bookings", booking_id, user_id, family_id=family_id
    )
    now = _now_iso()
    await db.execute(
        "UPDATE caregiver_bookings SET revoked_at = ?, bootstrap_hash = ?, "
        "session_hash = NULL, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (
            now,
            _hash_token(secrets.token_urlsafe(32)),
            now,
            booking_id,
            family_id,
        ),
    )
    await db.commit()
    return True


async def exchange_booking_code(db, code: str) -> tuple[str, dict]:
    now = _now()
    row = await (
        await db.execute(
            "SELECT * FROM caregiver_bookings WHERE bootstrap_hash = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (_hash_token(code),),
        )
    ).fetchone()
    if not row:
        raise ValueError("This caregiver link is invalid or has already been used")
    booking = dict(row)
    if booking.get("bootstrap_used_at") or booking.get("revoked_at"):
        raise ValueError("This caregiver link is invalid or has already been used")
    if datetime.fromisoformat(booking["expires_at"]) <= now:
        raise ValueError("This caregiver link has expired")
    if datetime.fromisoformat(booking["starts_at"]) > now:
        raise ValueError("This caregiver link is not active yet")
    session = secrets.token_urlsafe(32)
    now_iso = now.isoformat()
    cursor = await db.execute(
        """UPDATE caregiver_bookings
           SET bootstrap_used_at = ?, bootstrap_hash = ?, session_hash = ?, updated_at = ?
           WHERE id = ? AND bootstrap_hash = ? AND bootstrap_used_at IS NULL
             AND revoked_at IS NULL""",
        (
            now_iso,
            _hash_token(secrets.token_urlsafe(32)),
            _hash_token(session),
            now_iso,
            booking["id"],
            _hash_token(code),
        ),
    )
    if cursor.rowcount != 1:
        await db.rollback()
        raise ValueError("This caregiver link is invalid or has already been used")
    await db.commit()
    booking["bootstrap_used_at"] = now_iso
    return session, booking


async def booking_for_session(db, session: str | None) -> dict:
    if not session:
        raise ValueError("Caregiver access is required")
    row = await (
        await db.execute(
            "SELECT * FROM caregiver_bookings WHERE session_hash = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (_hash_token(session),),
        )
    ).fetchone()
    if not row:
        raise ValueError("Caregiver access is invalid")
    booking = dict(row)
    now = _now()
    if booking.get("revoked_at"):
        raise ValueError("Caregiver access was revoked")
    if datetime.fromisoformat(booking["starts_at"]) > now:
        raise ValueError("Caregiver access is not active yet")
    if datetime.fromisoformat(booking["expires_at"]) <= now:
        raise ValueError("Caregiver access has expired")
    return booking


async def session_view(db, booking: dict) -> dict:
    family_id = booking["family_id"]
    child_ids = json.loads(booking["child_ids"])
    placeholders = ", ".join("?" for _ in child_ids)
    children_rows = await (
        await db.execute(
            f"""SELECT c.id AS child_id, c.name, c.date_of_birth,
                       p.care_notes, p.allergies, p.food, p.comfort, p.toileting, p.bedtime
                FROM children c
                JOIN caregiver_child_profiles p ON p.child_id = c.id
                 AND p.family_id = c.family_id AND p.deleted_at IS NULL
                WHERE c.id IN ({placeholders}) AND c.family_id = ? AND c.deleted_at IS NULL
                ORDER BY c.date_of_birth""",
            [*child_ids, family_id],
        )
    ).fetchall()
    children = [
        {
            "child_id": row["child_id"],
            "name": row["name"],
            "age": _age(row["date_of_birth"]),
            "care_notes": row["care_notes"],
            "allergies": row["allergies"],
            "food": row["food"],
            "comfort": row["comfort"],
            "toileting": row["toileting"],
            "bedtime": row["bedtime"],
        }
        for row in children_rows
    ]

    handover = dict(
        await (
            await db.execute(
                "SELECT * FROM caregiver_handovers WHERE id = ? AND family_id = ? "
                "AND deleted_at IS NULL",
                (booking["handover_id"], family_id),
            )
        ).fetchone()
    )
    contacts = [
        dict(row)
        for row in await (
            await db.execute(
                "SELECT id, name, phone, relationship, priority FROM caregiver_contacts "
                "WHERE handover_id = ? AND family_id = ? AND deleted_at IS NULL "
                "ORDER BY priority, created_at",
                (booking["handover_id"], family_id),
            )
        ).fetchall()
    ]

    required_house = (
        handover.get("address"),
        handover.get("wifi_password"),
        handover.get("emergency_instructions"),
        handover.get("house_instructions"),
    )
    required_child_fields = (
        "care_notes",
        "allergies",
        "food",
        "comfort",
        "toileting",
        "bedtime",
    )
    if (
        {child["child_id"] for child in children} != set(child_ids)
        or not all(_ready(value) for value in required_house)
        or not contacts
        or any(
            not all(_ready(child.get(field)) for field in required_child_fields)
            for child in children
        )
    ):
        raise ValueError(
            "The parent needs to complete this caregiver handover before it can be shown"
        )

    naps = [
        dict(row)
        for row in await (
            await db.execute(
                f"""SELECT c.name AS child_name, n.started_at, n.location
                    FROM naps n JOIN children c ON c.id = n.child_id
                    WHERE n.child_id IN ({placeholders}) AND n.family_id = ?
                      AND n.ended_at IS NULL AND n.deleted_at IS NULL""",
                [*child_ids, family_id],
            )
        ).fetchall()
    ]

    medicines = []
    medicine_rows = await (
        await db.execute(
            f"""SELECT mt.id AS type_id, mt.name AS medicine_name,
                       mt.min_hours_between_doses, mt.notes AS dosage_notes,
                       c.name AS child_name
                FROM medicine_types mt JOIN children c ON c.id = mt.child_id
                WHERE mt.child_id IN ({placeholders}) AND mt.family_id = ?
                  AND mt.deleted_at IS NULL AND c.deleted_at IS NULL""",
            [*child_ids, family_id],
        )
    ).fetchall()
    for row in medicine_rows:
        medicine = dict(row)
        last = await (
            await db.execute(
                """SELECT md.given_at, u.name AS given_by_name
                   FROM medicine_doses md LEFT JOIN users u
                     ON u.id = md.given_by AND u.family_id = md.family_id
                   WHERE md.medicine_type_id = ? AND md.family_id = ?
                     AND md.deleted_at IS NULL ORDER BY md.given_at DESC LIMIT 1""",
                (medicine["type_id"], family_id),
            )
        ).fetchone()
        last_at = last["given_at"] if last else None
        next_at = None
        if last_at:
            next_at = (
                datetime.fromisoformat(last_at)
                + timedelta(hours=medicine["min_hours_between_doses"])
            ).isoformat()
        medicines.append(
            {
                "child_name": medicine["child_name"],
                "medicine_name": medicine["medicine_name"],
                "dosage_notes": medicine["dosage_notes"],
                "last_given_at": last_at,
                "last_given_by": last["given_by_name"] if last else None,
                "next_dose_allowed_at": next_at,
                "min_hours_between": medicine["min_hours_between_doses"],
            }
        )

    event_rows = await (
        await db.execute(
            """SELECT ce.id, ce.title, ce.start_time, ce.end_time, ce.all_day,
                      ce.location,
                      ce.recurrence_rule, ce.assigned_to, ce.family_member_ids
               FROM calendar_events ce
               WHERE ce.family_id = ? AND ce.deleted_at IS NULL
                 AND NOT EXISTS (
                     SELECT 1 FROM calendar_events replacement
                     WHERE replacement.overridden_event_id = ce.id
                       AND replacement.family_id = ce.family_id
                       AND replacement.deleted_at IS NULL
                 )
                 AND (
                     ce.recurrence_rule IS NOT NULL
                     OR (
                         datetime(ce.start_time) < datetime(?)
                         AND datetime(COALESCE(ce.end_time, ce.start_time)) > datetime(?)
                     )
                 )
               ORDER BY datetime(ce.start_time)
               LIMIT 500""",
            (family_id, booking["expires_at"], booking["starts_at"]),
        )
    ).fetchall()
    occurrences = await expand_calendar_rows(
        db,
        family_id=family_id,
        rows=event_rows,
        range_start=datetime.fromisoformat(booking["starts_at"]),
        range_end=datetime.fromisoformat(booking["expires_at"]),
        max_occurrences_per_series=100,
    )
    child_set = set(child_ids)
    events = []
    for occurrence in occurrences:
        row = occurrence.row
        try:
            participants = set(json.loads(row.get("family_member_ids") or "[]"))
        except (TypeError, ValueError):
            participants = set()
        if row.get("assigned_to"):
            participants.add(row["assigned_to"])
        if participants.isdisjoint(child_set):
            continue
        events.append(
            {
                "title": row["title"],
                "start_time": occurrence.start_value,
                "end_time": occurrence.end_value or occurrence.start_value,
                "location": row.get("location"),
            }
        )

    now_iso = _now_iso()
    await db.execute(
        "UPDATE caregiver_bookings SET last_accessed_at = ?, updated_at = ? WHERE id = ?",
        (now_iso, now_iso, booking["id"]),
    )
    await db.commit()
    return {
        "booking": {
            "label": booking["label"],
            "starts_at": booking["starts_at"],
            "expires_at": booking["expires_at"],
        },
        "now": {
            "children": children,
            "active_naps": naps,
            "medicine_schedule": medicines,
        },
        "next": {"events": events},
        "emergency": {
            "address": handover["address"],
            "instructions": handover["emergency_instructions"],
            "contacts": contacts,
            "allergies": [
                {"child_name": child["name"], "details": child["allergies"]}
                for child in children
            ],
        },
        "house": {
            "wifi_name": handover.get("wifi_name"),
            "wifi_password": handover["wifi_password"],
            "house_instructions": handover["house_instructions"],
            "dog_instructions": handover.get("dog_instructions"),
        },
        "read_only": True,
    }

"""Illness tracking service — business logic for illness/temperature features."""

from datetime import datetime, timezone

from app.models.illness import NextDoseTime
from app.services.medicine import check_dose_safety


async def get_active_illness(db, child_id: str, family_id: str | None = None) -> dict | None:
    """Get the currently active illness for a child, or None."""
    if family_id:
        cursor = await db.execute(
            "SELECT * FROM illnesses WHERE child_id = ? AND ended_at IS NULL AND deleted_at IS NULL AND family_id = ?",
            (child_id, family_id),
        )
    else:
        cursor = await db.execute(
            "SELECT * FROM illnesses WHERE child_id = ? AND ended_at IS NULL AND deleted_at IS NULL",
            (child_id,),
        )
    row = await cursor.fetchone()
    return dict(row) if row else None


async def auto_associate_illness(db, child_id: str, family_id: str | None = None) -> str | None:
    """If the child has an active illness, return its id for auto-association."""
    illness = await get_active_illness(db, child_id, family_id)
    return illness["id"] if illness else None


async def get_illness_detail(db, illness_id: str, family_id: str | None = None) -> dict:
    """Get full illness detail: readings, doses during illness, next dose times."""
    if family_id:
        cursor = await db.execute(
            "SELECT * FROM illnesses WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
            (illness_id, family_id),
        )
    else:
        cursor = await db.execute(
            "SELECT * FROM illnesses WHERE id = ? AND deleted_at IS NULL",
            (illness_id,),
        )
    illness_row = await cursor.fetchone()
    if illness_row is None:
        return None
    illness = dict(illness_row)

    child_id = illness["child_id"]
    started_at = illness["started_at"]
    ended_at = illness["ended_at"]

    # For active illnesses (no ended_at), include all data from started_at onward
    if ended_at:
        time_filter = "AND recorded_at >= ? AND recorded_at <= ?"
        time_params = (child_id, started_at, ended_at)
        dose_filter = "AND md.given_at >= ? AND md.given_at <= ?"
        dose_params = (child_id, started_at, ended_at)
    else:
        time_filter = "AND recorded_at >= ?"
        time_params = (child_id, started_at)
        dose_filter = "AND md.given_at >= ?"
        dose_params = (child_id, started_at)

    # Temperature readings during illness
    cursor = await db.execute(
        f"""
        SELECT * FROM temperature_readings
        WHERE child_id = ? AND deleted_at IS NULL
          {time_filter}
        ORDER BY recorded_at ASC
        """,
        time_params,
    )
    readings = [dict(row) for row in await cursor.fetchall()]

    # Medicine doses during illness
    cursor = await db.execute(
        f"""
        SELECT md.*, COALESCE(mt.name, md.medicine_name, 'Unknown') AS medicine_name_display,
               mt.color
        FROM medicine_doses md
        LEFT JOIN medicine_types mt ON md.medicine_type_id = mt.id
        WHERE md.child_id = ? AND md.deleted_at IS NULL
          {dose_filter}
        ORDER BY md.given_at ASC
        """,
        dose_params,
    )
    doses = [dict(row) for row in await cursor.fetchall()]

    # Next dose times — for each active medicine type for this child
    cursor = await db.execute(
        "SELECT id, name, default_dose_amount, color FROM medicine_types WHERE child_id = ? AND deleted_at IS NULL",
        (child_id,),
    )
    med_types = await cursor.fetchall()

    now = datetime.now(timezone.utc).isoformat()
    next_dose_times: list[NextDoseTime] = []
    for mt in med_types:
        mt_id, mt_name, mt_default_dose, mt_color = mt[0], mt[1], mt[2], mt[3]
        is_safe, warnings = await check_dose_safety(
            db,
            mt_id,
            child_id,
            now,
            family_id=family_id,
        )
        next_safe_at = None
        for w in warnings:
            if w.next_safe_at:
                if next_safe_at is None or w.next_safe_at > next_safe_at:
                    next_safe_at = w.next_safe_at

        # Find last given time for this medicine type
        last_cursor = await db.execute(
            "SELECT given_at FROM medicine_doses WHERE medicine_type_id = ? AND child_id = ? AND deleted_at IS NULL ORDER BY given_at DESC LIMIT 1",
            (mt_id, child_id),
        )
        last_row = await last_cursor.fetchone()
        last_given_at = last_row[0] if last_row else None

        next_dose_times.append(NextDoseTime(
            medicine_type_id=mt_id,
            medicine_name=mt_name,
            next_safe_at=next_safe_at,
            is_safe_now=is_safe,
            default_dose_amount=mt_default_dose,
            color=mt_color,
            last_given_at=last_given_at,
        ))

    return {
        "illness": illness,
        "temperature_readings": readings,
        "medicine_doses": doses,
        "next_dose_times": next_dose_times,
    }

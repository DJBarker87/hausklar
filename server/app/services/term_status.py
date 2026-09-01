from datetime import date as date_type


async def is_person_in_term(db, family_id: str, person_id: str, check_date: date_type) -> bool:
    """Four-state logic: override > holiday_dates > term_dates > default on."""
    cursor = await db.execute(
        "SELECT is_active FROM routine_term_overrides WHERE person_id = ? "
        "AND deleted_at IS NULL AND family_id = ? "
        "AND (expires_on IS NULL OR expires_on >= ?)",
        (person_id, family_id, check_date.isoformat()),
    )
    override = await cursor.fetchone()
    if override:
        return bool(override["is_active"])

    date_str = check_date.isoformat()

    cursor = await db.execute(
        "SELECT id FROM holiday_dates WHERE person_id = ? AND date = ? AND deleted_at IS NULL AND family_id = ?",
        (person_id, date_str, family_id),
    )
    if await cursor.fetchone():
        return False

    cursor = await db.execute(
        "SELECT id FROM term_dates WHERE person_id = ? AND deleted_at IS NULL AND family_id = ? LIMIT 1",
        (person_id, family_id),
    )
    has_terms = await cursor.fetchone()
    if has_terms:
        cursor = await db.execute(
            "SELECT id FROM term_dates WHERE person_id = ? AND deleted_at IS NULL AND family_id = ? AND start_date <= ? AND end_date >= ?",
            (person_id, family_id, date_str, date_str),
        )
        return (await cursor.fetchone()) is not None

    return True


async def get_people_with_routine_or_terms(db, family_id: str) -> set[str]:
    cursor = await db.execute(
        "SELECT DISTINCT person_id FROM routine_items WHERE deleted_at IS NULL AND family_id = ?",
        (family_id,),
    )
    person_ids = {row["person_id"] for row in await cursor.fetchall()}

    cursor = await db.execute(
        "SELECT DISTINCT person_id FROM term_dates WHERE deleted_at IS NULL AND family_id = ?",
        (family_id,),
    )
    person_ids.update(row["person_id"] for row in await cursor.fetchall())
    return person_ids

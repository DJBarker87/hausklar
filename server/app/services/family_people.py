"""Family-scoped person lookup helpers for application-level foreign keys."""


async def family_person_type(db, family_id: str, person_id: str) -> str | None:
    cursor = await db.execute(
        """
        SELECT id, 'user' AS person_type
        FROM users
        WHERE id = ? AND family_id = ? AND deleted_at IS NULL
        UNION ALL
        SELECT id, 'child' AS person_type
        FROM children
        WHERE id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (person_id, family_id, person_id, family_id),
    )
    row = await cursor.fetchone()
    return row["person_type"] if row else None


async def family_child_exists(db, family_id: str, child_id: str) -> bool:
    cursor = await db.execute(
        """
        SELECT id FROM children
        WHERE id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (child_id, family_id),
    )
    return await cursor.fetchone() is not None


async def family_people_exist(db, family_id: str, person_ids: list[str]) -> bool:
    for person_id in set(person_ids):
        if not await family_person_type(db, family_id, person_id):
            return False
    return True


async def validate_calendar_people(
    db,
    family_id: str,
    participant_ids: list[str],
    affected_member_ids: list[str],
    *,
    whole_family: bool,
) -> None:
    """Validate event participants separately from affected adult availability."""
    if len(participant_ids) != len(set(participant_ids)):
        raise ValueError("Calendar participants must be unique")
    if len(affected_member_ids) != len(set(affected_member_ids)):
        raise ValueError("Affected adults must be unique")
    if participant_ids and not await family_people_exist(db, family_id, participant_ids):
        raise ValueError("Calendar person is not in this family")

    for person_id in affected_member_ids:
        if await family_person_type(db, family_id, person_id) != "user":
            raise ValueError("Affected person must be an adult in this family")

    if affected_member_ids and whole_family:
        raise ValueError("A whole-family event cannot affect another attending adult")
    if set(participant_ids) & set(affected_member_ids):
        raise ValueError("An event participant cannot also be an affected adult")

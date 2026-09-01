"""Versioned, revocable permission for sending family data to external AI."""

from fastapi import HTTPException, status

AI_CONSENT_VERSION = "2026-08-12"
AI_PROVIDER = "OpenAI"
AI_DISCLOSURE = (
    "When you choose an AI feature, HausKlar sends the text you submit and a broad, "
    "bounded snapshot of data you are allowed to read to OpenAI. That snapshot can "
    "include family calendars, tasks, documents, routines, meals, shopping, children's "
    "and household records, your private adult Fitness goals, plans, detailed recent "
    "activities, strength, nutrition, body, sleep, cycle, recovery and calculated progress, "
    "and Finance balances, holdings and transactions visible to you. Shared household "
    "Finance is included only when every adult has current AI permission. "
    "OpenAI processes it to return the requested answer or draft. HausKlar does not send "
    "profile, child, progress, food-label or artwork image bytes, raw document or FIT files, "
    "full activity streams, bank account or sort-code identifiers, provider account "
    "identifiers, wallet addresses, credentials or signing material, and it does not run "
    "background AI processing. "
    "Chat is not retained by default. Fitness Coach stores owner-private conversations on "
    "your HausKlar server only if you separately enable Coach memory; that setting can be "
    "turned off or cleared without changing this AI permission. You can withdraw permission "
    "at any time."
)


def has_current_ai_consent(user: dict) -> bool:
    return bool(
        user.get("ai_consent_at")
        and user.get("ai_consent_version") == AI_CONSENT_VERSION
        and not user.get("ai_consent_revoked_at")
    )


def require_ai_consent(user: dict) -> None:
    if not has_current_ai_consent(user):
        raise HTTPException(
            status_code=status.HTTP_428_PRECONDITION_REQUIRED,
            detail=(
                "Allow OpenAI processing before using this feature. "
                "You can review or change this in Settings."
            ),
        )


async def user_has_current_ai_consent(db, user_id: str) -> bool:
    cursor = await db.execute(
        "SELECT ai_consent_version, ai_consent_at, ai_consent_revoked_at "
        "FROM users WHERE id = ? AND deleted_at IS NULL",
        (user_id,),
    )
    row = await cursor.fetchone()
    if not row:
        return False
    return has_current_ai_consent(
        {
            "ai_consent_version": row[0],
            "ai_consent_at": row[1],
            "ai_consent_revoked_at": row[2],
        }
    )

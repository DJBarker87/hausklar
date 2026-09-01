"""Surface upcoming renewals as insights before they lapse."""

import logging
from datetime import datetime, timezone

from app.database import database_lease

logger = logging.getLogger(__name__)

_CREATED_BY = "renewals"


def _phrase(title: str, days_until: int) -> str:
    # Deliberately stable (no day count) so the once-only insight dedup — keyed
    # on the message text — matches across days instead of spamming a new card
    # each morning. The exact timing comes from the insight's target_date.
    if days_until < 0:
        return f"{title} has expired — renew it as soon as you can"
    return f"{title} renewal is due soon"


async def check_renewals(family_id: str) -> list[dict]:
    """Retire legacy family-wide renewal insights.

    Renewals now belong to Finance. Their reviewed Calendar and Task projections
    are authorised per caller, so a family-wide insight would bypass the selected
    personal or household Finance scope.
    """
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        await db.execute(
            """
            UPDATE family_insights SET status = 'dismissed', updated_at = ?
            WHERE family_id = ? AND status = 'active' AND deleted_at IS NULL
              AND created_by = ?
            """,
            (now, family_id, _CREATED_BY),
        )
        await db.commit()
        return []


async def run_renewals_check() -> None:
    """Check renewals for every family with an active user."""
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT DISTINCT family_id FROM users "
            "WHERE deleted_at IS NULL AND family_id IS NOT NULL"
        )
        family_ids = [row["family_id"] for row in await cursor.fetchall()]
    for family_id in family_ids:
        try:
            created = await check_renewals(family_id)
            logger.info("Renewals check stored %d insights for family %s", len(created), family_id)
        except Exception:
            logger.exception("Renewals check failed for family %s", family_id)

from typing import Any


BIN_SCRAPER_CREATOR = "bin-scraper"
MANAGED_TASK_DETAIL = (
    "Council bin tasks are managed automatically; only completion and responsibility "
    "coordination are available"
)


def is_scraper_managed_task(row: Any) -> bool:
    """Return whether an active task is owned by the council bin scraper.

    ``created_by`` is the durable ownership marker.  Do not rely on category:
    older clients may already have changed it, and that must not remove the
    scraper's protection or let the next refresh overwrite user edits silently.
    """
    return row["created_by"] == BIN_SCRAPER_CREATOR and row["deleted_at"] is None


def is_completion_only_sync(payload: dict) -> bool:
    """Managed tasks accept the exact offline completion shape used by iOS."""
    return set(payload) == {"completed_at"}

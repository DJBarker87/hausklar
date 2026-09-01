"""Tests for the APScheduler integration (scheduler module)."""

import asyncio
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch

from app.config import Settings
from app.database import standalone_db
from conftest import EXAMPLE_FAMILY_ID
from app.scheduler import (
    get_scheduler_status,
    run_expiry_alerts,
    scheduler,
    send_morning_briefing,
    start_scheduler,
    stop_scheduler,
)


async def _stop_and_wait():
    """Stop the scheduler and yield control so the event loop processes the shutdown."""
    stop_scheduler()
    await asyncio.sleep(0)


def test_finance_bank_sync_and_retry_poll_defaults():
    assert Settings.model_fields["finance_bank_sync_interval_minutes"].default == 360
    assert Settings.model_fields["finance_bank_retry_poll_interval_minutes"].default == 5


# ---------------------------------------------------------------------------
# Tests — scheduler start / stop
# ---------------------------------------------------------------------------


async def test_scheduler_starts_and_stops():
    """Scheduler should start and stop without raising."""
    start_scheduler()
    try:
        assert scheduler.running is True
    finally:
        await _stop_and_wait()
    assert scheduler.running is False


async def test_stop_scheduler_is_safe_when_not_running():
    """Calling stop_scheduler when the scheduler is not running should be a no-op."""
    assert scheduler.running is False
    stop_scheduler()  # should not raise
    assert scheduler.running is False


# ---------------------------------------------------------------------------
# Tests — get_scheduler_status
# ---------------------------------------------------------------------------


async def test_get_scheduler_status_when_stopped():
    """Status should report not running and zero jobs when stopped."""
    # Ensure scheduler is stopped
    if scheduler.running:
        await _stop_and_wait()

    status = get_scheduler_status()
    assert status["running"] is False
    assert status["jobs"] == 0
    assert status["next_run"] is None


async def test_get_scheduler_status_when_running():
    """Status should report every non-AI background job and a next run time."""
    start_scheduler()
    try:
        status = get_scheduler_status()
        assert status["running"] is True
        assert status["jobs"] == 27
        assert status["next_run"] is not None
        assert isinstance(status["next_run"], str)
    finally:
        await _stop_and_wait()


# ---------------------------------------------------------------------------
# Tests — job configuration
# ---------------------------------------------------------------------------


async def test_scheduler_job_configuration():
    """The morning briefing job should be configured for 06:30 Europe/London."""
    start_scheduler()
    try:
        jobs = scheduler.get_jobs()
        assert len(jobs) == 27
        assert "school_brain" not in {job.id for job in jobs}
        assert "term_date_refresh_startup" in {job.id for job in jobs}
        assert {
            "finance_coaching",
            "finance_bank_sync",
            "finance_bank_retry_poll",
            "finance_nightly_refresh",
            "finance_weekly_opportunity_scan",
            "finance_watch_refresh",
            "fitness_daily_maintenance",
            "fitness_weekly_review_drafts",
            "fitness_maintenance_startup",
            "usage_history_cleanup",
            "idempotency_cleanup",
            "library_sync",
        } <= {job.id for job in jobs}

        job = next(j for j in jobs if j.id == "morning_briefing")
        assert job.name == "send_morning_briefing"

        # Verify the cron trigger fields
        trigger = job.trigger
        # APScheduler CronTrigger stores fields as a list; check hour and minute
        field_map = {str(f.name): str(f) for f in trigger.fields}
        assert field_map["hour"] == "6"
        assert field_map["minute"] == "30"
        assert str(trigger.timezone) == "Europe/London"

        calendar_job = next(j for j in jobs if j.id == "calendar_source_refresh")
        assert "0:30:00" in str(calendar_job.trigger)
        finance_bank_job = next(j for j in jobs if j.id == "finance_bank_sync")
        assert "6:00:00" in str(finance_bank_job.trigger)
        finance_retry_job = next(j for j in jobs if j.id == "finance_bank_retry_poll")
        assert "0:05:00" in str(finance_retry_job.trigger)
        bin_job = next(j for j in jobs if j.id == "bin_collection_refresh")
        assert "7 days" in str(bin_job.trigger)
        reminder_job = next(j for j in jobs if j.id == "reminder_dispatch")
        assert "0:01:00" in str(reminder_job.trigger)
        usage_cleanup_job = next(j for j in jobs if j.id == "usage_history_cleanup")
        usage_cleanup_fields = {
            str(field.name): str(field) for field in usage_cleanup_job.trigger.fields
        }
        assert usage_cleanup_fields["hour"] == "2"
        assert usage_cleanup_fields["minute"] == "40"
        assert str(usage_cleanup_job.trigger.timezone) == "Europe/London"
        idempotency_cleanup_job = next(
            j for j in jobs if j.id == "idempotency_cleanup"
        )
        idempotency_cleanup_fields = {
            str(field.name): str(field)
            for field in idempotency_cleanup_job.trigger.fields
        }
        assert idempotency_cleanup_fields["hour"] == "2"
        assert idempotency_cleanup_fields["minute"] == "50"
        assert str(idempotency_cleanup_job.trigger.timezone) == "Europe/London"
    finally:
        await _stop_and_wait()


# ---------------------------------------------------------------------------
# Tests — send_morning_briefing
# ---------------------------------------------------------------------------


async def test_send_morning_briefing():
    """send_morning_briefing should generate a briefing and call send_briefing_to_all."""
    mock_send = AsyncMock(
        return_value=[
            {"success": True, "recipient": "Alex"},
            {"success": True, "recipient": "Morgan"},
        ]
    )

    with (
        patch("app.scheduler.send_briefing_to_all", mock_send),
        patch(
            "app.scheduler.generate_briefing_for_family",
            new_callable=AsyncMock,
        ) as mock_gen,
        patch("app.scheduler._active_family_ids", new=AsyncMock(return_value=[EXAMPLE_FAMILY_ID])),
    ):
        mock_gen.return_value = {"message": "Good morning! Test briefing."}
        await send_morning_briefing()

    mock_gen.assert_awaited_once_with(EXAMPLE_FAMILY_ID)
    mock_send.assert_called_once_with("Good morning! Test briefing.")


async def test_expiry_alerts_are_scoped_to_default_family(initialized_db):
    mock_check = AsyncMock()

    with (
        patch("app.scheduler.check_expiring_items", mock_check),
        patch("app.scheduler.standalone_db", lambda: standalone_db(initialized_db)),
    ):
        await run_expiry_alerts()

    mock_check.assert_awaited_once()
    assert mock_check.await_args.kwargs["family_id"] == EXAMPLE_FAMILY_ID


async def test_send_morning_briefing_with_real_briefing(initialized_db):
    """send_morning_briefing should work end-to-end with a real database."""
    mock_send = AsyncMock(
        return_value=[
            {"success": True, "recipient": "Alex"},
            {"success": True, "recipient": "Morgan"},
        ]
    )

    with (
        patch("app.scheduler.send_briefing_to_all", mock_send),
    ):
        await send_morning_briefing()

    # Should have been called with a real briefing message string
    mock_send.assert_called_once()
    message = mock_send.call_args[0][0]
    assert isinstance(message, str)
    assert len(message) > 0


async def test_send_morning_briefing_handles_send_failure():
    """send_morning_briefing should log errors but not raise on send failure."""
    mock_send = AsyncMock(
        return_value=[
            {"success": False, "recipient": "Alex", "error": "timeout"},
            {"success": True, "recipient": "Morgan"},
        ]
    )

    with (
        patch("app.scheduler.send_briefing_to_all", mock_send),
        patch(
            "app.scheduler.generate_briefing_for_family",
            new_callable=AsyncMock,
            return_value={"message": "Good morning! Test briefing."},
        ),
    ):
        # Should not raise
        await send_morning_briefing()

    mock_send.assert_called_once()


async def test_send_morning_briefing_handles_exception():
    """send_morning_briefing should catch and log exceptions without re-raising."""
    with (
        patch(
            "app.scheduler.generate_briefing_for_family",
            new_callable=AsyncMock,
            side_effect=RuntimeError("DB exploded"),
        ),
    ):
        # Should not raise
        await send_morning_briefing()


async def test_send_morning_briefing_closes_db_on_error():
    """The briefing service should release its lease if aggregation fails."""
    connection_closed = False

    @asynccontextmanager
    async def fake_database_lease():
        nonlocal connection_closed
        try:
            yield object()
        finally:
            connection_closed = True

    with (
        patch("app.services.briefing.database_lease", fake_database_lease),
        patch(
            "app.services.briefing.get_weather_summary",
            new_callable=AsyncMock,
            return_value={},
        ),
        patch(
            "app.services.briefing.generate_briefing",
            new_callable=AsyncMock,
            side_effect=RuntimeError("Boom"),
        ),
    ):
        await send_morning_briefing()

    assert connection_closed is True

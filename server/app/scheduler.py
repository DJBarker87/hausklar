"""APScheduler integration for automated morning briefings.

Sends a WhatsApp briefing to all family members at 06:30 Europe/London daily.
"""

import logging
from datetime import datetime, timedelta, timezone

from apscheduler.schedulers.asyncio import AsyncIOScheduler

from app.database import standalone_db
from app.services.briefing import generate_briefing_for_family
from app.services.callmebot import send_briefing_to_all
from app.services.bin_scraper import refresh_bin_tasks_for_family
from app.services.grocery import check_expiring_items
from app.services.calendar_sync import sync_all_calendar_sources
from app.services.reminders import dispatch_due_reminders
from app.services.second_brain import run_second_brain
from app.services.renewals import run_renewals_check
from app.services.library import sync_due_library_accounts

logger = logging.getLogger(__name__)

scheduler = AsyncIOScheduler(
    job_defaults={
        "coalesce": True,
        "max_instances": 1,
        "misfire_grace_time": 300,
    }
)

async def _active_family_ids() -> list[str]:
    """Resolve households at runtime; scheduled jobs never target a fixed ID."""
    async with standalone_db() as db:
        rows = await (
            await db.execute("SELECT id FROM families WHERE deleted_at IS NULL ORDER BY id")
        ).fetchall()
    return [str(row[0]) for row in rows]


async def refresh_term_dates() -> None:
    """Fetch and update term dates from school websites.

    Runs quarterly (~every 13 weeks) to keep term dates current.
    Fetches school pages before taking a short pooled database write lease.
    """
    try:
        from app.services.term_scraper import refresh_all_terms_for_family

        for family_id in await _active_family_ids():
            result = await refresh_all_terms_for_family(family_id=family_id)
            for source, info in result.items():
                if info.get("status") != "ok":
                    logger.warning("Configured term-date source failed: %s", source)
    except Exception:
        logger.exception("Error in refresh_term_dates")


async def refresh_bin_collections() -> None:
    """Fetch and update bin collection tasks from Local authority council.

    Runs weekly because Local authority publishes only a short rolling horizon. A weekly
    retry leaves enough buffer for a transient council outage without future
    collections disappearing.
    Fetches before taking a short pooled database write lease.
    """
    try:
        for family_id in await _active_family_ids():
            result = await refresh_bin_tasks_for_family(family_id=family_id)
            if result.get("status") != "ok":
                logger.warning("Configured waste-collection source failed")
    except Exception:
        logger.exception("Error in refresh_bin_collections")


async def send_morning_briefing() -> None:
    """Generate and send the morning briefing via WhatsApp.

    Delegates to the family-scoped service, which owns a short database lease
    and releases it before waiting for external weather data.
    """
    try:
        for family_id in await _active_family_ids():
            briefing = await generate_briefing_for_family(family_id)
            await send_briefing_to_all(briefing["message"])
    except Exception:
        logger.exception("Error in send_morning_briefing")


async def refresh_swimming_lessons() -> None:
    """Fetch and update swimming lesson events from configured swimming provider.

    Runs every 4 weeks to keep swimming calendar events current.
    The importer fetches without a database lease, then performs a short write.
    """
    try:
        from app.services.swimming_scraper import refresh_swimming_lessons as _refresh

        for family_id in await _active_family_ids():
            result = await _refresh(family_id=family_id)
            if result.get("status") != "ok":
                logger.warning("Configured activity source failed")
    except Exception:
        logger.exception("Error in refresh_swimming_lessons")


async def run_logistics_check() -> None:
    """Deterministic scan for calendar clashes and tight turnarounds."""
    try:
        await run_second_brain()
    except Exception:
        logger.exception("Error in run_logistics_check")


async def run_daily_renewals_check() -> None:
    """Surface household renewals due within their reminder window."""
    try:
        await run_renewals_check()
    except Exception:
        logger.exception("Error in run_daily_renewals_check")


async def run_library_sync() -> None:
    """Refresh connected Local authority cards without logging account details."""
    try:
        completed = await sync_due_library_accounts()
        if completed:
            logger.info("Library refresh: %d cards updated", completed)
    except Exception:
        logger.error("Library refresh failed")


async def run_finance_coaching() -> None:
    """Generate due Finance reports for every active family member and bound space."""
    try:
        from app.services.finance.capture import expire_finance_capture_drafts
        from app.services.finance.coaching import run_finance_coaching_schedule

        async with standalone_db() as db:
            await expire_finance_capture_drafts(db)
            generated = await run_finance_coaching_schedule(db)
            await db.commit()
        if generated:
            logger.info("Finance coaching: %d due reports generated", generated)
    except Exception:
        # Finance exceptions may arise while handling private records. Do not
        # emit exception text or contextual tracebacks to shared logs.
        logger.error("Finance coaching failed")


async def run_finance_bank_sync() -> None:
    """Refresh configured read-only bank connections with isolated failures."""
    from app.config import settings

    completed = 0
    enable_banking_configured = all(
        value.strip()
        for value in (
            settings.enable_banking_application_id,
            settings.enable_banking_private_key_path,
            settings.enable_banking_callback_url,
        )
    )
    if enable_banking_configured:
        try:
            from app.services.finance.enable_banking_connections import (
                sync_due_enable_banking_connections,
            )
            from app.services.finance.providers.enable_banking_config import (
                configured_enable_banking_provider,
            )

            async with configured_enable_banking_provider() as provider:
                async with standalone_db() as db:
                    completed += await sync_due_enable_banking_connections(db, provider=provider)
        except Exception:
            # Provider details and exception text are private. One provider must
            # never stop a separately configured provider from refreshing.
            logger.error("Finance bank refresh failed")

    completed += await _run_truelayer_bank_sync()

    if completed:
        logger.info("Finance bank refresh: %d connections updated", completed)


async def _run_truelayer_bank_sync() -> int:
    """Run TrueLayer's due selector without exposing private provider details."""
    from app.config import settings

    truelayer_configured = all(
        value.strip()
        for value in (
            settings.truelayer_client_id,
            settings.truelayer_client_secret,
            settings.truelayer_callback_url,
        )
    )
    if not truelayer_configured:
        return 0
    try:
        from app.services.finance.providers.truelayer_config import (
            configured_truelayer_provider,
        )
        from app.services.finance.truelayer_connections import (
            sync_due_truelayer_connections,
        )

        async with configured_truelayer_provider() as provider:
            async with standalone_db() as db:
                return await sync_due_truelayer_connections(db, provider=provider)
    except Exception:
        logger.error("Finance bank refresh failed")
        return 0


async def run_finance_bank_retry_poll() -> None:
    """Wake for short TrueLayer retries; its selector contacts only due rows."""
    completed = await _run_truelayer_bank_sync()
    if completed:
        logger.info("Finance bank refresh: %d connections updated", completed)


async def _finance_scheduled_scopes(db) -> list[tuple[dict, str, tuple[str, ...]]]:
    """Bind each personal space and each household space to one family member."""
    from app.services.finance.foundation import accessible_finance_spaces

    users = await (
        await db.execute(
            "SELECT * FROM users WHERE family_id IS NOT NULL AND deleted_at IS NULL "
            "ORDER BY family_id, id"
        )
    ).fetchall()
    seen: set[tuple[str, str]] = set()
    scopes: list[tuple[dict, str, tuple[str, ...]]] = []
    for raw_user in users:
        user = dict(raw_user)
        for space in await accessible_finance_spaces(db, user=user):
            key = (user["family_id"], space.id)
            if key in seen:
                continue
            seen.add(key)
            currency_rows = await (
                await db.execute(
                    "SELECT currency FROM finance_accounts WHERE space_id = ? AND family_id = ? "
                    "AND deleted_at IS NULL UNION SELECT currency FROM finance_transactions "
                    "WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL UNION "
                    "SELECT default_currency AS currency FROM finance_settings "
                    "WHERE family_id = ? AND deleted_at IS NULL",
                    (
                        space.id,
                        user["family_id"],
                        space.id,
                        user["family_id"],
                        user["family_id"],
                    ),
                )
            ).fetchall()
            scopes.append((user, space.id, tuple(sorted(row[0] for row in currency_rows))))
    return scopes


async def run_finance_nightly_refresh() -> None:
    """Refresh recurring detections and reviewed price aggregates nightly."""
    try:
        from app.services.finance.pattern_detection import refresh_recurring_series
        from app.services.finance.product_comparison import rebuild_product_price_history

        completed = 0
        async with standalone_db() as db:
            for user, space_id, currencies in await _finance_scheduled_scopes(db):
                for currency in currencies:
                    try:
                        await refresh_recurring_series(
                            db, user=user, space_id=space_id, as_of=None, currency=currency
                        )
                        completed += 1
                    except Exception:
                        logger.error("Finance recurring refresh failed for one scope")
                try:
                    await rebuild_product_price_history(db, user=user, space_id=space_id)
                except Exception:
                    logger.error("Finance price aggregate refresh failed for one scope")
        if completed:
            logger.info("Finance nightly refresh: %d scope currencies updated", completed)
    except Exception:
        logger.error("Finance nightly refresh failed")


async def run_finance_weekly_opportunity_scan() -> None:
    """Run the broader deterministic opportunity scan once per week."""
    try:
        from app.services.finance.pattern_detection import scan_finance_patterns

        completed = 0
        async with standalone_db() as db:
            for user, space_id, currencies in await _finance_scheduled_scopes(db):
                for currency in currencies:
                    try:
                        await scan_finance_patterns(
                            db, user=user, space_id=space_id, as_of=None, currency=currency
                        )
                        completed += 1
                    except Exception:
                        logger.error("Finance opportunity scan failed for one scope")
        if completed:
            logger.info("Finance weekly scan: %d scope currencies updated", completed)
    except Exception:
        logger.error("Finance weekly scan failed")


async def run_finance_watch_refresh() -> None:
    """Refresh public watch balances and imported investment prices daily."""
    try:
        from app.services.finance.assets import (
            refresh_securities_prices,
            refresh_watch_source,
        )
        from app.services.finance.market_prices import (
            close_market_quote_provider,
            configured_market_quote_provider,
        )

        completed = 0
        quote_provider = configured_market_quote_provider()
        try:
            async with standalone_db() as db:
                for user, space_id, _ in await _finance_scheduled_scopes(db):
                    sources = await (
                        await db.execute(
                            "SELECT id, source_kind FROM finance_asset_sources WHERE space_id = ? "
                            "AND family_id = ? AND source_kind IN "
                            "('HL_REPORT', 'MANUAL_PORTFOLIO', "
                            "'SOLANA_PUBLIC', 'HYPERLIQUID_PUBLIC') "
                            "AND status = 'ACTIVE' AND deleted_at IS NULL ORDER BY id",
                            (space_id, user["family_id"]),
                        )
                    ).fetchall()
                    for source in sources:
                        try:
                            if source["source_kind"] in {
                                "HL_REPORT",
                                "MANUAL_PORTFOLIO",
                            }:
                                await refresh_securities_prices(
                                    db,
                                    user=user,
                                    source_id=source["id"],
                                    provider=quote_provider,
                                )
                            else:
                                await refresh_watch_source(db, user=user, source_id=source["id"])
                            completed += 1
                        except Exception:
                            logger.error("Finance watch refresh failed for one source")
        finally:
            await close_market_quote_provider(quote_provider)
        if completed:
            logger.info("Finance asset refresh: %d sources checked", completed)
    except Exception:
        logger.error("Finance watch refresh failed")


async def run_fitness_maintenance() -> None:
    """Reconcile private Fitness assets and bound retained sync state."""
    try:
        from app.services.account_deletion import (
            process_deferred_fitness_file_deletions,
        )
        from app.services.fitness.activity_import import (
            cleanup_stale_uploads,
            reconcile_assets,
        )
        from app.services.fitness.sync import cleanup_sync_state
        from app.services.fitness.strength import close_expired_strength_sessions

        reconciled = 0
        cleaned_uploads = 0
        expired_strength_sessions = 0
        async with standalone_db() as db:
            users = await (
                await db.execute(
                    "SELECT DISTINCT u.* FROM users u JOIN health_user_settings s "
                    "ON s.owner_user_id = u.id AND s.family_id = u.family_id "
                    "AND s.deleted_at IS NULL WHERE u.family_id IS NOT NULL "
                    "AND u.deleted_at IS NULL ORDER BY u.id"
                )
            ).fetchall()
            for raw_user in users:
                try:
                    expired_strength_sessions += len(
                        await close_expired_strength_sessions(db, user=dict(raw_user))
                    )
                    await reconcile_assets(db, user=dict(raw_user), reason="scheduled_maintenance")
                    cleanup = await cleanup_stale_uploads(db, user=dict(raw_user))
                    cleaned_uploads += sum(cleanup.values())
                    reconciled += 1
                except Exception:
                    if db.in_transaction:
                        await db.rollback()
                    # Asset identifiers and paths are private; retain details in
                    # owner-scoped reconciliation rows, never shared logs.
                    logger.error("Fitness reconciliation failed for one owner")
            await cleanup_sync_state(db)
            await db.commit()
            deleted = await process_deferred_fitness_file_deletions(db)
        if reconciled or deleted or cleaned_uploads or expired_strength_sessions:
            logger.info(
                "Fitness maintenance: %d owners reconciled, %d deferred files removed, "
                "%d abandoned uploads removed, %d stale strength sessions closed",
                reconciled,
                deleted,
                cleaned_uploads,
                expired_strength_sessions,
            )
    except Exception:
        logger.error("Fitness maintenance failed")


async def run_fitness_weekly_review_drafts() -> None:
    """Create deterministic review markers without invoking Hermes."""
    try:
        from app.services.fitness.coach import ensure_weekly_review_markers

        async with standalone_db() as db:
            created = await ensure_weekly_review_markers(db)
            await db.commit()
        if created:
            logger.info("Fitness weekly review drafts: %d created", created)
    except Exception:
        logger.error("Fitness weekly review draft generation failed")


async def run_withings_sync() -> None:
    """Backfill every active owner-bound Withings connection."""
    try:
        from app.services.fitness.withings import sync_due_connections

        completed = await sync_due_connections()
        if completed:
            logger.info("Withings refresh: %d owner connections updated", completed)
    except Exception:
        # Provider identifiers and health records remain owner-private.
        logger.error("Withings refresh failed")


async def run_withings_notification_retries() -> None:
    """Retry queued notifications that did not finish their data pull."""
    try:
        from app.services.fitness.withings import process_pending_notifications

        completed = await process_pending_notifications()
        if completed:
            logger.info("Withings notifications: %d queued events checked", completed)
    except Exception:
        logger.error("Withings notification retry failed")


async def run_intervals_delivery_retries() -> None:
    """Push queued Intervals.icu workout edits and cancellations."""
    try:
        from app.services.fitness.intervals_icu import process_pending_deliveries

        completed = await process_pending_deliveries()
        if completed:
            logger.info("Intervals.icu delivery: %d queued workouts updated", completed)
    except Exception:
        # Athlete identifiers, workout content and provider errors are private.
        logger.error("Intervals.icu delivery retry failed")


async def run_intervals_activity_imports() -> None:
    """Check for completed Garmin activities for owners who enabled imports."""
    try:
        from app.services.fitness.intervals_icu import (
            process_enabled_activity_imports,
        )

        completed = await process_enabled_activity_imports()
        if completed:
            logger.info("Intervals.icu activity import: %d owners checked", completed)
    except Exception:
        logger.error("Intervals.icu activity import failed")


async def run_expiry_alerts() -> None:
    """Check grocery expiry windows and send WhatsApp alerts."""
    try:
        async with standalone_db() as db:
            rows = await (
                await db.execute("SELECT id FROM families WHERE deleted_at IS NULL ORDER BY id")
            ).fetchall()
            for row in rows:
                await check_expiring_items(db, family_id=str(row[0]))
    except Exception:
        logger.exception("Error in run_expiry_alerts")


async def run_usage_history_cleanup() -> None:
    """Close the short 28-day window for opted-in, content-free usage facts."""
    try:
        from app.services.adoption import cleanup_expired_adoption_events

        async with standalone_db() as db:
            cleaned = await cleanup_expired_adoption_events(db)
            await db.commit()
        if cleaned:
            logger.info("Usage history: %d expired facts cleared", cleaned)
    except Exception:
        logger.error("Usage history cleanup failed")


async def run_idempotency_cleanup() -> None:
    """Bound the durable replay cache without adding a write to every mutation."""
    try:
        from app.middleware.idempotency import cleanup_expired_idempotency_records

        async with standalone_db() as db:
            cleaned = await cleanup_expired_idempotency_records(db)
            await db.commit()
        if cleaned:
            logger.info("Idempotency cache: %d expired records cleared", cleaned)
    except Exception:
        logger.error("Idempotency cache cleanup failed")


def start_scheduler() -> None:
    """Add the morning briefing cron job and start the scheduler."""
    scheduler.add_job(
        send_morning_briefing,
        "cron",
        hour=6,
        minute=30,
        timezone="Europe/London",
        id="morning_briefing",
        replace_existing=True,
    )
    scheduler.add_job(
        run_expiry_alerts,
        "cron",
        hour=8,
        minute=0,
        timezone="Europe/London",
        id="expiry_alerts",
        replace_existing=True,
    )
    scheduler.add_job(
        run_usage_history_cleanup,
        "cron",
        hour=2,
        minute=40,
        timezone="Europe/London",
        id="usage_history_cleanup",
        replace_existing=True,
    )
    scheduler.add_job(
        run_idempotency_cleanup,
        "cron",
        hour=2,
        minute=50,
        timezone="Europe/London",
        id="idempotency_cleanup",
        replace_existing=True,
    )
    scheduler.add_job(
        refresh_term_dates,
        "interval",
        weeks=13,
        timezone="Europe/London",
        id="term_date_refresh",
        replace_existing=True,
    )
    scheduler.add_job(
        refresh_bin_collections,
        "interval",
        weeks=1,
        timezone="Europe/London",
        id="bin_collection_refresh",
        replace_existing=True,
    )
    scheduler.add_job(
        dispatch_due_reminders,
        "interval",
        minutes=1,
        id="reminder_dispatch",
        replace_existing=True,
    )
    scheduler.add_job(
        sync_all_calendar_sources,
        "interval",
        minutes=30,
        timezone="Europe/London",
        id="calendar_source_refresh",
        replace_existing=True,
    )
    scheduler.add_job(
        refresh_swimming_lessons,
        "interval",
        weeks=4,
        timezone="Europe/London",
        id="swimming_lesson_refresh",
        replace_existing=True,
    )
    # Logistics clashes update as the calendar changes; a few times a day is
    # enough and it's cheap (deterministic, no LLM).
    scheduler.add_job(
        run_logistics_check,
        "interval",
        hours=4,
        timezone="Europe/London",
        id="second_brain",
        replace_existing=True,
    )
    scheduler.add_job(
        run_daily_renewals_check,
        "cron",
        hour=7,
        minute=0,
        timezone="Europe/London",
        id="renewals_check",
        replace_existing=True,
    )
    scheduler.add_job(
        run_library_sync,
        "interval",
        minutes=30,
        id="library_sync",
        replace_existing=True,
    )
    scheduler.add_job(
        run_finance_coaching,
        "interval",
        minutes=15,
        id="finance_coaching",
        replace_existing=True,
    )
    from app.config import settings

    scheduler.add_job(
        run_finance_bank_sync,
        "interval",
        minutes=max(360, settings.finance_bank_sync_interval_minutes),
        id="finance_bank_sync",
        replace_existing=True,
    )
    scheduler.add_job(
        run_finance_bank_retry_poll,
        "interval",
        minutes=settings.finance_bank_retry_poll_interval_minutes,
        id="finance_bank_retry_poll",
        replace_existing=True,
    )
    scheduler.add_job(
        run_finance_nightly_refresh,
        "cron",
        hour=2,
        minute=0,
        timezone="Europe/London",
        id="finance_nightly_refresh",
        replace_existing=True,
    )
    scheduler.add_job(
        run_finance_weekly_opportunity_scan,
        "cron",
        day_of_week="sun",
        hour=3,
        minute=0,
        timezone="Europe/London",
        id="finance_weekly_opportunity_scan",
        replace_existing=True,
    )
    scheduler.add_job(
        run_finance_watch_refresh,
        "cron",
        hour=4,
        minute=0,
        timezone="Europe/London",
        id="finance_watch_refresh",
        replace_existing=True,
    )
    scheduler.add_job(
        run_fitness_maintenance,
        "cron",
        hour=3,
        minute=30,
        timezone="Europe/London",
        id="fitness_daily_maintenance",
        replace_existing=True,
    )
    scheduler.add_job(
        run_fitness_weekly_review_drafts,
        "cron",
        day_of_week="sun",
        hour=6,
        minute=0,
        timezone="Europe/London",
        id="fitness_weekly_review_drafts",
        replace_existing=True,
    )
    scheduler.add_job(
        run_withings_sync,
        "interval",
        minutes=settings.withings_sync_interval_minutes,
        id="withings_sync",
        replace_existing=True,
    )
    scheduler.add_job(
        run_withings_notification_retries,
        "interval",
        minutes=2,
        id="withings_notification_retries",
        replace_existing=True,
    )
    scheduler.add_job(
        run_intervals_delivery_retries,
        "interval",
        minutes=settings.intervals_icu_delivery_retry_minutes,
        id="intervals_delivery_retries",
        replace_existing=True,
    )
    scheduler.add_job(
        run_intervals_activity_imports,
        "interval",
        minutes=settings.intervals_icu_activity_sync_minutes,
        id="intervals_activity_imports",
        replace_existing=True,
    )
    # Run bin collection scraper once on startup so first deploy populates immediately
    scheduler.add_job(
        refresh_bin_collections,
        id="bin_collection_startup",
        next_run_time=datetime.now(timezone.utc) + timedelta(seconds=20),
        replace_existing=True,
    )
    # Interval jobs restart their clock after a deploy. Run one safe refresh at
    # startup so frequent deploys cannot indefinitely postpone term updates.
    scheduler.add_job(
        refresh_term_dates,
        id="term_date_refresh_startup",
        next_run_time=datetime.now(timezone.utc) + timedelta(seconds=50),
        replace_existing=True,
    )
    scheduler.add_job(
        run_fitness_maintenance,
        id="fitness_maintenance_startup",
        next_run_time=datetime.now(timezone.utc) + timedelta(seconds=80),
        replace_existing=True,
    )
    scheduler.start()
    logger.info(
        "Scheduler started — morning briefing at 06:30, expiry alerts at 08:00, "
        "term refresh every 13 weeks, "
        "bin collection refresh weekly, swimming lesson refresh every 4 weeks, "
        "external calendars every 30 minutes, library loans when due, "
        "Finance coaching every 15 minutes, "
        "bank data several times daily, Finance aggregates nightly, opportunity "
        "scans weekly, watch assets daily, Fitness assets daily and at startup, "
        "Fitness review drafts weekly and enabled Garmin activities periodically"
    )


def stop_scheduler() -> None:
    """Shut down the scheduler gracefully."""
    if scheduler.running:
        scheduler.shutdown(wait=False)
        logger.info("Scheduler stopped")


def get_scheduler_status() -> dict:
    """Return current scheduler status for healthcheck endpoints.

    Returns:
        dict with keys: running (bool), jobs (int), next_run (str | None).
    """
    running = scheduler.running
    jobs = scheduler.get_jobs()
    next_run = None
    if jobs:
        # Find the earliest next_run_time across all jobs
        next_times = [j.next_run_time for j in jobs if j.next_run_time is not None]
        if next_times:
            next_run = min(next_times).isoformat()

    return {
        "running": running,
        "jobs": len(jobs),
        "next_run": next_run,
    }

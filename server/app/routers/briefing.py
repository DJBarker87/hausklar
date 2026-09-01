"""Briefing API endpoints — generate and send morning briefings."""

import asyncio
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from app.auth import get_current_user
from app.database import database_lease, get_db
from app.services.briefing import generate_briefing_for_family
from app.services.glance import family_glance
from app.services.glance import medicine_glance
from app.services.callmebot import send_briefing_to_all
from app.services.host_integrations import require_host_integration_admin
from app.services.weather import cached_weather_summary, get_weather_summary
from app.middleware.rate_limit import RateLimiter, extract_client_ip
from app.routers.birthdays import list_birthdays
from app.routers.calendar import list_events
from app.routers.dog import get_status as get_dog_status
from app.routers.family import list_family_members
from app.routers.illness import list_illnesses
from app.routers.homework import upcoming_homework
from app.routers.insights import list_insights
from app.routers.meals import list_meal_plans
from app.routers.naps import active_naps
from app.routers.presents import upcoming_present_preparation
from app.routers.routines import get_active_routines
from app.routers.tasks import list_tasks
from app.services.coordination import tomorrow_card
from app.services.finance.coaching import finance_today_action
from app.services.facilities import quick_fact as facility_quick_fact
from app.services.photos import cached_photo_memories
from app.services.prep_packs import suggestions as prep_suggestions

router = APIRouter()
send_limiter = RateLimiter(max_attempts=2, window_seconds=3_600)
send_lock = asyncio.Lock()


def _local_day_window(timezone_name: str) -> tuple[str, str, str]:
    try:
        zone = ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError):
        zone = ZoneInfo("Europe/London")
    local_now = datetime.now(zone)
    start = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=1) - timedelta(microseconds=1)
    return start.date().isoformat(), start.isoformat(), end.isoformat()


async def _optional(name: str, awaitable, fallback, unavailable: list[str]):
    try:
        return await awaitable
    except Exception:
        unavailable.append(name)
        return fallback


async def _active_illness_readings(db, family_id: str) -> dict[str, list[dict]]:
    cursor = await db.execute(
        """SELECT tr.*
           FROM temperature_readings tr
           JOIN illnesses i ON i.id = tr.illness_id
           WHERE tr.family_id = ? AND tr.deleted_at IS NULL
             AND i.family_id = ? AND i.deleted_at IS NULL AND i.ended_at IS NULL
           ORDER BY tr.recorded_at""",
        (family_id, family_id),
    )
    grouped: dict[str, list[dict]] = {}
    for row in await cursor.fetchall():
        item = dict(row)
        grouped.setdefault(item["illness_id"], []).append(item)
    return grouped


@router.get("/weather")
async def get_weather(
    current_user: dict = Depends(get_current_user),
):
    """Return the cached household forecast without generating a full briefing."""
    return {"weather": await get_weather_summary()}


@router.get("/glance")
async def get_glance(
    timezone: str = Query("Europe/London", max_length=50),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Compact today snapshot for home-screen widgets."""
    return await family_glance(
        db,
        family_id=current_user["family_id"],
        timezone_name=timezone,
    )


@router.get("/today")
async def get_today_briefing(
    current_user: dict = Depends(get_current_user),
):
    """Generate and return today's briefing as JSON."""
    return await generate_briefing_for_family(current_user["family_id"])


@router.get("/dashboard")
async def get_today_dashboard(
    timezone: str = Query("Europe/London", max_length=50),
    current_user: dict = Depends(get_current_user),
):
    """One stable payload for the PWA and iOS Today screens.

    Optional household feeds fail independently, so one integration cannot
    blank the core calendar and task plan or cause late layout insertions.
    """
    day, day_start, day_end = _local_day_window(timezone)
    unavailable: list[str] = []
    # Keep the pool lease scoped to database materialisation only. Optional
    # network enrichments are deliberately scheduled after the connection is
    # released so a slow provider can never starve ordinary family requests.
    async with database_lease() as db:
        calls = [
            _optional(
                "events",
                list_events(
                    start=day_start,
                    end=day_end,
                    assigned_to=None,
                    offset=0,
                    limit=200,
                    current_user=current_user,
                    db=db,
                ),
                [],
                unavailable,
            ),
            _optional(
                "tasks",
                list_tasks(
                    status_filter="pending",
                    category=None,
                    assigned_to=None,
                    actionable="now",
                    order="attention",
                    offset=0,
                    limit=7,
                    current_user=current_user,
                    db=db,
                ),
                [],
                unavailable,
            ),
            _optional("naps", active_naps(sleep_type=None, current_user=current_user, db=db), [], unavailable),
            _optional(
                "illnesses",
                list_illnesses(
                    child_id=None,
                    active=True,
                    offset=0,
                    limit=200,
                    current_user=current_user,
                    db=db,
                ),
                [],
                unavailable,
            ),
            _optional(
                "routines",
                get_active_routines(start=day, end=day, current_user=current_user, db=db),
                [],
                unavailable,
            ),
            _optional(
                "meals",
                list_meal_plans(start=day, end=day, current_user=current_user, db=db),
                [],
                unavailable,
            ),
            _optional(
                "dog",
                get_dog_status(
                    timezone_name=timezone,
                    current_user=current_user,
                    db=db,
                ),
                None,
                unavailable,
            ),
            _optional("coordination", tomorrow_card(db, current_user), None, unavailable),
            _optional("insights", list_insights(current_user=current_user, db=db), [], unavailable),
            _optional(
                "prep_suggestions",
                prep_suggestions(
                    db,
                    family_id=current_user["family_id"],
                    timezone_name=timezone,
                    horizon_days=2,
                ),
                [],
                unavailable,
            ),
            _optional(
                "medicine",
                medicine_glance(db, family_id=current_user["family_id"]),
                [],
                unavailable,
            ),
            _optional(
                "birthdays",
                list_birthdays(
                    upcoming_days=0,
                    offset=0,
                    limit=10,
                    current_user=current_user,
                    db=db,
                ),
                [],
                unavailable,
            ),
            _optional(
                "homework",
                upcoming_homework(
                    db,
                    family_id=current_user["family_id"],
                    reference_date=datetime.fromisoformat(day).date(),
                ),
                [],
                unavailable,
            ),
            _optional(
                "presents",
                upcoming_present_preparation(
                    db,
                    family_id=current_user["family_id"],
                    current_user_id=current_user["id"],
                    reference_date=datetime.fromisoformat(day).date(),
                ),
                [],
                unavailable,
            ),
            _optional("family_members", list_family_members(current_user=current_user, db=db), [], unavailable),
            _optional(
                "illness_readings",
                _active_illness_readings(db, current_user["family_id"]),
                {},
                unavailable,
            ),
            _optional(
                "finance_action",
                finance_today_action(db, current_user),
                None,
                unavailable,
            ),
            _optional(
                "facility_quick_fact",
                facility_quick_fact(
                    db,
                    family_id=current_user["family_id"],
                    user_id=current_user["id"],
                    reference_date=datetime.fromisoformat(day).date(),
                ),
                None,
                unavailable,
            ),
        ]
        (
            events,
            tasks,
            naps,
            illnesses,
            routines,
            meals,
            dog,
            coordination,
            insights,
            prep,
            medicine,
            birthdays,
            homework,
            presents,
            family_members,
            illness_readings,
            finance_action,
            facilities,
        ) = await asyncio.gather(*calls)

    memories, weather = await asyncio.gather(
        cached_photo_memories(timezone_name=timezone),
        cached_weather_summary(),
    )

    return {
        "generated_at": datetime.now(ZoneInfo("UTC")).isoformat(),
        "date": day,
        "events": events,
        "tasks": tasks,
        "naps": naps,
        "illnesses": illnesses,
        "routines": routines,
        "meals": meals,
        "dog": dog,
        "coordination": coordination,
        "memories": memories,
        "insights": insights,
        "prep_suggestions": prep,
        "medicine": medicine,
        "birthdays": birthdays,
        "homework": homework,
        "presents": presents,
        "family_members": family_members,
        "illness_readings": illness_readings,
        "weather": weather,
        "finance_action": finance_action,
        "facility_quick_fact": facilities.model_dump(mode="json") if facilities else None,
        "unavailable": sorted(unavailable),
    }


@router.post("/send")
async def send_briefing(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """Generate today's briefing and send it via WhatsApp to Alex and Morgan."""
    require_host_integration_admin(current_user)
    key = f"briefing-send:{current_user['id']}:{extract_client_ip(request)}"
    send_limiter.ensure_allowed(key, detail_prefix="Too many briefing send requests")  # gitleaks:allow
    send_limiter.record_failure(key)
    if send_lock.locked():
        raise HTTPException(status_code=409, detail="A briefing send is already running")
    async with send_lock:
        briefing = await generate_briefing_for_family(current_user["family_id"])
        results = await send_briefing_to_all(briefing["message"])

    return {
        "briefing": briefing,
        "whatsapp_results": results,
    }

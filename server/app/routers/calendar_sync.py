"""Admin-managed external calendars and the private HausKlar ICS feed."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Response, status

from app.auth import get_current_user
from app.config import settings
from app.database import database_lease, get_db
from app.models.calendar import (
    CalendarFeedCreated,
    CalendarFeedStatus,
    CalendarEventResponse,
    CalendarSourceCreate,
    CalendarSourceResponse,
    CalendarSourceSyncResponse,
    CalendarSourceUpdate,
    CalendarSourceValidationResponse,
    SchoolRugbySettingsResponse,
    SchoolRugbySettingsUpdate,
    SchoolRugbyTeamListResponse,
    SchoolRugbyVenueUpdate,
)
from app.routers.calendar import _event_response
from app.services.calendar_sync import (
    CalendarSyncError,
    build_outbound_calendar,
    fetch_calendar,
    new_feed_token,
    parse_calendar,
    sync_calendar_source,
    token_hash,
    validate_public_https_url,
)
from app.services.calendar_overrides import soft_delete_overrides_for_sources
from app.services.calendar_recurrence import exception_keys_for_series
from app.services.school_rugby import (
    SCHOOL_RUGBY_AWAY_COLOR,
    SCHOOL_RUGBY_HOSTNAME,
    SCHOOL_RUGBY_SOURCE_COLOR,
    SCHOOL_RUGBY_SOURCE_KIND,
    SchoolRugbyError,
    apply_rugby_venue,
    discover_rugby_teams,
    parse_rugby_source_config,
    rugby_fixture_feed_url,
    rugby_source_config,
)
from app.services.family_people import family_people_exist
from app.services.record_history import save_history
from app.utils.encryption import encrypt_value

router = APIRouter()


def _require_admin(user: dict) -> None:
    if user.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")


def _source_response(row) -> CalendarSourceResponse:
    data = dict(row)
    data["enabled"] = bool(data["enabled"])
    return CalendarSourceResponse(**data)


async def _get_source(source_id: str, family_id: str):
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT * FROM calendar_sources WHERE id=? AND family_id=? AND deleted_at IS NULL",
            (source_id, family_id),
        )
        return await cursor.fetchone()


@router.get("/sources", response_model=list[CalendarSourceResponse])
async def list_calendar_sources(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM calendar_sources WHERE family_id=? AND deleted_at IS NULL "
        "AND COALESCE(source_kind, 'ics')='ics' ORDER BY name",
        (current_user["family_id"],),
    )
    return [_source_response(row) for row in await cursor.fetchall()]


@router.post("/sources/validate", response_model=CalendarSourceValidationResponse)
async def validate_calendar_source(
    body: CalendarSourceCreate,
    current_user: dict = Depends(get_current_user),
):
    """Check a private ICS address and parse it without storing the address."""
    _require_admin(current_user)
    if body.assigned_to:
        async with database_lease() as db:
            if not await family_people_exist(
                db, current_user["family_id"], [body.assigned_to]
            ):
                raise HTTPException(
                    status_code=422,
                    detail="Calendar person is not in this family",
                )
    try:
        url, hostname = await validate_public_https_url(body.url)
        fetched = await fetch_calendar(url)
        events = parse_calendar(
            fetched.body or b"",
            source_id="connection-check",
            assigned_to=body.assigned_to,
        )
    except CalendarSyncError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return CalendarSourceValidationResponse(
        hostname=hostname,
        event_count=len(events),
    )


@router.post(
    "/sources",
    response_model=CalendarSourceResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_calendar_source(
    body: CalendarSourceCreate,
    current_user: dict = Depends(get_current_user),
):
    _require_admin(current_user)
    try:
        url, hostname = await validate_public_https_url(body.url)
    except CalendarSyncError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    source_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        if body.assigned_to and not await family_people_exist(
            db, current_user["family_id"], [body.assigned_to]
        ):
            raise HTTPException(status_code=422, detail="Calendar person is not in this family")
        await db.execute(
            """INSERT INTO calendar_sources
               (id,family_id,name,encrypted_url,hostname,assigned_to,color,enabled,
                created_at,updated_at,created_by)
               VALUES (?,?,?,?,?,?,?,1,?,?,?)""",
            (
                source_id,
                current_user["family_id"],
                body.name.strip(),
                encrypt_value(url),
                hostname,
                body.assigned_to,
                body.color.upper(),
                now,
                now,
                current_user["id"],
            ),
        )
        await db.commit()
    try:
        await sync_calendar_source(source_id, family_id=current_user["family_id"])
    except CalendarSyncError:
        # Keep the source and its safe last_error so the URL can be corrected or retried.
        pass
    return _source_response(await _get_source(source_id, current_user["family_id"]))


@router.patch("/sources/{source_id}", response_model=CalendarSourceResponse)
async def update_calendar_source(
    source_id: str,
    body: CalendarSourceUpdate,
    current_user: dict = Depends(get_current_user),
):
    _require_admin(current_user)
    existing = await _get_source(source_id, current_user["family_id"])
    if not existing or existing["source_kind"] != "ics":
        raise HTTPException(status_code=404, detail="Calendar source not found")
    updates = body.model_dump(exclude_unset=True)
    if "url" in updates:
        try:
            url, hostname = await validate_public_https_url(updates.pop("url"))
        except CalendarSyncError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        updates["encrypted_url"] = encrypt_value(url)
        updates["hostname"] = hostname
        updates["etag"] = None
        updates["last_modified"] = None
    async with database_lease() as db:
        if updates.get("assigned_to") and not await family_people_exist(
            db, current_user["family_id"], [updates["assigned_to"]]
        ):
            raise HTTPException(status_code=422, detail="Calendar person is not in this family")
        if updates:
            await save_history(
                db,
                "calendar_sources",
                source_id,
                current_user["id"],
                family_id=current_user["family_id"],
            )
            updates["updated_at"] = datetime.now(timezone.utc).isoformat()
            if "enabled" in updates:
                updates["enabled"] = int(updates["enabled"])
            if "color" in updates and updates["color"]:
                updates["color"] = updates["color"].upper()
            clause = ", ".join(f"{key}=?" for key in updates)
            await db.execute(
                f"UPDATE calendar_sources SET {clause} WHERE id=? AND family_id=?",
                (*updates.values(), source_id, current_user["family_id"]),
            )
            await db.commit()
    return _source_response(await _get_source(source_id, current_user["family_id"]))


@router.delete("/sources/{source_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_calendar_source(
    source_id: str,
    current_user: dict = Depends(get_current_user),
):
    _require_admin(current_user)
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT * FROM calendar_sources WHERE id=? AND family_id=? AND deleted_at IS NULL "
            "AND COALESCE(source_kind, 'ics')='ics'",
            (source_id, current_user["family_id"]),
        )
        if not await cursor.fetchone():
            raise HTTPException(status_code=404, detail="Calendar source not found")
        await save_history(
            db,
            "calendar_sources",
            source_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        cursor = await db.execute(
            "SELECT id FROM calendar_events WHERE calendar_source_id=? AND family_id=? AND deleted_at IS NULL",
            (source_id, current_user["family_id"]),
        )
        source_events = await cursor.fetchall()
        source_event_ids = [row["id"] for row in source_events]
        for row in source_events:
            await save_history(
                db,
                "calendar_events",
                row["id"],
                current_user["id"],
                family_id=current_user["family_id"],
            )
        await soft_delete_overrides_for_sources(
            db,
            source_event_ids,
            family_id=current_user["family_id"],
            actor_id=current_user["id"],
            now=now,
        )
        await db.execute(
            "UPDATE calendar_events SET deleted_at=?,updated_at=? WHERE calendar_source_id=? AND family_id=? AND deleted_at IS NULL",
            (now, now, source_id, current_user["family_id"]),
        )
        await db.execute(
            "UPDATE calendar_sources SET deleted_at=?,enabled=0,updated_at=? WHERE id=? AND family_id=?",
            (now, now, source_id, current_user["family_id"]),
        )
        await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/sources/{source_id}/sync", response_model=CalendarSourceSyncResponse)
async def sync_calendar_source_now(
    source_id: str,
    current_user: dict = Depends(get_current_user),
):
    _require_admin(current_user)
    source = await _get_source(source_id, current_user["family_id"])
    if not source or source["source_kind"] != "ics":
        raise HTTPException(status_code=404, detail="Calendar source not found")
    try:
        return await sync_calendar_source(source_id, family_id=current_user["family_id"])
    except CalendarSyncError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


async def _rugby_settings(family_id: str) -> SchoolRugbySettingsResponse:
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT * FROM calendar_sources WHERE family_id=? AND source_kind=? "
            "AND deleted_at IS NULL LIMIT 1",
            (family_id, SCHOOL_RUGBY_SOURCE_KIND),
        )
        source_row = await cursor.fetchone()
        if not source_row:
            return SchoolRugbySettingsResponse()
        source = dict(source_row)
        cursor = await db.execute(
            "SELECT id,name FROM users WHERE family_id=? AND deleted_at IS NULL "
            "ORDER BY priority DESC, created_at",
            (family_id,),
        )
        people = [dict(row) for row in await cursor.fetchall()]
        cursor = await db.execute(
            "SELECT COUNT(*) AS count FROM calendar_events WHERE family_id=? "
            "AND calendar_source_id=? AND deleted_at IS NULL",
            (family_id, source["id"]),
        )
        fixture_count = int((await cursor.fetchone())["count"])
    try:
        config = parse_rugby_source_config(source.get("config_json"))
    except SchoolRugbyError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    owner = next((person for person in people if person["id"] == source["assigned_to"]), None)
    affected = [person for person in people if person["id"] != source["assigned_to"]]
    return SchoolRugbySettingsResponse(
        configured=True,
        source_id=source["id"],
        team_id=config["team_id"],
        team_name=config["team_name"],
        season=config["season"],
        owner_user_id=source["assigned_to"],
        owner_name=owner["name"] if owner else None,
        affected_user_ids=[person["id"] for person in affected],
        affected_names=[person["name"] for person in affected],
        fixture_count=fixture_count,
        last_synced_at=source.get("last_synced_at"),
        last_success_at=source.get("last_success_at"),
        last_error=source.get("last_error"),
    )


@router.get("/rugby/teams", response_model=SchoolRugbyTeamListResponse)
async def list_example_school_rugby_teams(current_user: dict = Depends(get_current_user)):
    """Return Example School's published Rugby Union teams for the current school season."""
    del current_user
    try:
        return SchoolRugbyTeamListResponse(**(await discover_rugby_teams()))
    except SchoolRugbyError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/rugby", response_model=SchoolRugbySettingsResponse)
async def get_example_school_rugby_settings(current_user: dict = Depends(get_current_user)):
    return await _rugby_settings(current_user["family_id"])


@router.put("/rugby", response_model=SchoolRugbySettingsResponse)
async def configure_example_school_rugby(
    body: SchoolRugbySettingsUpdate,
    current_user: dict = Depends(get_current_user),
):
    """Choose one team and immediately create its managed family fixture calendar."""
    _require_admin(current_user)
    try:
        published = await discover_rugby_teams()
        team = next((item for item in published["teams"] if item["id"] == body.team_id), None)
        if not team:
            raise SchoolRugbyError("The selected team is not published for this season")
        feed_url = rugby_fixture_feed_url(team["id"])
        fetched_feed = await fetch_calendar(feed_url)
        config_json = rugby_source_config(
            team_id=team["id"],
            team_name=team["name"],
            season=published["season"],
        )
    except (SchoolRugbyError, CalendarSyncError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    family_id = current_user["family_id"]
    source_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        await db.execute("BEGIN IMMEDIATE")
        cursor = await db.execute(
            "SELECT * FROM calendar_sources WHERE family_id=? AND source_kind=? "
            "AND deleted_at IS NULL LIMIT 1",
            (family_id, SCHOOL_RUGBY_SOURCE_KIND),
        )
        existing = await cursor.fetchone()
        if existing:
            source_id = existing["id"]
            await save_history(
                db,
                "calendar_sources",
                source_id,
                current_user["id"],
                family_id=family_id,
            )
            await db.execute(
                """UPDATE calendar_sources SET name=?,encrypted_url=?,hostname=?,assigned_to=?,
                   source_kind=?,config_json=?,color=?,enabled=1,etag=NULL,last_modified=NULL,
                   last_error=NULL,updated_at=? WHERE id=? AND family_id=?""",
                (
                    f"Example School {team['name']} rugby",
                    encrypt_value(feed_url),
                    SCHOOL_RUGBY_HOSTNAME,
                    current_user["id"],
                    SCHOOL_RUGBY_SOURCE_KIND,
                    config_json,
                    SCHOOL_RUGBY_SOURCE_COLOR,
                    now,
                    source_id,
                    family_id,
                ),
            )
        else:
            await db.execute(
                """INSERT INTO calendar_sources
                   (id,family_id,name,encrypted_url,hostname,assigned_to,source_kind,config_json,
                    color,enabled,created_at,updated_at,created_by)
                   VALUES (?,?,?,?,?,?,?,?,?,1,?,?,?)""",
                (
                    source_id,
                    family_id,
                    f"Example School {team['name']} rugby",
                    encrypt_value(feed_url),
                    SCHOOL_RUGBY_HOSTNAME,
                    current_user["id"],
                    SCHOOL_RUGBY_SOURCE_KIND,
                    config_json,
                    SCHOOL_RUGBY_SOURCE_COLOR,
                    now,
                    now,
                    current_user["id"],
                ),
            )
        await db.commit()
    try:
        await sync_calendar_source(
            source_id,
            family_id=family_id,
            fetched_calendar=fetched_feed,
        )
    except CalendarSyncError:
        # Keep the selected team and expose the safe retry state in the response.
        pass
    return await _rugby_settings(family_id)


@router.post("/rugby/sync", response_model=CalendarSourceSyncResponse)
async def sync_example_school_rugby_now(current_user: dict = Depends(get_current_user)):
    _require_admin(current_user)
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT id FROM calendar_sources WHERE family_id=? AND source_kind=? "
            "AND deleted_at IS NULL",
            (current_user["family_id"], SCHOOL_RUGBY_SOURCE_KIND),
        )
        source = await cursor.fetchone()
    if not source:
        raise HTTPException(status_code=404, detail="Choose a rugby team first")
    try:
        return await sync_calendar_source(source["id"], family_id=current_user["family_id"])
    except CalendarSyncError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.put(
    "/rugby/fixtures/{event_id}/venue",
    response_model=CalendarEventResponse,
)
async def override_example_school_rugby_venue(
    event_id: str,
    body: SchoolRugbyVenueUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        """SELECT ce.*,cs.source_kind FROM calendar_events ce
           JOIN calendar_sources cs ON cs.id=ce.calendar_source_id
           WHERE ce.id=? AND ce.family_id=? AND ce.deleted_at IS NULL
             AND cs.deleted_at IS NULL""",
        (event_id, current_user["family_id"]),
    )
    row = await cursor.fetchone()
    if not row or row["source_kind"] != SCHOOL_RUGBY_SOURCE_KIND:
        raise HTTPException(status_code=404, detail="Rugby fixture not found")
    source_venue = row["rugby_source_venue"]
    if source_venue not in {"home", "away"}:
        raise HTTPException(status_code=409, detail="Rugby fixture venue is unavailable")
    override = None if body.venue == source_venue else body.venue
    updated = apply_rugby_venue(dict(row), body.venue)
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db,
        "calendar_events",
        event_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    await db.execute(
        """UPDATE calendar_events SET title=?,location=?,color=?,rugby_venue_override=?,
           updated_at=?,client_id=?,client_timestamp=? WHERE id=? AND family_id=?""",
        (
            updated["title"],
            updated["location"],
            SCHOOL_RUGBY_AWAY_COLOR if body.venue == "away" else None,
            override,
            now,
            body.client_id,
            body.client_timestamp,
            event_id,
            current_user["family_id"],
        ),
    )
    await db.commit()
    return await _event_response(db, event_id, current_user["family_id"])


@router.get("/feed", response_model=CalendarFeedStatus)
async def calendar_feed_status(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT token_prefix FROM calendar_feed_tokens WHERE family_id=? AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1",
        (current_user["family_id"],),
    )
    row = await cursor.fetchone()
    return CalendarFeedStatus(
        configured=bool(row),
        token_prefix=row["token_prefix"] if row else None,
        feed_url=None,
    )


@router.post("/feed/rotate", response_model=CalendarFeedCreated)
async def rotate_calendar_feed(
    current_user: dict = Depends(get_current_user),
):
    _require_admin(current_user)
    token = new_feed_token()
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT id FROM calendar_feed_tokens WHERE family_id=? AND deleted_at IS NULL",
            (current_user["family_id"],),
        )
        for row in await cursor.fetchall():
            await save_history(
                db,
                "calendar_feed_tokens",
                row["id"],
                current_user["id"],
                family_id=current_user["family_id"],
            )
        await db.execute(
            "UPDATE calendar_feed_tokens SET deleted_at=?,updated_at=? WHERE family_id=? AND deleted_at IS NULL",
            (now, now, current_user["family_id"]),
        )
        await db.execute(
            """INSERT INTO calendar_feed_tokens
               (id,family_id,token_hash,token_prefix,created_at,updated_at,created_by)
               VALUES (?,?,?,?,?,?,?)""",
            (
                str(uuid.uuid4()),
                current_user["family_id"],
                token_hash(token),
                token[:8],
                now,
                now,
                current_user["id"],
            ),
        )
        await db.commit()
    url = f"{settings.web_app_url.rstrip('/')}/api/calendar/feed/{token}.ics"
    return CalendarFeedCreated(
        configured=True,
        token_prefix=token[:8],
        feed_url=url,
        token=token,
    )


@router.delete("/feed", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_calendar_feed(
    current_user: dict = Depends(get_current_user),
):
    _require_admin(current_user)
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT id FROM calendar_feed_tokens WHERE family_id=? AND deleted_at IS NULL",
            (current_user["family_id"],),
        )
        rows = await cursor.fetchall()
        for row in rows:
            await save_history(
                db,
                "calendar_feed_tokens",
                row["id"],
                current_user["id"],
                family_id=current_user["family_id"],
            )
        await db.execute(
            "UPDATE calendar_feed_tokens SET deleted_at=?,updated_at=? WHERE family_id=? AND deleted_at IS NULL",
            (now, now, current_user["family_id"]),
        )
        await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/feed/{token}.ics", include_in_schema=False)
async def download_calendar_feed(token: str):
    if len(token) < 32 or len(token) > 128:
        raise HTTPException(status_code=404, detail="Calendar feed not found")
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT family_id FROM calendar_feed_tokens WHERE token_hash=? AND deleted_at IS NULL",
            (token_hash(token),),
        )
        feed = await cursor.fetchone()
        if not feed:
            raise HTTPException(status_code=404, detail="Calendar feed not found")
        cursor = await db.execute(
            """SELECT * FROM calendar_events
               WHERE family_id=? AND deleted_at IS NULL AND calendar_source_id IS NULL
                 AND NOT EXISTS (
                     SELECT 1 FROM calendar_events replacement
                     WHERE replacement.overridden_event_id = calendar_events.id
                       AND replacement.family_id = calendar_events.family_id
                       AND replacement.deleted_at IS NULL
                 )
               ORDER BY start_time LIMIT 5000""",
            (feed["family_id"],),
        )
        rows = [dict(row) for row in await cursor.fetchall()]
        excluded_occurrences = await exception_keys_for_series(
            db,
            family_id=feed["family_id"],
            series_ids=[row["id"] for row in rows if row.get("recurrence_rule")],
        )
    return Response(
        content=build_outbound_calendar(rows, excluded_occurrences),
        media_type="text/calendar; charset=utf-8",
        headers={
            "Cache-Control": "private, no-store",
            "Content-Disposition": 'inline; filename="hausklar-family.ics"',
        },
    )

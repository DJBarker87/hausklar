"""Fitness-owned menstrual-cycle tracking and read-only calendar projections."""

from __future__ import annotations

from datetime import date, datetime, time, timedelta

from app.models.calendar import CalendarEventResponse
from app.models.cycles import (
    CycleSettingsUpdate,
    FitnessCycleProfileResponse,
    FitnessCycleSettingsPayload,
    FitnessPeriodStartPayload,
    FitnessPeriodStartResponse,
)
from app.services.fitness.common import (
    FitnessConflictError,
    FitnessNotFoundError,
    insert_owned,
    new_id,
    now_iso,
    owned_row,
    soft_delete_owned,
    update_owned,
)

CYCLE_DISCLAIMER = (
    "Cycle dates are estimates for planning only, not medical advice or contraception guidance."
)


class CycleWriteConflictError(FitnessConflictError):
    """A client-generated cycle operation ID was reused for different data."""


class CycleRecordNotFoundError(FitnessNotFoundError):
    """An owned cycle record was not found."""


def settings_from_legacy(body: CycleSettingsUpdate) -> FitnessCycleSettingsPayload:
    """Preserve the legacy single-consent visibility semantics."""
    return FitnessCycleSettingsPayload(
        id=body.id,
        cycle_length_days=body.cycle_length_days,
        show_period_starts=body.show_period_starts,
        show_predicted_period=body.show_predicted_period,
        show_estimated_ovulation=body.show_estimated_ovulation,
        share_period_starts_with_adults=(
            body.share_with_adults and body.show_period_starts
        ),
        share_predicted_period_with_adults=(
            body.share_with_adults and body.show_predicted_period
        ),
        share_estimated_ovulation_with_adults=(
            body.share_with_adults and body.show_estimated_ovulation
        ),
    )


def _settings_values(body: FitnessCycleSettingsPayload) -> dict:
    return body.model_dump(
        exclude={"id", "client_id", "client_timestamp"},
    )


async def upsert_cycle_settings(
    db,
    *,
    body: FitnessCycleSettingsPayload,
    user: dict,
    settings_id: str | None = None,
    client_id: str | None = None,
    client_timestamp: str | None = None,
    now: str | None = None,
    adopt_existing_identity: bool = False,
) -> str:
    """Create, restore, or update the authenticated owner's canonical settings."""
    timestamp = now or now_iso()
    requested_id = settings_id or (str(body.id) if body.id else None)
    active = await (
        await db.execute(
            "SELECT * FROM health_cycle_settings WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    effective_client_id = client_id if client_id is not None else body.client_id
    effective_client_timestamp = (
        client_timestamp if client_timestamp is not None else body.client_timestamp
    )
    values = _settings_values(body)

    if active is not None:
        if (
            requested_id is not None
            and requested_id != active["id"]
            and not adopt_existing_identity
        ):
            raise CycleWriteConflictError(
                "Cycle settings identity does not match this owner"
            )
        await update_owned(
            db,
            table="health_cycle_settings",
            record_id=active["id"],
            values=values,
            user=user,
            now=timestamp,
            client_id=effective_client_id,
            client_timestamp=effective_client_timestamp,
        )
        return active["id"]

    identifier = requested_id or new_id()
    reused = await (
        await db.execute("SELECT * FROM health_cycle_settings WHERE id = ?", (identifier,))
    ).fetchone()
    if reused is not None:
        if (
            reused["family_id"] != user["family_id"]
            or reused["owner_user_id"] != user["id"]
        ):
            raise CycleWriteConflictError(
                "Cycle settings operation ID was already used for a different request"
            )
        await update_owned(
            db,
            table="health_cycle_settings",
            record_id=identifier,
            values=values,
            user=user,
            now=timestamp,
            client_id=effective_client_id,
            client_timestamp=effective_client_timestamp,
            restore=True,
        )
        return identifier

    await insert_owned(
        db,
        table="health_cycle_settings",
        record_id=identifier,
        values={**values, "revision": 1},
        user=user,
        now=timestamp,
        client_id=effective_client_id,
        client_timestamp=effective_client_timestamp,
    )
    return identifier


async def create_period_start(
    db,
    *,
    body: FitnessPeriodStartPayload,
    user: dict,
    period_id: str | None = None,
    client_id: str | None = None,
    client_timestamp: str | None = None,
    now: str | None = None,
) -> FitnessPeriodStartResponse:
    """Create an owned period start and acknowledge exact operation replays."""
    timestamp = now or now_iso()
    requested_id = period_id or (str(body.id) if body.id else new_id())
    settings = await (
        await db.execute(
            "SELECT 1 FROM health_cycle_settings WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if settings is None:
        raise CycleRecordNotFoundError("Cycle tracking is not set up")

    existing = await (
        await db.execute(
            "SELECT * FROM health_cycle_period_starts WHERE id = ?", (requested_id,)
        )
    ).fetchone()
    if existing is not None:
        if (
            existing["family_id"] != user["family_id"]
            or existing["owner_user_id"] != user["id"]
            or existing["deleted_at"] is not None
            or existing["started_on"] != body.started_on.isoformat()
        ):
            raise CycleWriteConflictError(
                "Period-start operation ID was already used for a different request"
            )
        return _period_response(existing)

    duplicate = await (
        await db.execute(
            "SELECT id FROM health_cycle_period_starts WHERE family_id = ? "
            "AND owner_user_id = ? AND started_on = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], body.started_on.isoformat()),
        )
    ).fetchone()
    if duplicate is not None:
        raise CycleWriteConflictError("That period start is already recorded")

    await insert_owned(
        db,
        table="health_cycle_period_starts",
        record_id=requested_id,
        values={"started_on": body.started_on, "revision": 1},
        user=user,
        now=timestamp,
        client_id=client_id if client_id is not None else body.client_id,
        client_timestamp=(
            client_timestamp
            if client_timestamp is not None
            else body.client_timestamp
        ),
    )
    return FitnessPeriodStartResponse(
        id=requested_id,
        started_on=body.started_on,
        revision=1,
        created_at=timestamp,
        updated_at=timestamp,
    )


async def upsert_period_start(
    db,
    *,
    body: FitnessPeriodStartPayload,
    user: dict,
    period_id: str,
) -> FitnessPeriodStartResponse:
    """Fitness-sync upsert, including restoration of an owned tombstone."""
    settings = await (
        await db.execute(
            "SELECT 1 FROM health_cycle_settings WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if settings is None:
        raise CycleRecordNotFoundError("Cycle tracking is not set up")
    existing = await (
        await db.execute(
            "SELECT * FROM health_cycle_period_starts WHERE id = ?", (period_id,)
        )
    ).fetchone()
    if existing is not None and (
        existing["family_id"] != user["family_id"]
        or existing["owner_user_id"] != user["id"]
        or existing["started_on"] != body.started_on.isoformat()
    ):
        raise CycleWriteConflictError(
            "Period-start operation ID was already used for a different request"
        )
    duplicate = await (
        await db.execute(
            "SELECT id FROM health_cycle_period_starts WHERE family_id = ? "
            "AND owner_user_id = ? AND started_on = ? AND id <> ? "
            "AND deleted_at IS NULL",
            (
                user["family_id"],
                user["id"],
                body.started_on.isoformat(),
                period_id,
            ),
        )
    ).fetchone()
    if duplicate is not None:
        raise CycleWriteConflictError("That period start is already recorded")
    if existing is None:
        return await create_period_start(
            db,
            body=body,
            user=user,
            period_id=period_id,
        )
    revision = await update_owned(
        db,
        table="health_cycle_period_starts",
        record_id=period_id,
        values={"started_on": body.started_on},
        user=user,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
        restore=existing["deleted_at"] is not None,
    )
    row = await owned_row(
        db,
        table="health_cycle_period_starts",
        record_id=period_id,
        user=user,
    )
    response = _period_response(row)
    return response.model_copy(update={"revision": revision})


async def soft_delete_period_start(
    db,
    *,
    period_id: str,
    user: dict,
    now: str | None = None,
    client_id: str | None = None,
    client_timestamp: str | None = None,
) -> int:
    """Soft-delete an owned start; an exact tombstone replay is successful."""
    try:
        row = await owned_row(
            db,
            table="health_cycle_period_starts",
            record_id=period_id,
            user=user,
            include_deleted=True,
        )
    except FitnessNotFoundError as exc:
        raise CycleRecordNotFoundError("Period start not found") from exc
    if row["deleted_at"] is not None:
        return int(row["revision"])
    return await update_owned(
        db,
        table="health_cycle_period_starts",
        record_id=period_id,
        values={"deleted_at": now or now_iso()},
        user=user,
        now=now,
        client_id=client_id,
        client_timestamp=client_timestamp,
    )


async def soft_delete_cycle_settings(
    db, *, settings_id: str, user: dict, now: str | None = None
) -> int:
    return await soft_delete_owned(
        db,
        table="health_cycle_settings",
        record_id=settings_id,
        user=user,
        now=now,
    )


def calculate_cycle_dates(
    latest_period_start: date | None,
    cycle_length_days: int,
) -> tuple[date | None, date | None]:
    if latest_period_start is None:
        return None, None
    next_period = latest_period_start + timedelta(days=cycle_length_days)
    ovulation = next_period - timedelta(days=14)
    if ovulation <= latest_period_start:
        ovulation = None
    return next_period, ovulation


def _period_response(row) -> FitnessPeriodStartResponse:
    return FitnessPeriodStartResponse(
        id=row["id"],
        started_on=date.fromisoformat(row["started_on"]),
        revision=int(row["revision"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


async def visible_cycle_profiles(
    db,
    *,
    family_id: str,
    current_user_id: str,
) -> list[FitnessCycleProfileResponse]:
    """Return own profile plus independently consented categories for adults."""
    rows = await (
        await db.execute(
            "SELECT cs.*, u.name AS owner_name FROM health_cycle_settings cs "
            "JOIN users u ON u.id = cs.owner_user_id AND u.family_id = cs.family_id "
            "AND u.deleted_at IS NULL WHERE cs.family_id = ? AND cs.deleted_at IS NULL "
            "AND (cs.owner_user_id = ? OR cs.share_period_starts_with_adults = 1 "
            "OR cs.share_predicted_period_with_adults = 1 "
            "OR cs.share_estimated_ovulation_with_adults = 1) ORDER BY u.name",
            (family_id, current_user_id),
        )
    ).fetchall()
    if not rows:
        return []

    owners = [row["owner_user_id"] for row in rows]
    placeholders = ",".join("?" for _ in owners)
    period_rows = await (
        await db.execute(
            f"SELECT * FROM health_cycle_period_starts WHERE family_id = ? "
            f"AND owner_user_id IN ({placeholders}) AND deleted_at IS NULL "
            "ORDER BY started_on DESC, created_at DESC",
            (family_id, *owners),
        )
    ).fetchall()
    periods_by_owner: dict[str, list[FitnessPeriodStartResponse]] = {
        owner: [] for owner in owners
    }
    for row in period_rows:
        periods_by_owner[row["owner_user_id"]].append(_period_response(row))

    profiles: list[FitnessCycleProfileResponse] = []
    for row in rows:
        is_owner = row["owner_user_id"] == current_user_id
        periods = periods_by_owner[row["owner_user_id"]]
        latest = periods[0].started_on if periods else None
        next_period, ovulation = calculate_cycle_dates(latest, row["cycle_length_days"])
        show_period_starts = (
            bool(row["show_period_starts"])
            if is_owner
            else bool(row["share_period_starts_with_adults"])
        )
        show_predicted_period = (
            bool(row["show_predicted_period"])
            if is_owner
            else bool(row["share_predicted_period_with_adults"])
        )
        show_estimated_ovulation = (
            bool(row["show_estimated_ovulation"])
            if is_owner
            else bool(row["share_estimated_ovulation_with_adults"])
        )
        profiles.append(
            FitnessCycleProfileResponse(
                id=row["id"],
                owner_user_id=row["owner_user_id"],
                owner_name=row["owner_name"],
                is_owner=is_owner,
                cycle_length_days=row["cycle_length_days"],
                show_period_starts=show_period_starts,
                show_predicted_period=show_predicted_period,
                show_estimated_ovulation=show_estimated_ovulation,
                share_period_starts_with_adults=bool(
                    row["share_period_starts_with_adults"]
                ),
                share_predicted_period_with_adults=bool(
                    row["share_predicted_period_with_adults"]
                ),
                share_estimated_ovulation_with_adults=bool(
                    row["share_estimated_ovulation_with_adults"]
                ),
                latest_period_start=(
                    latest if is_owner or show_period_starts else None
                ),
                predicted_next_period=(
                    next_period if is_owner or show_predicted_period else None
                ),
                estimated_ovulation=(
                    ovulation if is_owner or show_estimated_ovulation else None
                ),
                period_starts=periods if is_owner or show_period_starts else [],
                revision=int(row["revision"]),
                created_at=row["created_at"],
                updated_at=row["updated_at"],
            )
        )
    return profiles


def _within(day: date, start: datetime, end: datetime) -> bool:
    day_start = datetime.combine(day, time.min, tzinfo=start.tzinfo)
    day_end = day_start + timedelta(days=1)
    return day_start < end and day_end > start


def _projection(
    *,
    identifier: str,
    title: str,
    day: date,
    owner_user_id: str,
    event_type: str,
    description: str,
    created_at: str,
    updated_at: str,
) -> CalendarEventResponse:
    return CalendarEventResponse(
        id=identifier,
        title=title,
        description=description,
        start_time=day.isoformat(),
        end_time=None,
        all_day=True,
        recurrence_rule=None,
        location=None,
        family_member_ids=[owner_user_id],
        affected_member_ids=None,
        assigned_to=owner_user_id,
        event_type=event_type,
        exertion=0,
        calendar_source_id=None,
        source_name="Cycle tracking",
        source_color="#E11D74",
        read_only=True,
        created_at=created_at,
        updated_at=updated_at,
        created_by=owner_user_id,
    )


async def calendar_cycle_projections(
    db,
    *,
    family_id: str,
    current_user_id: str,
    range_start: datetime,
    range_end: datetime,
) -> list[CalendarEventResponse]:
    """Project consent-filtered cycle records as read-only calendar events."""
    profiles = await visible_cycle_profiles(
        db,
        family_id=family_id,
        current_user_id=current_user_id,
    )
    events: list[CalendarEventResponse] = []
    for profile in profiles:
        if profile.show_period_starts:
            for period in profile.period_starts:
                if _within(period.started_on, range_start, range_end):
                    events.append(
                        _projection(
                            identifier=f"cycle:{profile.id}:period:{period.id}",
                            title="Period started",
                            day=period.started_on,
                            owner_user_id=profile.owner_user_id,
                            event_type="cycle_period_start",
                            description="Recorded period start.",
                            created_at=period.created_at,
                            updated_at=period.updated_at,
                        )
                    )
        if (
            profile.show_predicted_period
            and profile.predicted_next_period
            and _within(profile.predicted_next_period, range_start, range_end)
        ):
            events.append(
                _projection(
                    identifier=f"cycle:{profile.id}:predicted-period",
                    title="Predicted period",
                    day=profile.predicted_next_period,
                    owner_user_id=profile.owner_user_id,
                    event_type="cycle_predicted_period",
                    description=CYCLE_DISCLAIMER,
                    created_at=profile.created_at,
                    updated_at=profile.updated_at,
                )
            )
        if (
            profile.show_estimated_ovulation
            and profile.estimated_ovulation
            and _within(profile.estimated_ovulation, range_start, range_end)
        ):
            events.append(
                _projection(
                    identifier=f"cycle:{profile.id}:estimated-ovulation",
                    title="Estimated ovulation",
                    day=profile.estimated_ovulation,
                    owner_user_id=profile.owner_user_id,
                    event_type="cycle_estimated_ovulation",
                    description=CYCLE_DISCLAIMER,
                    created_at=profile.created_at,
                    updated_at=profile.updated_at,
                )
            )
    return events

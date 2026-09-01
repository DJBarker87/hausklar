"""Idempotent HealthKit workout ingress with exact source provenance."""

from __future__ import annotations

import json
from datetime import timezone
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.fitness_registry import SPORTS
from app.models.fitness_activity import (
    HealthKitWorkoutImport,
    HealthKitWorkoutImportResponse,
    HealthKitWorkoutSourceMetadata,
)
from app.models.fitness_recovery import SourceRecordPayload
from app.services.fitness import activities, recovery
from app.services.fitness.common import (
    FitnessConflictError,
    insert_owned,
    new_id,
    owned_row,
    soft_delete_owned,
    update_owned,
)


SPORTS_BY_KEY = {item["key"]: item for item in SPORTS}


async def active_workout_sources(
    db, *, user: dict, workout_uuid: UUID
) -> list[HealthKitWorkoutSourceMetadata]:
    rows = await (
        await db.execute(
            "SELECT s.id, s.source_namespace, s.source_object_id, "
            "s.origin_provider_key, s.external_object_id, "
            "COALESCE((SELECT l.activity_id FROM health_activity_source_records l "
            "WHERE l.source_record_id = s.id AND l.family_id = s.family_id "
            "AND l.owner_user_id = s.owner_user_id AND l.deleted_at IS NULL "
            "ORDER BY CASE l.role WHEN 'primary' THEN 0 ELSE 1 END, l.created_at LIMIT 1), "
            "s.domain_entity_id) AS activity_id FROM health_source_records s "
            "WHERE s.family_id = ? AND s.owner_user_id = ? "
            "AND s.record_kind = 'activity' AND s.sample_type = 'workout' "
            "AND s.transport_key = 'healthkit' AND s.source_object_id = ? "
            "AND s.state = 'active' AND s.deleted_at IS NULL "
            "ORDER BY s.created_at, s.id",
            (user["family_id"], user["id"], str(workout_uuid)),
        )
    ).fetchall()
    return [
        HealthKitWorkoutSourceMetadata(
            source_record_id=row["id"],
            source_bundle_identifier=row["source_namespace"],
            workout_uuid=row["source_object_id"],
            origin_provider_key=row["origin_provider_key"],
            external_uuid=row["external_object_id"],
            activity_id=row["activity_id"],
        )
        for row in rows
    ]


def _source_values(body: HealthKitWorkoutImport, activity_id: str | None) -> dict:
    metadata = {"healthkit_workout_uuid": str(body.workout_uuid)}
    if not body.deleted:
        metadata.update(
            {
                "sport_key": body.sport_key,
                "sub_sport_key": body.sub_sport_key,
                "title": body.title,
                "started_at_utc": body.started_at_utc.astimezone(timezone.utc).isoformat()
                if body.started_at_utc
                else None,
                "ended_at_utc": body.ended_at_utc.astimezone(timezone.utc).isoformat()
                if body.ended_at_utc
                else None,
                "duration_s": body.duration_s,
                "distance_m": body.distance_m,
                "energy_kcal": body.energy_kcal,
                "local_timezone": body.local_timezone,
            }
        )
    return {
        "record_kind": "activity",
        "sample_type": "workout",
        "transport_key": "healthkit",
        "origin_provider_key": body.origin_provider_key,
        "source_namespace": body.source_bundle_identifier,
        "source_object_id": str(body.workout_uuid),
        "external_object_id": body.external_uuid,
        "source_device_identifier": body.source_device_identifier,
        "source_name": body.source_name,
        "product_type": body.product_type,
        "device_json": {},
        "metadata_json": metadata,
        "domain_entity_type": "activity" if activity_id else None,
        "domain_entity_id": activity_id,
        "state": "active",
    }


def _activity_values(body: HealthKitWorkoutImport, source_id: str) -> dict:
    assert body.sport_key is not None
    assert body.started_at_utc is not None and body.ended_at_utc is not None
    assert body.duration_s is not None and body.local_timezone is not None
    zone = ZoneInfo(body.local_timezone)
    started = body.started_at_utc.astimezone(timezone.utc)
    ended = body.ended_at_utc.astimezone(timezone.utc)
    sport = SPORTS_BY_KEY[body.sport_key]
    return {
        "sport_key": body.sport_key,
        "sub_sport_key": body.sub_sport_key,
        "title": body.title or sport["display_name"],
        "status": "completed",
        "primary_source_record_id": source_id,
        "started_at_utc": started,
        "ended_at_utc": ended,
        "local_timezone": body.local_timezone,
        "local_calendar_date": started.astimezone(zone).date(),
        "elapsed_duration_s": (ended - started).total_seconds(),
        "timer_duration_s": body.duration_s,
        "moving_duration_s": body.duration_s,
        "distance_m": body.distance_m,
        "energy_kcal": body.energy_kcal,
        "measurement_quality": "measured",
        "import_state": "complete",
        "parser_version": "healthkit-workout-v1",
        "revision": 1,
    }


def _stored_equal(row, values: dict, *, ignored: set[str] = frozenset()) -> bool:
    for key, expected in values.items():
        if key in ignored or key == "revision":
            continue
        if hasattr(expected, "isoformat"):
            expected = expected.isoformat()
        actual = row[key]
        if key in {"device_json", "metadata_json"}:
            try:
                actual = json.loads(actual or "{}")
            except json.JSONDecodeError:
                return False
        if actual != expected:
            return False
    return True


async def _exact_source(db, *, user: dict, body: HealthKitWorkoutImport):
    return await (
        await db.execute(
            "SELECT * FROM health_source_records WHERE family_id = ? "
            "AND owner_user_id = ? AND record_kind = 'activity' "
            "AND transport_key = 'healthkit' AND source_namespace = ? "
            "AND source_object_id = ? ORDER BY deleted_at IS NULL DESC LIMIT 1",
            (
                user["family_id"],
                user["id"],
                body.source_bundle_identifier,
                str(body.workout_uuid),
            ),
        )
    ).fetchone()


async def _source_link(db, *, user: dict, source):
    if source is None:
        return None
    return await (
        await db.execute(
            "SELECT * FROM health_activity_source_records WHERE family_id = ? "
            "AND owner_user_id = ? AND source_record_id = ? "
            "ORDER BY deleted_at IS NULL DESC LIMIT 1",
            (user["family_id"], user["id"], source["id"]),
        )
    ).fetchone()


async def _external_activity_id(db, *, user: dict, body: HealthKitWorkoutImport):
    if not body.external_uuid:
        return None
    row = await (
        await db.execute(
            "SELECT l.activity_id FROM health_source_records s "
            "JOIN health_activity_source_records l ON l.source_record_id = s.id "
            "AND l.family_id = s.family_id AND l.owner_user_id = s.owner_user_id "
            "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.record_kind = 'activity' "
            "AND s.origin_provider_key = ? AND s.external_object_id = ? "
            "AND s.deleted_at IS NULL AND s.state = 'active' AND l.deleted_at IS NULL "
            "ORDER BY CASE l.role WHEN 'primary' THEN 0 ELSE 1 END LIMIT 1",
            (
                user["family_id"],
                user["id"],
                body.origin_provider_key,
                body.external_uuid,
            ),
        )
    ).fetchone()
    return row["activity_id"] if row else None


async def _upsert_link(db, *, user: dict, activity_id: str, source_id: str, role: str) -> None:
    row = await (
        await db.execute(
            "SELECT * FROM health_activity_source_records WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND source_record_id = ? "
            "ORDER BY deleted_at IS NULL DESC LIMIT 1",
            (user["family_id"], user["id"], activity_id, source_id),
        )
    ).fetchone()
    if row is None:
        await insert_owned(
            db,
            table="health_activity_source_records",
            record_id=new_id(),
            values={
                "activity_id": activity_id,
                "source_record_id": source_id,
                "role": role,
                "revision": 1,
            },
            user=user,
        )
    else:
        await update_owned(
            db,
            table="health_activity_source_records",
            record_id=row["id"],
            values={"role": role},
            user=user,
            restore=True,
            record_sync_change=False,
        )


async def import_healthkit_workout(
    db, *, user: dict, body: HealthKitWorkoutImport
) -> HealthKitWorkoutImportResponse:
    await db.execute("BEGIN IMMEDIATE")
    exact = await _exact_source(db, user=user, body=body)
    exact_link = await _source_link(db, user=user, source=exact)
    activity_id = (exact_link["activity_id"] if exact_link else None) or (
        exact["domain_entity_id"] if exact else None
    )
    if body.deleted:
        if exact is not None and exact["deleted_at"] is not None:
            return HealthKitWorkoutImportResponse(
                status="already_deleted",
                source_record_id=exact["id"],
                activity_id=activity_id,
                deleted=True,
            )
        if exact is None:
            source_id = new_id()
            await recovery.upsert_source_record(
                db,
                user=user,
                record_id=source_id,
                body=SourceRecordPayload.model_validate(_source_values(body, None)),
            )
            exact = await _exact_source(db, user=user, body=body)
        assert exact is not None
        await recovery.delete_source_record(db, user=user, source_id=exact["id"])
        if activity_id:
            surviving = await (
                await db.execute(
                    "SELECT 1 FROM health_activity_source_records l "
                    "JOIN health_source_records s ON s.id = l.source_record_id "
                    "WHERE l.family_id = ? AND l.owner_user_id = ? AND l.activity_id = ? "
                    "AND l.deleted_at IS NULL AND s.deleted_at IS NULL AND s.state = 'active' LIMIT 1",
                    (user["family_id"], user["id"], activity_id),
                )
            ).fetchone()
            if surviving is None:
                activity = await owned_row(
                    db,
                    table="health_activities",
                    record_id=activity_id,
                    user=user,
                    include_deleted=True,
                )
                if activity["deleted_at"] is None:
                    await soft_delete_owned(
                        db,
                        table="health_activities",
                        record_id=activity_id,
                        user=user,
                        record_sync_change=False,
                    )
        return HealthKitWorkoutImportResponse(
            status="deleted",
            source_record_id=exact["id"],
            activity_id=activity_id,
            deleted=True,
        )

    assert body.sport_key is not None and body.local_timezone is not None
    if body.sport_key not in SPORTS_BY_KEY:
        raise FitnessConflictError("Workout sport is not registered")
    try:
        ZoneInfo(body.local_timezone)
    except ZoneInfoNotFoundError as exc:
        raise FitnessConflictError("Workout local timezone is not registered") from exc

    duplicate_activity_id = None
    if activity_id is None:
        duplicate_activity_id = await _external_activity_id(db, user=user, body=body)
        activity_id = duplicate_activity_id
    source_id = exact["id"] if exact is not None else new_id()
    activity_values = _activity_values(body, source_id)
    activity_row = None
    if activity_id:
        activity_row = await owned_row(
            db,
            table="health_activities",
            record_id=activity_id,
            user=user,
            include_deleted=True,
        )
    if (
        activity_row is not None
        and activity_row["deleted_at"] is None
        and (
            (exact_link is not None and exact_link["role"] != "primary")
            or (
                activity_row["primary_source_record_id"] is not None
                and activity_row["primary_source_record_id"] != source_id
            )
        )
    ):
        duplicate_activity_id = activity_id
    source_values = _source_values(body, activity_id)
    if (
        exact is not None
        and exact["deleted_at"] is None
        and exact["state"] == "active"
        and activity_row is not None
        and activity_row["deleted_at"] is None
        and _stored_equal(exact, source_values)
        and (duplicate_activity_id is not None or _stored_equal(activity_row, activity_values))
    ):
        return HealthKitWorkoutImportResponse(
            status="unchanged",
            source_record_id=source_id,
            activity_id=activity_id,
            deleted=False,
        )

    created_source = exact is None
    created_activity = activity_row is None
    if created_activity:
        activity_id = new_id()
        source_values = _source_values(body, activity_id)
        activity_values = _activity_values(body, source_id)
        await insert_owned(
            db,
            table="health_activities",
            record_id=activity_id,
            values=activity_values,
            user=user,
            record_sync_change=False,
        )
    elif duplicate_activity_id is None:
        assert activity_id is not None
        update_values = {**activity_values}
        update_values.pop("revision", None)
        await update_owned(
            db,
            table="health_activities",
            record_id=activity_id,
            values=update_values,
            user=user,
            restore=True,
            record_sync_change=False,
        )
    await recovery.upsert_source_record(
        db,
        user=user,
        record_id=source_id,
        body=SourceRecordPayload.model_validate(source_values),
    )
    assert activity_id is not None
    await _upsert_link(
        db,
        user=user,
        activity_id=activity_id,
        source_id=source_id,
        role="corroborating" if duplicate_activity_id else "primary",
    )
    if created_activity:
        await activities.auto_match_activity(
            db,
            user=user,
            activity_id=activity_id,
            record_activity_sync_change=False,
        )
    return HealthKitWorkoutImportResponse(
        status="created" if created_source else "updated",
        source_record_id=source_id,
        activity_id=activity_id,
        deleted=False,
    )

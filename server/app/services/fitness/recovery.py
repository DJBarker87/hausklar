"""External provenance, canonical weight, sleep and recovery behaviour."""

from __future__ import annotations

import json
import statistics
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.fitness_recovery import (
    RecoveryObservationPayload,
    SleepSessionPayload,
    SourcePriorityPayload,
    SourceRecordPayload,
)
from app.services.fitness.common import (
    FitnessConflictError,
    decoded_row,
    insert_owned,
    new_id,
    now_iso,
    owned_row,
    soft_delete_owned,
    update_owned,
)


RECOVERY_LABELS = {
    "recovery.resting_heart_rate_bpm": "Resting heart rate",
    "recovery.hrv_sdnn_ms": "Heart-rate variability",
    "recovery.hrv_rmssd_ms": "Heart-rate variability (RMSSD)",
    "recovery.body_battery": "Body Battery",
    "recovery.stress": "Stress",
    "vitals.blood_pressure_systolic_mmhg": "Systolic blood pressure",
    "vitals.blood_pressure_diastolic_mmhg": "Diastolic blood pressure",
    "vitals.heart_rate_bpm": "Heart rate",
    "sleep.quality": "Sleep quality",
    "general_fatigue": "General fatigue",
    "general_soreness": "General soreness",
    "illness_flag": "Illness flag",
}

REGISTERED_RECOVERY_METRICS = frozenset(RECOVERY_LABELS)
_PRESERVE_OVERRIDE = object()


def _normal_record_kind(value: str) -> str:
    return "recovery_metric" if value == "recovery_observation" else value


async def source_record_response(db, *, user: dict, source_id: str) -> dict:
    data = dict(
        await owned_row(
            db,
            table="health_source_records",
            record_id=source_id,
            user=user,
        )
    )
    for field in ("device_json", "metadata_json"):
        try:
            data[field] = json.loads(data.get(field) or "{}")
        except (TypeError, json.JSONDecodeError):
            data[field] = {}
    data.pop("raw_metadata_json", None)
    return data


async def upsert_source_record(
    db,
    *,
    user: dict,
    body: SourceRecordPayload,
    record_id: str | None = None,
) -> dict:
    identifier = record_id or new_id(body.id)
    record_kind = _normal_record_kind(body.record_kind)
    exact = await (
        await db.execute(
            "SELECT * FROM health_source_records WHERE family_id = ? AND owner_user_id = ? "
            "AND record_kind = ? AND transport_key = ? AND source_namespace = ? "
            "AND source_object_id = ? ORDER BY deleted_at IS NULL DESC LIMIT 1",
            (
                user["family_id"],
                user["id"],
                record_kind,
                body.transport_key,
                body.source_namespace,
                body.source_object_id,
            ),
        )
    ).fetchone()
    if exact is not None and exact["id"] != identifier:
        raise FitnessConflictError("This external source sample already has another identity")
    values = body.model_dump(
        exclude={
            "id",
            "client_id",
            "client_timestamp",
            "record_kind",
        }
    )
    values.update(
        {
            "record_kind": record_kind,
            "device_json": body.device_json,
            "metadata_json": body.metadata_json,
            "raw_metadata_json": {
                "source_name": body.source_name,
                "product_type": body.product_type,
            },
            "revision": 1,
        }
    )
    existing = await (
        await db.execute(
            "SELECT * FROM health_source_records WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_source_records",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        values.pop("revision", None)
        await update_owned(
            db,
            table="health_source_records",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return await source_record_response(db, user=user, source_id=identifier)


async def _active_source(
    db,
    *,
    user: dict,
    source_id: str | None,
    record_kinds: set[str],
):
    if source_id is None:
        return None
    row = await owned_row(
        db, table="health_source_records", record_id=source_id, user=user
    )
    if row["state"] != "active" or row["record_kind"] not in record_kinds:
        raise FitnessConflictError("The external source does not match this record")
    return row


async def validate_active_source(
    db,
    *,
    user: dict,
    source_id: str | None,
    record_kinds: set[str],
):
    """Validate an owner-private source dependency for another Fitness service."""
    return await _active_source(
        db,
        user=user,
        source_id=source_id,
        record_kinds=record_kinds,
    )


def source_wire(row) -> dict | None:
    if row is None:
        return None
    return {
        "transport_key": row["transport_key"],
        "origin_provider_key": row["origin_provider_key"],
        "source_namespace": row["source_namespace"],
        "source_device_identifier": row["source_device_identifier"],
        "state": row["state"],
    }


async def upsert_source_priority(
    db,
    *,
    user: dict,
    body: SourcePriorityPayload,
    record_id: str | None = None,
) -> dict:
    identifier = record_id or new_id(body.id)
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    existing = await (
        await db.execute(
            "SELECT id FROM health_source_priorities WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_source_priorities",
            record_id=identifier,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_source_priorities",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    result = decoded_row(
        await owned_row(
            db, table="health_source_priorities", record_id=identifier, user=user
        )
    )
    if body.metric_key == "body.weight_kg":
        clauses = [
            "m.family_id = ?",
            "m.owner_user_id = ?",
            "m.metric_key = 'body.weight_kg'",
            "m.deleted_at IS NULL",
            "s.deleted_at IS NULL",
            "s.origin_provider_key = ?",
        ]
        parameters: list[object] = [
            user["family_id"],
            user["id"],
            body.origin_provider_key,
        ]
        if body.transport_key:
            clauses.append("s.transport_key = ?")
            parameters.append(body.transport_key)
        if body.source_namespace:
            clauses.append("s.source_namespace = ?")
            parameters.append(body.source_namespace)
        affected = await (
            await db.execute(
                "SELECT m.id FROM health_body_measurements m "
                "JOIN health_source_records s ON s.id = m.source_record_id "
                f"WHERE {' AND '.join(clauses)} ORDER BY m.measured_at_utc, m.id",
                parameters,
            )
        ).fetchall()
        for measurement in affected:
            await rerank_weight_measurement(
                db,
                user=user,
                measurement_id=measurement["id"],
            )
    return result


async def list_source_priorities(db, *, user: dict) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_source_priorities WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL ORDER BY metric_key, priority DESC",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    return [decoded_row(row) for row in rows]


async def _priority(db, *, user: dict, metric_key: str, source) -> int:
    if source is None:
        return 75
    row = await (
        await db.execute(
            "SELECT priority FROM health_source_priorities WHERE family_id = ? "
            "AND owner_user_id = ? AND metric_key = ? AND origin_provider_key = ? "
            "AND transport_key IN ('', ?) AND source_namespace IN ('', ?) "
            "AND deleted_at IS NULL ORDER BY (transport_key <> '') + "
            "(source_namespace <> '') DESC, priority DESC LIMIT 1",
            (
                user["family_id"],
                user["id"],
                metric_key,
                source["origin_provider_key"],
                source["transport_key"],
                source["source_namespace"],
            ),
        )
    ).fetchone()
    if row:
        return int(row["priority"])
    if source["transport_key"] == "healthkit":
        return 50
    if source["transport_key"].endswith("_api"):
        return 100
    return 80


async def _weight_duplicate_group(db, *, user: dict, measurement) -> list:
    if (
        measurement["metric_key"] != "body.weight_kg"
        or not measurement["source_record_id"]
    ):
        return []
    source = await _active_source(
        db,
        user=user,
        source_id=measurement["source_record_id"],
        record_kinds={"body_measurement"},
    )
    candidates = await (
        await db.execute(
            "SELECT m.*, s.origin_provider_key, s.transport_key, s.source_namespace, "
            "s.external_object_id FROM health_body_measurements m "
            "JOIN health_source_records s ON s.id = m.source_record_id "
            "WHERE m.family_id = ? AND m.owner_user_id = ? AND m.metric_key = 'body.weight_kg' "
            "AND m.deleted_at IS NULL AND m.canonical_state <> 'excluded' "
            "AND s.deleted_at IS NULL AND s.state = 'active' AND s.origin_provider_key = ? "
            "AND (m.id = ? OR "
            "(? IS NOT NULL AND s.external_object_id = ?) OR "
            "(ABS(m.value - ?) <= 0.05 AND ABS(strftime('%s', m.measured_at_utc) - "
            "strftime('%s', ?)) <= 120)) "
            "ORDER BY m.measured_at_utc, m.id",
            (
                user["family_id"],
                user["id"],
                source["origin_provider_key"],
                measurement["id"],
                source["external_object_id"],
                source["external_object_id"],
                measurement["value"],
                measurement["measured_at_utc"],
            ),
        )
    ).fetchall()
    return list(candidates)


async def _weight_group_winner(
    db,
    *,
    user: dict,
    candidates: list,
    honour_manual_override: bool,
):
    ranked: list[tuple[int, int, str, object]] = []
    for candidate in candidates:
        candidate_source = {
            "origin_provider_key": candidate["origin_provider_key"],
            "transport_key": candidate["transport_key"],
            "source_namespace": candidate["source_namespace"],
        }
        ranked.append(
            (
                int(
                    honour_manual_override
                    and bool(candidate["manual_canonical_override"])
                ),
                await _priority(
                    db,
                    user=user,
                    metric_key="body.weight_kg",
                    source=candidate_source,
                ),
                candidate["created_at"],
                candidate,
            )
        )
    return max(
        ranked,
        key=lambda item: (item[0], item[1], item[2], item[3]["id"]),
    )[3]


async def _apply_weight_group(
    db,
    *,
    user: dict,
    candidates: list,
    winner_id: str,
    manual_override_id: str | None | object = _PRESERVE_OVERRIDE,
) -> None:
    timestamp = now_iso()
    for candidate in candidates:
        canonical = candidate["id"] == winner_id
        state = "canonical" if canonical else "duplicate"
        duplicate_of = None if canonical else winner_id
        values: dict[str, object] = {
            "canonical_state": state,
            "duplicate_of_measurement_id": duplicate_of,
        }
        override_unchanged = manual_override_id is _PRESERVE_OVERRIDE
        if not override_unchanged:
            values["manual_canonical_override"] = (
                candidate["id"] == manual_override_id
            )
        if (
            candidate["canonical_state"] == state
            and candidate["duplicate_of_measurement_id"] == duplicate_of
            and (
                override_unchanged
                or bool(candidate["manual_canonical_override"])
                == values["manual_canonical_override"]
            )
        ):
            continue
        await update_owned(
            db,
            table="health_body_measurements",
            record_id=candidate["id"],
            values=values,
            user=user,
            now=timestamp,
        )


def _canonical_override_response(
    *, candidates: list, winner_id: str, manual_override: bool
) -> dict:
    return {
        "canonical_measurement_id": winner_id,
        "group_member_ids": [candidate["id"] for candidate in candidates],
        "manual_override": manual_override,
    }


async def set_weight_canonical_override(
    db, *, user: dict, measurement_id: str
) -> dict:
    measurement = await owned_row(
        db,
        table="health_body_measurements",
        record_id=measurement_id,
        user=user,
    )
    candidates = await _weight_duplicate_group(
        db, user=user, measurement=measurement
    )
    if len(candidates) < 2 or measurement_id not in {
        candidate["id"] for candidate in candidates
    }:
        raise FitnessConflictError(
            "Only an imported member of a duplicate weight group can be selected"
        )
    await _apply_weight_group(
        db,
        user=user,
        candidates=candidates,
        winner_id=measurement_id,
        manual_override_id=measurement_id,
    )
    return _canonical_override_response(
        candidates=candidates,
        winner_id=measurement_id,
        manual_override=True,
    )


async def clear_weight_canonical_override(
    db, *, user: dict, measurement_id: str
) -> dict:
    measurement = await owned_row(
        db,
        table="health_body_measurements",
        record_id=measurement_id,
        user=user,
    )
    candidates = await _weight_duplicate_group(
        db, user=user, measurement=measurement
    )
    if len(candidates) < 2 or measurement_id not in {
        candidate["id"] for candidate in candidates
    }:
        raise FitnessConflictError(
            "Only an imported duplicate weight group can clear an override"
        )
    winner = await _weight_group_winner(
        db,
        user=user,
        candidates=candidates,
        honour_manual_override=False,
    )
    await _apply_weight_group(
        db,
        user=user,
        candidates=candidates,
        winner_id=winner["id"],
        manual_override_id=None,
    )
    return _canonical_override_response(
        candidates=candidates,
        winner_id=winner["id"],
        manual_override=False,
    )


async def rerank_weight_measurement(db, *, user: dict, measurement_id: str) -> None:
    measurement = await owned_row(
        db,
        table="health_body_measurements",
        record_id=measurement_id,
        user=user,
    )
    candidates = await _weight_duplicate_group(
        db, user=user, measurement=measurement
    )
    if not candidates:
        return
    winner = await _weight_group_winner(
        db,
        user=user,
        candidates=candidates,
        honour_manual_override=True,
    )
    await _apply_weight_group(
        db,
        user=user,
        candidates=candidates,
        winner_id=winner["id"],
    )


async def _promote_weight_replacement(
    db, *, user: dict, deleted_measurement: object
) -> None:
    if deleted_measurement["metric_key"] != "body.weight_kg":
        return
    rows = await (
        await db.execute(
            "SELECT id FROM health_body_measurements WHERE family_id = ? "
            "AND owner_user_id = ? AND duplicate_of_measurement_id = ? "
            "AND canonical_state <> 'excluded' AND deleted_at IS NULL ORDER BY created_at",
            (user["family_id"], user["id"], deleted_measurement["id"]),
        )
    ).fetchall()
    if not rows:
        return
    # Every member retains the same-provider exact/time grouping. Reranking any
    # one of them selects the configured best surviving source.
    await rerank_weight_measurement(db, user=user, measurement_id=rows[0]["id"])


async def delete_body_measurement(db, *, user: dict, measurement_id: str) -> int:
    row = await owned_row(
        db,
        table="health_body_measurements",
        record_id=measurement_id,
        user=user,
        include_deleted=True,
    )
    if row["deleted_at"] is not None:
        return int(row["revision"])
    revision = await soft_delete_owned(
        db,
        table="health_body_measurements",
        record_id=measurement_id,
        user=user,
    )
    await _promote_weight_replacement(db, user=user, deleted_measurement=row)
    return revision


async def sleep_session_response(db, *, user: dict, session_id: str) -> dict:
    row = await owned_row(
        db, table="health_sleep_sessions", record_id=session_id, user=user
    )
    stages = await (
        await db.execute(
            "SELECT stage, start_at_utc, end_at_utc, duration_s, source_record_id "
            "FROM health_sleep_stages "
            "WHERE family_id = ? AND owner_user_id = ? AND sleep_session_id = ? "
            "AND deleted_at IS NULL ORDER BY sequence, start_at_utc",
            (user["family_id"], user["id"], session_id),
        )
    ).fetchall()
    source = None
    if row["source_record_id"]:
        source = await (
            await db.execute(
                "SELECT * FROM health_source_records WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ?",
                (row["source_record_id"], user["family_id"], user["id"]),
            )
        ).fetchone()
    data = decoded_row(row)
    data["source_stages"] = [dict(stage) for stage in stages]
    data["source"] = source_wire(source)
    return data


async def upsert_sleep_session(
    db,
    *,
    user: dict,
    body: SleepSessionPayload,
    record_id: str | None = None,
) -> dict:
    identifier = record_id or new_id(body.id)
    source_id = str(body.source_record_id) if body.source_record_id else None
    await _active_source(
        db,
        user=user,
        source_id=source_id,
        record_kinds={"sleep_session"},
    )
    for stage in body.source_stages:
        stage_source_id = (
            str(stage.source_record_id) if stage.source_record_id else None
        )
        stage_source = await _active_source(
            db,
            user=user,
            source_id=stage_source_id,
            record_kinds={"sleep_session"},
        )
        if stage_source is not None and (
            stage_source["domain_entity_type"] not in {None, "sleep_session"}
            or stage_source["domain_entity_id"] not in {None, identifier}
        ):
            raise FitnessConflictError("Sleep stage provenance targets another session")
    values = body.model_dump(
        exclude={
            "id",
            "client_id",
            "client_timestamp",
            "source_stages",
            "source",
        }
    )
    values["source_record_id"] = source_id
    existing = await (
        await db.execute(
            "SELECT * FROM health_sleep_sessions WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_sleep_sessions",
            record_id=identifier,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_sleep_sessions",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
        old_stages = await (
            await db.execute(
                "SELECT * FROM health_sleep_stages WHERE family_id = ? "
                "AND owner_user_id = ? AND sleep_session_id = ? AND deleted_at IS NULL",
                (user["family_id"], user["id"], identifier),
            )
        ).fetchall()
        for stage in old_stages:
            await soft_delete_owned(
                db,
                table="health_sleep_stages",
                record_id=stage["id"],
                user=user,
                record_sync_change=False,
            )
    for sequence, stage in enumerate(
        sorted(body.source_stages, key=lambda item: item.start_at_utc)
    ):
        await insert_owned(
            db,
            table="health_sleep_stages",
            record_id=new_id(),
            values={
                "sleep_session_id": identifier,
                "source_record_id": (
                    str(stage.source_record_id) if stage.source_record_id else None
                ),
                "sequence": sequence,
                "stage": stage.stage,
                "start_at_utc": stage.start_at_utc,
                "end_at_utc": stage.end_at_utc,
                "duration_s": stage.duration_s,
                "revision": 1,
            },
            user=user,
            record_sync_change=False,
        )
    if body.source_stages:
        await _recompute_sleep_session(db, user=user, session_id=identifier)
    return await sleep_session_response(db, user=user, session_id=identifier)


async def list_sleep_sessions(
    db,
    *,
    user: dict,
    from_date: date | None,
    to_date: date | None,
    offset: int,
    limit: int,
) -> list[dict]:
    clauses = ["family_id = ?", "owner_user_id = ?", "deleted_at IS NULL"]
    parameters: list[object] = [user["family_id"], user["id"]]
    if from_date:
        clauses.append("substr(sleep_end_utc, 1, 10) >= ?")
        parameters.append(from_date.isoformat())
    if to_date:
        clauses.append("substr(sleep_end_utc, 1, 10) <= ?")
        parameters.append(to_date.isoformat())
    rows = await (
        await db.execute(
            f"SELECT id FROM health_sleep_sessions WHERE {' AND '.join(clauses)} "
            "ORDER BY sleep_start_utc DESC, id LIMIT ? OFFSET ?",
            (*parameters, limit, offset),
        )
    ).fetchall()
    return [
        await sleep_session_response(db, user=user, session_id=row["id"])
        for row in rows
    ]


async def recovery_observation_response(
    db, *, user: dict, observation_id: str
) -> dict:
    row = await owned_row(
        db,
        table="health_recovery_observations",
        record_id=observation_id,
        user=user,
    )
    source = None
    if row["source_record_id"]:
        source = await (
            await db.execute(
                "SELECT * FROM health_source_records WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ?",
                (row["source_record_id"], user["family_id"], user["id"]),
            )
        ).fetchone()
    data = decoded_row(row)
    data["source"] = source_wire(source)
    return data


async def upsert_recovery_observation(
    db,
    *,
    user: dict,
    body: RecoveryObservationPayload,
    record_id: str | None = None,
) -> dict:
    if body.metric_key not in REGISTERED_RECOVERY_METRICS:
        raise FitnessConflictError("Recovery metric is not registered")
    identifier = record_id or new_id(body.id)
    source_id = str(body.source_record_id) if body.source_record_id else None
    source = await _active_source(
        db,
        user=user,
        source_id=source_id,
        record_kinds={"recovery_metric"},
    )
    if source is not None and (
        source["domain_entity_type"] not in {None, "recovery_observation"}
        or source["domain_entity_id"] not in {None, identifier}
    ):
        raise FitnessConflictError("Recovery provenance targets another observation")
    values = body.model_dump(
        exclude={"id", "client_id", "client_timestamp", "source"}
    )
    values["source_record_id"] = source_id
    existing = await (
        await db.execute(
            "SELECT * FROM health_recovery_observations WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_recovery_observations",
            record_id=identifier,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_recovery_observations",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return await recovery_observation_response(
        db, user=user, observation_id=identifier
    )


async def list_recovery_observations(
    db,
    *,
    user: dict,
    from_date: date | None,
    to_date: date | None,
    metric_key: str | None,
    offset: int,
    limit: int,
) -> list[dict]:
    clauses = ["family_id = ?", "owner_user_id = ?", "deleted_at IS NULL"]
    parameters: list[object] = [user["family_id"], user["id"]]
    if from_date:
        clauses.append("substr(observed_at_utc, 1, 10) >= ?")
        parameters.append(from_date.isoformat())
    if to_date:
        clauses.append("substr(observed_at_utc, 1, 10) <= ?")
        parameters.append(to_date.isoformat())
    if metric_key:
        clauses.append("metric_key = ?")
        parameters.append(metric_key)
    rows = await (
        await db.execute(
            f"SELECT id FROM health_recovery_observations WHERE {' AND '.join(clauses)} "
            "ORDER BY observed_at_utc DESC, id LIMIT ? OFFSET ?",
            (*parameters, limit, offset),
        )
    ).fetchall()
    return [
        await recovery_observation_response(
            db, user=user, observation_id=row["id"]
        )
        for row in rows
    ]


async def _owner_zone(db, *, user: dict) -> ZoneInfo:
    row = await (
        await db.execute(
            "SELECT timezone FROM health_user_settings WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    try:
        return ZoneInfo(row["timezone"] if row else "Europe/London")
    except ZoneInfoNotFoundError:
        return ZoneInfo("Europe/London")


def _dt(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


async def recovery_summary(
    db, *, user: dict, from_date: date, to_date: date
) -> dict:
    expected_days = (to_date - from_date).days + 1
    zone = await _owner_zone(db, user=user)
    sleep_rows = await (
        await db.execute(
            "SELECT * FROM health_sleep_sessions WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL ORDER BY sleep_start_utc",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    selected_sleep = []
    for row in sleep_rows:
        local_day = _dt(row["sleep_end_utc"]).astimezone(zone).date()
        if from_date <= local_day <= to_date:
            selected_sleep.append(row)
    bedtimes = []
    wake_times = []
    sleep_days = set()
    for row in selected_sleep:
        start = _dt(row["sleep_start_utc"]).astimezone(zone)
        end = _dt(row["sleep_end_utc"]).astimezone(zone)
        bedtime = start.hour * 60 + start.minute
        if bedtime < 12 * 60:
            bedtime += 24 * 60
        bedtimes.append(float(bedtime))
        wake_times.append(float(end.hour * 60 + end.minute))
        sleep_days.add(end.date())
    average_bedtime = statistics.fmean(bedtimes) % 1440 if bedtimes else None
    average_wake = statistics.fmean(wake_times) if wake_times else None
    regularity = statistics.pstdev(bedtimes) if len(bedtimes) >= 2 else None
    durations = [float(row["duration_s"]) for row in selected_sleep]

    metric_rows = await (
        await db.execute(
            "SELECT o.*, s.source_name, s.origin_provider_key, s.source_namespace "
            "FROM health_recovery_observations o LEFT JOIN health_source_records s "
            "ON s.id = o.source_record_id AND s.family_id = o.family_id "
            "AND s.owner_user_id = o.owner_user_id WHERE o.family_id = ? "
            "AND o.owner_user_id = ? AND o.deleted_at IS NULL "
            "AND substr(o.observed_at_utc, 1, 10) BETWEEN ? AND ? "
            "ORDER BY o.metric_key, o.observed_at_utc",
            (user["family_id"], user["id"], from_date.isoformat(), to_date.isoformat()),
        )
    ).fetchall()
    grouped: dict[str, list] = {}
    for row in metric_rows:
        grouped.setdefault(row["metric_key"], []).append(row)
    baseline_keys = {
        "recovery.resting_heart_rate_bpm",
        "recovery.hrv_sdnn_ms",
        "recovery.hrv_rmssd_ms",
        *grouped.keys(),
    }
    baselines = []
    for metric_key in sorted(baseline_keys):
        rows = [row for row in grouped.get(metric_key, []) if row["value_number"] is not None]
        current = rows[-1] if rows else None
        previous = rows[:-1]
        baseline_values = [float(row["value_number"]) for row in previous[-28:]]
        baseline = statistics.fmean(baseline_values) if len(baseline_values) >= 3 else None
        current_value = float(current["value_number"]) if current else None
        deviation = current_value - baseline if current_value is not None and baseline is not None else None
        deviation_percent = (
            deviation / baseline * 100 if deviation is not None and baseline not in {None, 0} else None
        )
        status = "insufficient_data"
        missing_reason = None
        if current is None:
            missing_reason = "No numeric observation was recorded in this window."
        elif baseline is None:
            missing_reason = "At least three prior observations are needed for a personal baseline."
        elif abs(deviation_percent or 0) <= 5:
            status = "within_baseline"
        elif (deviation_percent or 0) > 0:
            status = "above_baseline"
        else:
            status = "below_baseline"
        source_name = None
        if current:
            source_name = (
                current["source_name"]
                or current["origin_provider_key"]
                or current["source_namespace"]
                or "Manual"
            )
        baselines.append(
            {
                "metric_key": metric_key,
                "label": RECOVERY_LABELS.get(metric_key, metric_key.replace("_", " ").title()),
                "unit_key": current["unit_key"] if current else None,
                "current_value": current_value,
                "baseline_value": baseline,
                "deviation_absolute": deviation,
                "deviation_percent": deviation_percent,
                "status": status,
                "window_days": min(28, expected_days),
                "observed_at_utc": current["observed_at_utc"] if current else None,
                "source_name": source_name,
                "missing_reason": missing_reason,
            }
        )

    readiness = await (
        await db.execute(
            "SELECT c.readiness_1_5, a.perceived_performance FROM health_session_checkins c "
            "JOIN health_activities a ON a.id = c.activity_id AND a.family_id = c.family_id "
            "AND a.owner_user_id = c.owner_user_id WHERE c.family_id = ? "
            "AND c.owner_user_id = ? AND c.timing = 'pre' "
            "AND c.capture_quality = 'contemporaneous' AND c.readiness_1_5 IS NOT NULL "
            "AND a.perceived_performance IS NOT NULL AND c.deleted_at IS NULL "
            "AND a.deleted_at IS NULL AND substr(c.captured_at_utc, 1, 10) BETWEEN ? AND ?",
            (user["family_id"], user["id"], from_date.isoformat(), to_date.isoformat()),
        )
    ).fetchall()
    sample_size = len(readiness)
    relationships = [
        {
            "label": "Readiness and perceived session performance",
            "summary": (
                "There are enough paired readiness and session outcomes for a descriptive view."
                if sample_size >= 3
                else "Not enough paired readiness and session outcomes are available yet."
            ),
            "sample_size": sample_size,
            "limitation": "This is descriptive personal history and does not establish causation.",
        }
    ]
    return {
        "window": {
            "from_date": from_date.isoformat(),
            "to_date": to_date.isoformat(),
            "expected_days": expected_days,
            "days_with_sleep": len(sleep_days),
        },
        "sleep": {
            "average_duration_s": statistics.fmean(durations) if durations else None,
            "average_bedtime_minutes": average_bedtime,
            "average_wake_time_minutes": average_wake,
            "timing_regularity_minutes": regularity,
        },
        "baselines": baselines,
        "relationships": relationships,
    }


async def delete_sleep_session(db, *, user: dict, session_id: str) -> int:
    row = await owned_row(
        db,
        table="health_sleep_sessions",
        record_id=session_id,
        user=user,
        include_deleted=True,
    )
    if row["deleted_at"] is not None:
        return int(row["revision"])
    stages = await (
        await db.execute(
            "SELECT id FROM health_sleep_stages WHERE family_id = ? AND owner_user_id = ? "
            "AND sleep_session_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], session_id),
        )
    ).fetchall()
    for stage in stages:
        await soft_delete_owned(
            db,
            table="health_sleep_stages",
            record_id=stage["id"],
            user=user,
            record_sync_change=False,
        )
    return await soft_delete_owned(
        db, table="health_sleep_sessions", record_id=session_id, user=user
    )


def _union_duration(intervals: list[tuple[datetime, datetime]]) -> float:
    if not intervals:
        return 0.0
    ordered = sorted(intervals)
    start, end = ordered[0]
    total = 0.0
    for next_start, next_end in ordered[1:]:
        if next_start <= end:
            end = max(end, next_end)
        else:
            total += (end - start).total_seconds()
            start, end = next_start, next_end
    return total + (end - start).total_seconds()


async def _recompute_sleep_session(
    db, *, user: dict, session_id: str
) -> None:
    session = await owned_row(
        db,
        table="health_sleep_sessions",
        record_id=session_id,
        user=user,
        include_deleted=True,
    )
    if session["deleted_at"] is not None:
        return
    stages = await (
        await db.execute(
            "SELECT * FROM health_sleep_stages WHERE family_id = ? AND owner_user_id = ? "
            "AND sleep_session_id = ? AND deleted_at IS NULL ORDER BY start_at_utc",
            (user["family_id"], user["id"], session_id),
        )
    ).fetchall()
    meaningful = [
        stage for stage in stages if stage["stage"].lower() not in {"awake", "in_bed"}
    ]
    if not meaningful:
        await delete_sleep_session(db, user=user, session_id=session_id)
        return
    all_intervals = [(_dt(stage["start_at_utc"]), _dt(stage["end_at_utc"])) for stage in stages]
    sleep_intervals = [
        (_dt(stage["start_at_utc"]), _dt(stage["end_at_utc"])) for stage in meaningful
    ]
    awake_intervals = [
        (_dt(stage["start_at_utc"]), _dt(stage["end_at_utc"]))
        for stage in stages
        if stage["stage"].lower() == "awake"
    ]
    primary_source_id = next(
        (stage["source_record_id"] for stage in meaningful if stage["source_record_id"]),
        None,
    )
    await update_owned(
        db,
        table="health_sleep_sessions",
        record_id=session_id,
        values={
            "sleep_start_utc": min(interval[0] for interval in all_intervals),
            "sleep_end_utc": max(interval[1] for interval in all_intervals),
            "duration_s": _union_duration(sleep_intervals),
            "awake_duration_s": _union_duration(awake_intervals),
            "source_record_id": primary_source_id,
        },
        user=user,
    )


async def delete_recovery_observation(
    db, *, user: dict, observation_id: str
) -> int:
    row = await owned_row(
        db,
        table="health_recovery_observations",
        record_id=observation_id,
        user=user,
        include_deleted=True,
    )
    if row["deleted_at"] is not None:
        return int(row["revision"])
    return await soft_delete_owned(
        db,
        table="health_recovery_observations",
        record_id=observation_id,
        user=user,
    )


async def delete_source_record(db, *, user: dict, source_id: str) -> int:
    source = await owned_row(
        db,
        table="health_source_records",
        record_id=source_id,
        user=user,
        include_deleted=True,
    )
    if source["deleted_at"] is not None:
        return int(source["revision"])
    # Remove only domain rows linked to this exact source UUID. Other provider
    # copies remain inspectable and weight groups are reranked afterwards.
    body_rows = await (
        await db.execute(
            "SELECT id FROM health_body_measurements WHERE family_id = ? "
            "AND owner_user_id = ? AND source_record_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    for row in body_rows:
        await delete_body_measurement(db, user=user, measurement_id=row["id"])
    stage_rows = await (
        await db.execute(
            "SELECT id, sleep_session_id FROM health_sleep_stages WHERE family_id = ? "
            "AND owner_user_id = ? "
            "AND source_record_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    affected_sessions: set[str] = set()
    for stage in stage_rows:
        affected_sessions.add(stage["sleep_session_id"])
        await soft_delete_owned(
            db,
            table="health_sleep_stages",
            record_id=stage["id"],
            user=user,
            record_sync_change=False,
        )
    for session_id in sorted(affected_sessions):
        await _recompute_sleep_session(db, user=user, session_id=session_id)

    # Ungrouped provider summaries can point directly at one source without
    # normalized stage rows. Grouped sessions above have already been repointed.
    sleep_rows = await (
        await db.execute(
            "SELECT id FROM health_sleep_sessions WHERE family_id = ? AND owner_user_id = ? "
            "AND source_record_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    for row in sleep_rows:
        await delete_sleep_session(db, user=user, session_id=row["id"])
    recovery_rows = await (
        await db.execute(
            "SELECT id FROM health_recovery_observations WHERE family_id = ? "
            "AND owner_user_id = ? AND source_record_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    for row in recovery_rows:
        await delete_recovery_observation(
            db, user=user, observation_id=row["id"]
        )

    # An imported activity may have several independent source records. Remove
    # only this attachment, then promote the best surviving attachment instead
    # of leaving the activity pointed at deleted provenance.
    activity_links = await (
        await db.execute(
            "SELECT id, activity_id FROM health_activity_source_records "
            "WHERE family_id = ? AND owner_user_id = ? AND source_record_id = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    affected_activities = {row["activity_id"] for row in activity_links}
    for link in activity_links:
        await soft_delete_owned(
            db,
            table="health_activity_source_records",
            record_id=link["id"],
            user=user,
            record_sync_change=False,
        )
    for activity_id in sorted(affected_activities):
        surviving = await (
            await db.execute(
                "SELECT l.id, l.source_record_id FROM health_activity_source_records l "
                "JOIN health_source_records s ON s.id = l.source_record_id "
                "WHERE l.family_id = ? AND l.owner_user_id = ? AND l.activity_id = ? "
                "AND l.deleted_at IS NULL AND s.family_id = l.family_id "
                "AND s.owner_user_id = l.owner_user_id AND s.state = 'active' "
                "AND s.deleted_at IS NULL ORDER BY CASE l.role WHEN 'primary' THEN 0 "
                "WHEN 'corroborating' THEN 1 ELSE 2 END, l.created_at LIMIT 1",
                (user["family_id"], user["id"], activity_id),
            )
        ).fetchone()
        await update_owned(
            db,
            table="health_activities",
            record_id=activity_id,
            values={
                "primary_source_record_id": (
                    surviving["source_record_id"] if surviving else None
                )
            },
            user=user,
            record_sync_change=False,
        )
        if surviving:
            await update_owned(
                db,
                table="health_activity_source_records",
                record_id=surviving["id"],
                values={"role": "primary"},
                user=user,
                record_sync_change=False,
            )
    return await update_owned(
        db,
        table="health_source_records",
        record_id=source_id,
        values={"state": "deleted", "deleted_at": now_iso()},
        user=user,
    )

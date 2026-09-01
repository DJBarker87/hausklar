"""Validate and persist coaching-grade Strava activity detail and streams."""

from __future__ import annotations

import math
import os
import statistics
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import UUID

import pyarrow as pa
import pyarrow.parquet as pq

from app.fitness_worker import (
    STREAM_SCHEMA,
    STREAM_UNITS,
    _analyse,
    _best_efforts,
    _metric,
    _standard_splits,
    _stream_metric_change,
    _stream_metric_samples,
)
from app.services.fitness.activity_import import fitness_cache_root
from app.services.fitness.common import (
    insert_owned,
    new_id,
    now_iso,
    save_owned_rows_history,
    update_owned,
)


PARSER_VERSION = "strava-api-v3"
MAX_STREAM_ROWS = 750_000
MAX_POLYLINE_CHARACTERS = 2_000_000
MAX_ROUTE_POINTS = 750_000


@dataclass(frozen=True)
class StravaEnrichment:
    rows: list[dict[str, Any]]
    route_preview: list[list[float]]
    metric_index: list[dict[str, Any]]
    summary_metrics: list[dict[str, Any]]
    intervals: list[dict[str, Any]]
    features: dict[str, Any]
    findings: list[dict[str, Any]]
    records: list[dict[str, Any]]
    quality_findings: list[dict[str, Any]]
    classification: str | None

    @property
    def has_stream(self) -> bool:
        return bool(self.rows)


def decode_polyline(value: Any) -> list[list[float]]:
    """Decode a bounded Google encoded polyline into [latitude, longitude]."""
    if not isinstance(value, str) or not value or len(value) > MAX_POLYLINE_CHARACTERS:
        return []
    coordinates: list[list[float]] = []
    latitude = longitude = index = 0
    try:
        while index < len(value):
            deltas: list[int] = []
            for _ in range(2):
                result = shift = 0
                while True:
                    if index >= len(value) or shift > 30:
                        return []
                    byte = ord(value[index]) - 63
                    index += 1
                    if byte < 0 or byte > 63:
                        return []
                    result |= (byte & 0x1F) << shift
                    shift += 5
                    if byte < 0x20:
                        break
                deltas.append(~(result >> 1) if result & 1 else result >> 1)
            latitude += deltas[0]
            longitude += deltas[1]
            point = [latitude / 100_000, longitude / 100_000]
            if not (-90 <= point[0] <= 90 and -180 <= point[1] <= 180):
                return []
            coordinates.append(point)
            if len(coordinates) > MAX_ROUTE_POINTS:
                return []
    except (TypeError, ValueError, OverflowError):
        return []
    return coordinates


def _number(value: Any, *, minimum: float | None = None, maximum: float | None = None) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(result):
        return None
    if minimum is not None and result < minimum:
        return None
    if maximum is not None and result > maximum:
        return None
    return result


def _stream_data(payload: Any, key: str) -> list[Any]:
    item = payload.get(key) if isinstance(payload, dict) else None
    if item is None and isinstance(payload, list):
        item = next(
            (entry for entry in payload if isinstance(entry, dict) and entry.get("type") == key),
            None,
        )
    data = item.get("data") if isinstance(item, dict) else None
    return data if isinstance(data, list) and len(data) <= MAX_STREAM_ROWS else []


def _at(values: list[Any], index: int) -> Any:
    return values[index] if index < len(values) else None


def _coordinate(value: Any) -> tuple[float | None, float | None]:
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None, None
    return (
        _number(value[0], minimum=-90, maximum=90),
        _number(value[1], minimum=-180, maximum=180),
    )


def _downsample_route(coordinates: list[list[float]], maximum: int = 200) -> list[list[float]]:
    if len(coordinates) <= maximum:
        return coordinates
    step = max(1, math.ceil(len(coordinates) / maximum))
    result = coordinates[::step]
    if result[-1] != coordinates[-1]:
        result.append(coordinates[-1])
    return result


def _route(detail: dict[str, Any], rows: list[dict[str, Any]]) -> list[list[float]]:
    recorded = [
        [float(row["latitude_deg"]), float(row["longitude_deg"])]
        for row in rows
        if row.get("latitude_deg") is not None and row.get("longitude_deg") is not None
    ]
    if recorded:
        return _downsample_route(recorded)
    map_value = detail.get("map") if isinstance(detail.get("map"), dict) else {}
    decoded = decode_polyline(map_value.get("polyline")) or decode_polyline(
        map_value.get("summary_polyline")
    )
    return _downsample_route(decoded)


def _summary_metric(
    key: str,
    value: Any,
    unit: str,
    *,
    origin: str = "source",
) -> dict[str, Any] | None:
    number = _number(value)
    if number is None:
        return None
    return {
        "metric_key": key,
        "value_number": number,
        "unit_key": unit,
        "origin": origin,
        "quality": "derived" if origin == "derived" else "measured",
        "calculation_version": PARSER_VERSION if origin == "derived" else None,
    }


def _sport_type(detail: dict[str, Any]) -> str:
    return str(detail.get("sport_type") or detail.get("type") or "")


def _cadence_spm(value: Any, *, sport: str) -> float | None:
    cadence = _number(value, minimum=0, maximum=1_000)
    if cadence is None:
        return None
    # Strava's API reports one complete stride for foot sports while its app
    # presents the familiar total steps per minute. Normalise to the canonical
    # HausKlar cadence_spm unit used by FIT and HealthKit imports.
    if sport in {"Run", "VirtualRun", "TrailRun", "Walk", "Hike"}:
        cadence *= 2
    return cadence if cadence <= 1_000 else None


def _normalise_rows(detail: dict[str, Any], streams: Any) -> list[dict[str, Any]]:
    raw_time = _stream_data(streams, "time")
    if not raw_time:
        return []
    if len(raw_time) > MAX_STREAM_ROWS:
        return []
    try:
        started = datetime.fromisoformat(str(detail["start_date"]).replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError):
        return []
    if started.tzinfo is None:
        started = started.replace(tzinfo=timezone.utc)
    started = started.astimezone(timezone.utc)
    series = {
        key: _stream_data(streams, key)
        for key in (
            "distance", "latlng", "altitude", "velocity_smooth", "heartrate",
            "cadence", "watts", "temp", "moving",
        )
    }
    sport = _sport_type(detail)
    rows: list[dict[str, Any]] = []
    previous_elapsed = 0
    timer_ms = 0
    for index, raw_elapsed in enumerate(raw_time):
        seconds = _number(raw_elapsed, minimum=0, maximum=31 * 86_400)
        if seconds is None:
            return []
        elapsed_ms = int(round(seconds * 1_000))
        if elapsed_ms < previous_elapsed:
            return []
        if index:
            moving = _at(series["moving"], index)
            if moving is not False:
                timer_ms += elapsed_ms - previous_elapsed
        latitude, longitude = _coordinate(_at(series["latlng"], index))
        speed = _number(_at(series["velocity_smooth"], index), minimum=0, maximum=200)
        row = {
            "sample_index": index,
            "timestamp_utc": started + timedelta(milliseconds=elapsed_ms),
            "elapsed_ms": elapsed_ms,
            "timer_ms": min(timer_ms, elapsed_ms),
            "distance_m": _number(_at(series["distance"], index), minimum=0, maximum=10_000_000),
            "latitude_deg": latitude,
            "longitude_deg": longitude,
            "speed_mps": speed,
            "pace_s_per_km": 1_000 / speed if speed and speed > 0 else None,
            "heart_rate_bpm": _number(_at(series["heartrate"], index), minimum=0, maximum=300),
            "altitude_m": _number(_at(series["altitude"], index), minimum=-1_000, maximum=10_000),
            "cadence_spm": _cadence_spm(
                _at(series["cadence"], index), sport=sport
            ),
            "power_w": _number(_at(series["watts"], index), minimum=0, maximum=10_000),
            "temperature_c": _number(_at(series["temp"], index), minimum=-100, maximum=100),
            "stride_length_m": None,
            "vertical_oscillation_mm": None,
            "vertical_ratio_pct": None,
            "ground_contact_time_ms": None,
            "ground_contact_balance_pct": None,
            "respiration_rate_bpm": None,
        }
        rows.append(row)
        previous_elapsed = elapsed_ms
    return rows


def _metric_index(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result = []
    for key, unit in STREAM_UNITS.items():
        values = [row.get(key) for row in rows]
        stats = _metric(values)
        if stats["non_null_count"]:
            result.append(
                {
                    "metric_key": key,
                    **stats,
                    "unit_key": unit,
                    "quality": "derived" if key == "pace_s_per_km" else "measured",
                    "source_field": "velocity_smooth" if key == "pace_s_per_km" else key,
                }
            )
    return result


def _lap_intervals(detail: dict[str, Any], rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    raw_laps = detail.get("laps")
    if not isinstance(raw_laps, list):
        return []
    intervals = []
    sport = _sport_type(detail)
    cumulative_elapsed_ms = 0
    cumulative_distance_m = 0.0
    altitude_samples = _stream_metric_samples(rows, "altitude_m")
    for lap in raw_laps[:10_000]:
        if not isinstance(lap, dict):
            continue
        start_index = int(_number(lap.get("start_index"), minimum=0) or 0)
        end_index = int(_number(lap.get("end_index"), minimum=start_index) or start_index)
        start_row = rows[min(start_index, len(rows) - 1)] if rows else None
        end_row = rows[min(end_index, len(rows) - 1)] if rows else None
        start_offset = (
            int(start_row["elapsed_ms"])
            if start_row
            else cumulative_elapsed_ms
        )
        elapsed = _number(lap.get("elapsed_time"), minimum=0) or 0
        end_offset = (
            int(end_row["elapsed_ms"])
            if end_row
            else start_offset + int(elapsed * 1_000)
        )
        distance = _number(lap.get("distance"), minimum=0)
        moving = _number(lap.get("moving_time"), minimum=0)
        speed = _number(lap.get("average_speed"), minimum=0)
        pace = (
            1_000 / speed
            if speed and speed > 0
            else moving * 1_000 / distance
            if moving and distance
            else elapsed * 1_000 / distance
            if elapsed and distance
            else None
        )
        start_distance = (
            start_row.get("distance_m")
            if start_row
            else cumulative_distance_m
        )
        end_distance = (
            end_row.get("distance_m")
            if end_row
            else cumulative_distance_m + distance
            if distance is not None
            else None
        )
        intervals.append(
            {
                "sequence": len(intervals),
                "interval_kind": "source_lap",
                "origin": "source",
                "start_offset_ms": start_offset,
                "end_offset_ms": max(start_offset, end_offset),
                "start_distance_m": start_distance,
                "end_distance_m": end_distance,
                "label": str(lap.get("name") or f"Lap {len(intervals) + 1}")[:120],
                "metrics": {
                    "distance_m": distance,
                    "duration_s": elapsed,
                    "elapsed_duration_s": elapsed,
                    "timer_duration_s": moving,
                    "pace_s_per_km": pace,
                    "heart_rate.average_bpm": _number(lap.get("average_heartrate"), minimum=0, maximum=300),
                    "heart_rate.maximum_bpm": _number(lap.get("max_heartrate"), minimum=0, maximum=300),
                    "speed.average_mps": _number(lap.get("average_speed"), minimum=0),
                    "speed.maximum_mps": _number(lap.get("max_speed"), minimum=0),
                    "cadence.average_spm": _cadence_spm(
                        lap.get("average_cadence"), sport=sport
                    ),
                    "power.average_w": _number(lap.get("average_watts"), minimum=0),
                    "elevation.change_m": _stream_metric_change(
                        altitude_samples, start_offset, max(start_offset, end_offset)
                    ),
                    "elevation.gain_m": _number(lap.get("total_elevation_gain"), minimum=0),
                },
            }
        )
        cumulative_elapsed_ms = max(
            cumulative_elapsed_ms,
            start_offset + int(elapsed * 1_000),
        )
        if distance is not None:
            cumulative_distance_m += distance
    return intervals


def prepare_enrichment(
    detail: dict[str, Any],
    streams: Any,
    *,
    heart_rate_zone_boundaries_bpm: list[int] | None = None,
) -> StravaEnrichment:
    rows = _normalise_rows(detail, streams)
    distance = _number(detail.get("distance"), minimum=0) or 0
    duration = _number(detail.get("moving_time"), minimum=0) or 0
    intervals = _standard_splits(rows, distance) if rows else []
    intervals.extend(_lap_intervals(detail, rows))
    speed_values = [float(row["speed_mps"]) for row in rows if row.get("speed_mps") is not None]
    heart_rates = [float(row["heart_rate_bpm"]) for row in rows if row.get("heart_rate_bpm") is not None]
    altitude = [float(row["altitude_m"]) for row in rows if row.get("altitude_m") is not None]
    cadence = [float(row["cadence_spm"]) for row in rows if row.get("cadence_spm") is not None]
    power = [float(row["power_w"]) for row in rows if row.get("power_w") is not None]
    sport = _sport_type(detail)
    average_speed = _number(detail.get("average_speed"), minimum=0) or (
        statistics.fmean(speed_values) if speed_values else None
    )
    average_pace = (
        1_000 / average_speed
        if average_speed and average_speed > 0
        else duration * 1_000 / distance
        if duration and distance
        else None
    )
    summary = [
        _summary_metric("speed.average_mps", average_speed, "m/s"),
        _summary_metric("speed.maximum_mps", detail.get("max_speed") or (max(speed_values) if speed_values else None), "m/s"),
        _summary_metric(
            "running.average_pace_s_per_km",
            average_pace if sport in {"Run", "VirtualRun", "TrailRun"} else None,
            "s/km",
            origin="derived",
        ),
        _summary_metric("heart_rate.average_bpm", detail.get("average_heartrate") or (statistics.fmean(heart_rates) if heart_rates else None), "bpm"),
        _summary_metric("heart_rate.maximum_bpm", detail.get("max_heartrate") or (max(heart_rates) if heart_rates else None), "bpm"),
        _summary_metric(
            "cadence.average_spm",
            _cadence_spm(detail.get("average_cadence"), sport=sport)
            or (statistics.fmean(cadence) if cadence else None),
            "spm",
        ),
        _summary_metric("power.average_w", detail.get("average_watts") or (statistics.fmean(power) if power else None), "W"),
        _summary_metric("power.maximum_w", detail.get("max_watts") or (max(power) if power else None), "W"),
        _summary_metric("elevation.maximum_m", detail.get("elev_high") or (max(altitude) if altitude else None), "m"),
        _summary_metric("elevation.minimum_m", detail.get("elev_low") or (min(altitude) if altitude else None), "m"),
        _summary_metric("elevation.gain_m", detail.get("total_elevation_gain"), "m"),
    ]
    analysis = (
        _analyse(rows, distance, duration, intervals, heart_rate_zone_boundaries_bpm)
        if rows and sport in {"Run", "VirtualRun", "TrailRun"}
        else {"classification": None, "findings": [], "features": {}}
    )
    quality = []
    if detail.get("has_heartrate") and not heart_rates:
        quality.append(
            {
                "key": "strava_heart_rate_stream_unavailable",
                "severity": "warning",
                "message": "Strava reported heart-rate data but did not return its sample stream.",
                "limits_analysis_keys": ["heart_rate_zones", "heart_rate_drift", "heart_rate_decoupling"],
            }
        )
    return StravaEnrichment(
        rows=rows,
        route_preview=_route(detail, rows),
        metric_index=_metric_index(rows),
        summary_metrics=[item for item in summary if item is not None],
        intervals=intervals,
        features=analysis["features"],
        findings=analysis["findings"],
        records=_best_efforts(rows) if rows and sport in {"Run", "VirtualRun", "TrailRun"} else [],
        quality_findings=quality,
        classification=analysis.get("classification"),
    )


async def _soft_delete_generated(db, *, user: dict, activity_id: str, timestamp: str) -> None:
    for table in (
        "health_activity_metric_index",
        "health_activity_features",
        "health_activity_analysis_results",
        "health_activity_quality_findings",
    ):
        await save_owned_rows_history(
            db, table=table, user=user,
            where="activity_id = ? AND deleted_at IS NULL", params=(activity_id,),
        )
        await db.execute(
            f"UPDATE {table} SET deleted_at = ?, updated_at = ?, revision = revision + 1 "
            "WHERE family_id = ? AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL",
            (timestamp, timestamp, user["family_id"], user["id"], activity_id),
        )
    for table in ("health_activity_intervals", "health_activity_summary_metrics"):
        await save_owned_rows_history(
            db, table=table, user=user,
            where="activity_id = ? AND origin IN ('source','derived') AND deleted_at IS NULL",
            params=(activity_id,),
        )
        await db.execute(
            f"UPDATE {table} SET deleted_at = ?, updated_at = ?, revision = revision + 1 "
            "WHERE family_id = ? AND owner_user_id = ? AND activity_id = ? "
            "AND origin IN ('source','derived') AND deleted_at IS NULL",
            (timestamp, timestamp, user["family_id"], user["id"], activity_id),
        )


async def persist_enrichment(
    db,
    *,
    user: dict,
    activity_id: str,
    enrichment: StravaEnrichment,
) -> None:
    timestamp = now_iso()
    old_stream = await (
        await db.execute(
            "SELECT s.*, f.id AS file_id FROM health_activity_stream_assets s "
            "JOIN health_file_assets f ON f.id = s.file_asset_id "
            "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.activity_id = ? "
            "AND s.deleted_at IS NULL AND f.deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchone()
    if old_stream is not None and not enrichment.has_stream:
        # A provider can briefly return an empty stream payload for an activity
        # that was imported successfully before. Keep the usable stream and its
        # derived evidence so a harmless metadata change cannot erase it.
        return
    if old_stream is not None and not str(old_stream["parser_version"] or "").startswith("strava"):
        await update_owned(
            db, table="health_activities", record_id=activity_id,
            values={"route_preview_json": enrichment.route_preview, "parser_version": PARSER_VERSION},
            user=user, record_sync_change=False,
        )
        return
    await _soft_delete_generated(
        db, user=user, activity_id=activity_id, timestamp=timestamp
    )
    if old_stream is not None:
        for table, identifier in (
            ("health_activity_stream_assets", old_stream["id"]),
            ("health_file_assets", old_stream["file_id"]),
        ):
            await save_owned_rows_history(
                db, table=table, user=user,
                where="id = ? AND deleted_at IS NULL", params=(identifier,),
            )
            await db.execute(
                f"UPDATE {table} SET deleted_at = ?, updated_at = ?, revision = revision + 1 "
                "WHERE id = ? AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
                (timestamp, timestamp, identifier, user["family_id"], user["id"]),
            )

    stream_id: str | None = None
    if enrichment.rows:
        stream_id = new_id()
        file_id = new_id()
        owner = str(UUID(str(user["id"])))
        storage_key = str(Path("streams") / owner / f"{stream_id}.parquet")
        destination = (fitness_cache_root() / storage_key).resolve()
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_suffix(".parquet.tmp")
        table = pa.Table.from_pylist(enrichment.rows, schema=STREAM_SCHEMA)
        try:
            pq.write_table(table, temporary, compression="zstd")
            os.chmod(temporary, 0o600)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        await insert_owned(
            db, table="health_file_assets", record_id=file_id,
            values={
                "asset_kind": "activity_stream", "storage_class": "regenerable",
                "storage_key": storage_key, "original_filename": None,
                "media_type": "application/vnd.apache.parquet",
                "byte_size": destination.stat().st_size, "state": "ready",
                "source_asset_id": None, "revision": 1,
            },
            user=user, record_sync_change=False,
        )
        await insert_owned(
            db, table="health_activity_stream_assets", record_id=stream_id,
            values={
                "activity_id": activity_id, "file_asset_id": file_id,
                "stream_kind": "primary", "format": "parquet", "schema_version": 1,
                "parser_version": PARSER_VERSION, "row_count": len(enrichment.rows),
                "start_offset_ms": enrichment.rows[0]["elapsed_ms"],
                "end_offset_ms": enrichment.rows[-1]["elapsed_ms"], "revision": 1,
            },
            user=user, record_sync_change=False,
        )
        for metric in enrichment.metric_index:
            await insert_owned(
                db, table="health_activity_metric_index", record_id=new_id(),
                values={**metric, "activity_id": activity_id, "stream_asset_id": stream_id, "revision": 1},
                user=user, record_sync_change=False,
            )

    for metric in enrichment.summary_metrics:
        await insert_owned(
            db, table="health_activity_summary_metrics", record_id=new_id(),
            values={**metric, "activity_id": activity_id, "revision": 1},
            user=user, record_sync_change=False,
        )
    for interval in enrichment.intervals:
        await insert_owned(
            db, table="health_activity_intervals", record_id=new_id(),
            values={
                **{key: value for key, value in interval.items() if key != "metrics"},
                "activity_id": activity_id, "metrics_json": interval.get("metrics", {}),
                "revision": 1,
            },
            user=user, record_sync_change=False,
        )
    for key, value in enrichment.features.items():
        await insert_owned(
            db, table="health_activity_features", record_id=new_id(),
            values={
                "activity_id": activity_id, "feature_key": key,
                "feature_version": PARSER_VERSION,
                "value_json": value if isinstance(value, dict) else {"value": value},
                "quality": "derived", "revision": 1,
            },
            user=user, record_sync_change=False,
        )
    if enrichment.records:
        await insert_owned(
            db, table="health_activity_features", record_id=new_id(),
            values={
                "activity_id": activity_id, "feature_key": "running.records",
                "feature_version": PARSER_VERSION, "value_json": enrichment.records,
                "quality": "derived", "revision": 1,
            },
            user=user, record_sync_change=False,
        )
    for finding in enrichment.findings:
        await insert_owned(
            db, table="health_activity_analysis_results", record_id=new_id(),
            values={
                "activity_id": activity_id, "analysis_key": finding["key"],
                "calculation_version": PARSER_VERSION,
                "status": finding.get("status", "valid"), "result_json": finding,
                "revision": 1,
            },
            user=user, record_sync_change=False,
        )
    for finding in enrichment.quality_findings:
        await insert_owned(
            db, table="health_activity_quality_findings", record_id=new_id(),
            values={
                "activity_id": activity_id, "finding_key": finding["key"],
                "severity": finding["severity"], "message": finding["message"],
                "start_offset_ms": finding.get("start_offset_ms"),
                "end_offset_ms": finding.get("end_offset_ms"),
                "limits_analysis_keys_json": finding.get("limits_analysis_keys", []),
                "revision": 1,
            },
            user=user, record_sync_change=False,
        )
    activity = await (
        await db.execute(
            "SELECT classification_source FROM health_activities WHERE id = ? "
            "AND family_id = ? AND owner_user_id = ?",
            (activity_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    values: dict[str, Any] = {
        "route_preview_json": enrichment.route_preview,
        "primary_stream_asset_id": stream_id,
        "parser_version": PARSER_VERSION,
    }
    if enrichment.classification and activity and activity["classification_source"] != "user":
        values.update(
            workout_classification=enrichment.classification,
            classification_source="derived",
        )
    await update_owned(
        db, table="health_activities", record_id=activity_id, values=values,
        user=user, record_sync_change=False,
    )

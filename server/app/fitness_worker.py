"""Single-concurrency Fitness worker.

This module deliberately has no database import. It receives fenced jobs from the
private API, reads retained sources, writes temporary regenerable outputs, and sends
one manifest back for validation and a short API-side commit.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import statistics
import sys
import warnings
from bisect import bisect_left
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import fitdecode
import pyarrow as pa
import pyarrow.parquet as pq
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener

register_heif_opener()
Image.MAX_IMAGE_PIXELS = 50_000_000

PARSER_NAME = "fitdecode"
PARSER_VERSION = "fitness-fit-v3"
MAX_FIT_STREAM_ROWS = 750_000
MAX_FIT_FRAMES = 1_000_000
MAX_FIT_LAPS = 10_000
MAX_FIT_MARKERS = 10_000
MAX_NDJSON_BYTES = 256 * 1024 * 1024
MAX_CHILD_JOB_BYTES = 256 * 1024

STREAM_UNITS = {
    "distance_m": "m",
    "speed_mps": "m/s",
    "pace_s_per_km": "s/km",
    "heart_rate_bpm": "bpm",
    "altitude_m": "m",
    "latitude_deg": "deg",
    "longitude_deg": "deg",
    "cadence_spm": "spm",
    "power_w": "W",
    "temperature_c": "degC",
    "stride_length_m": "m",
    "vertical_oscillation_mm": "mm",
    "vertical_ratio_pct": "%",
    "ground_contact_time_ms": "ms",
    "ground_contact_balance_pct": "%",
    "respiration_rate_bpm": "breaths/min",
}

STREAM_SCHEMA = pa.schema(
    [
        pa.field("sample_index", pa.int32(), nullable=False),
        pa.field("timestamp_utc", pa.timestamp("ms", tz="UTC"), nullable=False),
        pa.field("elapsed_ms", pa.int64(), nullable=False),
        pa.field("timer_ms", pa.int64(), nullable=False),
        pa.field("distance_m", pa.float64()),
        pa.field("latitude_deg", pa.float64()),
        pa.field("longitude_deg", pa.float64()),
        pa.field("speed_mps", pa.float64()),
        pa.field("pace_s_per_km", pa.float64()),
        pa.field("heart_rate_bpm", pa.float64()),
        pa.field("altitude_m", pa.float64()),
        pa.field("cadence_spm", pa.float64()),
        pa.field("power_w", pa.float64()),
        pa.field("temperature_c", pa.float64()),
        pa.field("stride_length_m", pa.float64()),
        pa.field("vertical_oscillation_mm", pa.float64()),
        pa.field("vertical_ratio_pct", pa.float64()),
        pa.field("ground_contact_time_ms", pa.float64()),
        pa.field("ground_contact_balance_pct", pa.float64()),
        pa.field("respiration_rate_bpm", pa.float64()),
    ]
)


def _value(message: Any, name: str) -> Any:
    try:
        return message.get_value(name, fallback=None)
    except (KeyError, TypeError, ValueError):
        return None


def _number(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def _timestamp(value: Any) -> datetime | None:
    if not isinstance(value, datetime):
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _coordinate(value: Any, *, latitude: bool) -> float | None:
    numeric = _number(value)
    if numeric is None:
        return None
    if abs(numeric) > 180:
        numeric = numeric * 180.0 / (2**31)
    limit = 90 if latitude else 180
    return numeric if -limit <= numeric <= limit else None


def _metric(values: list[float | None]) -> dict[str, float | int | None]:
    present = [value for value in values if value is not None]
    return {
        "sample_count": len(values),
        "non_null_count": len(present),
        "minimum": min(present) if present else None,
        "maximum": max(present) if present else None,
        "average": statistics.fmean(present) if present else None,
    }


def _summary_metric(
    metric_key: str, value: float | None, unit_key: str, *, origin: str = "source"
) -> dict[str, Any] | None:
    if value is None:
        return None
    return {
        "metric_key": metric_key,
        "value_number": value,
        "unit_key": unit_key,
        "origin": origin,
        "quality": "measured" if origin == "source" else "derived",
        "calculation_version": PARSER_VERSION if origin == "derived" else None,
    }


def _sport_key(value: Any, sub_sport: Any = None) -> str:
    raw = str(value or "other").lower().replace(" ", "_")
    sub = str(sub_sport or "").lower().replace(" ", "_")
    if raw == "rowing":
        return "rowing_indoor" if sub in {"indoor_rowing", "indoor"} else "rowing_water"
    if raw == "swimming":
        return (
            "swimming_open_water"
            if sub in {"open_water", "open_water_swimming"}
            else "swimming_pool"
        )
    return {
        "running": "running",
        "walking": "walking",
        "hiking": "hiking",
        "cycling": "cycling",
        "training": "strength",
    }.get(raw, "other")


def _distance_crossing_offset(rows: list[dict[str, Any]], target_m: float) -> int | None:
    """Interpolate a distance boundary instead of assigning it to the next sample."""
    previous: dict[str, Any] | None = None
    for row in rows:
        distance = row.get("distance_m")
        if distance is None:
            continue
        if distance >= target_m:
            if previous is None or distance <= float(previous["distance_m"]):
                return int(row["elapsed_ms"])
            fraction = (target_m - float(previous["distance_m"])) / (
                float(distance) - float(previous["distance_m"])
            )
            return round(
                int(previous["elapsed_ms"])
                + fraction * (int(row["elapsed_ms"]) - int(previous["elapsed_ms"]))
            )
        previous = row
    return None


def _stream_metric_samples(
    rows: list[dict[str, Any]], metric_key: str
) -> tuple[list[int], list[float]]:
    """Return ordered elapsed offsets and finite values for one stream metric."""
    offsets: list[int] = []
    values: list[float] = []
    for row in rows:
        value = _number(row.get(metric_key))
        if value is None:
            continue
        offsets.append(int(row["elapsed_ms"]))
        values.append(value)
    return offsets, values


def _interpolated_stream_value(
    samples: tuple[list[int], list[float]], offset_ms: int
) -> float | None:
    offsets, values = samples
    if not offsets:
        return None
    right = bisect_left(offsets, offset_ms)
    if right == 0:
        return values[0]
    if right == len(offsets):
        return values[-1]
    if offsets[right] == offset_ms:
        return values[right]
    left = right - 1
    span = offsets[right] - offsets[left]
    if span <= 0:
        return values[right]
    fraction = (offset_ms - offsets[left]) / span
    return values[left] + fraction * (values[right] - values[left])


def _stream_metric_change(
    samples: tuple[list[int], list[float]], start_offset_ms: int, end_offset_ms: int
) -> float | None:
    start = _interpolated_stream_value(samples, start_offset_ms)
    end = _interpolated_stream_value(samples, end_offset_ms)
    return end - start if start is not None and end is not None else None


def _split_series(
    rows: list[dict[str, Any]],
    activity_distance: float,
    *,
    distance_m: float,
    kind: str,
    label: str,
) -> list[dict]:
    if activity_distance < distance_m:
        return []
    intervals: list[dict] = []
    previous_offset = _distance_crossing_offset(rows, 0) or 0
    previous_distance = 0.0
    number = 1
    boundary = distance_m
    altitude_samples = _stream_metric_samples(rows, "altitude_m")
    while boundary <= activity_distance + 0.01:
        offset = _distance_crossing_offset(rows, boundary)
        if offset is None:
            break
        duration_s = max(0.0, (offset - previous_offset) / 1_000)
        elevation_change = _stream_metric_change(
            altitude_samples, previous_offset, offset
        )
        intervals.append(
            {
                "sequence": len(intervals),
                "interval_kind": kind,
                "origin": "derived",
                "start_offset_ms": previous_offset,
                "end_offset_ms": offset,
                "start_distance_m": previous_distance,
                "end_distance_m": boundary,
                "label": f"{label} {number}",
                "metrics": {
                    "duration_s": duration_s,
                    "pace_s_per_km": duration_s * 1_000 / distance_m,
                    "elevation.change_m": elevation_change,
                },
            }
        )
        number += 1
        previous_offset = offset
        previous_distance = boundary
        boundary += distance_m
    return intervals


def _standard_splits(rows: list[dict[str, Any]], activity_distance: float) -> list[dict]:
    splits = _split_series(
        rows,
        activity_distance,
        distance_m=1_000.0,
        kind="kilometre_split",
        label="Kilometre",
    )
    miles = _split_series(
        rows,
        activity_distance,
        distance_m=1_609.344,
        kind="mile_split",
        label="Mile",
    )
    for item in miles:
        item["sequence"] = len(splits) + item["sequence"]
    return [*splits, *miles]


def _best_efforts(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    usable = [row for row in rows if row.get("distance_m") is not None]
    records: list[dict[str, Any]] = []
    for distance_target, key, label in (
        (1_000, "best_1k", "Best 1 km"),
        (1_609.344, "best_mile", "Best mile"),
        (5_000, "best_5k", "Best 5 km"),
        (10_000, "best_10k", "Best 10 km"),
        (21_097.5, "best_half_marathon", "Best half marathon"),
    ):
        best: tuple[int, int] | None = None
        left = 0
        for right, row in enumerate(usable):
            while (
                left < right
                and row["distance_m"] - usable[left]["distance_m"] >= distance_target
            ):
                duration = int(row["elapsed_ms"] - usable[left]["elapsed_ms"])
                if best is None or duration < best[0]:
                    best = (duration, int(row["elapsed_ms"]))
                left += 1
        if best is not None:
            records.append(
                {
                    "id": key,
                    "record_key": key,
                    "label": label,
                    "value": f"{best[0] / 1_000:.1f} s",
                    "value_s": best[0] / 1_000,
                    "achieved_at_offset_ms": best[1],
                    "is_personal_best": False,
                }
            )
    return records


def _finding(
    key: str,
    title: str,
    summary: str,
    value: float | str | dict | list | None,
    unit_key: str | None,
    *,
    evidence: list[dict[str, str]] | None = None,
    confidence: float = 0.9,
    status: str = "valid",
) -> dict[str, Any]:
    return {
        "key": key,
        "title": title,
        "summary": summary,
        "status": status,
        "value": value,
        "unit_key": unit_key,
        "quality": "derived" if status == "valid" else "limited_by_source_data",
        "confidence": confidence,
        "calculation_version": PARSER_VERSION,
        "evidence": evidence or [],
    }


def _distance_bands(
    rows: list[dict[str, Any]], distance_m: float, count: int = 20
) -> list[float | None]:
    if distance_m <= 0:
        return []
    buckets: list[list[float]] = [[] for _ in range(count)]
    for row in rows:
        distance = row.get("distance_m")
        speed = row.get("speed_mps")
        if distance is None or speed is None or speed <= 0:
            continue
        index = min(count - 1, max(0, int(float(distance) / distance_m * count)))
        buckets[index].append(float(speed))
    return [statistics.fmean(bucket) if bucket else None for bucket in buckets]


def _mean_present(values: list[float | None]) -> float | None:
    present = [float(value) for value in values if value is not None]
    return statistics.fmean(present) if present else None


def _coefficient_of_variation(values: list[float]) -> float | None:
    if len(values) < 2:
        return None
    mean = statistics.fmean(values)
    return statistics.pstdev(values) / mean if mean else None


def _heart_rate_distribution(
    rows: list[dict[str, Any]],
    boundaries_bpm: list[int] | None,
) -> tuple[list[dict], float, bool] | None:
    values = [float(row["heart_rate_bpm"]) for row in rows if row.get("heart_rate_bpm")]
    if len(values) < 10:
        return None
    observed_max = max(values)
    configured = bool(
        boundaries_bpm
        and len(boundaries_bpm) == 4
        and boundaries_bpm == sorted(set(boundaries_bpm))
    )
    thresholds = (
        [float(value) for value in boundaries_bpm]
        if configured
        else [observed_max * fraction for fraction in (0.60, 0.70, 0.80, 0.90)]
    )
    seconds = [0.0] * 5
    for current, following in zip(rows, rows[1:]):
        heart_rate = current.get("heart_rate_bpm")
        if heart_rate is None:
            continue
        duration = max(0.0, (int(following["timer_ms"]) - int(current["timer_ms"])) / 1_000)
        if duration > 60:
            continue
        zone = sum(float(heart_rate) >= threshold for threshold in thresholds)
        seconds[zone] += duration
    total = sum(seconds)
    if total <= 0:
        return None
    return (
        [
            {"zone": index + 1, "duration_s": round(value, 1), "share": round(value / total, 4)}
            for index, value in enumerate(seconds)
        ],
        observed_max,
        configured,
    )


def _nearest_hr(rows: list[dict[str, Any]], offset_ms: int) -> float | None:
    candidates = [row for row in rows if row.get("heart_rate_bpm") is not None]
    if not candidates:
        return None
    nearest = min(candidates, key=lambda row: abs(int(row["elapsed_ms"]) - offset_ms))
    if abs(int(nearest["elapsed_ms"]) - offset_ms) > 20_000:
        return None
    return float(nearest["heart_rate_bpm"])


def _haversine_m(left: tuple[float, float], right: tuple[float, float]) -> float:
    radius_m = 6_371_000.0
    lat1, lon1 = map(math.radians, left)
    lat2, lon2 = map(math.radians, right)
    delta_lat = lat2 - lat1
    delta_lon = lon2 - lon1
    value = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
    )
    return 2 * radius_m * math.asin(min(1.0, math.sqrt(value)))


def _analyse(
    rows: list[dict[str, Any]],
    distance_m: float,
    duration_s: float,
    intervals: list[dict[str, Any]],
    heart_rate_zone_boundaries_bpm: list[int] | None = None,
) -> dict:
    speeds = [float(row["speed_mps"]) for row in rows if (row.get("speed_mps") or 0) > 0]
    pacing_cv = _coefficient_of_variation(speeds)
    midpoint = distance_m / 2 if distance_m else 0
    first_rows = [row for row in rows if (row.get("distance_m") or 0) <= midpoint]
    second_rows = [row for row in rows if (row.get("distance_m") or 0) > midpoint]
    first = [float(row["speed_mps"]) for row in first_rows if (row.get("speed_mps") or 0) > 0]
    second = [float(row["speed_mps"]) for row in second_rows if (row.get("speed_mps") or 0) > 0]
    split_delta_pct = None
    if first and second:
        first_pace = 1_000 / statistics.fmean(first)
        second_pace = 1_000 / statistics.fmean(second)
        split_delta_pct = (second_pace - first_pace) / first_pace * 100

    bands = _distance_bands(rows, distance_m)
    sustainable_speed = _mean_present(bands[2:10]) if bands else None
    start_speed = _mean_present(bands[:2]) if bands else None
    finish_speed = _mean_present(bands[-2:]) if bands else None
    start_delta_pct = (
        (start_speed - sustainable_speed) / sustainable_speed * 100
        if start_speed and sustainable_speed
        else None
    )
    finishing_delta_pct = (
        (finish_speed - sustainable_speed) / sustainable_speed * 100
        if finish_speed and sustainable_speed
        else None
    )
    slowdown_fraction = None
    if sustainable_speed and len(bands) == 20:
        for index in range(10, 19):
            pair = bands[index : index + 2]
            if len(pair) == 2 and all(value is not None and value < sustainable_speed * 0.9 for value in pair):
                slowdown_fraction = index / 20
                break

    heart_rates = [float(row["heart_rate_bpm"]) for row in rows if row.get("heart_rate_bpm")]
    decoupling_pct = None
    heart_rate_drift_pct = None
    if first and second and len(heart_rates) >= 10:
        first_hr = [float(row["heart_rate_bpm"]) for row in first_rows if row.get("heart_rate_bpm")]
        second_hr = [float(row["heart_rate_bpm"]) for row in second_rows if row.get("heart_rate_bpm")]
        if first_hr and second_hr:
            first_ratio = statistics.fmean(first) / statistics.fmean(first_hr)
            second_ratio = statistics.fmean(second) / statistics.fmean(second_hr)
            decoupling_pct = (first_ratio - second_ratio) / first_ratio * 100
            heart_rate_drift_pct = (
                statistics.fmean(second_hr) - statistics.fmean(first_hr)
            ) / statistics.fmean(first_hr) * 100

    comparable_hr_pace_delta = None
    comparable_pace_hr_delta = None
    if len(heart_rates) >= 20 and speeds:
        median_hr = statistics.median(heart_rates)
        at_hr_first = [float(row["speed_mps"]) for row in first_rows if row.get("speed_mps") and row.get("heart_rate_bpm") and abs(float(row["heart_rate_bpm"]) - median_hr) <= 5]
        at_hr_second = [float(row["speed_mps"]) for row in second_rows if row.get("speed_mps") and row.get("heart_rate_bpm") and abs(float(row["heart_rate_bpm"]) - median_hr) <= 5]
        if len(at_hr_first) >= 3 and len(at_hr_second) >= 3:
            comparable_hr_pace_delta = (
                statistics.fmean(at_hr_second) - statistics.fmean(at_hr_first)
            ) / statistics.fmean(at_hr_first) * 100
        median_speed = statistics.median(speeds)
        at_pace_first = [float(row["heart_rate_bpm"]) for row in first_rows if row.get("speed_mps") and row.get("heart_rate_bpm") and abs(float(row["speed_mps"]) - median_speed) <= median_speed * 0.05]
        at_pace_second = [float(row["heart_rate_bpm"]) for row in second_rows if row.get("speed_mps") and row.get("heart_rate_bpm") and abs(float(row["speed_mps"]) - median_speed) <= median_speed * 0.05]
        if len(at_pace_first) >= 3 and len(at_pace_second) >= 3:
            comparable_pace_hr_delta = statistics.fmean(at_pace_second) - statistics.fmean(at_pace_first)

    source_laps = [item for item in intervals if item["interval_kind"] == "source_lap"]
    lap_speeds = [float(item["metrics"]["speed.average_mps"]) for item in source_laps if item["metrics"].get("speed.average_mps")]
    work_laps: list[dict[str, Any]] = []
    recovery_laps: list[dict[str, Any]] = []
    interval_cv = None
    recovery_cv = None
    heart_rate_recovery = None
    if len(lap_speeds) >= 4:
        middle_speed = statistics.median(lap_speeds)
        work_laps = [item for item in source_laps if (item["metrics"].get("speed.average_mps") or 0) >= middle_speed]
        recovery_laps = [item for item in source_laps if (item["metrics"].get("speed.average_mps") or 0) < middle_speed]
        interval_cv = _coefficient_of_variation([float(item["metrics"]["speed.average_mps"]) for item in work_laps])
        recovery_cv = _coefficient_of_variation([float(item["metrics"].get("timer_duration_s") or item["metrics"].get("elapsed_duration_s") or 0) for item in recovery_laps if (item["metrics"].get("timer_duration_s") or item["metrics"].get("elapsed_duration_s"))])
        drops = []
        for item in work_laps:
            end_offset = int(item["end_offset_ms"])
            at_end = _nearest_hr(rows, end_offset)
            after = _nearest_hr(rows, end_offset + 60_000)
            if at_end is not None and after is not None and at_end >= after:
                drops.append(at_end - after)
        if drops:
            heart_rate_recovery = statistics.fmean(drops)

    findings: list[dict[str, Any]] = []
    if pacing_cv is not None:
        findings.append(_finding("pacing_variability", "Pacing variability", f"Speed varied by {pacing_cv * 100:.1f}% around its mean.", pacing_cv * 100, "%", evidence=[{"label": "Usable speed samples", "value": str(len(speeds))}]))
    if split_delta_pct is not None:
        split_name = "negative" if split_delta_pct < 0 else "positive"
        findings.append(_finding("split_balance", "Half split", f"The second half had a {abs(split_delta_pct):.1f}% {split_name} split.", split_delta_pct, "%", evidence=[{"label": "First-half mean pace", "value": f"{1_000 / statistics.fmean(first):.1f} s/km"}, {"label": "Second-half mean pace", "value": f"{1_000 / statistics.fmean(second):.1f} s/km"}]))
    if start_delta_pct is not None:
        description = "faster" if start_delta_pct > 0 else "slower"
        findings.append(_finding("start_discipline", "Start discipline", f"The opening 10% was {abs(start_delta_pct):.1f}% {description} than the sustainable middle section.", start_delta_pct, "%", evidence=[{"label": "Opening section", "value": f"{start_speed:.2f} m/s"}, {"label": "Middle reference", "value": f"{sustainable_speed:.2f} m/s"}]))
    findings.append(_finding("slowdown_point", "Slowdown point", f"A sustained slowdown began at about {slowdown_fraction * 100:.0f}% of the distance." if slowdown_fraction is not None else "No sustained slowdown greater than 10% was detected after halfway.", slowdown_fraction * distance_m if slowdown_fraction is not None else None, "m", evidence=[{"label": "Detection rule", "value": "Two consecutive 5% distance bands >10% below middle speed"}], confidence=0.8 if slowdown_fraction is not None else 0.75))
    if finishing_delta_pct is not None:
        description = "stronger" if finishing_delta_pct > 0 else "slower"
        findings.append(_finding("finishing_strength", "Finishing strength", f"The final 10% was {abs(finishing_delta_pct):.1f}% {description} than the sustainable middle section.", finishing_delta_pct, "%", evidence=[{"label": "Final section", "value": f"{finish_speed:.2f} m/s"}, {"label": "Middle reference", "value": f"{sustainable_speed:.2f} m/s"}]))
    if interval_cv is not None:
        findings.append(_finding("interval_consistency", "Work-interval consistency", f"Source-lap work speeds varied by {interval_cv * 100:.1f}%.", interval_cv * 100, "%", evidence=[{"label": "Work laps", "value": str(len(work_laps))}]))
    if recovery_cv is not None:
        findings.append(_finding("recovery_consistency", "Recovery consistency", f"Source-lap recovery durations varied by {recovery_cv * 100:.1f}%.", recovery_cv * 100, "%", evidence=[{"label": "Recovery laps", "value": str(len(recovery_laps))}]))
    if decoupling_pct is not None:
        findings.append(_finding("heart_rate_decoupling", "Pace/heart-rate decoupling", f"Estimated speed-to-heart-rate decoupling was {decoupling_pct:.1f}%.", decoupling_pct, "%", evidence=[{"label": "Method", "value": "First-half versus second-half speed/HR ratio"}]))
    if heart_rate_drift_pct is not None:
        findings.append(_finding("heart_rate_drift", "Heart-rate drift", f"Mean heart rate changed by {heart_rate_drift_pct:+.1f}% between halves.", heart_rate_drift_pct, "%", evidence=[{"label": "Usable HR samples", "value": str(len(heart_rates))}]))
    if comparable_hr_pace_delta is not None:
        findings.append(_finding("pace_at_comparable_heart_rate", "Pace at comparable heart rate", f"At a comparable heart rate, second-half speed changed by {comparable_hr_pace_delta:+.1f}%.", comparable_hr_pace_delta, "%", evidence=[{"label": "Heart-rate band", "value": "Median ±5 bpm"}]))
    if comparable_pace_hr_delta is not None:
        findings.append(_finding("heart_rate_at_comparable_pace", "Heart rate at comparable pace", f"At a comparable pace, second-half heart rate changed by {comparable_pace_hr_delta:+.1f} bpm.", comparable_pace_hr_delta, "bpm", evidence=[{"label": "Pace band", "value": "Median speed ±5%"}]))
    if heart_rate_recovery is not None:
        findings.append(_finding("heart_rate_recovery", "Heart-rate recovery", f"Heart rate fell by an average {heart_rate_recovery:.0f} bpm in the minute after work laps.", heart_rate_recovery, "bpm", evidence=[{"label": "Work laps with HR", "value": str(len(work_laps))}]))
    zones = _heart_rate_distribution(rows, heart_rate_zone_boundaries_bpm)
    if zones is not None:
        distribution, observed_max, configured = zones
        findings.append(_finding(
            "heart_rate_zones",
            "Heart-rate zones",
            "Time in the five configured heart-rate zones."
            if configured
            else "Time in five provisional bands is shown from the observed activity maximum; configure physiological boundaries before treating these as personal zones.",
            distribution,
            "seconds",
            evidence=[
                {"label": "Zone boundaries", "value": ", ".join(str(value) for value in heart_rate_zone_boundaries_bpm)}
                if configured and heart_rate_zone_boundaries_bpm
                else {"label": "Observed maximum", "value": f"{observed_max:.0f} bpm"}
            ],
            confidence=0.9 if configured else 0.55,
            status="valid" if configured else "limited",
        ))

    classification = "unclassified"
    if interval_cv is not None and len(work_laps) >= 2:
        classification = "interval"
    elif duration_s >= 5_400:
        classification = "long"
    elif split_delta_pct is not None and split_delta_pct < -5:
        classification = "progression"

    completeness = {
        "speed": round(len(speeds) / len(rows), 4) if rows else 0,
        "heart_rate": round(len(heart_rates) / len(rows), 4) if rows else 0,
        "distance": round(sum(row.get("distance_m") is not None for row in rows) / len(rows), 4) if rows else 0,
    }
    features = {
        finding["key"]: {
            "algorithm_version": PARSER_VERSION,
            "inputs": {"sample_count": len(rows), "distance_m": distance_m, "duration_s": duration_s},
            "result": finding["value"],
            "valid": finding["status"] == "valid",
            "confidence": finding["confidence"],
            "completeness": completeness,
        }
        for finding in findings
    }
    return {"classification": classification, "findings": findings, "features": features}


def decode_fit_to_manifest(
    source_path: str | Path,
    rows_path: str | Path,
    manifest_path: str | Path,
    heart_rate_zone_boundaries_bpm: list[int] | None = None,
) -> dict[str, Any]:
    """Decode one FIT source and atomically leave a JSON result manifest."""
    source = Path(source_path)
    rows_output = Path(rows_path)
    manifest = Path(manifest_path)
    if not source.is_file():
        raise FileNotFoundError("Retained FIT source is missing")

    file_id: dict[str, Any] = {}
    session: dict[str, Any] = {}
    records: list[dict[str, Any]] = []
    raw_laps: list[dict[str, Any]] = []
    markers: list[dict[str, Any]] = []
    device_name: str | None = None
    timer_running = True
    paused_at: datetime | None = None
    paused_ms = 0
    total_frames = 0

    with fitdecode.FitReader(source, check_crc=fitdecode.CrcCheck.RAISE) as fit:
        for frame in fit:
            total_frames += 1
            if total_frames > MAX_FIT_FRAMES:
                raise ValueError("FIT file contains too many frames")
            if frame.frame_type != fitdecode.FIT_FRAME_DATA:
                continue
            name = frame.name
            if name == "file_id":
                file_id = {
                    "serial_number": str(_value(frame, "serial_number") or ""),
                    "time_created": _timestamp(_value(frame, "time_created")),
                    "manufacturer": str(_value(frame, "manufacturer") or ""),
                    "product": str(_value(frame, "product") or ""),
                }
            elif name == "device_info" and device_name is None:
                device_name = str(
                    _value(frame, "product_name") or _value(frame, "product") or ""
                ) or None
            elif name == "session":
                session = {
                    "sport": _value(frame, "sport"),
                    "sub_sport": _value(frame, "sub_sport"),
                    "start_time": _timestamp(_value(frame, "start_time")),
                    "timestamp": _timestamp(_value(frame, "timestamp")),
                    "elapsed_s": _number(_value(frame, "total_elapsed_time")),
                    "timer_s": _number(_value(frame, "total_timer_time")),
                    "moving_s": _number(_value(frame, "total_moving_time")),
                    "distance_m": _number(_value(frame, "total_distance")),
                    "energy_kcal": _number(_value(frame, "total_calories")),
                    "avg_hr": _number(_value(frame, "avg_heart_rate")),
                    "max_hr": _number(_value(frame, "max_heart_rate")),
                    "avg_cadence": _number(_value(frame, "avg_running_cadence"))
                    or _number(_value(frame, "avg_cadence")),
                    "avg_speed": _number(_value(frame, "enhanced_avg_speed"))
                    or _number(_value(frame, "avg_speed")),
                    "max_speed": _number(_value(frame, "enhanced_max_speed"))
                    or _number(_value(frame, "max_speed")),
                    "ascent_m": _number(_value(frame, "total_ascent")),
                    "descent_m": _number(_value(frame, "total_descent")),
                    "source_classification": _value(frame, "sub_sport"),
                }
            elif name == "event":
                if len(markers) >= MAX_FIT_MARKERS:
                    raise ValueError("FIT file contains too many event markers")
                event_at = _timestamp(_value(frame, "timestamp"))
                event = str(_value(frame, "event") or "")
                event_type = str(_value(frame, "event_type") or "")
                if event == "timer" and event_at:
                    if event_type in {"stop", "stop_all", "stop_disable", "stop_disable_all"}:
                        if timer_running:
                            paused_at = event_at
                            timer_running = False
                    elif event_type in {"start", "start_all"}:
                        if not timer_running and paused_at:
                            paused_ms += int((event_at - paused_at).total_seconds() * 1_000)
                        paused_at = None
                        timer_running = True
                markers.append(
                    {
                        "timestamp": event_at,
                        "marker_key": f"{event}.{event_type}".strip("."),
                        "label": event_type or event or "FIT event",
                        "payload": {"event": event, "event_type": event_type},
                    }
                )
            elif name == "record":
                timestamp = _timestamp(_value(frame, "timestamp"))
                if timestamp is None:
                    continue
                if len(records) >= MAX_FIT_STREAM_ROWS:
                    raise ValueError("FIT file contains too many recorded samples")
                speed = _number(_value(frame, "enhanced_speed")) or _number(
                    _value(frame, "speed")
                )
                records.append(
                    {
                        "timestamp_utc": timestamp,
                        "distance_m": _number(_value(frame, "distance")),
                        "latitude_deg": _coordinate(
                            _value(frame, "position_lat"), latitude=True
                        ),
                        "longitude_deg": _coordinate(
                            _value(frame, "position_long"), latitude=False
                        ),
                        "speed_mps": speed,
                        "pace_s_per_km": 1_000 / speed if speed and speed > 0 else None,
                        "heart_rate_bpm": _number(_value(frame, "heart_rate")),
                        "altitude_m": _number(_value(frame, "enhanced_altitude"))
                        or _number(_value(frame, "altitude")),
                        "cadence_spm": _number(_value(frame, "cadence")),
                        "power_w": _number(_value(frame, "power")),
                        "temperature_c": _number(_value(frame, "temperature")),
                        "stride_length_m": _number(_value(frame, "step_length"))
                        or _number(_value(frame, "stride_length")),
                        "vertical_oscillation_mm": _number(
                            _value(frame, "vertical_oscillation")
                        ),
                        "vertical_ratio_pct": _number(_value(frame, "vertical_ratio")),
                        "ground_contact_time_ms": _number(
                            _value(frame, "stance_time")
                        )
                        or _number(_value(frame, "ground_contact_time")),
                        "ground_contact_balance_pct": _number(
                            _value(frame, "stance_time_balance")
                        )
                        or _number(_value(frame, "ground_contact_time_balance")),
                        "respiration_rate_bpm": _number(
                            _value(frame, "respiration_rate")
                        ),
                        "paused_ms": paused_ms,
                    }
                )
            elif name == "lap":
                if len(raw_laps) >= MAX_FIT_LAPS:
                    raise ValueError("FIT file contains too many laps")
                raw_laps.append(
                    {
                        "start": _timestamp(_value(frame, "start_time")),
                        "end": _timestamp(_value(frame, "timestamp")),
                        "distance_m": _number(_value(frame, "total_distance")),
                        "elapsed_s": _number(_value(frame, "total_elapsed_time")),
                        "timer_s": _number(_value(frame, "total_timer_time")),
                        "avg_hr": _number(_value(frame, "avg_heart_rate")),
                        "avg_speed": _number(_value(frame, "enhanced_avg_speed"))
                        or _number(_value(frame, "avg_speed")),
                    }
                )

    if not records:
        raise ValueError("FIT file contains no timestamped record samples")
    start = session.get("start_time") or records[0]["timestamp_utc"]
    end = session.get("timestamp") or records[-1]["timestamp_utc"]
    normalized_rows: list[dict[str, Any]] = []
    for index, record in enumerate(records):
        elapsed_ms = max(0, int((record["timestamp_utc"] - start).total_seconds() * 1_000))
        normalized_rows.append(
            {
                "sample_index": index,
                "timestamp_utc": record["timestamp_utc"],
                "elapsed_ms": elapsed_ms,
                "timer_ms": max(0, elapsed_ms - int(record.pop("paused_ms", 0))),
                **record,
            }
        )

    distance_m = session.get("distance_m")
    if distance_m is None:
        distance_values = [row["distance_m"] for row in normalized_rows if row["distance_m"]]
        distance_m = max(distance_values) if distance_values else 0.0
    elapsed_s = session.get("elapsed_s") or max(
        0.0, (end - start).total_seconds()
    )
    timer_s = session.get("timer_s") or normalized_rows[-1]["timer_ms"] / 1_000
    moving_s = session.get("moving_s") or timer_s

    rows_output.parent.mkdir(parents=True, exist_ok=True)
    temporary_rows = rows_output.with_suffix(rows_output.suffix + ".tmp")
    stream_hash = hashlib.sha256()
    stream_bytes = 0
    with temporary_rows.open("xb") as handle:
        for row in normalized_rows:
            encoded = (
                json.dumps(
                    {
                        **row,
                        "timestamp_utc": row["timestamp_utc"].isoformat(),
                    },
                    separators=(",", ":"),
                )
                + "\n"
            ).encode("utf-8")
            stream_bytes += len(encoded)
            if stream_bytes > MAX_NDJSON_BYTES:
                raise ValueError("FIT activity stream is too large")
            stream_hash.update(encoded)
            handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_rows, rows_output)

    metric_index: list[dict[str, Any]] = []
    for metric_key in STREAM_UNITS:
        values = [row.get(metric_key) for row in normalized_rows]
        stats = _metric(values)
        if stats["non_null_count"]:
            metric_index.append(
                {
                    "metric_key": metric_key,
                    **stats,
                    "unit_key": STREAM_UNITS[metric_key],
                    "quality": "measured" if metric_key != "pace_s_per_km" else "derived",
                    "source_field": None if metric_key == "pace_s_per_km" else metric_key,
                }
            )

    intervals = _standard_splits(normalized_rows, float(distance_m or 0))
    altitude_samples = _stream_metric_samples(normalized_rows, "altitude_m")
    for lap_index, lap in enumerate(raw_laps):
        lap_start = lap["start"] or start
        lap_end = lap["end"] or lap_start
        lap_start_offset_ms = max(
            0, int((lap_start - start).total_seconds() * 1_000)
        )
        lap_end_offset_ms = max(
            lap_start_offset_ms, int((lap_end - start).total_seconds() * 1_000)
        )
        intervals.append(
            {
                "sequence": len(intervals),
                "interval_kind": "source_lap",
                "origin": "source",
                "start_offset_ms": lap_start_offset_ms,
                "end_offset_ms": lap_end_offset_ms,
                "start_distance_m": None,
                "end_distance_m": lap["distance_m"],
                "label": f"Lap {lap_index + 1}",
                "metrics": {
                    "distance_m": lap["distance_m"],
                    "elapsed_duration_s": lap["elapsed_s"],
                    "timer_duration_s": lap["timer_s"],
                    "heart_rate.average_bpm": lap["avg_hr"],
                    "speed.average_mps": lap["avg_speed"],
                    "elevation.change_m": _stream_metric_change(
                        altitude_samples, lap_start_offset_ms, lap_end_offset_ms
                    ),
                },
            }
        )

    speed_values = [row["speed_mps"] for row in normalized_rows if row["speed_mps"]]
    hr_values = [row["heart_rate_bpm"] for row in normalized_rows if row["heart_rate_bpm"]]
    altitude_values = [row["altitude_m"] for row in normalized_rows if row["altitude_m"]]
    analysis = _analyse(
        normalized_rows,
        float(distance_m or 0),
        float(timer_s or 0),
        intervals,
        heart_rate_zone_boundaries_bpm,
    )
    quality: list[dict[str, Any]] = []
    if any((value or 0) > 15 for value in speed_values):
        quality.append(
            {
                "key": "impossible_speed",
                "severity": "warning",
                "message": "One or more samples exceed the broad running speed limit.",
                "limits_analysis_keys": ["pacing_variability", "split_balance"],
            }
        )
    coordinate_rows = [
        row
        for row in normalized_rows
        if row["latitude_deg"] is not None and row["longitude_deg"] is not None
    ]
    gps_spikes = 0
    for previous, current in zip(coordinate_rows, coordinate_rows[1:]):
        elapsed = (int(current["elapsed_ms"]) - int(previous["elapsed_ms"])) / 1_000
        if elapsed <= 0:
            continue
        inferred_speed = _haversine_m(
            (float(previous["latitude_deg"]), float(previous["longitude_deg"])),
            (float(current["latitude_deg"]), float(current["longitude_deg"])),
        ) / elapsed
        if inferred_speed > 15:
            gps_spikes += 1
    if gps_spikes:
        quality.append(
            {
                "key": "gps_spike",
                "severity": "warning",
                "message": f"{gps_spikes} implausible GPS jump{'s were' if gps_spikes != 1 else ' was'} detected.",
                "limits_analysis_keys": [
                    "pacing_variability",
                    "split_balance",
                    "start_discipline",
                    "slowdown_point",
                    "finishing_strength",
                    "heart_rate_decoupling",
                    "pace_at_comparable_heart_rate",
                ],
            }
        )
    if coordinate_rows and len(coordinate_rows) / len(normalized_rows) < 0.8:
        quality.append(
            {
                "key": "missing_route_sections",
                "severity": "warning",
                "message": "More than 20% of samples have no route coordinate.",
                "limits_analysis_keys": ["route_overlap", "distance_aligned_overlay"],
            }
        )
    if hr_values and len(hr_values) / len(normalized_rows) < 0.8:
        quality.append(
            {
                "key": "heart_rate_dropout",
                "severity": "warning",
                "message": "Heart-rate coverage is below 80%; heart-rate conclusions are limited.",
                "limits_analysis_keys": [
                    "heart_rate_zones",
                    "heart_rate_drift",
                    "heart_rate_decoupling",
                    "heart_rate_recovery",
                    "pace_at_comparable_heart_rate",
                    "heart_rate_at_comparable_pace",
                ],
            }
        )
    cadence_values = [row["cadence_spm"] for row in normalized_rows if row["cadence_spm"]]
    if cadence_values and len(cadence_values) / len(normalized_rows) < 0.8:
        quality.append(
            {
                "key": "cadence_gap",
                "severity": "warning",
                "message": "Cadence coverage is below 80%.",
                "limits_analysis_keys": ["cadence_analysis"],
            }
        )
    longest_plateau_s = 0.0
    plateau_start = 0
    for index in range(1, len(normalized_rows)):
        previous_hr = normalized_rows[index - 1].get("heart_rate_bpm")
        current_hr = normalized_rows[index].get("heart_rate_bpm")
        if previous_hr is not None and current_hr == previous_hr:
            continue
        if index - plateau_start > 1:
            longest_plateau_s = max(
                longest_plateau_s,
                (int(normalized_rows[index - 1]["elapsed_ms"]) - int(normalized_rows[plateau_start]["elapsed_ms"])) / 1_000,
            )
        plateau_start = index
    if longest_plateau_s >= 120:
        quality.append(
            {
                "key": "heart_rate_plateau",
                "severity": "warning",
                "message": f"Heart rate was unchanged for about {longest_plateau_s / 60:.1f} minutes.",
                "limits_analysis_keys": [
                    "heart_rate_zones",
                    "heart_rate_drift",
                    "heart_rate_decoupling",
                    "heart_rate_recovery",
                ],
            }
        )
    hr_spikes = 0
    for previous, current in zip(normalized_rows, normalized_rows[1:]):
        left = previous.get("heart_rate_bpm")
        right = current.get("heart_rate_bpm")
        elapsed = (int(current["elapsed_ms"]) - int(previous["elapsed_ms"])) / 1_000
        if left is not None and right is not None and 0 < elapsed <= 10 and abs(float(right) - float(left)) > 40:
            hr_spikes += 1
    if hr_spikes:
        quality.append(
            {
                "key": "heart_rate_spike",
                "severity": "warning",
                "message": f"{hr_spikes} abrupt heart-rate jump{'s were' if hr_spikes != 1 else ' was'} detected.",
                "limits_analysis_keys": [
                    "heart_rate_zones",
                    "heart_rate_drift",
                    "heart_rate_decoupling",
                    "heart_rate_recovery",
                ],
            }
        )
    duplicate_times = len(normalized_rows) - len(
        {row["timestamp_utc"] for row in normalized_rows}
    )
    if duplicate_times:
        quality.append(
            {
                "key": "duplicate_samples",
                "severity": "warning",
                "message": f"{duplicate_times} duplicate sample timestamps were retained.",
                "limits_analysis_keys": [],
            }
        )
    if timer_s > elapsed_s + 1:
        quality.append(
            {
                "key": "timer_inconsistency",
                "severity": "warning",
                "message": "Timer duration exceeds elapsed duration in the source.",
                "limits_analysis_keys": ["plan_adherence"],
            }
        )
    final_recorded_distance = next(
        (
            float(row["distance_m"])
            for row in reversed(normalized_rows)
            if row.get("distance_m") is not None
        ),
        None,
    )
    if (
        distance_m
        and final_recorded_distance is not None
        and abs(float(distance_m) - final_recorded_distance) / float(distance_m) > 0.05
    ):
        quality.append(
            {
                "key": "incomplete_or_disagreeing_distance",
                "severity": "warning",
                "message": "Session distance and the final stream sample differ by more than 5%.",
                "limits_analysis_keys": [
                    "split_balance",
                    "start_discipline",
                    "slowdown_point",
                    "finishing_strength",
                    "plan_adherence",
                ],
            }
        )

    limited_keys = {
        key
        for finding in quality
        for key in finding.get("limits_analysis_keys", [])
    }
    for finding in analysis["findings"]:
        if finding["key"] in limited_keys and finding["status"] == "valid":
            finding["status"] = "limited"
            finding["quality"] = "limited_by_source_data"
            finding["confidence"] = min(float(finding.get("confidence") or 1), 0.5)
            feature = analysis["features"].get(finding["key"])
            if feature:
                feature["valid"] = False
                feature["confidence"] = finding["confidence"]

    summary_metrics = [
        _summary_metric("speed.average_mps", session.get("avg_speed") or (_metric(speed_values)["average"] if speed_values else None), "m/s"),
        _summary_metric("speed.maximum_mps", session.get("max_speed") or (max(speed_values) if speed_values else None), "m/s"),
        _summary_metric("heart_rate.average_bpm", session.get("avg_hr") or (statistics.fmean(hr_values) if hr_values else None), "bpm"),
        _summary_metric("heart_rate.maximum_bpm", session.get("max_hr") or (max(hr_values) if hr_values else None), "bpm"),
        _summary_metric("cadence.average_spm", session.get("avg_cadence"), "spm"),
        _summary_metric("elevation.maximum_m", max(altitude_values) if altitude_values else None, "m"),
        _summary_metric("elevation.gain_m", session.get("ascent_m"), "m"),
        _summary_metric("elevation.loss_m", session.get("descent_m"), "m"),
    ]

    coordinates = [
        [row["latitude_deg"], row["longitude_deg"]]
        for row in normalized_rows
        if row["latitude_deg"] is not None and row["longitude_deg"] is not None
    ]
    route_step = max(1, len(coordinates) // 100)
    route_preview = coordinates[::route_step]
    if coordinates and route_preview[-1] != coordinates[-1]:
        route_preview.append(coordinates[-1])

    source_identity_parts = [
        file_id.get("manufacturer") or "unknown",
        file_id.get("product") or "unknown",
        file_id.get("serial_number") or "unknown",
        start.isoformat(),
    ]
    marker_values = []
    for marker in markers:
        timestamp = marker.pop("timestamp")
        if timestamp is None:
            continue
        marker_values.append(
            {
                **marker,
                "offset_ms": max(0, int((timestamp - start).total_seconds() * 1_000)),
                "distance_m": None,
            }
        )

    result = {
        "parser_name": PARSER_NAME,
        "parser_version": PARSER_VERSION,
        "source": {
            "fit_identity": "|".join(source_identity_parts),
            "device_name": device_name,
            "manufacturer": file_id.get("manufacturer") or None,
            "source_created_at_utc": (
                file_id["time_created"].isoformat() if file_id.get("time_created") else None
            ),
        },
        "activity": {
            "sport_key": _sport_key(session.get("sport"), session.get("sub_sport")),
            "sub_sport_key": str(session.get("sub_sport") or "") or None,
            "title": "Imported run" if _sport_key(session.get("sport"), session.get("sub_sport")) == "running" else "Imported activity",
            "started_at_utc": start.isoformat(),
            "ended_at_utc": end.isoformat(),
            "elapsed_duration_s": elapsed_s,
            "timer_duration_s": timer_s,
            "moving_duration_s": moving_s,
            "distance_m": distance_m,
            "energy_kcal": session.get("energy_kcal"),
            "measurement_quality": "source_reported",
            "workout_classification": (
                str(session.get("source_classification"))
                if str(session.get("source_classification") or "")
                in {
                    "recovery",
                    "easy",
                    "steady",
                    "long",
                    "tempo",
                    "threshold",
                    "interval",
                    "hill",
                    "race",
                    "time_trial",
                    "progression",
                    "mixed",
                }
                else analysis["classification"]
            ),
            "classification_source": (
                "source"
                if str(session.get("source_classification") or "")
                in {
                    "recovery",
                    "easy",
                    "steady",
                    "long",
                    "tempo",
                    "threshold",
                    "interval",
                    "hill",
                    "race",
                    "time_trial",
                    "progression",
                    "mixed",
                }
                else "derived"
            ),
            "route_preview": route_preview,
        },
        "stream": {
            "temporary_path": rows_output.name,
            "byte_size": stream_bytes,
            "sha256": stream_hash.hexdigest(),
            "row_count": len(normalized_rows),
            "start_offset_ms": 0,
            "end_offset_ms": normalized_rows[-1]["elapsed_ms"],
            "schema_version": 1,
            "metric_index": metric_index,
        },
        "summary_metrics": [metric for metric in summary_metrics if metric is not None],
        "intervals": intervals,
        "markers": marker_values,
        "features": analysis["features"],
        "analysis_findings": analysis["findings"],
        "records": _best_efforts(normalized_rows),
        "quality_findings": quality,
    }
    manifest.parent.mkdir(parents=True, exist_ok=True)
    temporary_manifest = manifest.with_suffix(manifest.suffix + ".tmp")
    temporary_manifest.write_text(json.dumps(result, separators=(",", ":")))
    os.replace(temporary_manifest, manifest)
    return result


def _run_job(job: dict[str, Any]) -> None:
    payload = job["payload"]
    if job["job_type"] == "fit_import":
        decode_fit_to_manifest(
            payload["source_path"],
            payload["rows_temporary_path"],
            payload["manifest_path"],
            payload.get("heart_rate_zone_boundaries_bpm"),
        )
        return
    if job["job_type"] == "analysis_query":
        values: list[float] = []
        missing = 0
        maximum = min(int(payload.get("max_stream_samples", 200_000)), 200_000)
        for source_path in payload.get("source_paths", [])[:50]:
            parquet = pq.ParquetFile(source_path)
            for batch in parquet.iter_batches(
                batch_size=4_096,
                columns=["pace_s_per_km"],
            ):
                for value in batch.column(0).to_pylist():
                    if value is None:
                        missing += 1
                    else:
                        numeric = float(value)
                        if math.isfinite(numeric) and numeric > 0:
                            values.append(numeric)
                        else:
                            missing += 1
                    if len(values) + missing >= maximum:
                        break
                if len(values) + missing >= maximum:
                    break
            if len(values) + missing >= maximum:
                break
        points: list[dict[str, Any]] = []
        if values:
            lower, upper = min(values), max(values)
            bucket_count = min(12, max(1, int(math.sqrt(len(values)))))
            width = (upper - lower) / bucket_count if upper > lower else 1.0
            buckets: dict[int, list[float]] = {}
            for value in values:
                index = (
                    min(int((value - lower) / width), bucket_count - 1)
                    if width
                    else 0
                )
                buckets.setdefault(index, []).append(value)
            for index, bucket in sorted(buckets.items()):
                start = lower + index * width
                end = lower + (index + 1) * width
                points.append(
                    {
                        "key": f"pace-{index}",
                        "label": f"{start:.1f}–{end:.1f}",
                        "x_value": start + width / 2,
                        "value": float(len(bucket)),
                        "low": min(bucket),
                        "high": max(bucket),
                        "sample_size": len(bucket),
                        "missing_rate": 0.0,
                        "quality": "recorded_stream_sample",
                    }
                )
        result = {
            "source_count": len(payload.get("source_paths", [])[:50]),
            "sample_count": len(values),
            "missing_count": missing,
            "points": points,
        }
        manifest = Path(payload["manifest_path"])
        manifest.parent.mkdir(parents=True, exist_ok=True)
        temporary_manifest = manifest.with_suffix(manifest.suffix + ".tmp")
        temporary_manifest.write_text(json.dumps(result, separators=(",", ":")))
        os.replace(temporary_manifest, manifest)
        return
    if job["job_type"] == "photo_thumbnail":
        source = Path(payload["source_path"])
        destination = Path(payload["thumbnail_temporary_path"])
        manifest = Path(payload["manifest_path"])
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(source) as opened:
                opened.load()
                image = ImageOps.exif_transpose(opened)
                if image.mode in {"RGBA", "LA"} or "transparency" in image.info:
                    canvas = Image.new("RGB", image.size, "white")
                    alpha = image.getchannel("A") if "A" in image.getbands() else None
                    canvas.paste(image.convert("RGB"), mask=alpha)
                    image = canvas
                else:
                    image = image.convert("RGB")
                image.thumbnail((512, 512), Image.Resampling.LANCZOS)
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_suffix(".jpg.tmp")
                image.save(
                    temporary,
                    format="JPEG",
                    quality=82,
                    optimize=True,
                    progressive=True,
                )
                os.replace(temporary, destination)
        result = {
            "thumbnail": {
                "temporary_path": destination.name,
                "byte_size": destination.stat().st_size,
                "media_type": "image/jpeg",
            }
        }
        manifest.parent.mkdir(parents=True, exist_ok=True)
        temporary_manifest = manifest.with_suffix(manifest.suffix + ".tmp")
        temporary_manifest.write_text(json.dumps(result, separators=(",", ":")))
        os.replace(temporary_manifest, manifest)
        return
    raise ValueError(f"Unsupported Fitness job type: {job['job_type']}")


def _path_inside_exchange(root: Path, value: Any, *, must_exist: bool) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError("Fitness parser path is invalid")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Fitness parser path is invalid")
    candidate = (root / relative).resolve(strict=must_exist)
    if root not in candidate.parents:
        raise ValueError("Fitness parser path leaves its job exchange")
    return candidate


def _validate_child_job(job: Any, *, exchange_root: Path) -> dict[str, Any]:
    if not isinstance(job, dict) or set(job) != {"job_type", "payload"}:
        raise ValueError("Fitness parser job is invalid")
    job_type = job.get("job_type")
    payload = job.get("payload")
    if job_type not in {"fit_import", "analysis_query", "photo_thumbnail"}:
        raise ValueError("Fitness parser job type is invalid")
    if not isinstance(payload, dict):
        raise ValueError("Fitness parser payload is invalid")
    root = exchange_root.resolve(strict=True)
    if job_type == "fit_import":
        payload["source_path"] = str(
            _path_inside_exchange(root, payload.get("source_path"), must_exist=True)
        )
        payload["rows_temporary_path"] = str(
            _path_inside_exchange(
                root, payload.get("rows_temporary_path"), must_exist=False
            )
        )
        payload["manifest_path"] = str(
            _path_inside_exchange(root, payload.get("manifest_path"), must_exist=False)
        )
    elif job_type == "analysis_query":
        source_paths = payload.get("source_paths")
        if not isinstance(source_paths, list) or len(source_paths) > 50:
            raise ValueError("Fitness analysis inputs are invalid")
        payload["source_paths"] = [
            str(_path_inside_exchange(root, source_path, must_exist=True))
            for source_path in source_paths
        ]
        payload["manifest_path"] = str(
            _path_inside_exchange(root, payload.get("manifest_path"), must_exist=False)
        )
    else:
        payload["source_path"] = str(
            _path_inside_exchange(root, payload.get("source_path"), must_exist=True)
        )
        payload["thumbnail_temporary_path"] = str(
            _path_inside_exchange(
                root, payload.get("thumbnail_temporary_path"), must_exist=False
            )
        )
        payload["manifest_path"] = str(
            _path_inside_exchange(root, payload.get("manifest_path"), must_exist=False)
        )
    return job


def load_parser_job(job_path: str | Path) -> dict[str, Any]:
    path = Path(job_path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        stat = os.fstat(descriptor)
        if not stat.st_size or stat.st_size > MAX_CHILD_JOB_BYTES:
            raise ValueError("Fitness parser job is invalid")
        raw = os.read(descriptor, MAX_CHILD_JOB_BYTES + 1)
    finally:
        os.close(descriptor)
    return _validate_child_job(json.loads(raw), exchange_root=path.parent)


def _child_file_main(job_path: str) -> int:
    try:
        _run_job(load_parser_job(job_path))
    except (fitdecode.FitError, ValueError, json.JSONDecodeError):
        return 2
    except Exception:
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised in the worker container
    if len(sys.argv) == 3 and sys.argv[1] == "--run-job-file":
        sys.exit(_child_file_main(sys.argv[2]))
    raise SystemExit("Fitness parser requires one --run-job-file path")

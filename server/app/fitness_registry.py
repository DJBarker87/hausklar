"""Small code registries for generic Fitness sports and stream metrics."""

from __future__ import annotations

from typing import Any


SPORTS: tuple[dict[str, Any], ...] = (
    {"key": "running", "display_name": "Running", "family": "running", "distance_meaningful": True, "route_expected": True, "intervals_expected": True, "power_common": True, "cadence_common": True, "heart_rate_common": True, "planner_type": "run_steps", "analyser": "running", "default_panels": ["route_map", "synchronised_line_chart", "run_pacing_analysis", "run_heart_rate_analysis", "plan_adherence"]},
    {"key": "strength", "display_name": "Strength", "family": "strength", "distance_meaningful": False, "route_expected": False, "intervals_expected": True, "power_common": False, "cadence_common": False, "heart_rate_common": False, "planner_type": "strength_exercises", "analyser": "strength", "default_panels": ["strength_exercise_summary", "strength_muscle_summary", "plan_adherence"]},
    {"key": "walking", "display_name": "Walking", "family": "foot", "distance_meaningful": True, "route_expected": True, "intervals_expected": False, "power_common": False, "cadence_common": True, "heart_rate_common": True, "planner_type": "generic", "analyser": "generic", "default_panels": ["route_map", "synchronised_line_chart"]},
    {"key": "hiking", "display_name": "Hiking", "family": "foot", "distance_meaningful": True, "route_expected": True, "intervals_expected": False, "power_common": False, "cadence_common": True, "heart_rate_common": True, "planner_type": "generic", "analyser": "generic", "default_panels": ["route_map", "synchronised_line_chart", "elevation"]},
    {"key": "cycling", "display_name": "Cycling", "family": "cycling", "distance_meaningful": True, "route_expected": True, "intervals_expected": True, "power_common": True, "cadence_common": True, "heart_rate_common": True, "planner_type": "generic", "analyser": "generic", "default_panels": ["route_map", "synchronised_line_chart", "power"]},
    {"key": "rowing_indoor", "display_name": "Indoor rowing", "family": "rowing", "distance_meaningful": True, "route_expected": False, "intervals_expected": True, "power_common": True, "cadence_common": True, "heart_rate_common": True, "planner_type": "generic", "analyser": "generic", "default_panels": ["synchronised_line_chart", "power"]},
    {"key": "rowing_water", "display_name": "Water rowing", "family": "rowing", "distance_meaningful": True, "route_expected": True, "intervals_expected": True, "power_common": True, "cadence_common": True, "heart_rate_common": True, "planner_type": "generic", "analyser": "generic", "default_panels": ["route_map", "synchronised_line_chart"]},
    {"key": "swimming_pool", "display_name": "Pool swimming", "family": "swimming", "distance_meaningful": True, "route_expected": False, "intervals_expected": True, "power_common": False, "cadence_common": True, "heart_rate_common": True, "planner_type": "generic", "analyser": "generic", "default_panels": ["synchronised_line_chart"]},
    {"key": "swimming_open_water", "display_name": "Open-water swimming", "family": "swimming", "distance_meaningful": True, "route_expected": True, "intervals_expected": True, "power_common": False, "cadence_common": True, "heart_rate_common": True, "planner_type": "generic", "analyser": "generic", "default_panels": ["route_map", "synchronised_line_chart"]},
    {"key": "other", "display_name": "Other activity", "family": "other", "distance_meaningful": False, "route_expected": False, "intervals_expected": False, "power_common": False, "cadence_common": False, "heart_rate_common": True, "planner_type": "generic", "analyser": "generic", "default_panels": ["synchronised_line_chart"]},
)


def _metric(
    key: str,
    display_name: str,
    unit: str,
    valid_range: tuple[float, float] | None,
    *,
    interpolation: bool = True,
    chart: str = "line",
    aggregations: tuple[str, ...] = ("average", "minimum", "maximum"),
    favourable: str | None = None,
    origin: str = "source",
    families: tuple[str, ...] = (),
) -> dict[str, Any]:
    return {
        "key": key,
        "display_name": display_name,
        "value_type": "number",
        "canonical_unit": unit,
        "valid_range": list(valid_range) if valid_range else None,
        "interpolation_allowed": interpolation,
        "default_chart_style": chart,
        "default_aggregations": list(aggregations),
        "favourable_direction": favourable,
        "origin": origin,
        "sport_families": list(families),
    }


METRICS: tuple[dict[str, Any], ...] = (
    _metric("distance_m", "Distance", "m", (0, 1_000_000), favourable="higher"),
    _metric("speed_mps", "Speed", "m/s", (0, 40), favourable="higher"),
    _metric("pace_s_per_km", "Pace", "s/km", (90, 3_600), favourable="lower", origin="derived", families=("running", "foot")),
    _metric("heart_rate_bpm", "Heart rate", "bpm", (20, 260), interpolation=False),
    _metric("altitude_m", "Altitude", "m", (-500, 9_000), favourable=None),
    _metric("latitude_deg", "Latitude", "deg", (-90, 90), favourable=None),
    _metric("longitude_deg", "Longitude", "deg", (-180, 180), favourable=None),
    _metric("cadence_spm", "Cadence", "spm", (0, 300), interpolation=False),
    _metric("power_w", "Power", "W", (0, 3_000), favourable="higher"),
    _metric("temperature_c", "Temperature", "degC", (-80, 80), favourable=None),
    _metric("stride_length_m", "Stride length", "m", (0, 5), families=("running", "foot")),
    _metric("vertical_oscillation_mm", "Vertical oscillation", "mm", (0, 300), families=("running",)),
    _metric("vertical_ratio_pct", "Vertical ratio", "%", (0, 30), families=("running",)),
    _metric("ground_contact_time_ms", "Ground contact time", "ms", (0, 1_000), families=("running",)),
    _metric("ground_contact_balance_pct", "Ground contact balance", "%", (0, 100), families=("running",)),
    _metric("respiration_rate_bpm", "Respiration rate", "breaths/min", (0, 120), interpolation=False),
)


def activity_registry() -> dict[str, list[dict[str, Any]]]:
    return {"sports": [dict(item) for item in SPORTS], "metrics": [dict(item) for item in METRICS]}

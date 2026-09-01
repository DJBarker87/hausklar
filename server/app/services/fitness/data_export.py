"""Owner-private Fitness data export with originals and full normalized streams."""

from __future__ import annotations

import asyncio
import csv
import io
import json
import re
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from app.services.fitness.activity_import import asset_path


EXPORT_TABLES = (
    "health_cycle_settings",
    "health_cycle_period_starts",
    "health_user_settings",
    "health_fitness_reminders",
    "health_onboarding_profiles",
    "health_goals",
    "health_goal_relationships",
    "health_training_phases",
    "health_training_phase_goal_links",
    "health_training_programmes",
    "health_training_programme_goal_links",
    "health_workout_definitions",
    "health_workout_versions",
    "health_strength_workout_exercises",
    "health_strength_workout_exercise_substitutions",
    "health_strength_planned_sets",
    "health_planned_sessions",
    "health_planned_session_goal_links",
    "health_planned_session_exercises",
    "health_planned_session_exercise_substitutions",
    "health_planned_session_sets",
    "health_planned_session_gear_links",
    "health_intervals_publications",
    "health_foods",
    "health_food_versions",
    "health_food_servings",
    "health_recipes",
    "health_recipe_versions",
    "health_recipe_components",
    "health_meal_templates",
    "health_meal_template_items",
    "health_food_log_entries",
    "health_nutrition_targets",
    "health_body_measurements",
    "health_sleep_sessions",
    "health_sleep_stages",
    "health_recovery_observations",
    "health_source_records",
    "health_source_priorities",
    "health_imports",
    "health_import_review_candidates",
    "health_activities",
    "health_activity_source_records",
    "health_activity_features",
    "health_activity_markers",
    "health_activity_intervals",
    "health_activity_summary_metrics",
    "health_activity_metric_index",
    "health_activity_stream_assets",
    "health_activity_analysis_results",
    "health_activity_quality_findings",
    "health_run_workout_steps",
    "health_run_workout_cues",
    "health_exercises",
    "health_exercise_muscle_roles",
    "health_exercise_setups",
    "health_strength_session_exercises",
    "health_strength_set_groups",
    "health_strength_sets",
    "health_session_checkins",
    "health_body_issue_observations",
    "health_gear_items",
    "health_activity_gear_links",
    "health_activity_goal_links",
    "health_plan_activity_links",
    "health_progress_photos",
    "health_saved_analysis_charts",
    "health_coach_proposals",
    "health_coach_recommendations",
    "health_coach_conversations",
    "health_coach_messages",
    "health_coach_memories",
)

SHARED_EXPORT_TABLES = ("health_household_meal_recipe_links",)


def _json_row(row) -> dict:
    result = dict(row)
    for key, value in list(result.items()):
        if key.endswith("_json") and isinstance(value, str):
            try:
                result[key.removesuffix("_json")] = json.loads(value)
                del result[key]
            except json.JSONDecodeError:
                pass
    return result


def _merge_rows(existing: list[dict], additions) -> list[dict]:
    by_id = {row["id"]: row for row in existing}
    for row in additions:
        decoded = _json_row(row)
        by_id.setdefault(decoded["id"], decoded)
    return sorted(by_id.values(), key=lambda row: (row["created_at"], row["id"]))


async def _include_linked_household_recipes(db, *, family_id: str, tables: dict) -> None:
    """Make each exported family link self-contained without exporting private diaries."""
    versions = await (
        await db.execute(
            "SELECT DISTINCT v.* FROM health_household_meal_recipe_links l "
            "JOIN health_recipe_versions v ON v.id = l.recipe_version_id "
            "AND v.family_id = l.family_id WHERE l.family_id = ? "
            "ORDER BY v.created_at, v.id",
            (family_id,),
        )
    ).fetchall()
    recipes = await (
        await db.execute(
            "SELECT DISTINCT r.* FROM health_household_meal_recipe_links l "
            "JOIN health_recipe_versions v ON v.id = l.recipe_version_id "
            "AND v.family_id = l.family_id "
            "JOIN health_recipes r ON r.id = v.recipe_id AND r.family_id = v.family_id "
            "WHERE l.family_id = ? ORDER BY r.created_at, r.id",
            (family_id,),
        )
    ).fetchall()
    tables["health_recipe_versions"] = _merge_rows(tables["health_recipe_versions"], versions)
    tables["health_recipes"] = _merge_rows(tables["health_recipes"], recipes)


def _safe_name(value: str | None, fallback: str) -> str:
    basename = Path(value or "").name
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", basename).strip(".-")
    return (cleaned[:160] or fallback).replace("..", ".")


def _write_csv(archive: zipfile.ZipFile, name: str, rows: Iterable[dict]) -> None:
    materialized = list(rows)
    if not materialized:
        archive.writestr(name, "")
        return
    fields: list[str] = []
    for row in materialized:
        fields.extend(key for key in row if key not in fields)
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    for row in materialized:
        writer.writerow(
            {
                key: json.dumps(value, ensure_ascii=False)
                if isinstance(value, (dict, list))
                else value
                for key, value in row.items()
            }
        )
    archive.writestr(name, output.getvalue())


def _joined_strength_rows(tables: dict[str, list[dict]]) -> list[dict]:
    activities = {row["id"]: row for row in tables["health_activities"]}
    session_exercises = {row["id"]: row for row in tables["health_strength_session_exercises"]}
    exercises = {row["id"]: row for row in tables["health_exercises"]}
    groups = {row["id"]: row for row in tables["health_strength_set_groups"]}
    result = []
    for component in tables["health_strength_sets"]:
        group = groups.get(component["set_group_id"], {})
        session_exercise = session_exercises.get(group.get("session_exercise_id"), {})
        activity = activities.get(group.get("activity_id"), {})
        exercise = exercises.get(session_exercise.get("exercise_id"), {})
        result.append(
            {
                "activity_id": activity.get("id"),
                "activity_title": activity.get("title"),
                "started_at_utc": activity.get("started_at_utc"),
                "exercise_id": exercise.get("id"),
                "exercise_name": exercise.get("name"),
                "source_setup_label": session_exercise.get("exercise_setup_name_snapshot"),
                "group_id": group.get("id"),
                "training_role": group.get("training_role"),
                "structure_type": group.get("structure_type"),
                "failure_state": group.get("failure_state"),
                **component,
            }
        )
    return result


def _build_archive(
    tables: dict[str, list[dict]],
    original_assets: list[dict],
    stream_assets: list[dict],
):
    output = tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024, mode="w+b")
    missing_assets: list[str] = []
    with zipfile.ZipFile(output, mode="w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "fitness-data.json",
            json.dumps(
                {
                    "format": "hausklar-fitness-export-v1",
                    "exported_at": datetime.now(timezone.utc).isoformat(),
                    "tables": tables,
                },
                ensure_ascii=False,
                indent=2,
            ),
        )
        _write_csv(
            archive,
            "csv/nutrition-diary.csv",
            tables["health_food_log_entries"],
        )
        _write_csv(
            archive,
            "csv/body-measurements.csv",
            tables["health_body_measurements"],
        )
        _write_csv(archive, "csv/activities.csv", tables["health_activities"])
        _write_csv(
            archive,
            "csv/strength-sets.csv",
            _joined_strength_rows(tables),
        )
        _write_csv(archive, "csv/session-checkins.csv", tables["health_session_checkins"])
        _write_csv(archive, "csv/body-issues.csv", tables["health_body_issue_observations"])
        for asset in [*original_assets, *stream_assets]:
            try:
                source = asset_path(asset)
            except (OSError, ValueError):
                missing_assets.append(asset["id"])
                continue
            if not source.is_file():
                missing_assets.append(asset["id"])
                continue
            filename = _safe_name(
                asset.get("original_filename"),
                f"{asset['id']}.bin",
            )
            if asset["asset_kind"] == "activity_stream":
                archive.write(
                    source,
                    arcname=f"normalized-streams/{asset['id']}-{filename.removesuffix('.bin')}.parquet",
                )
            else:
                archive.write(
                    source,
                    arcname=f"original-assets/{asset['asset_kind']}/{asset['id']}-{filename}",
                )
        archive.writestr(
            "manifest.json",
            json.dumps(
                {
                    "format": "hausklar-fitness-export-v1",
                    "table_row_counts": {table: len(rows) for table, rows in tables.items()},
                    "included_original_asset_ids": [
                        asset["id"]
                        for asset in original_assets
                        if asset["id"] not in missing_assets
                    ],
                    "included_normalized_stream_asset_ids": [
                        asset["id"] for asset in stream_assets if asset["id"] not in missing_assets
                    ],
                    "missing_asset_ids": missing_assets,
                    "normalized_streams_are_full_resolution": True,
                    "excluded_regenerable_asset_kinds": ["garmin_workout", "photo_thumbnail"],
                    "includes_soft_deleted_records": True,
                    "excluded_derived_tables": [
                        "health_garmin_exports",
                    ],
                    "excluded_operational_tables": [
                        "health_intervals_connections",
                        "health_intervals_oauth_states",
                        "health_jobs",
                        "health_file_reconciliation_runs",
                        "health_sync_mutation_receipts",
                        "health_change_log",
                        "health_sync_notices",
                    ],
                    "excluded_shared_registries": ["health_body_locations"],
                },
                ensure_ascii=False,
                indent=2,
            ),
        )
    output.seek(0)
    return output


async def build_fitness_export(db, *, user: dict):
    """Read owner rows asynchronously, then build/compress the ZIP off-loop.

    Soft-deleted records are intentionally included because they remain retained
    owner data until account deletion; the manifest states this explicitly.
    """
    tables: dict[str, list[dict]] = {}
    for table in EXPORT_TABLES:
        rows = await (
            await db.execute(
                f"SELECT * FROM {table} WHERE family_id = ? AND owner_user_id = ? "
                "ORDER BY created_at, id",
                (user["family_id"], user["id"]),
            )
        ).fetchall()
        tables[table] = [_json_row(row) for row in rows]
        if table == "health_intervals_publications":
            # Keep owner-visible delivery metadata without duplicating the
            # outbound workout body. Credential rows are excluded entirely.
            for row in tables[table]:
                row.pop("payload", None)
                row.pop("payload_json", None)
    for table in SHARED_EXPORT_TABLES:
        rows = await (
            await db.execute(
                f"SELECT * FROM {table} WHERE family_id = ? ORDER BY created_at, id",
                (user["family_id"],),
            )
        ).fetchall()
        tables[table] = [_json_row(row) for row in rows]
    await _include_linked_household_recipes(
        db,
        family_id=user["family_id"],
        tables=tables,
    )
    original_asset_rows = await (
        await db.execute(
            "SELECT * FROM health_file_assets WHERE family_id = ? AND owner_user_id = ? "
            "AND storage_class IN ('source_required','private_required') "
            "AND asset_kind IN ('fit_source','progress_photo','nutrition_label') "
            "AND state = 'ready' AND deleted_at IS NULL ORDER BY created_at, id",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    stream_asset_rows = await (
        await db.execute(
            "SELECT * FROM health_file_assets WHERE family_id = ? AND owner_user_id = ? "
            "AND storage_class = 'regenerable' AND asset_kind = 'activity_stream' "
            "AND state = 'ready' AND deleted_at IS NULL ORDER BY created_at, id",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    original_assets = [_json_row(row) for row in original_asset_rows]
    stream_assets = [_json_row(row) for row in stream_asset_rows]
    tables["health_file_assets"] = [*original_assets, *stream_assets]
    return await asyncio.to_thread(
        _build_archive,
        tables,
        original_assets,
        stream_assets,
    )

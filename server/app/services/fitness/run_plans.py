"""Structured running workout validation, persistence and Garmin FIT export."""

from __future__ import annotations

import os
import struct
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app.models.fitness import RunWorkoutCuePayload, RunWorkoutStepPayload
from app.services.fitness.activity_import import fitness_cache_root
from app.services.fitness.common import (
    FitnessConflictError,
    decoded_row,
    insert_owned,
    new_id,
    now_iso,
    owned_row,
    update_owned,
)


TARGET_UNITS = {
    "pace_s_per_km": "s/km",
    "heart_rate_bpm": "bpm",
    "heart_rate_zone": "zone",
    "power_w": "W",
    "power_zone": "zone",
    "cadence_spm": "spm",
    "rpe": "rpe",
    "none": None,
}


def _walk_steps(steps: list[RunWorkoutStepPayload], multiplier: int = 1):
    for step in steps:
        if step.step_kind == "repeat_block":
            repeat = int(step.repeat_count or 0) * multiplier
            yield from _walk_steps(step.children, repeat)
        else:
            for _ in range(multiplier):
                yield step


def validate_run_steps(
    steps: list[RunWorkoutStepPayload],
    cues: list[RunWorkoutCuePayload],
    *,
    expected_distance_m: float | None,
    expected_duration_s: int | None,
) -> dict:
    if not steps:
        return {"total_distance_m": None, "total_duration_s": None, "warnings": []}
    all_ids: set[str] = set()

    def validate_siblings(siblings: list[RunWorkoutStepPayload]) -> None:
        sequences = [step.sequence for step in siblings]
        if len(sequences) != len(set(sequences)):
            raise FitnessConflictError("Run step sequence values must be unique among siblings")
        for step in siblings:
            if step.id:
                identifier = str(step.id)
                if identifier in all_ids:
                    raise FitnessConflictError("Run step identifiers must be unique")
                all_ids.add(identifier)
            expected_unit = TARGET_UNITS[step.target_type]
            if step.target_unit != expected_unit:
                raise FitnessConflictError(
                    f"{step.target_type} targets must use {expected_unit or 'no unit'}"
                )
            if step.target_type != "none" and (
                step.target_low is None or step.target_high is None
            ):
                raise FitnessConflictError("Run step targets need both low and high values")
            if step.target_type == "rpe" and (
                (step.target_low or 0) < 0 or (step.target_high or 0) > 10
            ):
                raise FitnessConflictError("RPE targets must be between 0 and 10")
            if step.target_type in {"heart_rate_zone", "power_zone"} and (
                (step.target_low or 0) < 1 or (step.target_high or 0) > 10
            ):
                raise FitnessConflictError("Zone targets are outside the supported range")
            validate_siblings(step.children)

    validate_siblings(steps)
    leaves = list(_walk_steps(steps))
    total_distance = sum(
        float(step.duration_value or 0)
        for step in leaves
        if step.duration_type == "distance_m"
    )
    known_duration = 0.0
    for step in leaves:
        if step.duration_type == "time_s":
            known_duration += float(step.duration_value or 0)
    distance_is_fully_known = bool(leaves) and all(
        step.duration_type == "distance_m" for step in leaves
    )
    duration_is_fully_known = bool(leaves) and all(
        step.duration_type == "time_s" for step in leaves
    )
    if (
        expected_distance_m is not None
        and distance_is_fully_known
        and abs(total_distance - expected_distance_m) > 1
    ):
        raise FitnessConflictError("Displayed workout distance does not match its leaf steps")
    if (
        expected_duration_s is not None
        and duration_is_fully_known
        and abs(known_duration - expected_duration_s) > 1
    ):
        raise FitnessConflictError("Displayed workout duration does not match its leaf steps")
    kilometre_indices = sorted(
        step.kilometre_index for step in leaves if step.kilometre_index is not None
    )
    if kilometre_indices and kilometre_indices != list(
        range(1, len(kilometre_indices) + 1)
    ):
        raise FitnessConflictError("Kilometre steps must have no gaps or duplicates")
    known_step_ids = {str(step.id) for step in leaves if step.id}
    for cue in cues:
        if cue.step_id and str(cue.step_id) not in known_step_ids:
            raise FitnessConflictError("A run cue references a step outside this workout")
        needs_value = cue.trigger_type in {
            "distance_from_workout_start_m",
            "distance_from_step_start_m",
            "time_from_workout_start_s",
            "time_from_step_start_s",
        }
        if needs_value != (cue.trigger_value is not None):
            raise FitnessConflictError("The selected cue trigger has an invalid trigger_value")
    warnings = []
    if any(step.spoken_cue_text for step in leaves) or any(cue.spoken_text for cue in cues):
        warnings.append(
            "Standard Garmin workout FIT files cannot promise arbitrary spoken cue text."
        )
    return {
        "total_distance_m": total_distance or None,
        "total_duration_s": known_duration or None,
        "warnings": warnings,
    }


async def planning_context_warnings(
    db, *, user: dict, planned_distance_m: float | None
) -> list[str]:
    warnings: list[str] = []
    issue = await (
        await db.execute(
            "SELECT 1 FROM health_body_issue_observations WHERE family_id = ? "
            "AND owner_user_id = ? AND status = 'active' AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if issue:
        warnings.append("Active body issues are recorded; review them before accepting this run.")
    altered = await (
        await db.execute(
            "SELECT 1 FROM health_body_issue_observations WHERE family_id = ? "
            "AND owner_user_id = ? AND changed_session = 1 AND deleted_at IS NULL "
            "ORDER BY observed_at_utc DESC LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if altered:
        warnings.append("A recent body issue altered or stopped a session; review before acceptance.")
    if planned_distance_m:
        recent = await (
            await db.execute(
                "SELECT MAX(distance_m) AS longest FROM health_activities WHERE family_id = ? "
                "AND owner_user_id = ? AND sport_key = 'running' AND status = 'completed' "
                "AND started_at_utc >= ? AND deleted_at IS NULL",
                (
                    user["family_id"],
                    user["id"],
                    (datetime.now(timezone.utc) - timedelta(days=42)).isoformat(),
                ),
            )
        ).fetchone()
        # The date predicate above can be empty on a fresh database; a bounded
        # all-time fallback keeps this warning useful without claiming safety.
        longest = float(recent["longest"] or 0) if recent else 0
        if longest and planned_distance_m > longest * 1.5:
            warnings.append("Planned distance is over 50% longer than the recent longest run.")
    return warnings


async def persist_run_plan(
    db,
    *,
    user: dict,
    version_id: str,
    steps: list[RunWorkoutStepPayload],
    cues: list[RunWorkoutCuePayload],
) -> None:
    id_map: dict[str, str] = {}

    def allocate(items: list[RunWorkoutStepPayload]) -> None:
        for step in items:
            identifier = new_id(step.id)
            if step.id:
                id_map[str(step.id)] = identifier
            id_map[f"object:{id(step)}"] = identifier
            allocate(step.children)

    allocate(steps)

    async def write(items: list[RunWorkoutStepPayload], parent_id: str | None) -> None:
        for step in sorted(items, key=lambda item: item.sequence):
            identifier = id_map[f"object:{id(step)}"]
            await insert_owned(
                db,
                table="health_run_workout_steps",
                record_id=identifier,
                values={
                    "workout_version_id": version_id,
                    "parent_step_id": parent_id,
                    "sequence": step.sequence,
                    "kilometre_index": step.kilometre_index,
                    "step_kind": step.step_kind,
                    "repeat_count": step.repeat_count,
                    "duration_type": step.duration_type,
                    "duration_value": step.duration_value,
                    "target_type": step.target_type,
                    "target_low": step.target_low,
                    "target_high": step.target_high,
                    "target_unit": step.target_unit,
                    "intensity_label": step.intensity_label,
                    "display_name": step.display_name,
                    "instruction_text": step.instruction_text,
                    "mental_cue_text": step.mental_cue_text,
                    "spoken_cue_text": step.spoken_cue_text,
                    "allow_manual_advance": step.allow_manual_advance,
                    "notes": step.notes,
                    "revision": 1,
                },
                user=user,
            )
            await write(step.children, identifier)

    await write(steps, None)
    for cue in sorted(cues, key=lambda item: item.sequence):
        await insert_owned(
            db,
            table="health_run_workout_cues",
            record_id=new_id(cue.id),
            values={
                "workout_version_id": version_id,
                "step_id": id_map.get(str(cue.step_id)) if cue.step_id else None,
                "sequence": cue.sequence,
                "trigger_type": cue.trigger_type,
                "trigger_value": cue.trigger_value,
                "short_text": cue.short_text,
                "spoken_text": cue.spoken_text,
                "priority": cue.priority,
                "revision": 1,
            },
            user=user,
        )


async def run_steps_for_version(db, *, user: dict, version_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_run_workout_steps WHERE family_id = ? "
            "AND owner_user_id = ? AND workout_version_id = ? AND deleted_at IS NULL "
            "ORDER BY parent_step_id, sequence",
            (user["family_id"], user["id"], version_id),
        )
    ).fetchall()
    items = {row["id"]: decoded_row(row) for row in rows}
    roots: list[dict] = []
    for item in items.values():
        item["children"] = []
    for item in items.values():
        parent = item.get("parent_step_id")
        if parent and parent in items:
            items[parent]["children"].append(item)
        else:
            roots.append(item)
    for item in items.values():
        item["children"].sort(key=lambda child: child["sequence"])
    roots.sort(key=lambda item: item["sequence"])
    return roots


async def run_cues_for_version(db, *, user: dict, version_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_run_workout_cues WHERE family_id = ? "
            "AND owner_user_id = ? AND workout_version_id = ? AND deleted_at IS NULL "
            "ORDER BY sequence",
            (user["family_id"], user["id"], version_id),
        )
    ).fetchall()
    return [decoded_row(row) for row in rows]


async def accept_workout_version(
    db, *, user: dict, definition_id: str, version_id: str
) -> dict:
    version = await owned_row(
        db, table="health_workout_versions", record_id=version_id, user=user
    )
    if version["workout_definition_id"] != definition_id:
        raise FitnessConflictError("Workout version does not belong to this definition")
    if not version["accepted_at"]:
        timestamp = now_iso()
        await update_owned(
            db,
            table="health_workout_versions",
            record_id=version_id,
            values={"accepted_at": timestamp, "accepted_by": user["id"]},
            user=user,
        )
        await update_owned(
            db,
            table="health_workout_definitions",
            record_id=definition_id,
            values={},
            user=user,
        )
    from app.services.fitness.templates import workout_version_response

    return await workout_version_response(db, user=user, version_id=version_id)


# FIT CRC implementation from the public FIT protocol. It is intentionally local
# so Garmin export does not add a second heavyweight SDK dependency.
_CRC_TABLE = (
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
)


def _fit_crc(data: bytes, crc: int = 0) -> int:
    for byte in data:
        tmp = _CRC_TABLE[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc ^= tmp ^ _CRC_TABLE[byte & 0xF]
        tmp = _CRC_TABLE[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc ^= tmp ^ _CRC_TABLE[(byte >> 4) & 0xF]
    return crc


def _definition(local: int, global_number: int, fields: list[tuple[int, int, int]]) -> bytes:
    return bytes([0x40 | local, 0, 0]) + struct.pack("<H", global_number) + bytes(
        [len(fields)]
    ) + b"".join(bytes(field) for field in fields)


def _fit_string(value: str, size: int) -> bytes:
    raw = value.encode("utf-8")[: size - 1]
    return raw + b"\x00" * (size - len(raw))


def _fit_sport(sport_key: str) -> int:
    return {
        "running": 1,
        "cycling": 2,
        "swimming_pool": 5,
        "strength": 10,
        "walking": 11,
        "hiking": 17,
    }.get(sport_key, 0)


def _fit_intensity(label: str | None, name: str) -> int:
    text = f"{label or ''} {name}".lower()
    if "warm" in text:
        return 2
    if "cool" in text:
        return 3
    if "recover" in text or "rest" in text:
        return 4
    if "interval" in text:
        return 5
    return 0


def encode_garmin_workout(
    *, sport_key: str, title: str, steps: list[dict], cues: list[dict]
) -> tuple[bytes, list[dict]]:
    """Encode the standard FIT workout subset and return an honest mapping report."""
    messages: list[bytes] = []
    report = [
        {"field": "sport", "status": "exported", "detail": "Mapped to FIT workout sport."},
        {"field": "workout_name", "status": "shortened" if len(title.encode()) > 31 else "exported", "detail": "Stored in the FIT workout name field (31 UTF-8 bytes maximum)."},
    ]
    file_fields = [(0, 1, 0x00), (1, 2, 0x84), (2, 2, 0x84), (4, 4, 0x86)]
    messages.append(_definition(0, 0, file_fields))
    fit_epoch = datetime(1989, 12, 31, tzinfo=timezone.utc)
    created = int((datetime.now(timezone.utc) - fit_epoch).total_seconds())
    messages.append(bytes([0]) + struct.pack("<BHHI", 5, 255, 0, created))

    emitted: list[dict] = []

    def emit(items: list[dict]) -> None:
        for item in sorted(items, key=lambda value: value["sequence"]):
            if item["step_kind"] == "repeat_block":
                start_index = len(emitted)
                emit(item.get("children", []))
                emitted.append(
                    {
                        "name": item["display_name"],
                        "duration_type": 6,
                        "duration_value": start_index,
                        "target_type": 2,
                        "target_value": int(item.get("repeat_count") or 1),
                        "low": 0,
                        "high": 0,
                        "intensity": 5,
                    }
                )
                continue
            duration_type = item["duration_type"]
            if duration_type == "time_s":
                fit_duration, fit_value = 0, round(float(item["duration_value"]) * 1_000)
            elif duration_type == "distance_m":
                fit_duration, fit_value = 1, round(float(item["duration_value"]) * 100)
            elif duration_type == "calories":
                fit_duration, fit_value = 3, round(float(item["duration_value"]))
            else:
                fit_duration, fit_value = 5, 0
            target_type = item["target_type"]
            low = float(item.get("target_low") or 0)
            high = float(item.get("target_high") or 0)
            fit_target = 2
            target_value = 0
            fit_low = fit_high = 0
            if target_type == "pace_s_per_km":
                fit_target = 0
                fit_low = round((1_000 / high) * 1_000) if high else 0
                fit_high = round((1_000 / low) * 1_000) if low else 0
            elif target_type == "heart_rate_bpm":
                fit_target = 1
                fit_low, fit_high = round(low + 100), round(high + 100)
            elif target_type == "heart_rate_zone":
                fit_target, target_value = 1, round(low)
            elif target_type == "cadence_spm":
                fit_target, fit_low, fit_high = 3, round(low), round(high)
            elif target_type == "power_w":
                fit_target, fit_low, fit_high = 4, round(low + 1000), round(high + 1000)
            elif target_type == "power_zone":
                fit_target, target_value = 4, round(low)
            elif target_type == "rpe":
                report.append(
                    {"field": f"step.{item['id']}.rpe", "status": "omitted", "detail": "Standard FIT workout targets do not represent HausKlar RPE ranges."}
                )
            emitted.append(
                {
                    "name": item["display_name"],
                    "duration_type": fit_duration,
                    "duration_value": fit_value,
                    "target_type": fit_target,
                    "target_value": target_value,
                    "low": fit_low,
                    "high": fit_high,
                    "intensity": _fit_intensity(item.get("intensity_label"), item["display_name"]),
                }
            )
            for field in ("instruction_text", "mental_cue_text", "spoken_cue_text"):
                if item.get(field):
                    report.append(
                        {"field": f"step.{item['id']}.{field}", "status": "omitted", "detail": "Retained in HausKlar; arbitrary cue text is not promised by standard FIT."}
                    )

    emit(steps)
    workout_fields = [(4, 1, 0x00), (5, 4, 0x8C), (6, 2, 0x84), (8, 32, 0x07)]
    messages.append(_definition(1, 26, workout_fields))
    capabilities = 1 | 2 | 128 | 256 | 512 | 1024 | 2048
    messages.append(
        bytes([1])
        + struct.pack("<BIH", _fit_sport(sport_key), capabilities, len(emitted))
        + _fit_string(title, 32)
    )
    step_fields = [
        (254, 2, 0x84),
        (0, 32, 0x07),
        (1, 1, 0x00),
        (2, 4, 0x86),
        (3, 1, 0x00),
        (4, 4, 0x86),
        (5, 4, 0x86),
        (6, 4, 0x86),
        (7, 1, 0x00),
    ]
    messages.append(_definition(2, 27, step_fields))
    for index, item in enumerate(emitted):
        messages.append(
            bytes([2])
            + struct.pack("<H", index)
            + _fit_string(item["name"], 32)
            + struct.pack(
                "<BIBIIIB",
                item["duration_type"],
                item["duration_value"],
                item["target_type"],
                item["target_value"],
                item["low"],
                item["high"],
                item["intensity"],
            )
        )
    for cue in cues:
        report.append(
            {"field": f"cue.{cue['id']}", "status": "omitted", "detail": "Independent HausKlar cues remain available in the app but are not encoded as arbitrary FIT speech."}
        )
    data = b"".join(messages)
    header_without_crc = struct.pack("<BBHI4s", 14, 0x20, 2160, len(data), b".FIT")
    header = header_without_crc + struct.pack("<H", _fit_crc(header_without_crc))
    body = header + data
    return body + struct.pack("<H", _fit_crc(body)), report


async def garmin_export_response(db, *, user: dict, export_id: str) -> dict:
    row = decoded_row(
        await owned_row(db, table="health_garmin_exports", record_id=export_id, user=user),
        json_fields={"mapping_report_json"},
    )
    return {
        "id": row["id"],
        "workout_version_id": row["workout_version_id"],
        "status": row["status"],
        "file_name": row["file_name"],
        "last_error": row["last_error"],
        "mapping_report": row["mapping_report"],
    }


async def _ready_export_file_exists(db, *, user: dict, export) -> bool:
    if not export["file_asset_id"]:
        return False
    asset = await (
        await db.execute(
            "SELECT storage_key FROM health_file_assets WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND state = 'ready' AND deleted_at IS NULL",
            (export["file_asset_id"], user["family_id"], user["id"]),
        )
    ).fetchone()
    if asset is None:
        return False
    root = fitness_cache_root()
    path = (root / asset["storage_key"]).resolve()
    return root in path.parents and path.is_file()


async def create_garmin_export(
    db, *, user: dict, version_id: str, force: bool = False
) -> dict:
    version = await owned_row(
        db, table="health_workout_versions", record_id=version_id, user=user
    )
    if not version["accepted_at"]:
        raise FitnessConflictError("Accept the workout version before exporting it")
    existing = await (
        await db.execute(
            "SELECT id, status, file_asset_id FROM health_garmin_exports "
            "WHERE family_id = ? "
            "AND owner_user_id = ? AND workout_version_id = ? "
            "AND destination = 'garmin_fit_file' AND status <> 'revoked' "
            "AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], version_id),
        )
    ).fetchone()
    if (
        existing
        and existing["status"] == "ready"
        and not force
        and await _ready_export_file_exists(db, user=user, export=existing)
    ):
        return await garmin_export_response(db, user=user, export_id=existing["id"])
    export_id = existing["id"] if existing else new_id()
    timestamp = now_iso()
    if existing:
        await update_owned(
            db,
            table="health_garmin_exports",
            record_id=export_id,
            values={"status": "generating", "last_attempt_at": timestamp, "last_error": None},
            user=user,
        )
    else:
        await insert_owned(
            db,
            table="health_garmin_exports",
            record_id=export_id,
            values={
                "workout_version_id": version_id,
                "destination": "garmin_fit_file",
                "status": "generating",
                "mapping_report_json": [],
                "last_attempt_at": timestamp,
                "revision": 1,
            },
            user=user,
        )
    try:
        steps = await run_steps_for_version(db, user=user, version_id=version_id)
        cues = await run_cues_for_version(db, user=user, version_id=version_id)
        fit_bytes, report = encode_garmin_workout(
            sport_key=version["sport_key"], title=version["title"], steps=steps, cues=cues
        )
        owner = str(version["owner_user_id"])
        storage_key = str(Path("generated") / owner / f"{export_id}.fit")
        path = (fitness_cache_root() / storage_key).resolve()
        if fitness_cache_root() not in path.parents:
            raise FitnessConflictError("Garmin export path is invalid")
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".fit.tmp")
        temporary.write_bytes(fit_bytes)
        os.replace(temporary, path)
        asset_values = {
            "asset_kind": "garmin_fit_workout",
            "storage_class": "regenerable",
            "storage_key": storage_key,
            "original_filename": f"{version['title']}.fit",
            "media_type": "application/vnd.ant.fit",
            "byte_size": len(fit_bytes),
            "state": "ready",
        }
        asset_id = existing["file_asset_id"] if existing else None
        existing_asset = None
        if asset_id:
            existing_asset = await (
                await db.execute(
                    "SELECT id FROM health_file_assets WHERE id = ? AND family_id = ? "
                    "AND owner_user_id = ? AND deleted_at IS NULL",
                    (asset_id, user["family_id"], user["id"]),
                )
            ).fetchone()
        if existing_asset:
            await update_owned(
                db,
                table="health_file_assets",
                record_id=asset_id,
                values=asset_values,
                user=user,
            )
        else:
            asset_id = new_id()
            await insert_owned(
                db,
                table="health_file_assets",
                record_id=asset_id,
                values={**asset_values, "revision": 1},
                user=user,
            )
        await update_owned(
            db,
            table="health_garmin_exports",
            record_id=export_id,
            values={
                "status": "ready",
                "file_asset_id": asset_id,
                "file_name": f"{version['title']}.fit",
                "mapping_report_json": report,
                "last_error": None,
            },
            user=user,
        )
    except Exception as exc:
        await update_owned(
            db,
            table="health_garmin_exports",
            record_id=export_id,
            values={"status": "error", "last_error": str(exc)[:1_000]},
            user=user,
        )
        raise
    return await garmin_export_response(db, user=user, export_id=export_id)


async def retry_garmin_export(db, *, user: dict, export_id: str) -> dict:
    export = await owned_row(
        db, table="health_garmin_exports", record_id=export_id, user=user
    )
    return await create_garmin_export(
        db,
        user=user,
        version_id=export["workout_version_id"],
        force=True,
    )


async def garmin_download_path(db, *, user: dict, export_id: str) -> tuple[Path, str]:
    export = await owned_row(
        db, table="health_garmin_exports", record_id=export_id, user=user
    )
    if export["status"] != "ready" or not export["file_asset_id"]:
        raise FitnessConflictError("Garmin export is not ready")
    asset = await owned_row(
        db, table="health_file_assets", record_id=export["file_asset_id"], user=user
    )
    path = (fitness_cache_root() / asset["storage_key"]).resolve()
    if fitness_cache_root() not in path.parents or not path.is_file():
        raise FitnessConflictError("Generated Garmin file is missing; retry the export")
    return path, export["file_name"] or "workout.fit"

"""Exactly-once regressions for direct and offline-capable create paths."""

import asyncio
import uuid
from datetime import datetime, timezone

import aiosqlite
import pytest


def _case(kind: str, child_id: str) -> tuple[str, str, dict, str]:
    if kind == "calendar":
        return (
            "/api/calendar/",
            "calendar_events",
            {
                "title": "School assembly",
                "start_time": "2026-08-01T09:00:00Z",
                "assigned_to": child_id,
            },
            "title",
        )
    if kind == "task":
        return (
            "/api/tasks/",
            "tasks",
            {
                "title": "Pack bags",
                "category": "household",
                "priority": 2,
                "assignees": [
                    {"assignee_id": child_id, "assignee_type": "child"}
                ],
            },
            "title",
        )
    return (
        "/api/medicine/types",
        "medicine_types",
        {
            "name": "Calpol",
            "child_id": child_id,
            "min_hours_between_doses": 4,
            "max_doses_24h": 4,
        },
        "name",
    )


@pytest.mark.parametrize("kind", ["calendar", "task", "medicine_type"])
async def test_concurrent_direct_create_replay_and_mismatch(
    kind,
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    endpoint, table_name, payload, changed_field = _case(kind, child1["id"])
    operation_id = str(uuid.uuid4())
    request_payload = {"id": operation_id, **payload}
    start = asyncio.Event()

    async def deliver():
        await start.wait()
        return await client.post(endpoint, json=request_payload, headers=adult_a_headers)

    deliveries = [asyncio.create_task(deliver()) for _ in range(2)]
    start.set()
    responses = await asyncio.gather(*deliveries)

    assert [response.status_code for response in responses] == [201, 201]
    assert {response.json()["id"] for response in responses} == {operation_id}
    mismatch = await client.post(
        endpoint,
        json={
            **request_payload,
            changed_field: f"{payload[changed_field]} changed",
        },
        headers=adult_a_headers,
    )
    assert mismatch.status_code == 409

    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute(
                    f"SELECT COUNT(*) FROM {table_name} WHERE id = ?",
                    (operation_id,),
                )
            ).fetchone()
        )[0]
    assert count == 1


@pytest.mark.parametrize("kind", ["calendar", "task", "medicine_type"])
async def test_direct_create_then_sync_replay_and_mismatch(
    kind,
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    endpoint, table_name, payload, changed_field = _case(kind, child1["id"])
    operation_id = str(uuid.uuid4())
    direct = await client.post(
        endpoint,
        json={"id": operation_id, **payload},
        headers=adult_a_headers,
    )
    assert direct.status_code == 201

    def push(sync_payload: dict) -> dict:
        return {
            "items": [
                {
                    "operation": "create",
                    "table_name": table_name,
                    "record_id": operation_id,
                    "payload": sync_payload,
                    "client_id": str(uuid.uuid4()),
                    "client_timestamp": datetime.now(timezone.utc).isoformat(),
                }
            ]
        }

    replay = await client.post(
        "/api/sync/push",
        json=push(payload),
        headers=adult_a_headers,
    )
    assert replay.status_code == 200
    assert replay.json()["results"][0]["status"] == "accepted"

    mismatch_payload = {
        **payload,
        changed_field: f"{payload[changed_field]} changed",
    }
    mismatch = await client.post(
        "/api/sync/push",
        json=push(mismatch_payload),
        headers=adult_a_headers,
    )
    assert mismatch.status_code == 200
    assert mismatch.json()["results"][0]["status"] == "error"

    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute(
                    f"SELECT COUNT(*) FROM {table_name} WHERE id = ?",
                    (operation_id,),
                )
            ).fetchone()
        )[0]
    assert count == 1

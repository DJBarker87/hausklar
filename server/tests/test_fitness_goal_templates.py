"""Human goal templates map safely to owner-private Fitness goals."""

import uuid

import aiosqlite
import pytest


pytestmark = pytest.mark.asyncio


def _internal_keys(payload: object) -> set[str]:
    forbidden = {
        "metric_key",
        "goal_type",
        "unit_key",
        "model",
        "provider",
        "confidence",
        "completeness",
        "evidence",
        "source",
    }
    found: set[str] = set()
    if isinstance(payload, dict):
        for key, value in payload.items():
            if key.lower() in forbidden:
                found.add(key.lower())
            found.update(_internal_keys(value))
    elif isinstance(payload, list):
        for value in payload:
            found.update(_internal_keys(value))
    return found


async def test_goal_templates_are_human_bounded_and_map_to_internal_goals(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    listed = await client.get("/api/fitness/goal-templates", headers=adult_a_headers)
    assert listed.status_code == 200, listed.text
    templates = listed.json()
    assert [template["id"] for template in templates] == [
        "run-faster-5k",
        "run-consistently",
        "move-consistently",
        "run-weekly-distance",
        "strength-consistency",
        "energy-and-wellbeing",
        "body-weight-support",
    ]
    assert _internal_keys(templates) == set()
    assert all(template["minimum_value"] < template["maximum_value"] for template in templates)
    assert all(
        template["minimum_value"] <= template["suggested_value"] <= template["maximum_value"]
        for template in templates
    )

    cases = (
        ("run-faster-5k", 22 * 60 + 30, "running", "running.5k_seconds", 1_350, "s"),
        ("run-consistently", 3, "running", "running.sessions_per_week", 3, "sessions per week"),
        ("move-consistently", 4, "fitness", "activity.sessions_per_week", 4, "sessions per week"),
        ("run-weekly-distance", 12.5, "running", "running.distance_m", 12_500, "m per week"),
        (
            "strength-consistency",
            3,
            "strength",
            "strength.sessions_per_week",
            3,
            "sessions per week",
        ),
        (
            "energy-and-wellbeing",
            5,
            "wellbeing",
            "activity.active_days_per_week",
            5,
            "days per week",
        ),
        ("body-weight-support", 72.5, "body", "body.weight_kg", 72.5, "kg"),
    )
    expected: dict[str, tuple] = {}
    for index, (template_id, value, goal_type, metric, target, unit) in enumerate(cases):
        goal_id = str(uuid.uuid4())
        body = {
            "id": goal_id,
            "template_id": template_id,
            "target_value": value,
            "starts_on": "2026-08-03",
            "target_date": "2026-11-03",
            "priority": 20 + index,
            "client_id": "dom-phone",
            "client_timestamp": "2026-08-03T09:00:00+01:00",
        }
        created = await client.post(
            "/api/fitness/goals/from-template",
            headers=adult_a_headers,
            json=body,
        )
        assert created.status_code == 201, created.text
        response = created.json()
        assert response["goal_id"] == goal_id
        assert response["template_id"] == template_id
        assert response["status"] == "active"
        assert response["target_text"]
        assert _internal_keys(response) == set()
        expected[goal_id] = (goal_type, metric, float(target), unit)

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT * FROM health_goals WHERE owner_user_id = ? ORDER BY created_at, id",
                (adult_a_user["id"],),
            )
        ).fetchall()
    assert len(rows) == 7
    for row in rows:
        goal_type, metric, target, unit = expected[row["id"]]
        assert row["goal_type"] == goal_type
        assert row["metric_key"] == metric
        assert row["target_value"] == target
        assert row["unit_key"] == unit


async def test_goal_template_create_is_exactly_once_and_owner_isolated(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    initialized_db,
):
    goal_id = str(uuid.uuid4())
    body = {
        "id": goal_id,
        "template_id": "run-weekly-distance",
        "target_value": 10,
        "starts_on": "2026-08-03",
        "priority": 80,
        "client_id": "stable-device",
        "client_timestamp": "2026-08-03T08:00:00Z",
    }
    created = await client.post("/api/fitness/goals/from-template", headers=adult_a_headers, json=body)
    replayed = await client.post("/api/fitness/goals/from-template", headers=adult_a_headers, json=body)
    assert created.status_code == replayed.status_code == 201
    assert replayed.json() == created.json()

    changed = await client.post(
        "/api/fitness/goals/from-template",
        headers=adult_a_headers,
        json={**body, "target_value": 11},
    )
    foreign_reuse = await client.post(
        "/api/fitness/goals/from-template",
        headers=adult_b_headers,
        json=body,
    )
    assert changed.status_code == 409
    assert foreign_reuse.status_code == 409
    assert goal_id not in {
        goal["id"] for goal in (await client.get("/api/fitness/goals", headers=adult_b_headers)).json()
    }

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        goal = await (
            await db.execute("SELECT * FROM health_goals WHERE id = ?", (goal_id,))
        ).fetchone()
        history_count = await (
            await db.execute(
                "SELECT COUNT(*) FROM record_history "
                "WHERE table_name = 'health_goals' AND record_id = ?",
                (goal_id,),
            )
        ).fetchone()
    assert goal["owner_user_id"] == adult_a_user["id"]
    assert goal["revision"] == 1
    assert history_count[0] == 0


@pytest.mark.parametrize(
    ("template_id", "target_value", "starts_on", "target_date"),
    [
        ("move-consistently", 0, "2026-08-03", None),
        ("run-faster-5k", 719, "2026-08-03", None),
        ("run-faster-5k", 1_500.5, "2026-08-03", None),
        ("run-consistently", 2.5, "2026-08-03", None),
        ("move-consistently", 2.5, "2026-08-03", None),
        ("run-weekly-distance", 301, "2026-08-03", None),
        ("strength-consistency", 8, "2026-08-03", None),
        ("energy-and-wellbeing", 3, "2026-08-03", "2026-08-02"),
        ("body-weight-support", 20, "2026-08-03", None),
        ("unknown-template", 3, "2026-08-03", None),
    ],
)
async def test_goal_templates_reject_invalid_choices(
    client,
    adult_a_headers,
    template_id,
    target_value,
    starts_on,
    target_date,
):
    response = await client.post(
        "/api/fitness/goals/from-template",
        headers=adult_a_headers,
        json={
            "id": str(uuid.uuid4()),
            "template_id": template_id,
            "target_value": target_value,
            "starts_on": starts_on,
            "target_date": target_date,
        },
    )
    assert response.status_code == 422

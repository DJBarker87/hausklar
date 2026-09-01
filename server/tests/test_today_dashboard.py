from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


async def test_dashboard_requires_authentication(client):
    response = await client.get("/api/briefing/dashboard")
    assert response.status_code == 401


async def test_dashboard_returns_one_stable_family_scoped_payload(
    client, adult_a_headers, adult_a_user
):
    start = datetime.now(ZoneInfo("Europe/London")).replace(
        hour=12,
        minute=0,
        second=0,
    ).isoformat()
    event = await client.post(
        "/api/calendar/",
        json={"title": "Family lunch", "start_time": start},
        headers=adult_a_headers,
    )
    task = await client.post(
        "/api/tasks/",
        json={"title": "Pack school bags", "priority": 3},
        headers=adult_a_headers,
    )
    assert event.status_code == 201
    assert task.status_code == 201

    response = await client.get(
        "/api/briefing/dashboard?timezone=Europe/London", headers=adult_a_headers
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["unavailable"] == [], payload
    assert {item["title"] for item in payload["events"]} == {"Family lunch"}, payload
    assert {item["title"] for item in payload["tasks"]} == {"Pack school bags"}
    assert payload["family_members"] == [
        {
            "id": adult_a_user["id"],
            "name": "Alex",
            "member_type": "user",
            "avatar_url": None,
        }
    ]
    assert payload["illness_readings"] == {}
    assert isinstance(payload["unavailable"], list)
    for field in (
        "naps",
        "illnesses",
        "routines",
        "meals",
        "memories",
        "insights",
        "prep_suggestions",
        "medicine",
        "birthdays",
        "presents",
    ):
        assert field in payload


async def test_dashboard_only_surfaces_gift_preparation_in_its_lead_window(
    client, adult_a_headers, child1
):
    today = datetime.now(ZoneInfo("Europe/London")).date()
    near = await client.post(
        "/api/children/presents/ideas",
        json={
            "child_id": child1["id"],
            "title": "Wooden castle",
            "status": "arrived",
            "deadline": (today + timedelta(days=5)).isoformat(),
        },
        headers=adult_a_headers,
    )
    assert near.status_code == 201
    far = await client.post(
        "/api/children/presents/ideas",
        json={
            "child_id": child1["id"],
            "title": "Roller skates",
            "deadline": (today + timedelta(days=30)).isoformat(),
        },
        headers=adult_a_headers,
    )
    assert far.status_code == 201
    ready = await client.post(
        "/api/children/presents/ideas",
        json={
            "child_id": child1["id"],
            "title": "Story book",
            "status": "stashed",
            "deadline": (today + timedelta(days=2)).isoformat(),
        },
        headers=adult_a_headers,
    )
    assert ready.status_code == 201

    response = await client.get(
        "/api/briefing/dashboard?timezone=Europe/London", headers=adult_a_headers
    )
    assert response.status_code == 200
    presents = response.json()["presents"]
    assert presents == [
        {
            "id": near.json()["id"],
            "child_id": child1["id"],
            "recipient_name": "Child 1",
            "title": "Wooden castle",
            "deadline": (today + timedelta(days=5)).isoformat(),
            "days_until_due": 5,
            "status": "arrived",
            "owner_id": None,
            "owner_name": None,
            "action": "Wrap Wooden castle",
        }
    ]

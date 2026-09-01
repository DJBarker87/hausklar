from datetime import datetime, timezone


async def test_today_dashboard_uses_requested_timezone_for_dog_care_states(
    client,
    adult_a_headers,
    monkeypatch,
):
    saved = await client.put(
        "/api/dog/profile",
        json={
            "name": "Mabel",
            "breakfast_window_start": "07:30",
            "breakfast_window_end": "08:30",
            "walk_window_start": "10:00",
            "walk_window_end": "12:00",
            "dinner_window_start": "17:30",
            "dinner_window_end": "19:00",
        },
        headers=adult_a_headers,
    )
    assert saved.status_code == 200

    monkeypatch.setattr(
        "app.routers.dog._utc_now",
        lambda: datetime(2026, 8, 9, 7, 0, tzinfo=timezone.utc),
    )

    utc_dashboard = await client.get(
        "/api/briefing/dashboard",
        params={"timezone": "UTC"},
        headers=adult_a_headers,
    )
    london_dashboard = await client.get(
        "/api/briefing/dashboard",
        params={"timezone": "Europe/London"},
        headers=adult_a_headers,
    )

    assert utc_dashboard.status_code == 200
    assert utc_dashboard.json()["dog"]["dog_name"] == "Mabel"
    assert utc_dashboard.json()["dog"]["breakfast_state"] == "upcoming"
    assert london_dashboard.status_code == 200
    assert london_dashboard.json()["dog"]["breakfast_state"] == "due"

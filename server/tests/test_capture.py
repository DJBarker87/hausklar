from unittest.mock import AsyncMock

import aiosqlite

from app.models.document import CaptureSuggestionCreate


async def test_capture_requires_authentication(client):
    response = await client.post("/api/capture/parse", json={"text": "Pay nursery"})
    assert response.status_code == 401


async def test_capture_rejects_blank_and_oversized_text(client, adult_a_headers):
    blank = await client.post(
        "/api/capture/parse",
        json={"text": "   "},
        headers=adult_a_headers,
    )
    oversized = await client.post(
        "/api/capture/parse",
        json={"text": "a" * 10_001},
        headers=adult_a_headers,
    )
    assert blank.status_code == 422
    assert oversized.status_code == 422


async def test_fallback_splits_event_and_task(client, adult_a_headers):
    response = await client.post(
        "/api/capture/parse",
        json={
            "text": "Nursery closes tomorrow at 3pm; pay the nursery bill by 18/07/2026",
            "client_now": "2026-07-10T12:00:00+01:00",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["processor"] == "fallback"
    assert [proposal["kind"] for proposal in body["proposals"]] == ["event", "task"]
    assert body["proposals"][0]["start_time"] == "2026-07-11T15:00:00+01:00"
    assert body["proposals"][0]["all_day"] is False
    assert body["proposals"][1]["due_date"] == "2026-07-18"


async def test_fallback_matches_family_member(client, adult_a_headers, adult_b_user):
    response = await client.post(
        "/api/capture/parse",
        json={"text": "Morgan pay nursery tomorrow", "client_now": "2026-07-10T09:00:00Z"},
        headers=adult_a_headers,
    )

    proposal = response.json()["proposals"][0]
    assert proposal["assigned_to"] == adult_b_user["id"]
    assert proposal["assigned_to_name"] == "Morgan"


async def test_fallback_corrects_only_obvious_typos(client, adult_a_headers):
    response = await client.post(
        "/api/capture/parse",
        json={
            "text": "Nursary closes tomorow at 3pm; remeber spoecialist appoitment",
            "client_now": "2026-07-10T09:00:00+01:00",
        },
        headers=adult_a_headers,
    )

    proposals = response.json()["proposals"]
    assert proposals[0]["title"] == "Nursery closes tomorrow at 3pm"
    assert proposals[0]["start_time"] == "2026-07-11T15:00:00+01:00"
    assert proposals[0]["source_text"] == "Nursary closes tomorow at 3pm"
    assert proposals[1]["title"] == "Specialist appointment"


async def test_hermes_is_never_called_without_opt_in(client, adult_a_headers, monkeypatch):
    mock_extract = AsyncMock()
    monkeypatch.setattr("app.routers.capture.extract_capture_suggestions", mock_extract)

    response = await client.post(
        "/api/capture/parse",
        json={"text": "Book the dentist"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json()["processor"] == "fallback"
    mock_extract.assert_not_awaited()


async def test_hermes_requires_current_ai_permission(client, adult_a_headers, monkeypatch):
    revoked = await client.delete("/api/auth/ai-consent", headers=adult_a_headers)
    assert revoked.status_code == 200
    mock_extract = AsyncMock()
    monkeypatch.setattr("app.routers.capture.extract_capture_suggestions", mock_extract)

    response = await client.post(
        "/api/capture/parse",
        json={"text": "Book the dentist", "use_hermes": True},
        headers=adult_a_headers,
    )

    assert response.status_code == 428
    assert "OpenAI" in response.json()["detail"]
    mock_extract.assert_not_awaited()


async def test_hermes_proposals_are_returned_for_review(
    client,
    adult_a_headers,
    adult_b_user,
    monkeypatch,
):
    mock_extract = AsyncMock(
        return_value=[
            CaptureSuggestionCreate(
                kind="event",
                title="Swimming lesson",
                start_time="2026-07-17T16:30:00+01:00",
                assigned_to=adult_b_user["id"],
                confidence=0.96,
                source_text="Morgan takes swimming Friday at 4:30pm",
            )
        ]
    )
    monkeypatch.setattr("app.routers.capture.extract_capture_suggestions", mock_extract)

    response = await client.post(
        "/api/capture/parse",
        json={
            "text": "Morgan takes swimming Friday at 4:30pm",
            "use_hermes": True,
            "client_now": "2026-07-10T10:00:00+01:00",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    assert response.json()["processor"] == "hermes"
    assert response.json()["proposals"][0]["assigned_to_name"] == "Morgan"
    assert mock_extract.await_args.kwargs["reference_date"] == "2026-07-10"


async def test_naive_hermes_time_uses_client_timezone(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(
        "app.routers.capture.extract_capture_suggestions",
        AsyncMock(
            return_value=[
                CaptureSuggestionCreate(
                    kind="event",
                    title="Swimming lesson",
                    start_time="2026-07-17T16:30:00",
                )
            ]
        ),
    )

    response = await client.post(
        "/api/capture/parse",
        json={
            "text": "Swimming lesson",
            "use_hermes": True,
            "client_now": "2026-07-10T09:00:00Z",
            "timezone": "Europe/London",
        },
        headers=adult_a_headers,
    )

    assert response.json()["proposals"][0]["start_time"] == "2026-07-17T16:30:00+01:00"


async def test_invalid_hermes_fields_are_removed(client, adult_a_headers, monkeypatch):
    mock_extract = AsyncMock(
        return_value=[
            CaptureSuggestionCreate(
                kind="event",
                title="Invalid date",
                start_time="not-a-date",
            ),
            CaptureSuggestionCreate(
                kind="task",
                title="Valid task",
                due_date="also-not-a-date",
                assigned_to="not-a-family-member",
            ),
        ]
    )
    monkeypatch.setattr("app.routers.capture.extract_capture_suggestions", mock_extract)

    response = await client.post(
        "/api/capture/parse",
        json={"text": "Something", "use_hermes": True},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert [item["title"] for item in response.json()["proposals"]] == ["Valid task"]
    proposal = response.json()["proposals"][0]
    assert proposal["due_date"] is None
    assert proposal["assigned_to"] is None


async def test_hermes_failure_falls_back_with_warning(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(
        "app.routers.capture.extract_capture_suggestions",
        AsyncMock(return_value=None),
    )

    response = await client.post(
        "/api/capture/parse",
        json={"text": "Buy milk", "use_hermes": True},
        headers=adult_a_headers,
    )

    body = response.json()
    assert body["processor"] == "fallback"
    assert body["warning"]
    assert body["proposals"][0]["kind"] == "task"


async def test_parse_does_not_write_events_or_tasks(
    client,
    adult_a_headers,
    initialized_db,
):
    response = await client.post(
        "/api/capture/parse",
        json={"text": "Sports day tomorrow; buy milk"},
        headers=adult_a_headers,
    )
    assert response.status_code == 200

    async with aiosqlite.connect(initialized_db) as db:
        event_count = (await (await db.execute("SELECT COUNT(*) FROM calendar_events")).fetchone())[0]
        task_count = (await (await db.execute("SELECT COUNT(*) FROM tasks")).fetchone())[0]
    assert event_count == 0
    assert task_count == 0

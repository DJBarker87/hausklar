"""Tests for /api/healthcheck response hardening."""


async def test_healthcheck_hides_scheduler_details_by_default(client):
    resp = await client.get("/api/healthcheck")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


async def test_healthcheck_can_include_scheduler_when_enabled(client, monkeypatch):
    from app import main

    monkeypatch.setattr(main.settings, "healthcheck_show_scheduler_details", True)
    resp = await client.get("/api/healthcheck")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert "scheduler" in body

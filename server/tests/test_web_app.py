"""Tests for the browser app shell and PWA delivery headers."""

from app import main


def _write_web_fixture(root):
    (root / "index.html").write_text("<!doctype html><title>HausKlar</title>")
    (root / "manifest.webmanifest").write_text('{"name":"HausKlar"}')
    (root / "sw.js").write_text("self.addEventListener('fetch', () => {});")


async def test_web_shell_has_restrictive_security_and_update_headers(
    client,
    monkeypatch,
    tmp_path,
):
    _write_web_fixture(tmp_path)
    monkeypatch.setattr(main, "WEB_ROOT", tmp_path)

    response = await client.get("/")

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-cache"
    assert response.headers["x-frame-options"] == "DENY"
    content_security_policy = response.headers["content-security-policy"]
    assert "default-src 'self'" in content_security_policy
    assert "object-src 'none'" in content_security_policy
    assert "connect-src 'self'" in content_security_policy
    assert "img-src 'self' data: blob:" in content_security_policy
    assert "openfreemap" not in content_security_policy
    assert "worker-src 'self'" in content_security_policy
    assert "camera=(self)" in response.headers["permissions-policy"]


async def test_manifest_and_service_worker_are_not_served_stale(client, monkeypatch, tmp_path):
    _write_web_fixture(tmp_path)
    monkeypatch.setattr(main, "WEB_ROOT", tmp_path)

    manifest = await client.get("/manifest.webmanifest")
    worker = await client.get("/sw.js")

    assert manifest.status_code == 200
    assert manifest.headers["content-type"].startswith("application/manifest+json")
    assert manifest.headers["cache-control"] == "no-cache"
    assert worker.status_code == 200
    assert worker.headers["cache-control"] == "no-cache"


async def test_missing_web_build_returns_service_unavailable(client, monkeypatch, tmp_path):
    monkeypatch.setattr(main, "WEB_ROOT", tmp_path)

    response = await client.get("/")

    assert response.status_code == 503
    assert response.json() == {"detail": "HausKlar web app is not built"}

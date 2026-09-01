"""Tests for family members and their private profile photos."""

import io

import aiosqlite
from PIL import Image

from app.config import settings


def avatar_png(width: int = 900, height: int = 600) -> bytes:
    output = io.BytesIO()
    Image.new("RGB", (width, height), (42, 120, 196)).save(output, format="PNG")
    return output.getvalue()


async def test_list_family_members(client, adult_a_headers, adult_a_user, adult_b_user, child1, child2):
    """GET /api/family/members returns users and children with correct types."""
    resp = await client.get("/api/family/members", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()

    # Should have 2 users + 2 children
    assert len(data) == 4

    names = {m["name"] for m in data}
    assert "Alex" in names
    assert "Morgan" in names
    assert "Child 1" in names
    assert "Child 2" in names

    # Check types
    types_by_name = {m["name"]: m["member_type"] for m in data}
    assert types_by_name["Alex"] == "user"
    assert types_by_name["Morgan"] == "user"
    assert types_by_name["Child 1"] == "child"
    assert types_by_name["Child 2"] == "child"
    assert all(member["avatar_url"] is None for member in data)


async def test_list_family_members_excludes_deleted(client, adult_b_headers, adult_a_user, adult_b_user, initialized_db):
    """Soft-deleted users/children should not appear in family members."""
    import aiosqlite

    # Soft-delete Alex (use Morgan's token to query afterwards)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE users SET deleted_at = '2025-01-01T00:00:00Z' WHERE id = ?",
            (adult_a_user["id"],),
        )
        await db.commit()

    resp = await client.get("/api/family/members", headers=adult_b_headers)
    assert resp.status_code == 200
    data = resp.json()
    names = {m["name"] for m in data}
    assert "Alex" not in names
    assert "Morgan" in names


async def test_upload_and_read_child_avatar(
    client, adult_b_headers, adult_b_user, child1, tmp_path, monkeypatch, initialized_db
):
    monkeypatch.setattr(settings, "avatar_storage_path", str(tmp_path / "avatars"))
    response = await client.put(
        f"/api/family/members/{child1['id']}/avatar",
        headers=adult_b_headers,
        files={"file": ("portrait.png", avatar_png(), "image/png")},
    )
    assert response.status_code == 200
    member = response.json()
    assert member["id"] == child1["id"]
    assert member["member_type"] == "child"
    assert member["avatar_url"].startswith(f"/family/members/{child1['id']}/avatar?v=")

    image_response = await client.get(f"/api{member['avatar_url']}", headers=adult_b_headers)
    assert image_response.status_code == 200
    assert image_response.headers["content-type"] == "image/jpeg"
    assert "immutable" in image_response.headers["cache-control"]
    with Image.open(io.BytesIO(image_response.content)) as image:
        assert image.size == (512, 512)
        assert image.mode == "RGB"

    async with aiosqlite.connect(initialized_db) as db:
        cursor = await db.execute(
            "SELECT COUNT(*), previous_values FROM record_history "
            "WHERE table_name = 'children' AND record_id = ?",
            (child1["id"],),
        )
        history = await cursor.fetchone()
        assert history[0] == 1


async def test_avatar_replacement_changes_url_and_removes_old_file(
    client, adult_a_headers, adult_a_user, tmp_path, monkeypatch, initialized_db
):
    avatar_root = tmp_path / "avatars"
    monkeypatch.setattr(settings, "avatar_storage_path", str(avatar_root))
    first = await client.put(
        f"/api/family/members/{adult_a_user['id']}/avatar",
        headers=adult_a_headers,
        files={"file": ("first.png", avatar_png(), "image/png")},
    )
    second = await client.put(
        f"/api/family/members/{adult_a_user['id']}/avatar",
        headers=adult_a_headers,
        files={"file": ("second.png", avatar_png(600, 900), "image/png")},
    )
    assert first.status_code == second.status_code == 200
    assert first.json()["avatar_url"] != second.json()["avatar_url"]
    assert len(list(avatar_root.rglob("*.jpg"))) == 1
    assert (await client.get(f"/api{first.json()['avatar_url']}", headers=adult_a_headers)).status_code == 404
    listed = await client.get("/api/family/members", headers=adult_a_headers)
    dom = next(member for member in listed.json() if member["id"] == adult_a_user["id"])
    assert dom["avatar_url"] == second.json()["avatar_url"]
    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT previous_values FROM record_history "
                "WHERE table_name = 'users' AND record_id = ?",
                (adult_a_user["id"],),
            )
        ).fetchall()
        assert len(rows) == 2
        assert all("password_hash" not in row[0] for row in rows)


async def test_avatar_is_family_scoped_and_validated(
    client,
    adult_a_headers,
    adult_a_user,
    other_family_headers,
    other_family_user,
    tmp_path,
    monkeypatch,
):
    monkeypatch.setattr(settings, "avatar_storage_path", str(tmp_path / "avatars"))
    uploaded = await client.put(
        f"/api/family/members/{adult_a_user['id']}/avatar",
        headers=adult_a_headers,
        files={"file": ("portrait.png", avatar_png(), "image/png")},
    )
    assert uploaded.status_code == 200
    assert (
        await client.get(f"/api{uploaded.json()['avatar_url']}", headers=other_family_headers)
    ).status_code == 404
    assert (
        await client.put(
            f"/api/family/members/{other_family_user['id']}/avatar",
            headers=adult_a_headers,
            files={"file": ("portrait.png", avatar_png(), "image/png")},
        )
    ).status_code == 404

    wrong_type = await client.put(
        f"/api/family/members/{adult_a_user['id']}/avatar",
        headers=adult_a_headers,
        files={"file": ("portrait.svg", b"<svg/>", "image/svg+xml")},
    )
    assert wrong_type.status_code == 422
    unreadable = await client.put(
        f"/api/family/members/{adult_a_user['id']}/avatar",
        headers=adult_a_headers,
        files={"file": ("portrait.png", b"not-an-image", "image/png")},
    )
    assert unreadable.status_code == 422


async def test_account_deletion_physically_removes_profile_photos(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    child1,
    tmp_path,
    monkeypatch,
):
    avatar_root = tmp_path / "avatars"
    monkeypatch.setattr(settings, "avatar_storage_path", str(avatar_root))
    for member_id in (adult_a_user["id"], child1["id"]):
        response = await client.put(
            f"/api/family/members/{member_id}/avatar",
            headers=adult_a_headers,
            files={"file": ("portrait.png", avatar_png(), "image/png")},
        )
        assert response.status_code == 200
    assert len(list(avatar_root.rglob("*.jpg"))) == 2

    deleted_dom = await client.delete("/api/auth/me", headers=adult_a_headers)
    assert deleted_dom.status_code == 204
    assert len(list(avatar_root.rglob("*.jpg"))) == 1

    deleted_last_account = await client.delete("/api/auth/me", headers=adult_b_headers)
    assert deleted_last_account.status_code == 204
    assert not list(avatar_root.rglob("*.jpg"))

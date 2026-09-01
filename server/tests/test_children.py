"""Tests for the children router (/api/children)."""


async def test_list_children_empty(client, adult_a_user, adult_a_headers):
    """GET /api/children returns an empty list when no children exist."""
    resp = await client.get("/api/children/", headers=adult_a_headers)
    assert resp.status_code == 200
    assert resp.json() == []


async def test_create_child_rejects_future_date(client, adult_a_headers):
    response = await client.post(
        "/api/children/",
        headers=adult_a_headers,
        json={"name": "Time traveller", "date_of_birth": "2999-01-01"},
    )
    assert response.status_code == 422


async def test_list_children(client, adult_a_user, adult_a_headers, child1, child2):
    """GET /api/children returns all non-deleted children."""
    resp = await client.get("/api/children/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 2
    names = {c["name"] for c in data}
    assert names == {"Child 1", "Child 2"}
    # Each child should have id, name, date_of_birth
    for child in data:
        assert "id" in child
        assert "name" in child
        assert "date_of_birth" in child


async def test_list_children_excludes_deleted(client, adult_a_user, adult_a_headers, child1, initialized_db):
    """GET /api/children excludes soft-deleted children."""
    import aiosqlite

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE children SET deleted_at = '2026-01-01T00:00:00Z' WHERE id = ?",
            (child1["id"],),
        )
        await db.commit()

    resp = await client.get("/api/children/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 0


async def test_list_children_requires_auth(client):
    """GET /api/children without auth returns 401."""
    resp = await client.get("/api/children/")
    assert resp.status_code == 401


async def test_list_children_ordered_by_dob(client, adult_a_user, adult_a_headers, child1, child2, child3):
    """GET /api/children returns children ordered by date_of_birth ASC."""
    resp = await client.get("/api/children/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 3
    dobs = [c["date_of_birth"] for c in data]
    assert dobs == sorted(dobs)

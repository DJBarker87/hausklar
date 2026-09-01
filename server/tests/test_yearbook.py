from datetime import datetime, timezone
from unittest.mock import AsyncMock

import aiosqlite
import pytest

from app.config import settings


@pytest.fixture(autouse=True)
def no_immich(monkeypatch):
    monkeypatch.setattr(settings, "immich_url", "")
    monkeypatch.setattr(settings, "immich_api_key", "")


async def _seed_year(db_path: str, adult_a_user: dict, child1: dict, year: int) -> None:
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT INTO growth_records (id, child_id, date, height_cm, weight_kg, family_id, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "g1",
                child1["id"],
                f"{year}-01-10",
                80.0,
                10.0,
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            "INSERT INTO growth_records (id, child_id, date, height_cm, weight_kg, family_id, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "g2",
                child1["id"],
                f"{year}-11-10",
                88.0,
                12.5,
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            "INSERT INTO artworks (id, child_id, approx_date, media_type, storage_key, file_size, sha256, family_id, created_by) "
            "VALUES (?, ?, ?, 'image/jpeg', 'k', 1, 's', ?, ?)",
            ("a1", child1["id"], f"{year}-03", adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            "INSERT INTO homework_reading (id, child_id, book_title, minutes, date, family_id, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "r1",
                child1["id"],
                "The Gruffalo",
                15,
                f"{year}-04-01",
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            "INSERT INTO star_charts (id, child_id, title, reward_amount_pence, completed_at, family_id, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "sc1",
                child1["id"],
                "Potty training",
                500,
                f"{year}-05-01T10:00:00Z",
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()


async def test_yearbook_requires_authentication(client, child1):
    assert (await client.get(f"/api/yearbook/{child1['id']}/2026")).status_code == 401


async def test_yearbook_composes_sections(client, adult_a_headers, adult_a_user, child1, initialized_db):
    await _seed_year(initialized_db, adult_a_user, child1, 2025)

    response = await client.get("/api/yearbook/{}/2025".format(child1["id"]), headers=adult_a_headers)
    assert response.status_code == 200
    book = response.json()
    assert book["child"]["name"] == child1["name"]
    assert book["year"] == 2025
    assert book["sections"]["artwork"]["count"] == 1
    assert book["sections"]["growth"]["grew_cm"] == 8.0
    assert book["sections"]["growth"]["gained_kg"] == 2.5
    assert book["sections"]["star_charts"]["completed"] == 1
    assert book["sections"]["star_charts"]["earned_pence"] == 500
    assert "The Gruffalo" in book["sections"]["learning"]["books"]
    # No hermes configured in tests → narrative is gracefully null.
    assert book["narrative"] is None


async def test_yearbook_narrative_uses_hermes_and_caches(
    client, adult_a_headers, adult_a_user, child1, initialized_db, monkeypatch
):
    await _seed_year(initialized_db, adult_a_user, child1, 2025)
    monkeypatch.setattr(settings, "hermes_bridge_url", "http://192.0.2.91:9120")
    monkeypatch.setattr(settings, "hermes_bridge_token", "x" * 40)
    mock = AsyncMock(return_value="What a wonderful year of growing and reading.")
    monkeypatch.setattr("app.services.yearbook.ask_hermes", mock)

    passive = await client.get(f"/api/yearbook/{child1['id']}/2025", headers=adult_a_headers)
    assert passive.status_code == 200
    assert passive.json()["narrative"] is None
    mock.assert_not_awaited()

    first = await client.post(f"/api/yearbook/{child1['id']}/2025/refresh", headers=adult_a_headers)
    assert first.status_code == 200
    assert "wonderful year" in first.json()["narrative"]
    assert mock.await_count == 1

    # Second view reuses the cached narrative (facts unchanged → no new call).
    second = await client.get(f"/api/yearbook/{child1['id']}/2025", headers=adult_a_headers)
    assert second.json()["narrative"] == first.json()["narrative"]
    assert mock.await_count == 1


async def test_yearbook_refresh_requires_current_ai_permission(
    client, adult_a_headers, child1, monkeypatch
):
    revoked = await client.delete("/api/auth/ai-consent", headers=adult_a_headers)
    assert revoked.status_code == 200
    mock = AsyncMock()
    monkeypatch.setattr("app.services.yearbook.ask_hermes", mock)

    response = await client.post(
        f"/api/yearbook/{child1['id']}/2025/refresh",
        headers=adult_a_headers,
    )

    assert response.status_code == 428
    assert "OpenAI" in response.json()["detail"]
    mock.assert_not_awaited()


async def test_available_years_and_current_year(
    client, adult_a_headers, adult_a_user, child1, initialized_db
):
    await _seed_year(initialized_db, adult_a_user, child1, 2024)
    response = await client.get(f"/api/yearbook/{child1['id']}/years", headers=adult_a_headers)
    assert response.status_code == 200
    years = response.json()["years"]
    assert 2024 in years
    assert datetime.now(timezone.utc).year in years  # current year always offered


async def test_yearbook_unknown_child_is_404(client, adult_a_headers):
    assert (
        await client.get("/api/yearbook/not-a-child/2025", headers=adult_a_headers)
    ).status_code == 404


async def test_yearbook_is_family_isolated(client, other_family_headers, child1):
    assert (
        await client.get(f"/api/yearbook/{child1['id']}/2025", headers=other_family_headers)
    ).status_code == 404


async def test_yearbook_photos_are_curated_for_the_requested_child_only(
    client,
    adult_a_headers,
    adult_a_user,
    child1,
    child2,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        for photo_id, child_id, taken_on in (
            ("photo-child-1", child1["id"], "2025-03-10"),
            ("photo-child-2", child2["id"], "2025-04-11"),
            ("photo-child-1-other-year", child1["id"], "2024-05-12"),
        ):
            await db.execute(
                """
                INSERT INTO child_photos
                    (id, child_id, taken_on, media_type, storage_key,
                     file_size, sha256, family_id, created_by)
                VALUES (?, ?, ?, 'image/jpeg', ?, 1, ?, ?, ?)
                """,
                (
                    photo_id,
                    child_id,
                    taken_on,
                    f"photos/{photo_id}.jpg",
                    f"sha-{photo_id}",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            )
        await db.commit()

    response = await client.get(
        f"/api/yearbook/{child1['id']}/2025",
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    photos = response.json()["sections"]["photos"]
    assert photos["count"] == 1
    assert photos["highlights"] == [
        {
            "asset_id": "photo-child-1",
            "thumbnail_url": "/child-photos/photo-child-1/image?size=thumb",
        }
    ]


async def test_available_years_includes_child_photo_only_year(
    client,
    adult_a_headers,
    adult_a_user,
    child1,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO child_photos
                (id, child_id, taken_on, media_type, storage_key,
                 file_size, sha256, family_id, created_by)
            VALUES ('photo-only-year', ?, '2023-06-01', 'image/jpeg',
                    'photos/photo-only-year.jpg', 1, 'sha-photo-only-year', ?, ?)
            """,
            (child1["id"], adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    response = await client.get(
        f"/api/yearbook/{child1['id']}/years",
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert 2023 in response.json()["years"]


async def test_yearbook_choose_and_arrange_persists_exact_order(
    client, adult_a_headers, adult_a_user, child1, initialized_db
):
    await _seed_year(initialized_db, adult_a_user, child1, 2025)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO artworks (id, child_id, title, approx_date, media_type, storage_key, "
            "file_size, sha256, family_id, created_by) "
            "VALUES ('a2', ?, 'A second picture', '2025-08', 'image/jpeg', 'k2', 1, 's2', ?, ?)",
            (child1["id"], adult_a_user["family_id"], adult_a_user["id"]),
        )
        for photo_id, taken_on in (("p1", "2025-02-10"), ("p2", "2025-09-11")):
            await db.execute(
                "INSERT INTO child_photos (id, child_id, caption, taken_on, media_type, "
                "storage_key, file_size, sha256, family_id, created_by) "
                "VALUES (?, ?, ?, ?, 'image/jpeg', ?, 1, ?, ?, ?)",
                (
                    photo_id,
                    child1["id"],
                    f"Moment {photo_id}",
                    taken_on,
                    f"photos/{photo_id}.jpg",
                    f"sha-{photo_id}",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            )
        await db.commit()

    options = await client.get(
        f"/api/yearbook/{child1['id']}/2025/options", headers=adult_a_headers
    )
    assert options.status_code == 200
    assert {item["id"] for item in options.json()["artwork"]} == {"a1", "a2"}
    assert {item["id"] for item in options.json()["photos"]} == {"p1", "p2"}

    saved = await client.put(
        f"/api/yearbook/{child1['id']}/2025/arrangement",
        headers=adult_a_headers,
        json={"artwork_ids": ["a2"], "photo_ids": ["p2", "p1"]},
    )
    assert saved.status_code == 200, saved.text
    book = saved.json()
    assert [item["id"] for item in book["sections"]["artwork"]["items"]] == ["a2"]
    assert [item["asset_id"] for item in book["sections"]["photos"]["highlights"]] == [
        "p2",
        "p1",
    ]

    async with aiosqlite.connect(initialized_db) as db:
        artwork = await (
            await db.execute(
                "SELECT id, include_in_yearbook, yearbook_position FROM artworks "
                "WHERE id IN ('a1', 'a2') ORDER BY id"
            )
        ).fetchall()
        assert artwork == [("a1", 0, None), ("a2", 1, 0)]


async def test_yearbook_arrangement_rejects_cross_year_or_unknown_items(
    client, adult_a_headers, child1
):
    response = await client.put(
        f"/api/yearbook/{child1['id']}/2025/arrangement",
        headers=adult_a_headers,
        json={"artwork_ids": ["not-this-childs-artwork"], "photo_ids": []},
    )
    assert response.status_code == 422
    assert "does not belong" in response.json()["detail"]

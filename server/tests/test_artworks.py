import io

import pytest
from PIL import Image

from app.config import settings


def _jpeg() -> bytes:
    output = io.BytesIO()
    Image.new("RGB", (80, 60), (220, 90, 40)).save(output, format="JPEG", quality=90)
    return output.getvalue()


@pytest.fixture(autouse=True)
def artwork_storage(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "document_storage_path", str(tmp_path / "documents"))
    monkeypatch.setattr(settings, "media_cache_path", str(tmp_path / "media-cache"))
    monkeypatch.setattr(settings, "document_max_upload_bytes", 2 * 1024 * 1024)


async def upload_artwork(client, headers, child_id, *, approx_date="2026", title=None):
    data = {"child_id": child_id, "approx_date": approx_date}
    if title:
        data["title"] = title
    return await client.post(
        "/api/artworks/",
        headers=headers,
        files={"file": ("drawing.jpg", _jpeg(), "image/jpeg")},
        data=data,
    )


async def test_artwork_requires_authentication(client):
    response = await client.get("/api/artworks/")
    assert response.status_code == 401


async def test_upload_rough_dates_and_age_labels(client, adult_a_headers, child1):
    year_only = await upload_artwork(client, adult_a_headers, child1["id"], approx_date="2026")
    assert year_only.status_code == 201, year_only.text
    assert year_only.json()["date_precision"] == "year"

    month = await upload_artwork(
        client, adult_a_headers, child1["id"], approx_date="2025-03", title="A rocket"
    )
    assert month.status_code == 201
    body = month.json()
    assert body["date_precision"] == "month"
    assert body["title"] == "A rocket"
    assert body["child_name"] == child1["name"]
    # Age label derives from the child's date of birth at the artwork's midpoint.
    assert body["age_label"] is None or body["age_label"].startswith("Age") or "month" in body["age_label"]

    day = await upload_artwork(client, adult_a_headers, child1["id"], approx_date="2026-07-01")
    assert day.status_code == 201
    assert day.json()["date_precision"] == "day"

    listing = await client.get("/api/artworks/", headers=adult_a_headers)
    assert listing.status_code == 200
    assert len(listing.json()) == 3

    filtered = await client.get(
        "/api/artworks/", params={"child_id": child1["id"]}, headers=adult_a_headers
    )
    assert len(filtered.json()) == 3

    image = await client.get(
        f"/api/artworks/{day.json()['id']}/image", headers=adult_a_headers
    )
    assert image.status_code == 200
    assert image.headers["content-type"].startswith("image/")


async def test_upload_rejects_bad_dates_and_unknown_child(client, adult_a_headers, child1):
    bad_date = await upload_artwork(client, adult_a_headers, child1["id"], approx_date="last summer")
    assert bad_date.status_code == 422

    impossible = await upload_artwork(client, adult_a_headers, child1["id"], approx_date="2026-02-31")
    assert impossible.status_code == 422

    unknown_child = await upload_artwork(client, adult_a_headers, "not-a-child")
    assert unknown_child.status_code == 404


async def test_update_and_delete_artwork(client, adult_a_headers, child1, child2):
    created = (await upload_artwork(client, adult_a_headers, child1["id"])).json()

    updated = await client.patch(
        f"/api/artworks/{created['id']}",
        json={"title": "Our house", "approx_date": "2025-11", "child_id": child2["id"]},
        headers=adult_a_headers,
    )
    assert updated.status_code == 200
    body = updated.json()
    assert body["title"] == "Our house"
    assert body["date_precision"] == "month"
    assert body["child_id"] == child2["id"]

    removed = await client.delete(f"/api/artworks/{created['id']}", headers=adult_a_headers)
    assert removed.status_code == 204
    assert (await client.get("/api/artworks/", headers=adult_a_headers)).json() == []

    restored = await client.post(
        f"/api/artworks/{created['id']}/restore", headers=adult_a_headers
    )
    assert restored.status_code == 200
    assert restored.json()["title"] == "Our house"


async def test_artwork_keeps_original_and_supports_gallery_and_yearbook_choices(
    client, adult_a_headers, child1
):
    created = (await upload_artwork(client, adult_a_headers, child1["id"], title="Rainbow")).json()
    assert created["original_available"] is True
    assert (
        await client.get(
            f"/api/artworks/{created['id']}/image",
            params={"size": "original"},
            headers=adult_a_headers,
        )
    ).status_code == 200

    updated = await client.patch(
        f"/api/artworks/{created['id']}",
        json={
            "favourite": True,
            "include_in_yearbook": False,
            "medium": "Watercolour",
            "school_year": "Reception",
            "story": "Painted after the storm",
            "child_quote": "The sun came back",
        },
        headers=adult_a_headers,
    )
    adjusted = await client.put(
        f"/api/artworks/{created['id']}/appearance",
        json={"rotation_degrees": 90, "enhanced": True},
        headers=adult_a_headers,
    )
    yearbook = await client.get(
        f"/api/yearbook/{child1['id']}/2026", headers=adult_a_headers
    )

    assert updated.status_code == 200
    assert updated.json()["favourite"] is True
    assert updated.json()["medium"] == "Watercolour"
    assert adjusted.status_code == 200
    assert adjusted.json()["rotation_degrees"] == 90
    assert adjusted.json()["enhanced"] is True
    assert yearbook.status_code == 200
    assert yearbook.json()["sections"]["artwork"]["count"] == 0


async def test_artworks_are_family_isolated(client, adult_a_headers, other_family_headers, child1):
    created = (await upload_artwork(client, adult_a_headers, child1["id"])).json()

    assert (await client.get("/api/artworks/", headers=other_family_headers)).json() == []
    stolen = await client.get(
        f"/api/artworks/{created['id']}/image", headers=other_family_headers
    )
    assert stolen.status_code == 404

import asyncio
import io
from pathlib import Path

import pytest
from PIL import Image

from app.config import settings
from app.routers import child_photos as child_photos_router

def _jpeg(*, colour=(32, 120, 210), size=(80, 60), exif_date=None) -> bytes:
    output = io.BytesIO()
    image = Image.new("RGB", size, colour)
    exif = Image.Exif()
    if exif_date:
        exif[36867] = exif_date
    image.save(output, format="JPEG", quality=90, exif=exif)
    return output.getvalue()


def _large_png() -> bytes:
    output = io.BytesIO()
    Image.effect_noise((1_600, 1_600), 120).convert("RGB").save(output, format="PNG")
    data = output.getvalue()
    assert len(data) > 1024 * 1024
    return data


def _image_bytes(format_name: str) -> bytes:
    output = io.BytesIO()
    Image.new("RGB", (32, 24), (90, 140, 200)).save(output, format=format_name)
    return output.getvalue()


_EXIF_JPEG = _jpeg(exif_date="2023:05:04 09:30:00")


@pytest.fixture(autouse=True)
def photo_storage(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "document_storage_path", str(tmp_path / "documents"))
    monkeypatch.setattr(settings, "media_cache_path", str(tmp_path / "media-cache"))
    monkeypatch.setattr(settings, "document_max_upload_bytes", 16 * 1024 * 1024)


async def _upload(client, headers, child_id, files, taken_on=None):
    data = {"child_id": child_id}
    if taken_on:
        data["taken_on"] = taken_on
    return await client.post("/api/child-photos/", headers=headers, files=files, data=data)


async def test_child_photos_requires_authentication(client):
    assert (await client.get("/api/child-photos/")).status_code == 401


async def test_batch_upload_with_client_dates(client, adult_a_headers, child1):
    files = [
        ("files", ("beach.jpg", _jpeg(), "image/jpeg")),
        ("files", ("park.jpg", _jpeg(colour=(80, 180, 70)), "image/jpeg")),
    ]
    resp = await _upload(client, adult_a_headers, child1["id"], files, taken_on=["2026-06-01", "2026-07-02"])
    assert resp.status_code == 201, resp.text
    photos = resp.json()["photos"]
    assert len(photos) == 2
    assert {p["taken_on"] for p in photos} == {"2026-06-01", "2026-07-02"}
    assert all(p["caption"] is None for p in photos)
    assert all(p["child_name"] == child1["name"] for p in photos)

    listing = await client.get("/api/child-photos/", params={"child_id": child1["id"]}, headers=adult_a_headers)
    assert len(listing.json()) == 2
    # Newest taken_on first.
    assert listing.json()[0]["taken_on"] == "2026-07-02"

    image = await client.get(f"/api/child-photos/{photos[0]['id']}/image", headers=adult_a_headers)
    assert image.status_code == 200
    assert image.headers["content-type"].startswith("image/")


async def test_date_falls_back_to_exif_then_today(client, adult_a_headers, child1):
    files = [("files", ("exif.jpg", _EXIF_JPEG, "image/jpeg"))]
    # No client date supplied → the EXIF DateTimeOriginal is used.
    resp = await _upload(client, adult_a_headers, child1["id"], files)
    assert resp.status_code == 201
    assert resp.json()["photos"][0]["taken_on"] == "2023-05-04"


async def test_edit_caption_and_date_later(client, adult_a_headers, child1, child2):
    files = [("files", ("p.jpg", _jpeg(), "image/jpeg"))]
    created = (await _upload(client, adult_a_headers, child1["id"], files, taken_on=["2026-01-01"])).json()["photos"][0]

    edited = await client.patch(
        f"/api/child-photos/{created['id']}",
        json={"caption": "First steps!", "taken_on": "2026-02-14", "child_id": child2["id"]},
        headers=adult_a_headers,
    )
    assert edited.status_code == 200
    body = edited.json()
    assert body["caption"] == "First steps!"
    assert body["taken_on"] == "2026-02-14"
    assert body["child_id"] == child2["id"]


async def test_delete_photo(client, adult_a_headers, child1):
    files = [("files", ("p.jpg", _jpeg(), "image/jpeg"))]
    created = (await _upload(client, adult_a_headers, child1["id"], files, taken_on=["2026-01-01"])).json()["photos"][0]
    removed = await client.delete(f"/api/child-photos/{created['id']}", headers=adult_a_headers)
    assert removed.status_code == 204
    assert (await client.get("/api/child-photos/", headers=adult_a_headers)).json() == []


async def test_rejects_non_image_and_unknown_child(client, adult_a_headers, child1):
    bad = await _upload(client, adult_a_headers, child1["id"], [("files", ("x.pdf", b"%PDF", "application/pdf"))])
    assert bad.status_code == 422
    unknown = await _upload(client, adult_a_headers, "not-a-child", [("files", ("p.jpg", _jpeg(), "image/jpeg"))])
    assert unknown.status_code == 404


async def test_batch_and_family_quota_are_bounded(client, adult_a_headers, child1, monkeypatch):
    too_many = [("files", (f"{index}.jpg", _jpeg(), "image/jpeg")) for index in range(6)]
    assert (await _upload(client, adult_a_headers, child1["id"], too_many)).status_code == 422

    monkeypatch.setattr(settings, "media_family_quota_bytes", 100)
    quota = await _upload(
        client,
        adult_a_headers,
        child1["id"],
        [("files", ("photo.jpg", _jpeg(), "image/jpeg"))],
    )
    assert quota.status_code == 413
    assert quota.json()["detail"] == "Family photo storage quota exceeded"


async def test_child_photos_are_family_isolated(client, adult_a_headers, other_family_headers, child1):
    files = [("files", ("p.jpg", _jpeg(), "image/jpeg"))]
    created = (await _upload(client, adult_a_headers, child1["id"], files, taken_on=["2026-01-01"])).json()["photos"][0]
    assert (await client.get("/api/child-photos/", headers=other_family_headers)).json() == []
    assert (await client.get(f"/api/child-photos/{created['id']}/image", headers=other_family_headers)).status_code == 404


async def test_upload_over_one_megabyte_is_normalised_thumbnailed_and_idempotent(
    client, adult_a_headers, child1
):
    data = _large_png()
    files = [("files", ("camera.png", data, "image/png"))]
    form = {
        "child_id": child1["id"],
        "taken_on": "2026-07-12",
        "client_id": "camera-upload-1",
    }
    first = await client.post("/api/child-photos/", headers=adult_a_headers, files=files, data=form)
    assert first.status_code == 201, first.text
    photo = first.json()["photos"][0]

    replay = await client.post("/api/child-photos/", headers=adult_a_headers, files=files, data=form)
    assert replay.status_code == 201
    assert replay.json()["photos"][0]["id"] == photo["id"]
    assert len((await client.get("/api/child-photos/", headers=adult_a_headers)).json()) == 1

    display = await client.get(f"/api/child-photos/{photo['id']}/image", headers=adult_a_headers)
    thumb = await client.get(
        f"/api/child-photos/{photo['id']}/image?size=thumb", headers=adult_a_headers
    )
    assert display.headers["content-type"].startswith("image/jpeg")
    assert display.headers["cache-control"] == "private, max-age=86400"
    assert len(thumb.content) < len(display.content)


async def test_concurrent_client_id_replay_returns_one_photo_without_unique_index_error(
    client,
    adult_a_headers,
    child1,
    monkeypatch,
):
    original_prepare = child_photos_router.prepare_family_image
    prepare_count = 0
    both_preflight_checks_finished = asyncio.Event()
    release_preparation = asyncio.Event()

    async def pause_preparation(data: bytes):
        nonlocal prepare_count
        prepare_count += 1
        if prepare_count == 2:
            both_preflight_checks_finished.set()
        await release_preparation.wait()
        return await original_prepare(data)

    monkeypatch.setattr(child_photos_router, "prepare_family_image", pause_preparation)
    files = [("files", ("camera.jpg", _jpeg(), "image/jpeg"))]
    form = {
        "child_id": child1["id"],
        "taken_on": "2026-07-12",
        "client_id": "same-concurrent-camera-upload",
    }
    first_task = asyncio.create_task(
        client.post("/api/child-photos/", headers=adult_a_headers, files=files, data=form)
    )
    second_task = asyncio.create_task(
        client.post("/api/child-photos/", headers=adult_a_headers, files=files, data=form)
    )
    await asyncio.wait_for(both_preflight_checks_finished.wait(), timeout=2)
    release_preparation.set()
    first, second = await asyncio.gather(first_task, second_task)

    assert first.status_code == 201, first.text
    assert second.status_code == 201, second.text
    assert first.json()["photos"][0]["id"] == second.json()["photos"][0]["id"]
    listing = await client.get("/api/child-photos/", headers=adult_a_headers)
    assert len(listing.json()) == 1
    assert len(list(Path(settings.document_storage_path).rglob("photo.jpg"))) == 1


async def test_delete_photo_keeps_original_and_can_be_restored(client, adult_a_headers, child1):
    created = (
        await _upload(
            client,
            adult_a_headers,
            child1["id"],
            [("files", ("p.jpg", _jpeg(), "image/jpeg"))],
        )
    ).json()["photos"][0]
    stored = list(Path(settings.document_storage_path).rglob("photo.jpg"))
    assert len(stored) == 1 and stored[0].is_file()
    original = list(Path(settings.document_storage_path).rglob("original.jpg"))
    assert len(original) == 1 and original[0].is_file()
    assert (await client.delete(f"/api/child-photos/{created['id']}", headers=adult_a_headers)).status_code == 204
    assert stored[0].exists()
    assert original[0].exists()

    restored = await client.post(
        f"/api/child-photos/{created['id']}/restore", headers=adult_a_headers
    )
    assert restored.status_code == 200
    assert restored.json()["id"] == created["id"]
    assert len((await client.get("/api/child-photos/", headers=adult_a_headers)).json()) == 1


async def test_original_metadata_and_keepsake_fields_round_trip(
    client, adult_a_headers, child1
):
    response = await client.post(
        "/api/child-photos/",
        headers=adult_a_headers,
        files=[("files", ("memory.png", _jpeg(), "image/jpeg"))],
        data={
            "child_id": child1["id"],
            "taken_on": "2026-05-10",
            "caption": "First day at the seaside",
            "location": "Walberswick",
            "story": "They ran straight into the water.",
            "favourite": "true",
            "include_in_yearbook": "false",
        },
    )
    assert response.status_code == 201, response.text
    photo = response.json()["photos"][0]
    assert photo["caption"] == "First day at the seaside"
    assert photo["location"] == "Walberswick"
    assert photo["story"] == "They ran straight into the water."
    assert photo["favourite"] is True
    assert photo["include_in_yearbook"] is False
    assert photo["original_available"] is True
    assert photo["original_image_url"].endswith("?size=original")

    original = await client.get(
        f"/api/child-photos/{photo['id']}/image?size=original", headers=adult_a_headers
    )
    assert original.status_code == 200
    assert original.content == _jpeg()

    edited = await client.patch(
        f"/api/child-photos/{photo['id']}",
        headers=adult_a_headers,
        json={"favourite": False, "include_in_yearbook": True, "yearbook_position": 2},
    )
    assert edited.status_code == 200
    assert edited.json()["favourite"] is False
    assert edited.json()["include_in_yearbook"] is True
    assert edited.json()["yearbook_position"] == 2


@pytest.mark.parametrize(
    ("format_name", "filename", "media_type"),
    [("GIF", "memory.gif", "image/gif"), ("TIFF", "memory.tiff", "image/tiff")],
)
async def test_less_common_ios_original_formats_are_preserved(
    client, adult_a_headers, child1, format_name, filename, media_type
):
    original_bytes = _image_bytes(format_name)
    response = await _upload(
        client,
        adult_a_headers,
        child1["id"],
        [("files", (filename, original_bytes, media_type))],
    )
    assert response.status_code == 201, response.text
    photo = response.json()["photos"][0]

    original = await client.get(
        f"/api/child-photos/{photo['id']}/image?size=original", headers=adult_a_headers
    )
    assert original.status_code == 200
    assert original.headers["content-type"].startswith(media_type)
    assert original.content == original_bytes

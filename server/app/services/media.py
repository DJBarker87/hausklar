"""Safe image normalisation, thumbnail caching, and family-media quotas."""

from __future__ import annotations

import asyncio
import hashlib
import io
import shutil
import warnings
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError
from pillow_heif import register_heif_opener

from app.config import settings

register_heif_opener()
Image.MAX_IMAGE_PIXELS = 50_000_000

DISPLAY_MAX_PIXELS = 2_560
THUMBNAIL_MAX_PIXELS = 512
AVATAR_PIXELS = 512


class MediaProcessingError(ValueError):
    pass


def _rgb(image: Image.Image) -> Image.Image:
    image = ImageOps.exif_transpose(image)
    if image.mode in {"RGBA", "LA"} or "transparency" in image.info:
        canvas = Image.new("RGB", image.size, "white")
        alpha = image.getchannel("A") if "A" in image.getbands() else None
        canvas.paste(image.convert("RGB"), mask=alpha)
        return canvas
    return image.convert("RGB")


def _jpeg(image: Image.Image, *, quality: int) -> bytes:
    output = io.BytesIO()
    image.save(output, format="JPEG", quality=quality, optimize=True, progressive=True)
    return output.getvalue()


def _prepare(data: bytes) -> tuple[bytes, bytes]:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as source:
                source.load()
                display = _rgb(source)
    except (
        UnidentifiedImageError,
        OSError,
        ValueError,
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
    ) as exc:
        raise MediaProcessingError(
            "That photo could not be read. Choose a JPEG, PNG, HEIC, WebP, GIF, or TIFF image."
        ) from exc

    display.thumbnail((DISPLAY_MAX_PIXELS, DISPLAY_MAX_PIXELS), Image.Resampling.LANCZOS)
    thumbnail = display.copy()
    thumbnail.thumbnail((THUMBNAIL_MAX_PIXELS, THUMBNAIL_MAX_PIXELS), Image.Resampling.LANCZOS)
    return _jpeg(display, quality=86), _jpeg(thumbnail, quality=82)


async def prepare_family_image(data: bytes) -> tuple[bytes, bytes]:
    return await asyncio.to_thread(_prepare, data)


def _prepare_artwork_appearance(
    data: bytes, *, rotation_degrees: int, enhanced: bool
) -> tuple[bytes, bytes]:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as source:
                source.load()
                display = _rgb(source)
    except (
        UnidentifiedImageError,
        OSError,
        ValueError,
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
    ) as exc:
        raise MediaProcessingError("The original artwork photo could not be read.") from exc

    if rotation_degrees:
        display = display.rotate(-rotation_degrees, expand=True, fillcolor="white")
    if enhanced:
        # A restrained paper-friendly correction: lift the usable tonal range
        # without inventing colour or replacing the child's marks.
        display = ImageOps.autocontrast(display, cutoff=1)
    display.thumbnail((DISPLAY_MAX_PIXELS, DISPLAY_MAX_PIXELS), Image.Resampling.LANCZOS)
    thumbnail = display.copy()
    thumbnail.thumbnail((THUMBNAIL_MAX_PIXELS, THUMBNAIL_MAX_PIXELS), Image.Resampling.LANCZOS)
    return _jpeg(display, quality=88), _jpeg(thumbnail, quality=84)


async def prepare_artwork_appearance(
    data: bytes, *, rotation_degrees: int, enhanced: bool
) -> tuple[bytes, bytes]:
    return await asyncio.to_thread(
        _prepare_artwork_appearance,
        data,
        rotation_degrees=rotation_degrees,
        enhanced=enhanced,
    )


def _prepare_avatar(data: bytes) -> bytes:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as source:
                source.load()
                image = _rgb(source)
    except (
        UnidentifiedImageError,
        OSError,
        ValueError,
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
    ) as exc:
        raise MediaProcessingError(
            "That photo could not be read. Choose a JPEG, PNG, HEIC, or WebP image."
        ) from exc

    # Clients send the crop the person reviewed. The centre-fit is a final
    # defensive normalisation for malformed or older clients.
    image = ImageOps.fit(
        image,
        (AVATAR_PIXELS, AVATAR_PIXELS),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )
    return _jpeg(image, quality=88)


async def prepare_avatar_image(data: bytes) -> bytes:
    """Return a bounded, metadata-free square JPEG for a circular avatar."""
    return await asyncio.to_thread(_prepare_avatar, data)


def avatar_storage_directory(family_id: str) -> Path:
    family_key = hashlib.sha256(family_id.encode()).hexdigest()
    return Path(settings.avatar_storage_path).expanduser().resolve() / family_key


def avatar_file_path(family_id: str, member_id: str, token: str) -> Path:
    member_key = hashlib.sha256(member_id.encode()).hexdigest()
    return avatar_storage_directory(family_id) / f"{member_key}-{token}.jpg"


async def remove_member_avatar_files(family_id: str, member_id: str) -> None:
    """Physically erase every stored avatar version for one family member."""
    directory = avatar_storage_directory(family_id)
    member_key = hashlib.sha256(member_id.encode()).hexdigest()

    def remove() -> None:
        for path in directory.glob(f"{member_key}-*.jpg"):
            path.unlink(missing_ok=True)
        try:
            directory.rmdir()
        except OSError:
            pass

    await asyncio.to_thread(remove)


async def remove_family_avatar_files(family_id: str) -> None:
    """Physically erase all profile photos when the final account is deleted."""
    await asyncio.to_thread(
        shutil.rmtree,
        avatar_storage_directory(family_id),
        ignore_errors=True,
    )


def media_cache_root() -> Path:
    return Path(settings.media_cache_path).expanduser().resolve()


async def remove_family_media_cache(family_id: str) -> None:
    """Physically erase generated artwork and child-photo copies for a family."""
    await asyncio.to_thread(
        shutil.rmtree,
        media_cache_root() / family_id,
        ignore_errors=True,
    )


def media_cache_path(family_id: str, kind: str, item_id: str, variant: str) -> Path:
    safe_kind = "artworks" if kind == "artworks" else "child-photos"
    safe_variant = "thumb" if variant == "thumb" else "display"
    return media_cache_root() / family_id / safe_kind / f"{item_id}-{safe_variant}.jpg"


async def store_cached_image(
    family_id: str, kind: str, item_id: str, variant: str, data: bytes
) -> Path:
    path = media_cache_path(family_id, kind, item_id, variant)

    def write() -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".uploading")
        temporary.write_bytes(data)
        temporary.replace(path)

    await asyncio.to_thread(write)
    return path


async def family_image_path(
    *,
    original: Path,
    media_type: str,
    family_id: str,
    kind: str,
    item_id: str,
    size: str,
) -> tuple[Path, str]:
    """Return a bounded JPEG display/thumbnail, regenerating cache as needed."""
    variant = "thumb" if size == "thumb" else "display"
    if variant == "display" and media_type == "image/jpeg":
        return original, "image/jpeg"
    cached = media_cache_path(family_id, kind, item_id, variant)
    if cached.is_file():
        return cached, "image/jpeg"
    try:
        raw = await asyncio.to_thread(original.read_bytes)
    except OSError as exc:
        raise MediaProcessingError("The stored photo is missing.") from exc
    display, thumbnail = await prepare_family_image(raw)
    display_path, thumbnail_path = await asyncio.gather(
        store_cached_image(family_id, kind, item_id, "display", display),
        store_cached_image(family_id, kind, item_id, "thumb", thumbnail),
    )
    return (thumbnail_path if variant == "thumb" else display_path), "image/jpeg"


async def remove_cached_images(family_id: str, kind: str, item_id: str) -> None:
    paths = [
        media_cache_path(family_id, kind, item_id, "thumb"),
        media_cache_path(family_id, kind, item_id, "display"),
    ]
    await asyncio.gather(
        *(asyncio.to_thread(path.unlink, missing_ok=True) for path in paths)
    )


async def media_storage_used(db, family_id: str) -> int:
    cursor = await db.execute(
        """
        SELECT
          COALESCE((SELECT SUM(file_size + COALESCE(original_file_size, 0)) FROM artworks
                    WHERE family_id = ? AND deleted_at IS NULL), 0) +
          COALESCE((SELECT SUM(file_size + COALESCE(original_file_size, 0)) FROM child_photos
                    WHERE family_id = ? AND deleted_at IS NULL), 0)
        """,
        (family_id, family_id),
    )
    return int((await cursor.fetchone())[0])

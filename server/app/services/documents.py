"""Filesystem operations for the document store."""

import asyncio
import hashlib
import io
import os
import re
import uuid
from pathlib import Path

from fastapi import UploadFile

from app.config import settings

ALLOWED_MEDIA_TYPES = {
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/pdf",
    "image/heic",
    "image/heif",
    "image/gif",
    "image/jpeg",
    "image/png",
    "image/tiff",
    "image/webp",
    "text/plain",
}


class DocumentStorageError(ValueError):
    pass


async def family_document_storage_bytes(db, *, family_id: str) -> int:
    """Return durable bytes sharing the family document-store quota."""
    row = await (
        await db.execute(
            """
            SELECT
                (SELECT COALESCE(SUM(file_size), 0)
                 FROM documents
                 WHERE family_id = ? AND deleted_at IS NULL)
              + (SELECT COALESCE(SUM(byte_size), 0)
                 FROM finance_purchase_source_files
                 WHERE family_id = ? AND storage_status = 'STORED'
                   AND deleted_at IS NULL)
            """,
            (family_id, family_id),
        )
    ).fetchone()
    return int(row[0])


def safe_filename(value: str | None) -> str:
    name = Path(value or "document").name
    name = re.sub(r"[^A-Za-z0-9._ -]+", "_", name).strip(" .")
    return name[:180] or "document"


def document_root() -> Path:
    return Path(settings.document_storage_path).expanduser().resolve()


def harden_document_store_permissions() -> None:
    """Make existing document directories and files owner-only.

    New writes already set these modes. Running the same rule at startup also
    repairs files created before that protection was added. Symlinks and other
    special filesystem entries fail closed instead of being followed.
    """

    root = document_root()
    if root.exists() and (root.is_symlink() or not root.is_dir()):
        raise DocumentStorageError("Document storage root is not a private directory")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)

    for current_value, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_value)
        if current.is_symlink():
            raise DocumentStorageError("Document storage contains a symbolic link")
        current.chmod(0o700)
        for name in directory_names:
            path = current / name
            if path.is_symlink() or not path.is_dir():
                raise DocumentStorageError("Document storage contains an unsafe directory")
            path.chmod(0o700)
        for name in file_names:
            path = current / name
            if path.is_symlink() or not path.is_file():
                raise DocumentStorageError("Document storage contains an unsafe file")
            path.chmod(0o600)


def resolve_storage_key(storage_key: str) -> Path:
    root = document_root()
    candidate = (root / storage_key).resolve()
    if candidate != root and root not in candidate.parents:
        raise DocumentStorageError("Invalid document storage key")
    return candidate


def _ensure_private_directory(path: Path) -> None:
    """Create every document-store directory with owner-only permissions."""
    root = document_root()
    try:
        relative = path.relative_to(root)
    except ValueError as exc:
        raise DocumentStorageError("Invalid document storage directory") from exc

    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    current = root
    for part in relative.parts:
        current /= part
        current.mkdir(exist_ok=True, mode=0o700)
        current.chmod(0o700)


def _copy_and_hash(source, destination: Path, max_bytes: int) -> tuple[int, str]:
    _ensure_private_directory(destination.parent)
    temporary = destination.with_suffix(destination.suffix + ".uploading")
    digest = hashlib.sha256()
    total = 0

    try:
        with temporary.open("wb") as target:
            temporary.chmod(0o600)
            while chunk := source.read(1024 * 1024):
                total += len(chunk)
                if total > max_bytes:
                    raise DocumentStorageError(
                        f"Document exceeds the {max_bytes // (1024 * 1024)} MB upload limit"
                    )
                digest.update(chunk)
                target.write(chunk)
        temporary.replace(destination)
        destination.chmod(0o600)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise

    return total, digest.hexdigest()


async def stage_upload(upload: UploadFile) -> tuple[Path, str, str, int, str]:
    """Copy an upload once to a private same-filesystem staging file."""
    media_type = (upload.content_type or "application/octet-stream").lower()
    filename = safe_filename(upload.filename)
    if filename.lower().endswith(".docx") and media_type in {
        "application/octet-stream",
        "application/zip",
    }:
        media_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    if media_type not in ALLOWED_MEDIA_TYPES:
        raise DocumentStorageError("Only PDF, Word, image, and plain-text documents are supported")
    staging_root = document_root() / ".staging"
    _ensure_private_directory(staging_root)
    staged_path = staging_root / f"{uuid.uuid4()}.upload"
    await upload.seek(0)
    try:
        size, sha256 = await asyncio.to_thread(
            _copy_and_hash,
            upload.file,
            staged_path,
            settings.document_max_upload_bytes,
        )
        await asyncio.to_thread(staged_path.chmod, 0o600)
    except BaseException:
        staged_path.unlink(missing_ok=True)
        raise
    if size == 0:
        staged_path.unlink(missing_ok=True)
        raise DocumentStorageError("The uploaded document is empty")
    return staged_path, filename, media_type, size, sha256


async def promote_staged_upload(
    staged_path: Path,
    *,
    family_id: str,
    document_id: str,
    filename: str,
) -> str:
    """Atomically move staged bytes into their final family/document location."""
    storage_key = str(Path(family_id) / document_id / filename)
    destination = resolve_storage_key(storage_key)

    def promote() -> None:
        _ensure_private_directory(destination.parent)
        staged_path.replace(destination)
        destination.chmod(0o600)

    await asyncio.to_thread(promote)
    return storage_key


async def remove_staged_upload(staged_path: Path | None) -> None:
    if staged_path is not None:
        await asyncio.to_thread(staged_path.unlink, missing_ok=True)


async def store_bytes(
    data: bytes,
    *,
    filename: str,
    media_type: str,
    family_id: str,
    document_id: str,
) -> tuple[str, str, int, str]:
    media_type = media_type.lower()
    if media_type not in ALLOWED_MEDIA_TYPES:
        raise DocumentStorageError("Only PDF, Word, image, and plain-text documents are supported")
    if not data:
        raise DocumentStorageError("The uploaded document is empty")

    filename = safe_filename(filename)
    storage_key = str(Path(family_id) / document_id / filename)
    destination = resolve_storage_key(storage_key)
    size, sha256 = await asyncio.to_thread(
        _copy_and_hash,
        io.BytesIO(data),
        destination,
        settings.document_max_upload_bytes,
    )
    return storage_key, filename, size, sha256


async def remove_new_upload(storage_key: str) -> None:
    """Remove a file only when its database insert failed before creation completed."""
    path = resolve_storage_key(storage_key)
    await asyncio.to_thread(path.unlink, missing_ok=True)


async def remove_stored_document(storage_key: str) -> None:
    """Physically erase a document while retaining its soft-deleted audit row."""
    path = resolve_storage_key(storage_key)

    def remove() -> None:
        path.unlink(missing_ok=True)
        root = document_root()
        parent = path.parent
        while parent != root and root in parent.parents:
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent

    await asyncio.to_thread(remove)

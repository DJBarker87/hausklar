from __future__ import annotations

from pydantic import BaseModel, Field


class ToastImportChanges(BaseModel):
    added: int = Field(ge=0)
    changed: int = Field(ge=0)
    removed: int = Field(ge=0)
    unchanged: int = Field(ge=0)


class ToastImportPreview(BaseModel):
    sha256: str
    source_title: str
    child_id: str
    child_name: str
    valid_from: str
    valid_to: str
    base_start_time: str
    booked_days: int = Field(ge=0)
    until_1630: int = Field(ge=0)
    until_1730: int = Field(ge=0)
    changes: ToastImportChanges
    already_imported: bool = False
    can_confirm: bool = True


class ToastImportResult(BaseModel):
    import_id: str
    imported: bool
    preview: ToastImportPreview


class ToastImportStatus(BaseModel):
    import_id: str
    child_id: str
    child_name: str
    source_title: str
    valid_from: str
    valid_to: str
    booked_days: int = Field(ge=0)
    imported_at: str

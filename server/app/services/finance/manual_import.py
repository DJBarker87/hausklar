"""Strict, read-only previews for manual Finance history files.

The functions in this module accept file bytes and return normalized transaction
DTOs plus row diagnostics. They deliberately have no database, filesystem, URL,
or ledger-import capability; committing a reviewed preview is a separate concern.
"""

import csv
import hashlib
import io
import json
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Literal

from app.models.finance import NormalisedSourceTransaction
from app.services.finance.money import Money, normalise_currency
from app.services.finance.upload_limits import MAX_STATEMENT_IMPORT_BYTES

MAX_IMPORT_BYTES = MAX_STATEMENT_IMPORT_BYTES
MAX_IMPORT_ROWS = 5_000
MAX_IMPORT_COLUMNS = 64
MAX_FIELD_CHARS = 500
MAX_HEADER_CHARS = 120
MAX_ABS_AMOUNT_MINOR = 1_000_000_000_000_000

SignConvention = Literal["DEBIT_NEGATIVE", "DEBIT_POSITIVE"]
IssueSeverity = Literal["ERROR", "WARNING"]
RepairRelationship = Literal["NO_IMPORTABLE_ROWS", "NEW_HISTORY", "GAP", "CONTIGUOUS", "OVERLAP"]

_DATE_FORMATS = {"%d/%m/%Y", "%Y-%m-%d"}
_DELIMITERS = {",", ";", "\t"}
_CSV_ENCODINGS = {"utf-8", "utf-8-sig"}
_AMOUNT_PATTERN = re.compile(r"^[+-]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?$")
_OFX_BLOCK = re.compile(r"<STMTTRN>(.*?)</STMTTRN>", re.IGNORECASE | re.DOTALL)


class ManualImportInputError(ValueError):
    """A whole file or its confirmed import settings are unsafe or invalid."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class ManualImportContext:
    """User-confirmed destination and interpretation of a manual file."""

    account_id: str
    currency: str
    sign_convention: SignConvention
    observed_at: datetime
    confirmed: bool

    def __post_init__(self) -> None:
        account_id = self.account_id.strip() if isinstance(self.account_id, str) else ""
        if not self.confirmed:
            raise ManualImportInputError(
                "CONFIRMATION_REQUIRED",
                "Confirm the account, currency, and sign convention before previewing",
            )
        if not account_id or len(account_id) > 200:
            raise ManualImportInputError("INVALID_ACCOUNT", "Account ID is invalid")
        try:
            currency = normalise_currency(self.currency)
        except (TypeError, ValueError) as exc:
            raise ManualImportInputError("INVALID_CURRENCY", str(exc)) from exc
        if self.sign_convention not in {"DEBIT_NEGATIVE", "DEBIT_POSITIVE"}:
            raise ManualImportInputError(
                "INVALID_SIGN_CONVENTION",
                "Sign convention must say whether debit values are negative or positive",
            )
        if self.observed_at.tzinfo is None or self.observed_at.utcoffset() is None:
            raise ManualImportInputError(
                "INVALID_OBSERVED_AT", "Import observation time must include a timezone"
            )
        object.__setattr__(self, "account_id", account_id)
        object.__setattr__(self, "currency", currency)
        object.__setattr__(self, "observed_at", self.observed_at.astimezone(timezone.utc))


@dataclass(frozen=True, slots=True)
class CsvColumnMapping:
    """Exact source headers; no guessed or positional column mapping is allowed."""

    booking_date: str
    amount: str
    description: str
    currency: str | None = None
    transaction_id: str | None = None
    value_date: str | None = None
    pending_status: str | None = None

    def __post_init__(self) -> None:
        values = [
            self.booking_date,
            self.amount,
            self.description,
            self.currency,
            self.transaction_id,
            self.value_date,
            self.pending_status,
        ]
        present = [value.strip() for value in values if value is not None]
        if len(present) != len(set(present)) or any(not value for value in present):
            raise ManualImportInputError(
                "INVALID_COLUMN_MAPPING", "Mapped CSV headers must be non-empty and unique"
            )
        if any(len(value) > MAX_HEADER_CHARS for value in present):
            raise ManualImportInputError(
                "INVALID_COLUMN_MAPPING", "A mapped CSV header is too long"
            )
        for field_name in (
            "booking_date",
            "amount",
            "description",
            "currency",
            "transaction_id",
            "value_date",
            "pending_status",
        ):
            value = getattr(self, field_name)
            if value is not None:
                object.__setattr__(self, field_name, value.strip())


@dataclass(frozen=True, slots=True)
class CsvImportSpec:
    columns: CsvColumnMapping
    date_format: str
    delimiter: str
    encoding: str

    def __post_init__(self) -> None:
        if self.date_format not in _DATE_FORMATS:
            raise ManualImportInputError(
                "UNSUPPORTED_DATE_FORMAT",
                "CSV date format must be DD/MM/YYYY or YYYY-MM-DD",
            )
        if self.delimiter not in _DELIMITERS:
            raise ManualImportInputError(
                "UNSUPPORTED_DELIMITER", "CSV delimiter must be comma, semicolon, or tab"
            )
        encoding = self.encoding.lower()
        if encoding not in _CSV_ENCODINGS:
            raise ManualImportInputError("UNSUPPORTED_ENCODING", "CSV encoding must be UTF-8")
        object.__setattr__(self, "encoding", encoding)


@dataclass(frozen=True, slots=True)
class ManualImportIssue:
    row_number: int | None
    code: str
    message: str
    severity: IssueSeverity = "ERROR"


@dataclass(frozen=True, slots=True)
class ManualImportRecord:
    row_number: int
    row_provenance: str
    transaction: NormalisedSourceTransaction


@dataclass(frozen=True, slots=True)
class ManualImportPreview:
    batch_id: str
    source_kind: Literal["CSV", "OFX"]
    account_id: str
    currency: str
    total_rows: int
    records: tuple[ManualImportRecord, ...]
    issues: tuple[ManualImportIssue, ...]

    @property
    def invalid_rows(self) -> int:
        return sum(issue.severity == "ERROR" for issue in self.issues)

    @property
    def duplicate_rows(self) -> int:
        return sum(issue.code == "DUPLICATE_ROW" for issue in self.issues)

    @property
    def can_commit(self) -> bool:
        return bool(self.records) and self.invalid_rows == 0


@dataclass(frozen=True, slots=True)
class HistoryRepairPreview:
    relationship: RepairRelationship
    imported_start: date | None
    imported_end: date | None
    existing_start: date | None
    existing_end: date | None
    gap_start: date | None = None
    gap_end: date | None = None
    overlap_start: date | None = None
    overlap_end: date | None = None
    importable_rows: int = 0


def preview_csv_import(
    payload: bytes,
    *,
    context: ManualImportContext,
    spec: CsvImportSpec,
) -> ManualImportPreview:
    """Parse a bounded CSV into a review-only normalized preview."""
    raw = _require_file_bytes(payload)
    try:
        text = raw.decode(spec.encoding, errors="strict")
    except UnicodeDecodeError as exc:
        raise ManualImportInputError(
            "INVALID_ENCODING", "CSV is not valid in the selected UTF-8 encoding"
        ) from exc
    _reject_unsafe_text(text)
    batch_id = _batch_id(
        raw,
        source_kind="CSV",
        context=context,
        settings={
            "date_format": spec.date_format,
            "delimiter": spec.delimiter,
            "encoding": spec.encoding,
            "columns": {
                field_name: getattr(spec.columns, field_name)
                for field_name in spec.columns.__dataclass_fields__
            },
        },
    )

    try:
        reader = csv.reader(io.StringIO(text, newline=""), delimiter=spec.delimiter, strict=True)
        raw_headers = next(reader)
    except StopIteration as exc:
        raise ManualImportInputError("EMPTY_FILE", "CSV has no header row") from exc
    except csv.Error as exc:
        raise ManualImportInputError("INVALID_CSV", f"CSV header is malformed: {exc}") from exc

    headers = [header.strip() for header in raw_headers]
    _validate_headers(headers, spec.columns)
    records: list[ManualImportRecord] = []
    issues: list[ManualImportIssue] = []
    seen_identities: set[str] = set()
    seen_source_ids: set[str] = set()
    total_rows = 0

    try:
        for row_number, values in enumerate(reader, start=2):
            total_rows += 1
            if total_rows > MAX_IMPORT_ROWS:
                raise ManualImportInputError(
                    "ROW_LIMIT_EXCEEDED",
                    f"Manual imports are limited to {MAX_IMPORT_ROWS} data rows",
                )
            if len(values) != len(headers):
                issues.append(
                    ManualImportIssue(
                        row_number,
                        "COLUMN_COUNT_MISMATCH",
                        "Row does not contain the same number of fields as the header",
                    )
                )
                continue
            if any(len(value) > MAX_FIELD_CHARS for value in values):
                issues.append(
                    ManualImportIssue(
                        row_number,
                        "FIELD_TOO_LONG",
                        f"A field exceeds the {MAX_FIELD_CHARS}-character limit",
                    )
                )
                continue
            row = dict(zip(headers, values, strict=True))
            result = _normalise_csv_row(
                row,
                row_number=row_number,
                batch_id=batch_id,
                context=context,
                spec=spec,
            )
            if isinstance(result, ManualImportIssue):
                issues.append(result)
                continue
            identity, source_id, transaction = result
            if identity in seen_identities or source_id in seen_source_ids:
                issues.append(
                    ManualImportIssue(
                        row_number,
                        "DUPLICATE_ROW",
                        "This row duplicates an earlier row in the same file",
                        "WARNING",
                    )
                )
                continue
            seen_identities.add(identity)
            seen_source_ids.add(source_id)
            records.append(
                ManualImportRecord(
                    row_number=row_number,
                    row_provenance=f"{batch_id}:row:{row_number}",
                    transaction=transaction,
                )
            )
    except csv.Error as exc:
        raise ManualImportInputError("INVALID_CSV", f"CSV is malformed: {exc}") from exc

    return ManualImportPreview(
        batch_id=batch_id,
        source_kind="CSV",
        account_id=context.account_id,
        currency=context.currency,
        total_rows=total_rows,
        records=tuple(records),
        issues=tuple(issues),
    )


def preview_ofx_import(
    payload: bytes,
    *,
    context: ManualImportContext,
) -> ManualImportPreview:
    """Parse booked OFX 1.x statement records without invoking an XML parser."""
    raw = _require_file_bytes(payload)
    upper_raw = raw.upper()
    if b"<!DOCTYPE" in upper_raw or b"<!ENTITY" in upper_raw:
        raise ManualImportInputError(
            "UNSAFE_OFX", "OFX document type and entity declarations are not allowed"
        )
    ofx_offset = upper_raw.find(b"<OFX>")
    if ofx_offset < 0:
        raise ManualImportInputError("INVALID_OFX", "OFX root element is missing")
    try:
        header_text = raw[:ofx_offset].decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise ManualImportInputError("INVALID_OFX_HEADER", "OFX header must be ASCII") from exc
    headers = _parse_ofx_headers(header_text)
    codec = _ofx_codec(headers)
    try:
        text = raw.decode(codec, errors="strict")
    except UnicodeDecodeError as exc:
        raise ManualImportInputError(
            "INVALID_ENCODING", "OFX content does not match its declared encoding"
        ) from exc
    _reject_unsafe_text(text)

    statement_currency = _ofx_value(text, "CURDEF")
    if statement_currency is None:
        raise ManualImportInputError("MISSING_CURRENCY", "OFX statement has no CURDEF")
    try:
        statement_currency = normalise_currency(statement_currency)
    except ValueError as exc:
        raise ManualImportInputError("INVALID_CURRENCY", "OFX CURDEF is invalid") from exc
    if statement_currency != context.currency:
        raise ManualImportInputError(
            "CURRENCY_MISMATCH",
            f"OFX currency {statement_currency} does not match {context.currency}",
        )

    blocks = _OFX_BLOCK.findall(text)
    if not blocks:
        raise ManualImportInputError("NO_TRANSACTIONS", "OFX has no booked transactions")
    if len(blocks) > MAX_IMPORT_ROWS:
        raise ManualImportInputError(
            "ROW_LIMIT_EXCEEDED",
            f"Manual imports are limited to {MAX_IMPORT_ROWS} data rows",
        )

    batch_id = _batch_id(
        raw,
        source_kind="OFX",
        context=context,
        settings={"encoding": codec},
    )
    records: list[ManualImportRecord] = []
    issues: list[ManualImportIssue] = []
    seen_identities: set[str] = set()
    seen_source_ids: set[str] = set()

    for index, block in enumerate(blocks, start=1):
        result = _normalise_ofx_block(
            block,
            row_number=index,
            batch_id=batch_id,
            context=context,
        )
        if isinstance(result, ManualImportIssue):
            issues.append(result)
            continue
        identity, source_id, transaction = result
        if identity in seen_identities or source_id in seen_source_ids:
            issues.append(
                ManualImportIssue(
                    index,
                    "DUPLICATE_ROW",
                    "This OFX record duplicates an earlier record in the same file",
                    "WARNING",
                )
            )
            continue
        seen_identities.add(identity)
        seen_source_ids.add(source_id)
        records.append(
            ManualImportRecord(
                row_number=index,
                row_provenance=f"{batch_id}:stmttrn:{index}",
                transaction=transaction,
            )
        )

    return ManualImportPreview(
        batch_id=batch_id,
        source_kind="OFX",
        account_id=context.account_id,
        currency=context.currency,
        total_rows=len(blocks),
        records=tuple(records),
        issues=tuple(issues),
    )


def preview_history_repair(
    preview: ManualImportPreview,
    *,
    existing_start: date | None,
    existing_end: date | None,
) -> HistoryRepairPreview:
    """Describe date-range gap or overlap without changing either history."""
    if (existing_start is None) != (existing_end is None):
        raise ManualImportInputError(
            "INVALID_EXISTING_RANGE", "Existing history needs both a start and end date"
        )
    if existing_start is not None and existing_end is not None and existing_start > existing_end:
        raise ManualImportInputError(
            "INVALID_EXISTING_RANGE", "Existing history start is after its end"
        )
    imported_dates = [record.transaction.booking_date for record in preview.records]
    if not imported_dates:
        return HistoryRepairPreview(
            relationship="NO_IMPORTABLE_ROWS",
            imported_start=None,
            imported_end=None,
            existing_start=existing_start,
            existing_end=existing_end,
        )

    imported_start = min(imported_dates)
    imported_end = max(imported_dates)
    common = {
        "imported_start": imported_start,
        "imported_end": imported_end,
        "existing_start": existing_start,
        "existing_end": existing_end,
        "importable_rows": len(preview.records),
    }
    if existing_start is None or existing_end is None:
        return HistoryRepairPreview(relationship="NEW_HISTORY", **common)
    if imported_end < existing_start:
        if imported_end + timedelta(days=1) == existing_start:
            return HistoryRepairPreview(relationship="CONTIGUOUS", **common)
        return HistoryRepairPreview(
            relationship="GAP",
            gap_start=imported_end + timedelta(days=1),
            gap_end=existing_start - timedelta(days=1),
            **common,
        )
    if imported_start > existing_end:
        if existing_end + timedelta(days=1) == imported_start:
            return HistoryRepairPreview(relationship="CONTIGUOUS", **common)
        return HistoryRepairPreview(
            relationship="GAP",
            gap_start=existing_end + timedelta(days=1),
            gap_end=imported_start - timedelta(days=1),
            **common,
        )
    return HistoryRepairPreview(
        relationship="OVERLAP",
        overlap_start=max(imported_start, existing_start),
        overlap_end=min(imported_end, existing_end),
        **common,
    )


def _require_file_bytes(payload: bytes) -> bytes:
    if not isinstance(payload, bytes):
        raise ManualImportInputError(
            "RAW_BYTES_REQUIRED",
            "Manual import accepts uploaded bytes, not a filesystem path or URL",
        )
    if not payload:
        raise ManualImportInputError("EMPTY_FILE", "Manual import file is empty")
    if len(payload) > MAX_IMPORT_BYTES:
        raise ManualImportInputError(
            "FILE_TOO_LARGE",
            f"Manual import files are limited to {MAX_IMPORT_BYTES} bytes",
        )
    return payload


def _reject_unsafe_text(text: str) -> None:
    if "\x00" in text:
        raise ManualImportInputError("NUL_BYTE", "Manual import contains a NUL byte")


def _batch_id(
    payload: bytes,
    *,
    source_kind: str,
    context: ManualImportContext,
    settings: dict,
) -> str:
    configuration = json.dumps(
        {
            "source_kind": source_kind,
            "account_id": context.account_id,
            "currency": context.currency,
            "sign_convention": context.sign_convention,
            "settings": settings,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(configuration + b"\x00" + payload).hexdigest()
    return f"manual-{source_kind.lower()}-{digest}"


def _validate_headers(headers: list[str], mapping: CsvColumnMapping) -> None:
    if not headers or all(not header for header in headers):
        raise ManualImportInputError("EMPTY_HEADER", "CSV header row is empty")
    if len(headers) > MAX_IMPORT_COLUMNS:
        raise ManualImportInputError(
            "COLUMN_LIMIT_EXCEEDED",
            f"Manual imports are limited to {MAX_IMPORT_COLUMNS} columns",
        )
    if any(not header or len(header) > MAX_HEADER_CHARS for header in headers):
        raise ManualImportInputError("INVALID_HEADER", "CSV headers must be non-empty and bounded")
    if len(headers) != len(set(headers)):
        raise ManualImportInputError("DUPLICATE_HEADER", "CSV headers must be unique")
    required = {
        value
        for value in (
            mapping.booking_date,
            mapping.amount,
            mapping.description,
            mapping.currency,
            mapping.transaction_id,
            mapping.value_date,
            mapping.pending_status,
        )
        if value is not None
    }
    missing = sorted(required.difference(headers))
    if missing:
        raise ManualImportInputError(
            "MISSING_MAPPED_HEADER",
            f"CSV is missing mapped header(s): {', '.join(missing)}",
        )


def _normalise_csv_row(
    row: dict[str, str],
    *,
    row_number: int,
    batch_id: str,
    context: ManualImportContext,
    spec: CsvImportSpec,
) -> tuple[str, str, NormalisedSourceTransaction] | ManualImportIssue:
    try:
        booking_date = _parse_csv_date(
            row[spec.columns.booking_date], spec.date_format, field="booking date"
        )
        value_date = (
            _parse_csv_date(row[spec.columns.value_date], spec.date_format, field="value date")
            if spec.columns.value_date and row[spec.columns.value_date].strip()
            else None
        )
        if spec.columns.currency:
            row_currency = normalise_currency(row[spec.columns.currency])
            if row_currency != context.currency:
                raise ValueError(f"row currency {row_currency} does not match {context.currency}")
        amount_minor = _parse_amount_minor(
            row[spec.columns.amount],
            currency=context.currency,
            sign_convention=context.sign_convention,
        )
        description = row[spec.columns.description].strip()
        if not description:
            raise ValueError("description is empty")
        status = _parse_status(
            row[spec.columns.pending_status] if spec.columns.pending_status else "POSTED"
        )
        supplied_source_id = (
            row[spec.columns.transaction_id].strip() if spec.columns.transaction_id else ""
        )
        if len(supplied_source_id) > 300:
            raise ValueError("transaction ID exceeds 300 characters")
        identity = _row_identity(
            booking_date=booking_date,
            value_date=value_date,
            status=status,
            amount_minor=amount_minor,
            currency=context.currency,
            description=description,
            source_id=supplied_source_id or None,
        )
        source_id = supplied_source_id or f"csv-{identity[:48]}"
        transaction = NormalisedSourceTransaction(
            source_kind="CSV",
            source_batch_id=batch_id,
            source_transaction_id=source_id,
            booking_date=booking_date,
            value_date=value_date,
            pending_status=status,
            amount_minor=amount_minor,
            currency=context.currency,
            description=description,
            observed_at=context.observed_at,
        )
    except (KeyError, TypeError, ValueError) as exc:
        return ManualImportIssue(row_number, "INVALID_ROW", str(exc))
    return identity, source_id, transaction


def _normalise_ofx_block(
    block: str,
    *,
    row_number: int,
    batch_id: str,
    context: ManualImportContext,
) -> tuple[str, str, NormalisedSourceTransaction] | ManualImportIssue:
    try:
        fields = {
            name: _ofx_value(block, name)
            for name in ("DTPOSTED", "DTUSER", "TRNAMT", "FITID", "NAME", "MEMO")
        }
        if any(value is not None and len(value) > MAX_FIELD_CHARS for value in fields.values()):
            raise ValueError(f"a field exceeds the {MAX_FIELD_CHARS}-character limit")
        posted_raw = fields["DTPOSTED"]
        amount_raw = fields["TRNAMT"]
        source_id = fields["FITID"]
        if posted_raw is None or amount_raw is None or source_id is None:
            raise ValueError("DTPOSTED, TRNAMT, and FITID are required")
        if len(source_id) > 300:
            raise ValueError("FITID exceeds 300 characters")
        booking_date = _parse_ofx_date(posted_raw, field="DTPOSTED")
        value_date = _parse_ofx_date(fields["DTUSER"], field="DTUSER") if fields["DTUSER"] else None
        amount_minor = _parse_amount_minor(
            amount_raw,
            currency=context.currency,
            sign_convention=context.sign_convention,
        )
        description_parts = [
            part.strip() for part in (fields["NAME"], fields["MEMO"]) if part and part.strip()
        ]
        description = " — ".join(dict.fromkeys(description_parts))
        if not description:
            raise ValueError("NAME or MEMO is required")
        if len(description) > MAX_FIELD_CHARS:
            raise ValueError(f"description exceeds {MAX_FIELD_CHARS} characters")
        identity = _row_identity(
            booking_date=booking_date,
            value_date=value_date,
            status="POSTED",
            amount_minor=amount_minor,
            currency=context.currency,
            description=description,
            source_id=source_id,
        )
        transaction = NormalisedSourceTransaction(
            source_kind="OFX",
            source_batch_id=batch_id,
            source_transaction_id=source_id,
            booking_date=booking_date,
            value_date=value_date,
            pending_status="POSTED",
            amount_minor=amount_minor,
            currency=context.currency,
            description=description,
            observed_at=context.observed_at,
        )
    except (TypeError, ValueError) as exc:
        return ManualImportIssue(row_number, "INVALID_ROW", str(exc))
    return identity, source_id, transaction


def _parse_csv_date(value: str, date_format: str, *, field: str) -> date:
    stripped = value.strip()
    if not stripped:
        raise ValueError(f"{field} is empty")
    try:
        return datetime.strptime(stripped, date_format).date()
    except ValueError as exc:
        raise ValueError(f"{field} does not match the confirmed date format") from exc


def _parse_ofx_date(value: str, *, field: str) -> date:
    stripped = value.strip()
    if not re.match(r"^\d{8}", stripped):
        raise ValueError(f"{field} must start with YYYYMMDD")
    try:
        return datetime.strptime(stripped[:8], "%Y%m%d").date()
    except ValueError as exc:
        raise ValueError(f"{field} is not a real date") from exc


def _parse_amount_minor(
    value: str,
    *,
    currency: str,
    sign_convention: SignConvention,
) -> int:
    stripped = value.strip()
    if stripped.startswith("£"):
        if currency != "GBP":
            raise ValueError("pound sign is only valid for a GBP import")
        stripped = stripped[1:].strip()
    if not _AMOUNT_PATTERN.fullmatch(stripped):
        raise ValueError("amount must be a signed decimal with no more than two decimals")
    amount = Money.from_major(stripped.replace(",", ""), currency).minor_units
    if sign_convention == "DEBIT_POSITIVE":
        amount = -amount
    if amount == 0:
        raise ValueError("amount must not be zero")
    if abs(amount) > MAX_ABS_AMOUNT_MINOR:
        raise ValueError("amount exceeds the manual-import limit")
    return amount


def _parse_status(value: str) -> Literal["PENDING", "POSTED"]:
    status = value.strip().upper()
    if status in {"BOOKED", "COMPLETED", "POSTED"}:
        return "POSTED"
    if status == "PENDING":
        return "PENDING"
    raise ValueError("status must be pending, booked, completed, or posted")


def _row_identity(
    *,
    booking_date: date,
    value_date: date | None,
    status: str,
    amount_minor: int,
    currency: str,
    description: str,
    source_id: str | None,
) -> str:
    fields = (
        source_id or "",
        booking_date.isoformat(),
        value_date.isoformat() if value_date else "",
        status,
        str(amount_minor),
        currency,
        " ".join(description.split()).casefold(),
    )
    return hashlib.sha256("\x1f".join(fields).encode("utf-8")).hexdigest()


def _parse_ofx_headers(header_text: str) -> dict[str, str]:
    headers: dict[str, str] = {}
    for line in header_text.replace("\r", "\n").split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        if ":" not in stripped:
            raise ManualImportInputError("INVALID_OFX_HEADER", "Malformed OFX header line")
        key, value = (part.strip().upper() for part in stripped.split(":", 1))
        if not key or not value or key in headers:
            raise ManualImportInputError(
                "INVALID_OFX_HEADER", "OFX headers must be non-empty and unique"
            )
        if len(key) > MAX_HEADER_CHARS or len(value) > MAX_HEADER_CHARS:
            raise ManualImportInputError("INVALID_OFX_HEADER", "OFX header is too long")
        headers[key] = value
    required = {"OFXHEADER", "DATA", "VERSION", "ENCODING"}
    if not required.issubset(headers):
        raise ManualImportInputError("INVALID_OFX_HEADER", "Required OFX headers are missing")
    if headers["OFXHEADER"] != "100" or headers["DATA"] != "OFXSGML":
        raise ManualImportInputError(
            "UNSUPPORTED_OFX", "Only OFX 1.x SGML statements are supported"
        )
    if headers["VERSION"] not in {"102", "103"}:
        raise ManualImportInputError(
            "UNSUPPORTED_OFX", "Only OFX versions 1.02 and 1.03 are supported"
        )
    return headers


def _ofx_codec(headers: dict[str, str]) -> str:
    encoding = headers["ENCODING"]
    charset = headers.get("CHARSET", "")
    if charset in {"1252", "CP1252", "WINDOWS-1252"}:
        if encoding not in {"USASCII", "ASCII"}:
            raise ManualImportInputError(
                "UNSUPPORTED_ENCODING", "OFX encoding and charset conflict"
            )
        return "cp1252"
    if charset in {"UTF-8", "UTF8", "65001"} or encoding in {"UTF-8", "UTF8", "UNICODE"}:
        return "utf-8-sig"
    if encoding in {"USASCII", "ASCII"} and charset in {"", "USASCII", "ASCII"}:
        return "ascii"
    raise ManualImportInputError(
        "UNSUPPORTED_ENCODING", "OFX encoding must be ASCII, Windows-1252, or UTF-8"
    )


def _ofx_value(text: str, tag: str) -> str | None:
    match = re.search(rf"<{tag}>\s*([^<\r\n]*)", text, re.IGNORECASE)
    if match is None:
        return None
    return match.group(1).strip()

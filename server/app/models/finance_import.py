"""Request settings and concise responses for manual Finance imports."""

from datetime import date
from typing import Literal

from pydantic import BaseModel, Field, model_validator


class FinanceImportSettings(BaseModel):
    source_kind: Literal["CSV", "OFX"]
    space_id: str = Field(min_length=1, max_length=100)
    account_id: str = Field(min_length=1, max_length=200)
    currency: str = Field(min_length=3, max_length=3)
    confirmed: bool
    sign_convention: Literal["DEBIT_NEGATIVE", "DEBIT_POSITIVE"] | None = None
    csv_date_format: Literal["%d/%m/%Y", "%Y-%m-%d"] | None = None
    csv_delimiter: Literal[",", ";", "\t"] | None = None
    csv_encoding: Literal["utf-8", "utf-8-sig"] | None = None
    csv_booking_date_column: str | None = Field(default=None, max_length=120)
    csv_amount_column: str | None = Field(default=None, max_length=120)
    csv_description_column: str | None = Field(default=None, max_length=120)
    csv_currency_column: str | None = Field(default=None, max_length=120)
    csv_transaction_id_column: str | None = Field(default=None, max_length=120)
    csv_value_date_column: str | None = Field(default=None, max_length=120)
    csv_status_column: str | None = Field(default=None, max_length=120)

    @model_validator(mode="after")
    def validate_source_settings(self) -> "FinanceImportSettings":
        if not self.confirmed:
            raise ValueError("Account, space, currency, and import settings must be confirmed")
        if self.source_kind == "OFX":
            if self.sign_convention not in {None, "DEBIT_NEGATIVE"}:
                raise ValueError("OFX uses its standard debit-negative sign convention")
            return self
        required_csv = (
            self.sign_convention,
            self.csv_date_format,
            self.csv_delimiter,
            self.csv_encoding,
            self.csv_booking_date_column,
            self.csv_amount_column,
            self.csv_description_column,
        )
        if any(value is None for value in required_csv):
            raise ValueError("CSV mapping, date, encoding, delimiter, and sign are required")
        return self


class FinanceImportIssueResponse(BaseModel):
    row_number: int | None
    code: str
    message: str
    severity: Literal["ERROR", "WARNING"]


class FinanceImportSampleRow(BaseModel):
    row_number: int
    booking_date: date
    value_date: date | None
    amount_minor: int
    currency: str
    description: str
    source_transaction_id: str | None


class FinanceImportRepairResponse(BaseModel):
    relationship: Literal["NO_IMPORTABLE_ROWS", "NEW_HISTORY", "GAP", "CONTIGUOUS", "OVERLAP"]
    imported_start: date | None
    imported_end: date | None
    existing_start: date | None
    existing_end: date | None
    gap_start: date | None
    gap_end: date | None
    overlap_start: date | None
    overlap_end: date | None


class FinanceImportPreviewResponse(BaseModel):
    batch_id: str
    source_kind: Literal["CSV", "OFX"]
    space_id: str
    account_id: str
    currency: str
    total_rows: int
    importable_rows: int
    invalid_rows: int
    duplicate_rows: int
    can_confirm: bool
    date_from: date | None
    date_to: date | None
    issue_count: int
    issues_truncated: bool
    issues: list[FinanceImportIssueResponse]
    sample_rows: list[FinanceImportSampleRow]
    repair: FinanceImportRepairResponse

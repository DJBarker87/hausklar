from datetime import date, datetime, timezone
from typing import cast

import pytest

from app.services.finance.manual_import import (
    MAX_FIELD_CHARS,
    MAX_IMPORT_BYTES,
    MAX_IMPORT_ROWS,
    CsvColumnMapping,
    CsvImportSpec,
    ManualImportContext,
    ManualImportInputError,
    SignConvention,
    preview_csv_import,
    preview_history_repair,
    preview_ofx_import,
)


def _context(
    *,
    currency: str = "GBP",
    sign_convention: SignConvention = "DEBIT_NEGATIVE",
    confirmed: bool = True,
) -> ManualImportContext:
    return ManualImportContext(
        account_id="account-current",
        currency=currency,
        sign_convention=sign_convention,
        observed_at=datetime(2026, 8, 1, 9, 30, tzinfo=timezone.utc),
        confirmed=confirmed,
    )


def _natwest_spec() -> CsvImportSpec:
    return CsvImportSpec(
        columns=CsvColumnMapping(
            booking_date="Date",
            amount="Value",
            description="Description",
            currency="Currency",
            transaction_id="Reference",
        ),
        date_format="%d/%m/%Y",
        delimiter=",",
        encoding="utf-8",
    )


def _csv(*rows: str) -> bytes:
    header = "Date,Description,Value,Currency,Reference"
    return ("\n".join((header, *rows)) + "\n").encode()


def _ofx(*transactions: str, currency: str = "GBP") -> bytes:
    body = "".join(transactions)
    return (
        "OFXHEADER:100\n"
        "DATA:OFXSGML\n"
        "VERSION:102\n"
        "SECURITY:NONE\n"
        "ENCODING:USASCII\n"
        "CHARSET:1252\n\n"
        f"<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>{currency}"
        f"<BANKTRANLIST>{body}</BANKTRANLIST></STMTRS></STMTTRNRS>"
        "</BANKMSGSRSV1></OFX>"
    ).encode("cp1252")


def _ofx_transaction(
    *,
    fitid: str,
    posted: str = "20260731",
    amount: str = "-12.34",
    name: str = "TESCO STORES",
    memo: str = "CARD PURCHASE",
) -> str:
    return (
        "<STMTTRN><TRNTYPE>DEBIT"
        f"<DTPOSTED>{posted}<TRNAMT>{amount}<FITID>{fitid}"
        f"<NAME>{name}<MEMO>{memo}</STMTTRN>"
    )


def test_natwest_csv_produces_normalised_preview_with_row_provenance() -> None:
    preview = preview_csv_import(
        _csv("31/07/2026,TESCO STORES,-12.34,GBP,natwest-001"),
        context=_context(),
        spec=_natwest_spec(),
    )

    assert preview.account_id == "account-current"
    assert preview.total_rows == 1
    assert preview.can_commit is True
    record = preview.records[0]
    assert record.row_provenance == f"{preview.batch_id}:row:2"
    assert record.transaction.source_kind == "CSV"
    assert record.transaction.source_transaction_id == "natwest-001"
    assert record.transaction.booking_date == date(2026, 7, 31)
    assert record.transaction.amount_minor == -1234
    assert record.transaction.pending_status == "POSTED"


def test_ofx_booked_records_use_declared_currency_and_fitid() -> None:
    preview = preview_ofx_import(
        _ofx(
            _ofx_transaction(fitid="ofx-001"),
            _ofx_transaction(
                fitid="ofx-002",
                posted="20260801",
                amount="2500.00",
                name="SALARY",
                memo="SALARY",
            ),
        ),
        context=_context(),
    )

    assert preview.total_rows == 2
    assert not preview.issues
    assert [record.transaction.source_transaction_id for record in preview.records] == [
        "ofx-001",
        "ofx-002",
    ]
    assert [record.transaction.amount_minor for record in preview.records] == [-1234, 250000]
    assert all(record.transaction.pending_status == "POSTED" for record in preview.records)


def test_formula_like_csv_content_stays_plain_inert_text() -> None:
    preview = preview_csv_import(
        _csv("31/07/2026,=2+3,-1.00,GBP,formula-1"),
        context=_context(),
        spec=_natwest_spec(),
    )

    assert preview.records[0].transaction.description == "=2+3"


def test_confirmation_and_raw_bytes_are_required() -> None:
    with pytest.raises(ManualImportInputError, match="Confirm") as unconfirmed:
        _context(confirmed=False)
    assert unconfirmed.value.code == "CONFIRMATION_REQUIRED"

    for external_reference in ("/tmp/history.csv", "https://bank.example/history.csv"):
        with pytest.raises(ManualImportInputError) as invalid_input:
            preview_csv_import(  # type: ignore[arg-type]
                external_reference,
                context=_context(),
                spec=_natwest_spec(),
            )
        assert invalid_input.value.code == "RAW_BYTES_REQUIRED"


def test_wrong_currency_date_and_sign_settings_are_not_guessed() -> None:
    preview = preview_csv_import(
        _csv(
            "2026-07-31,Wrong date,-1.00,GBP,bad-date",
            "31/07/2026,Wrong currency,-2.00,EUR,bad-currency",
        ),
        context=_context(),
        spec=_natwest_spec(),
    )
    assert not preview.records
    assert [issue.code for issue in preview.issues] == ["INVALID_ROW", "INVALID_ROW"]

    inverted = preview_csv_import(
        _csv("31/07/2026,Debit shown positive,12.34,GBP,debit-1"),
        context=_context(sign_convention="DEBIT_POSITIVE"),
        spec=_natwest_spec(),
    )
    assert inverted.records[0].transaction.amount_minor == -1234

    with pytest.raises(ManualImportInputError) as bad_sign:
        _context(sign_convention=cast(SignConvention, "UNKNOWN"))
    assert bad_sign.value.code == "INVALID_SIGN_CONVENTION"

    with pytest.raises(ManualImportInputError) as bad_ofx_currency:
        preview_ofx_import(_ofx(_ofx_transaction(fitid="1"), currency="EUR"), context=_context())
    assert bad_ofx_currency.value.code == "CURRENCY_MISMATCH"


def test_duplicate_rows_are_reported_and_retry_is_deterministic() -> None:
    payload = _csv(
        "31/07/2026,TESCO STORES,-12.34,GBP,natwest-001",
        "31/07/2026,TESCO STORES,-12.34,GBP,natwest-001",
    )
    first = preview_csv_import(payload, context=_context(), spec=_natwest_spec())
    retry = preview_csv_import(payload, context=_context(), spec=_natwest_spec())

    assert first == retry
    assert len(first.records) == 1
    assert first.duplicate_rows == 1
    assert first.issues[0].severity == "WARNING"
    assert first.can_commit is True


def test_file_row_and_field_limits_fail_closed() -> None:
    with pytest.raises(ManualImportInputError) as too_large:
        preview_csv_import(
            b"x" * (MAX_IMPORT_BYTES + 1),
            context=_context(),
            spec=_natwest_spec(),
        )
    assert too_large.value.code == "FILE_TOO_LARGE"

    oversized_field = "x" * (MAX_FIELD_CHARS + 1)
    field_preview = preview_csv_import(
        _csv(f"31/07/2026,{oversized_field},-1.00,GBP,long-1"),
        context=_context(),
        spec=_natwest_spec(),
    )
    assert field_preview.issues[0].code == "FIELD_TOO_LONG"

    too_many_rows = _csv(
        *(f"31/07/2026,ROW {index},-1.00,GBP,id-{index}" for index in range(MAX_IMPORT_ROWS + 1))
    )
    with pytest.raises(ManualImportInputError) as row_limit:
        preview_csv_import(too_many_rows, context=_context(), spec=_natwest_spec())
    assert row_limit.value.code == "ROW_LIMIT_EXCEEDED"


def test_history_repair_preview_identifies_gap_and_overlap_without_mutation() -> None:
    preview = preview_csv_import(
        _csv(
            "10/07/2026,OLDER ONE,-1.00,GBP,old-1",
            "12/07/2026,OLDER TWO,-2.00,GBP,old-2",
        ),
        context=_context(),
        spec=_natwest_spec(),
    )
    original = preview.records

    gap = preview_history_repair(
        preview,
        existing_start=date(2026, 7, 15),
        existing_end=date(2026, 7, 31),
    )
    overlap = preview_history_repair(
        preview,
        existing_start=date(2026, 7, 11),
        existing_end=date(2026, 7, 31),
    )

    assert (gap.relationship, gap.gap_start, gap.gap_end) == (
        "GAP",
        date(2026, 7, 13),
        date(2026, 7, 14),
    )
    assert (overlap.relationship, overlap.overlap_start, overlap.overlap_end) == (
        "OVERLAP",
        date(2026, 7, 11),
        date(2026, 7, 12),
    )
    assert preview.records is original

"""Authenticated, in-memory workflow around strict manual statement parsing."""

from dataclasses import dataclass
from datetime import date, datetime, timezone

from app.models.finance import FinanceImportResult
from app.models.finance_import import FinanceImportSettings
from app.services.finance.ledger import import_source_transactions, list_finance_accounts
from app.services.finance.manual_import import (
    CsvColumnMapping,
    CsvImportSpec,
    HistoryRepairPreview,
    ManualImportContext,
    ManualImportPreview,
    preview_csv_import,
    preview_history_repair,
    preview_ofx_import,
)


class ManualImportWorkflowError(ValueError):
    """A reviewed manual import cannot safely proceed."""


class ManualImportAccountNotFoundError(ManualImportWorkflowError):
    """The selected account is not visible in the selected space."""


class ManualImportChangedError(ManualImportWorkflowError):
    """The confirm request does not match the previewed file and settings."""


class ManualImportRowsInvalidError(ManualImportWorkflowError):
    """At least one file row still needs correction before import."""


@dataclass(frozen=True, slots=True)
class ManualImportPreparedPreview:
    preview: ManualImportPreview
    repair: HistoryRepairPreview


async def prepare_manual_import(
    db,
    *,
    user: dict,
    settings: FinanceImportSettings,
    payload: bytes,
) -> ManualImportPreparedPreview:
    """Authorize the destination before parsing and return a read-only preview."""
    accounts = await list_finance_accounts(
        db,
        user=user,
        space_id=settings.space_id,
    )
    account = next((item for item in accounts if item.id == settings.account_id), None)
    if account is None:
        raise ManualImportAccountNotFoundError("Finance account not found")

    context = ManualImportContext(
        account_id=account.id,
        currency=settings.currency,
        sign_convention=(
            "DEBIT_NEGATIVE" if settings.source_kind == "OFX" else settings.sign_convention
        ),
        observed_at=datetime.now(timezone.utc),
        confirmed=settings.confirmed,
    )
    if context.currency != account.currency:
        raise ManualImportWorkflowError("Import currency does not match the account")

    if settings.source_kind == "OFX":
        preview = preview_ofx_import(payload, context=context)
    else:
        preview = preview_csv_import(
            payload,
            context=context,
            spec=CsvImportSpec(
                columns=CsvColumnMapping(
                    booking_date=settings.csv_booking_date_column,
                    amount=settings.csv_amount_column,
                    description=settings.csv_description_column,
                    currency=settings.csv_currency_column,
                    transaction_id=settings.csv_transaction_id_column,
                    value_date=settings.csv_value_date_column,
                    pending_status=settings.csv_status_column,
                ),
                date_format=settings.csv_date_format,
                delimiter=settings.csv_delimiter,
                encoding=settings.csv_encoding,
            ),
        )

    existing = await (
        await db.execute(
            """
            SELECT MIN(canonical_date) AS date_from, MAX(canonical_date) AS date_to
            FROM finance_transactions
            WHERE account_id = ? AND space_id = ? AND family_id = ?
              AND state = 'POSTED' AND deleted_at IS NULL
            """,
            (account.id, settings.space_id, user["family_id"]),
        )
    ).fetchone()
    repair = preview_history_repair(
        preview,
        existing_start=(
            date.fromisoformat(existing["date_from"])
            if existing and existing["date_from"]
            else None
        ),
        existing_end=(
            date.fromisoformat(existing["date_to"]) if existing and existing["date_to"] else None
        ),
    )
    return ManualImportPreparedPreview(preview=preview, repair=repair)


async def confirm_manual_import(
    db,
    *,
    user: dict,
    settings: FinanceImportSettings,
    payload: bytes,
    expected_batch_id: str,
) -> FinanceImportResult:
    """Reparse a reviewed upload, verify it is unchanged, then import it once."""
    prepared = await prepare_manual_import(
        db,
        user=user,
        settings=settings,
        payload=payload,
    )
    preview = prepared.preview
    if preview.batch_id != expected_batch_id:
        raise ManualImportChangedError("The file or import settings changed after preview")
    if preview.invalid_rows or not preview.records:
        raise ManualImportRowsInvalidError(
            "The preview must contain importable rows and no errors before importing"
        )
    return await import_source_transactions(
        db,
        user=user,
        space_id=settings.space_id,
        account_id=settings.account_id,
        observations=[record.transaction for record in preview.records],
    )

from datetime import date, datetime, timezone

import aiosqlite
import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.ledger import create_finance_account, import_source_transactions



def _enabled(user: dict) -> dict:
    return user


async def _spaces(client, headers: dict) -> dict[str, str]:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200
    return {item["kind"]: item["id"] for item in response.json()}


def _settings(*, space_id: str, account_id: str) -> dict[str, str]:
    return {
        "source_kind": "CSV",
        "space_id": space_id,
        "account_id": account_id,
        "currency": "GBP",
        "confirmed": "true",
        "sign_convention": "DEBIT_NEGATIVE",
        "csv_date_format": "%d/%m/%Y",
        "csv_delimiter": ",",
        "csv_encoding": "utf-8",
        "csv_booking_date_column": "Date",
        "csv_amount_column": "Value",
        "csv_description_column": "Description",
        "csv_currency_column": "Currency",
        "csv_transaction_id_column": "Reference",
    }


def _statement(second_amount: str = "-25.00") -> bytes:
    return (
        "Date,Description,Value,Currency,Reference\n"
        "31/07/2026,TESCO STORES,-12.34,GBP,natwest-001\n"
        f"01/08/2026,COUNCIL TAX,{second_amount},GBP,natwest-002\n"
    ).encode()


@pytest.mark.asyncio
async def test_private_statement_preview_confirm_retry_and_changed_file_rejection(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_space = (await _spaces(client, adult_a_headers))["personal"]
    await _spaces(client, adult_b_headers)

    async with standalone_db(initialized_db) as db:
        account = await create_finance_account(
            db,
            user=_enabled(adult_a_user),
            space_id=adult_a_space,
            body=FinanceAccountCreate(
                label="Alex current",
                institution="Fixture Bank",
                account_type="CURRENT",
                currency="GBP",
            ),
        )
        await import_source_transactions(
            db,
            user=_enabled(adult_a_user),
            space_id=adult_a_space,
            account_id=account.id,
            observations=[
                NormalisedSourceTransaction(
                    source_kind="PROVIDER",
                    source_batch_id="provider-existing",
                    source_transaction_id="provider-aug-3",
                    booking_date=date(2026, 8, 3),
                    pending_status="POSTED",
                    amount_minor=-500,
                    currency="GBP",
                    description="Existing provider history",
                    observed_at=datetime(2026, 8, 3, 12, tzinfo=timezone.utc),
                )
            ],
        )

    settings = _settings(space_id=adult_a_space, account_id=account.id)
    file_part = {"file": ("history.csv", _statement(), "text/csv")}

    private_attempt = await client.post(
        "/api/finance/imports/preview",
        data=settings,
        files=file_part,
        headers=adult_b_headers,
    )
    assert private_attempt.status_code == 404
    assert account.id not in private_attempt.text

    preview = await client.post(
        "/api/finance/imports/preview",
        data=settings,
        files={"file": ("history.csv", _statement(), "text/csv")},
        headers=adult_a_headers,
    )
    assert preview.status_code == 200, preview.text
    preview_body = preview.json()
    assert preview_body["importable_rows"] == 2
    assert preview_body["invalid_rows"] == 0
    assert preview_body["date_from"] == "2026-07-31"
    assert preview_body["date_to"] == "2026-08-01"
    assert preview_body["repair"] == {
        "relationship": "GAP",
        "imported_start": "2026-07-31",
        "imported_end": "2026-08-01",
        "existing_start": "2026-08-03",
        "existing_end": "2026-08-03",
        "gap_start": "2026-08-02",
        "gap_end": "2026-08-02",
        "overlap_start": None,
        "overlap_end": None,
    }
    assert "file" not in preview_body

    confirm_settings = {**settings, "preview_batch_id": preview_body["batch_id"]}
    confirmed = await client.post(
        "/api/finance/imports/confirm",
        data=confirm_settings,
        files={"file": ("history.csv", _statement(), "text/csv")},
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()["source_created"] == 2
    assert confirmed.json()["canonical_created"] == 2

    retry = await client.post(
        "/api/finance/imports/confirm",
        data=confirm_settings,
        files={"file": ("history.csv", _statement(), "text/csv")},
        headers=adult_a_headers,
    )
    assert retry.status_code == 200, retry.text
    assert retry.json()["source_created"] == 0
    assert retry.json()["canonical_created"] == 0
    assert retry.json()["duplicates"] == 2

    changed = await client.post(
        "/api/finance/imports/confirm",
        data=confirm_settings,
        files={"file": ("history.csv", _statement("-26.00"), "text/csv")},
        headers=adult_a_headers,
    )
    assert changed.status_code == 409
    assert "changed" in changed.json()["detail"].lower()

    async with aiosqlite.connect(initialized_db) as db:
        counts = await (
            await db.execute(
                """
                SELECT
                    (SELECT COUNT(*) FROM finance_source_transactions WHERE account_id = ?),
                    (SELECT COUNT(*) FROM finance_transactions WHERE account_id = ?)
                """,
                (account.id, account.id),
            )
        ).fetchone()
    assert counts == (3, 3)

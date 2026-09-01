from urllib.parse import urlencode

import pytest
from cryptography.fernet import Fernet
from fastapi import HTTPException

from app.config import settings
from app.database import standalone_db
from app.main import app
from app.routers.finance_connections import enable_banking_provider_dependency
from app.services.finance.providers.base import AuthorisationStart
from app.services.finance.resource_limits import (
    finance_process_slot,
    reserve_finance_resource,
    reset_finance_process_slots,
)


async def _personal_space(client, headers: dict) -> str:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200
    return next(item["id"] for item in response.json() if item["kind"] == "personal")


async def test_finance_resource_limits_are_durable_per_user_and_family(
    initialized_db,
    adult_a_user,
    adult_b_user,
    monkeypatch,
):
    monkeypatch.setattr(settings, "finance_provider_rate_limit_requests", 1)
    monkeypatch.setattr(settings, "finance_family_rate_limit_requests", 2)

    async with standalone_db(initialized_db) as db:
        await reserve_finance_resource(db, user=adult_a_user, kind="provider")
        with pytest.raises(HTTPException) as repeated:
            await reserve_finance_resource(db, user=adult_a_user, kind="provider")
        assert repeated.value.status_code == 429
        assert repeated.value.headers["Retry-After"]

        await reserve_finance_resource(db, user=adult_b_user, kind="provider")
        with pytest.raises(HTTPException) as family_exhausted:
            await reserve_finance_resource(db, user=adult_b_user, kind="capture")
        assert family_exhausted.value.status_code == 429


def test_finance_process_slots_bound_bursts_and_release_after_work(
    adult_a_user,
    adult_b_user,
    monkeypatch,
):
    reset_finance_process_slots()
    monkeypatch.setattr(settings, "finance_family_concurrent_requests", 2)
    monkeypatch.setattr(settings, "finance_adult_concurrent_requests_per_kind", 1)

    with finance_process_slot(user=adult_a_user, kind="upload"):
        with pytest.raises(HTTPException) as repeated:
            with finance_process_slot(user=adult_a_user, kind="upload"):
                pass
        assert repeated.value.status_code == 429
        assert repeated.value.headers["Retry-After"] == "1"
        with finance_process_slot(user=adult_b_user, kind="upload"):
            with pytest.raises(HTTPException) as family_full:
                with finance_process_slot(user=adult_a_user, kind="ai"):
                    pass
            assert family_full.value.status_code == 429

    with finance_process_slot(user=adult_a_user, kind="upload"):
        pass
    reset_finance_process_slots()


async def test_finance_coach_and_capture_routes_return_useful_429s(
    client,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _personal_space(client, adult_a_headers)
    monkeypatch.setattr(settings, "finance_ai_rate_limit_requests", 1)
    monkeypatch.setattr(settings, "finance_capture_rate_limit_requests", 1)

    coach_body = {
        "question": "Give me an overview",
        "scope": "mine",
        "space_id": space_id,
    }
    first_coach = await client.post(
        "/api/finance/coach/ask", json=coach_body, headers=adult_a_headers
    )
    second_coach = await client.post(
        "/api/finance/coach/ask", json=coach_body, headers=adult_a_headers
    )
    assert first_coach.status_code == 503
    assert second_coach.status_code == 429
    assert second_coach.json()["detail"].startswith("Too many Finance coach requests")
    assert second_coach.headers["Retry-After"]

    capture_body = {"space_id": space_id, "text": "We want a £500 holiday."}
    first_capture = await client.post(
        "/api/finance/capture/interpret", json=capture_body, headers=adult_a_headers
    )
    second_capture = await client.post(
        "/api/finance/capture/interpret", json=capture_body, headers=adult_a_headers
    )
    assert first_capture.status_code == 200, first_capture.text
    assert second_capture.status_code == 429
    assert second_capture.json()["detail"].startswith("Too many Finance capture requests")


async def test_bank_start_and_sync_routes_share_the_provider_budget(
    client,
    adult_a_headers,
    monkeypatch,
    tmp_path,
):
    class StartOnlyProvider:
        calls = 0

        async def start_authorisation(self, request):
            self.calls += 1
            return AuthorisationStart(
                redirect_url="https://auth.enablebanking.com/start?"
                + urlencode({"state": request.state}),
                authorisation_id="authorisation-1",
            )

    provider = StartOnlyProvider()
    app.dependency_overrides[enable_banking_provider_dependency] = lambda: provider
    key_path = tmp_path / "enable-banking.pem"
    key_path.write_text("provider dependency is overridden in this test")
    monkeypatch.setattr(
        settings,
        "enable_banking_application_id",
        "0ecb8be6-8c02-4f2a-b4d8-ae66866ea873",
    )
    monkeypatch.setattr(settings, "enable_banking_private_key_path", str(key_path))
    monkeypatch.setattr(
        settings,
        "enable_banking_callback_url",
        "https://hausklar.example/api/finance/connections/enable-banking/callback",
    )
    monkeypatch.setattr(
        settings, "finance_provider_encryption_key", Fernet.generate_key().decode()
    )
    monkeypatch.setattr(settings, "finance_provider_rate_limit_requests", 1)
    space_id = await _personal_space(client, adult_a_headers)
    body = {
        "space_id": space_id,
        "institution_name": "NatWest",
        "institution_country": "GB",
    }

    try:
        first = await client.post(
            "/api/finance/connections/enable-banking/start",
            json=body,
            headers=adult_a_headers,
        )
        repeated_start = await client.post(
            "/api/finance/connections/enable-banking/start",
            json=body,
            headers=adult_a_headers,
        )
        sync_after_budget = await client.post(
            "/api/finance/connections/missing/sync",
            headers=adult_a_headers,
        )

        assert first.status_code == 200, first.text
        assert repeated_start.status_code == 429
        assert sync_after_budget.status_code == 429
        assert provider.calls == 1
    finally:
        app.dependency_overrides.pop(enable_banking_provider_dependency, None)


async def test_finance_import_and_evidence_uploads_share_a_bounded_upload_budget(
    client,
    adult_a_headers,
    monkeypatch,
    tmp_path,
):
    space_id = await _personal_space(client, adult_a_headers)
    monkeypatch.setattr(settings, "finance_upload_rate_limit_requests", 1)
    monkeypatch.setattr(settings, "document_storage_path", str(tmp_path / "documents"))

    first = await client.post(
        "/api/finance/purchases/evidence/upload",
        params={"space_id": space_id},
        data={"title": "Receipt"},
        files={"file": ("receipt.txt", b"Receipt total GBP 12", "text/plain")},
        headers=adult_a_headers,
    )
    second = await client.post(
        "/api/finance/imports/preview",
        data={
            "source_kind": "CSV",
            "space_id": space_id,
            "account_id": "missing-account",
            "currency": "GBP",
            "confirmed": "true",
            "sign_convention": "DEBIT_NEGATIVE",
            "csv_date_format": "%d/%m/%Y",
            "csv_delimiter": ",",
            "csv_encoding": "utf-8",
            "csv_booking_date_column": "Date",
            "csv_amount_column": "Amount",
            "csv_description_column": "Description",
        },
        files={
            "file": (
                "statement.csv",
                b"Date,Amount,Description\n01/08/2026,-12.00,Shop\n",
                "text/csv",
            )
        },
        headers=adult_a_headers,
    )
    confirm = await client.post(
        "/api/finance/imports/confirm",
        data={
            "source_kind": "CSV",
            "space_id": space_id,
            "account_id": "missing-account",
            "currency": "GBP",
            "confirmed": "true",
            "sign_convention": "DEBIT_NEGATIVE",
            "csv_date_format": "%d/%m/%Y",
            "csv_delimiter": ",",
            "csv_encoding": "utf-8",
            "csv_booking_date_column": "Date",
            "csv_amount_column": "Amount",
            "csv_description_column": "Description",
            "preview_batch_id": "preview-1",
        },
        files={
            "file": (
                "statement.csv",
                b"Date,Amount,Description\n01/08/2026,-12.00,Shop\n",
                "text/csv",
            )
        },
        headers=adult_a_headers,
    )

    assert first.status_code == 201, first.text
    assert second.status_code == 429
    assert confirm.status_code == 429
    assert second.json()["detail"].startswith(
        "Too many Finance imports or evidence uploads"
    )


async def test_finance_evidence_uploads_cannot_exceed_family_document_quota(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
    tmp_path,
):
    space_id = await _personal_space(client, adult_a_headers)
    storage_root = tmp_path / "documents"
    monkeypatch.setattr(settings, "document_storage_path", str(storage_root))
    monkeypatch.setattr(settings, "document_family_quota_bytes", 30)
    upload = {
        "file": ("receipt.txt", b"Receipt total GBP 12", "text/plain"),
    }

    first = await client.post(
        "/api/finance/purchases/evidence/upload",
        params={"space_id": space_id},
        data={"title": "First receipt"},
        files=upload,
        headers=adult_a_headers,
    )
    second = await client.post(
        "/api/finance/purchases/evidence/upload",
        params={"space_id": space_id},
        data={"title": "Second receipt"},
        files=upload,
        headers=adult_a_headers,
    )

    assert first.status_code == 201, first.text
    assert second.status_code == 413
    assert "quota" in second.json()["detail"].lower()
    async with standalone_db(initialized_db) as db:
        stored = await (
            await db.execute(
                """
                SELECT COUNT(*), COALESCE(SUM(byte_size), 0)
                FROM finance_purchase_source_files
                WHERE storage_status = 'STORED' AND deleted_at IS NULL
                """
            )
        ).fetchone()
    assert tuple(stored) == (1, len(upload["file"][1]))
    assert len([path for path in storage_root.rglob("*") if path.is_file()]) == 1


async def test_finance_export_is_rate_limited_before_archive_work(
    client,
    adult_a_headers,
    monkeypatch,
):
    await _personal_space(client, adult_a_headers)
    monkeypatch.setattr(settings, "finance_export_rate_limit_requests", 1)

    first = await client.get("/api/finance/export", headers=adult_a_headers)
    second = await client.get("/api/finance/export", headers=adult_a_headers)

    assert first.status_code == 200, first.text
    assert first.headers["content-type"] == "application/zip"
    assert second.status_code == 429
    assert second.json()["detail"].startswith("Too many Finance export requests")

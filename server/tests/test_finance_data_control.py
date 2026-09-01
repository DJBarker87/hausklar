import io
import json
import zipfile

import pytest

from app.config import settings
from app.database import standalone_db
from app.services.finance.foundation import accessible_finance_spaces
from app.services.record_history import save_history


async def _spaces(db_path: str, user: dict) -> dict[str, str]:
    async with standalone_db(db_path) as db:
        return {
            space.kind: space.id
            for space in await accessible_finance_spaces(db, user=user)
        }


async def _insert_account_and_transaction(
    db,
    *,
    user: dict,
    space_id: str,
    prefix: str,
    description: str,
) -> None:
    now = "2026-08-03T08:00:00+00:00"
    await db.execute(
        """
        INSERT INTO finance_accounts
            (id, space_id, label, account_type, currency, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, 'CURRENT', 'GBP', ?, ?, ?, ?)
        """,
        (f"{prefix}-account", space_id, description, user["family_id"], now, now, user["id"]),
    )
    await db.execute(
        """
        INSERT INTO finance_transactions
            (id, space_id, account_id, canonical_date, amount_minor, currency,
             state, transaction_kind, source_kind, description,
             cleaned_description, data_through_at, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, '2026-08-01', -1000, 'GBP', 'POSTED', 'CASEY',
                'MANUAL', ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            f"{prefix}-transaction",
            space_id,
            f"{prefix}-account",
            description,
            description.upper(),
            now,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )


async def _insert_member_report(
    db,
    *,
    user: dict,
    space_id: str,
    prefix: str,
    explanation: str,
) -> None:
    now = "2026-08-03T08:00:00+00:00"
    await db.execute(
        """
        INSERT INTO finance_coaching_reports
            (id, space_id, member_user_id, report_kind, local_date,
             household_timezone, locale, input_digest, trajectory_status,
             expected_durable_saving_minor, summary_json, explanation,
             family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, 'DAILY', '2026-08-03', 'Europe/London', 'en', ?,
                'ON_PLAN', 0, '{}', ?, ?, ?, ?, ?)
        """,
        (
            f"{prefix}-report",
            space_id,
            user["id"],
            f"{prefix}-digest",
            explanation,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )


@pytest.mark.asyncio
async def test_finance_history_is_pre_filtered_for_dom_kat_and_household(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_spaces = await _spaces(initialized_db, adult_a_user)
    adult_b_spaces = await _spaces(initialized_db, adult_b_user)
    async with standalone_db(initialized_db) as db:
        history_indexes = {
            row["name"]
            for row in await (
                await db.execute("PRAGMA index_list(record_history)")
            ).fetchall()
        }
        assert "idx_record_history_family_changed" in history_indexes
        await _insert_account_and_transaction(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["personal"],
            prefix="dom-private",
            description="Alex private AI subscription",
        )
        await _insert_account_and_transaction(
            db,
            user=adult_b_user,
            space_id=adult_b_spaces["personal"],
            prefix="kat-private",
            description="Morgan private present",
        )
        await _insert_account_and_transaction(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["household"],
            prefix="shared",
            description="Shared nursery bill",
        )
        await _insert_member_report(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["household"],
            prefix="dom-household",
            explanation="Alex's private household coaching note",
        )
        await _insert_member_report(
            db,
            user=adult_b_user,
            space_id=adult_a_spaces["household"],
            prefix="kat-household",
            explanation="Morgan's private household coaching note",
        )
        await db.execute(
            """
            INSERT INTO finance_connections
                (id, space_id, provider, status, encrypted_provider_secret_ref,
                 sync_lease_token, family_id, created_at, updated_at, created_by)
            VALUES ('dom-secret-connection', ?, 'enable-banking', 'CONNECTED',
                    'DO-NOT-SHOW-PROVIDER-SECRET', 'DO-NOT-SHOW-LEASE', ?,
                    '2026-08-03T08:00:00+00:00', '2026-08-03T08:00:00+00:00', ?)
            """,
            (adult_a_spaces["personal"], adult_a_user["family_id"], adult_a_user["id"]),
        )
        for record_id, actor in (
            ("dom-private-transaction", adult_a_user),
            ("kat-private-transaction", adult_b_user),
            ("shared-transaction", adult_a_user),
        ):
            await save_history(
                db,
                "finance_transactions",
                record_id,
                actor["id"],
                family_id=actor["family_id"],
            )
        await save_history(
            db,
            "finance_connections",
            "dom-secret-connection",
            adult_a_user["id"],
            family_id=adult_a_user["family_id"],
        )
        for record_id, actor in (
            ("dom-household-report", adult_a_user),
            ("kat-household-report", adult_b_user),
        ):
            await save_history(
                db,
                "finance_coaching_reports",
                record_id,
                actor["id"],
                family_id=actor["family_id"],
            )
        await db.commit()

    dom = await client.get("/api/finance/history?scope=mine", headers=adult_a_headers)
    kat = await client.get("/api/finance/history?scope=mine", headers=adult_b_headers)
    household = await client.get(
        "/api/finance/history?scope=household", headers=adult_a_headers
    )
    first_page = await client.get(
        "/api/finance/history?scope=mine&offset=0&limit=1", headers=adult_a_headers
    )
    assert dom.status_code == kat.status_code == household.status_code == 200
    adult_a_ids = {item["record_id"] for item in dom.json()["items"]}
    adult_b_ids = {item["record_id"] for item in kat.json()["items"]}
    household_ids = {item["record_id"] for item in household.json()["items"]}
    assert adult_a_ids == {
        "dom-private-transaction",
        "shared-transaction",
        "dom-secret-connection",
        "dom-household-report",
    }
    assert adult_b_ids == {
        "kat-private-transaction",
        "shared-transaction",
        "kat-household-report",
    }
    assert household_ids == {"shared-transaction", "dom-household-report"}
    assert first_page.json()["limit"] == 1
    assert first_page.json()["has_more"] is True
    assert len(first_page.json()["items"]) == 1
    assert "space_id" not in dom.json()["items"][0]["previous_values"]
    assert "account_id" not in dom.json()["items"][0]["previous_values"]
    assert "DO-NOT-SHOW" not in dom.text


@pytest.mark.asyncio
async def test_finance_export_includes_own_and_household_but_not_partner_private_data(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    tmp_path,
    monkeypatch,
):
    storage_root = tmp_path / "finance-evidence"
    monkeypatch.setattr(settings, "document_storage_path", str(storage_root))
    adult_a_spaces = await _spaces(initialized_db, adult_a_user)
    adult_b_spaces = await _spaces(initialized_db, adult_b_user)
    now = "2026-08-03T08:00:00+00:00"
    evidence_specs = (
        ("dom-source", adult_a_spaces["personal"], "DOM-PRIVATE-EVIDENCE", b"dom receipt"),
        ("kat-source", adult_b_spaces["personal"], "KAT-PRIVATE-PARENT", b"kat receipt"),
        ("shared-source", adult_a_spaces["household"], "SHARED-LINE-ONLY", b"shared receipt"),
    )
    async with standalone_db(initialized_db) as db:
        await _insert_account_and_transaction(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["personal"],
            prefix="dom-export",
            description="DOM-PRIVATE-TRANSACTION",
        )
        await _insert_account_and_transaction(
            db,
            user=adult_b_user,
            space_id=adult_b_spaces["personal"],
            prefix="kat-export",
            description="KAT-PRIVATE-TRANSACTION",
        )
        await _insert_account_and_transaction(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["household"],
            prefix="shared-export",
            description="SHARED-TRANSACTION",
        )
        await _insert_member_report(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["household"],
            prefix="dom-export-household",
            explanation="DOM-HOUSEHOLD-REPORT",
        )
        await _insert_member_report(
            db,
            user=adult_b_user,
            space_id=adult_a_spaces["household"],
            prefix="kat-export-household",
            explanation="KAT-HOUSEHOLD-REPORT",
        )
        for record_id, actor in (
            ("dom-export-transaction", adult_a_user),
            ("kat-export-transaction", adult_b_user),
            ("shared-export-transaction", adult_a_user),
            ("dom-export-household-report", adult_a_user),
            ("kat-export-household-report", adult_b_user),
        ):
            await save_history(
                db,
                "finance_transactions",
                record_id,
                actor["id"],
                family_id=actor["family_id"],
            )
        await db.execute(
            """
            INSERT INTO finance_connections
                (id, space_id, provider, status, encrypted_provider_secret_ref,
                 callback_state_hash, sync_lease_token, family_id, created_at,
                 updated_at, created_by)
            VALUES ('dom-connection', ?, 'enable-banking', 'CONNECTED',
                    'SECRET-PROVIDER-SESSION', 'SECRET-CALLBACK-HASH',
                    'SECRET-SYNC-LEASE', ?, ?, ?, ?)
            """,
            (adult_a_spaces["personal"], adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        for source_id, space_id, marker, payload in evidence_specs:
            storage_key = f"{adult_a_user['family_id']}/{source_id}/receipt.txt"
            destination = storage_root / storage_key
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(payload)
            await db.execute(
                """
                INSERT INTO finance_purchase_sources
                    (id, space_id, external_source_id, source_kind,
                     extraction_status, raw_payload_json, received_at, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, 'natural_language', 'PARSED', ?, ?, ?, ?, ?, ?)
                """,
                (
                    source_id,
                    space_id,
                    source_id,
                    json.dumps({"marker": marker}),
                    now,
                    adult_a_user["family_id"],
                    now,
                    now,
                    adult_a_user["id"],
                ),
            )
            await db.execute(
                """
                INSERT INTO finance_purchase_source_files
                    (id, space_id, source_id, file_role, filename, media_type,
                     storage_key, byte_size, storage_status, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, 'ATTACHMENT', 'receipt.txt', 'text/plain', ?, ?,
                        'STORED', ?, ?, ?, ?)
                """,
                (
                    f"{source_id}-file",
                    space_id,
                    source_id,
                    storage_key,
                    len(payload),
                    adult_a_user["family_id"],
                    now,
                    now,
                    adult_a_user["id"],
                ),
            )
        await db.execute(
            """
            INSERT INTO finance_share_actions
                (id, owner_user_id, source_space_id, household_space_id,
                 share_kind, source_record_type, source_record_id,
                 selection_json, selection_digest, status,
                 household_record_type, household_record_id, family_id,
                 created_at, updated_at, created_by)
            VALUES ('partner-private-parent-share', ?, ?, ?, 'PURCHASE_LINES',
                    'purchase', 'KAT-PRIVATE-PARENT-ID', '["private-line"]',
                    'digest', 'COMPLETED', 'purchase', 'shared-source', ?, ?, ?, ?)
            """,
            (
                adult_b_user["id"],
                adult_b_spaces["personal"],
                adult_a_spaces["household"],
                adult_a_user["family_id"],
                now,
                now,
                adult_b_user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_share_copy_links
                (id, share_action_id, source_space_id, source_record_type,
                 source_record_id, household_space_id, household_record_type,
                 household_record_id, family_id, created_at, updated_at, created_by)
            VALUES ('partner-private-parent-link', 'partner-private-parent-share', ?,
                    'purchase', 'KAT-PRIVATE-PARENT-ID', ?, 'purchase',
                    'shared-source', ?, ?, ?, ?)
            """,
            (
                adult_b_spaces["personal"],
                adult_a_spaces["household"],
                adult_a_user["family_id"],
                now,
                now,
                adult_b_user["id"],
            ),
        )
        await db.commit()

    response = await client.get("/api/finance/export", headers=adult_a_headers)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "private, no-store"
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        combined = b"\n".join(archive.read(name) for name in archive.namelist())
        exported_history = archive.read("records/finance_history.ndjson")
        manifest = json.loads(archive.read("manifest.json"))
        names = set(archive.namelist())

    assert b"DOM-PRIVATE-TRANSACTION" in combined
    assert b"SHARED-TRANSACTION" in combined
    assert b"SHARED-LINE-ONLY" in combined
    assert b"DOM-HOUSEHOLD-REPORT" in combined
    assert b"KAT-PRIVATE-TRANSACTION" not in combined
    assert b"KAT-PRIVATE-PARENT" not in combined
    assert b"KAT-PRIVATE-PARENT-ID" not in combined
    assert b"KAT-HOUSEHOLD-REPORT" not in combined
    assert b"dom-export-transaction" in exported_history
    assert b"shared-export-transaction" in exported_history
    assert b"kat-export-transaction" not in exported_history
    assert b"SECRET-PROVIDER-SESSION" not in combined
    assert b"SECRET-CALLBACK-HASH" not in combined
    assert b"SECRET-SYNC-LEASE" not in combined
    assert any("dom-source-file" in name for name in names)
    assert any("shared-source-file" in name for name in names)
    assert not any("kat-source-file" in name for name in names)
    assert manifest["scope"] == "current adult personal plus household"

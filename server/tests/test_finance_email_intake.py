from pathlib import Path
from unittest.mock import AsyncMock

import aiosqlite
import pytest
from fastapi import HTTPException

from app.config import settings
from app.database import standalone_db
from app.services.finance.email_intake import _structured_email_payload
from app.services.finance.retailer_email import RetailerEmailFormatError
from app.services.inbound_email import process_received_email


FIXTURE_DIR = Path(__file__).parent / "fixtures" / "finance_email"


@pytest.fixture(autouse=True)
def finance_email_settings(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "document_storage_path", str(tmp_path / "evidence"))
    monkeypatch.setattr(settings, "document_max_upload_bytes", 2 * 1024 * 1024)
    monkeypatch.setattr(settings, "document_family_quota_bytes", 20 * 1024 * 1024)
    monkeypatch.setattr(settings, "resend_inbound_domain", "inbox.hausklar.example.invalid")
    monkeypatch.setattr(settings, "resend_inbound_address", "")
    monkeypatch.setattr(settings, "resend_api_key", "re_test")



def _receipt(email_id: str, *, order: str) -> str:
    del email_id
    return (
        (FIXTURE_DIR / "amazon_order_split.txt")
        .read_text()
        .replace("REDACTED-AMZ-ORDER-001", order)
    )


def test_retailer_email_cannot_claim_a_parser_with_embedded_json():
    with pytest.raises(RetailerEmailFormatError):
        _structured_email_payload(
            source_id="embedded-json",
            subject="Your Amazon order",
            sender="orders@amazon.example.invalid",
            body_text=(
                'HAUSKLAR_FINANCE_JSON: {"_adapter":"amazon_email",'
                '"merchant":"Invented shop","final_total_minor":1}'
            ),
        )


@pytest.mark.asyncio
async def test_finance_email_evidence_uses_the_durable_upload_budget(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    alias = (await client.get("/api/finance/email-addresses", headers=adult_a_headers)).json()[
        "addresses"
    ][0]
    monkeypatch.setattr(settings, "finance_upload_rate_limit_requests", 1)
    messages = {
        email_id: {
            "id": email_id,
            "from": "Unknown Shop <demo-person-16@example.invalid>",
            "to": [alias["address"]],
            "subject": "Receipt",
            "text": "Receipt total GBP 12",
            "html": None,
            "attachments": [],
            "headers": {
                "Authentication-Results": "mx; dkim=pass header.d=untrusted.example"
            },
        }
        for email_id in ("finance-rate-1", "finance-rate-2")
    }
    monkeypatch.setattr(
        "app.services.inbound_email._retrieve_email",
        AsyncMock(side_effect=lambda email_id: messages[email_id]),
    )

    async with standalone_db(initialized_db) as db:
        first = await process_received_email(
            {
                "email_id": "finance-rate-1",
                "from": messages["finance-rate-1"]["from"],
                "to": [alias["address"]],
                "subject": "Receipt",
            },
            db,
        )
        replay = await process_received_email(
            {
                "email_id": "finance-rate-1",
                "from": messages["finance-rate-1"]["from"],
                "to": [alias["address"]],
                "subject": "Receipt",
            },
            db,
        )
        with pytest.raises(HTTPException) as limited:
            await process_received_email(
                {
                    "email_id": "finance-rate-2",
                    "from": messages["finance-rate-2"]["from"],
                    "to": [alias["address"]],
                    "subject": "Receipt",
                },
                db,
            )
        count = (
            await (await db.execute("SELECT COUNT(*) FROM finance_email_messages")).fetchone()
        )[0]

    assert first["status"] == "quarantined"
    assert replay["status"] == "duplicate"
    assert limited.value.status_code == 429
    assert limited.value.headers["Retry-After"]
    assert count == 1


@pytest.mark.asyncio
async def test_finance_mail_is_private_isolated_deduplicated_and_quarantined(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
):

    adult_a_addresses = await client.get("/api/finance/email-addresses", headers=adult_a_headers)
    adult_b_addresses = await client.get("/api/finance/email-addresses", headers=adult_b_headers)
    assert adult_a_addresses.status_code == adult_b_addresses.status_code == 200
    adult_a_alias = adult_a_addresses.json()["addresses"][0]
    adult_b_alias = adult_b_addresses.json()["addresses"][0]
    assert adult_a_alias["alias_kind"] == adult_b_alias["alias_kind"] == "PERSONAL"
    assert adult_a_alias["address"] != adult_b_alias["address"]
    assert "dom" not in adult_a_alias["address"]

    household_response = await client.post(
        "/api/finance/email-addresses/household",
        headers=adult_a_headers,
    )
    assert household_response.status_code == 201, household_response.text
    household_alias = household_response.json()
    adult_b_listing = await client.get("/api/finance/email-addresses", headers=adult_b_headers)
    assert household_alias["address"] in {
        item["address"] for item in adult_b_listing.json()["addresses"]
    }

    send_test = AsyncMock(return_value=True)
    monkeypatch.setattr(
        "app.services.finance.email_intake._send_test_email",
        send_test,
    )
    test_response = await client.post(
        f"/api/finance/email-addresses/{adult_a_alias['id']}/send-test",
        headers=adult_a_headers,
    )
    assert test_response.status_code == 200, test_response.text
    assert test_response.json() == {"queued": True, "destination": adult_a_user["email"]}
    send_test.assert_awaited_once_with(
        destination=adult_a_user["email"],
        address=adult_a_alias["address"],
    )

    enrollment_body = {
        "expected_forwarder_address": adult_a_user["email"],
        "retailer_domain": "amazon.example.invalid",
        "transport_marker": adult_a_user["email"],
    }
    personal_enrollment = await client.post(
        f"/api/finance/email-addresses/{adult_a_alias['id']}/enrollments",
        json=enrollment_body,
        headers=adult_a_headers,
    )
    household_enrollment = await client.post(
        f"/api/finance/email-addresses/{household_alias['id']}/enrollments",
        json=enrollment_body,
        headers=adult_a_headers,
    )
    assert personal_enrollment.status_code == household_enrollment.status_code == 201

    ordinary_address = (
        await client.get("/api/documents/email-address", headers=adult_a_headers)
    ).json()["address"]
    messages = {
        "finance-personal-1": {
            "id": "finance-personal-1",
            "from": "Amazon Orders <orders@amazon.example.invalid>",
            "to": [adult_a_alias["address"]],
            "subject": "Your Amazon order",
            "text": _receipt("finance-personal-1", order="ORDER-PERSONAL-1"),
            "html": None,
            "attachments": [],
            "headers": {
                "Authentication-Results": (
                    "mx; dkim=pass header.d=amazon.example.invalid; "
                    "spf=pass smtp.mailfrom=amazon.example.invalid"
                ),
                "X-Forwarded-To": adult_a_user["email"],
            },
        },
        "finance-household-1": {
            "id": "finance-household-1",
            "from": "Amazon Orders <orders@amazon.example.invalid>",
            "to": [household_alias["address"]],
            "subject": "A household Amazon order",
            "text": _receipt("finance-household-1", order="ORDER-HOUSEHOLD-1"),
            "html": None,
            "attachments": [],
            "headers": {
                "Authentication-Results": "mx; dkim=pass header.d=amazon.example.invalid",
                "X-Forwarded-To": adult_a_user["email"],
            },
        },
        "finance-arc-spoof": {
            "id": "finance-arc-spoof",
            "from": "Amazon Orders <orders@amazon.example.invalid>",
            "to": [],
            "subject": "Spoofed Amazon order",
            "text": _receipt("finance-arc-spoof", order="ORDER-SPOOF-1"),
            "html": None,
            "attachments": [
                {
                    "id": "unsafe-attachment",
                    "filename": "receipt.exe",
                    "content_type": "application/octet-stream",
                    "size": 100,
                }
            ],
            "headers": {
                "Authentication-Results": "mx; arc=pass",
                "ARC-Seal": "i=1; cv=pass",
                "ARC-Authentication-Results": (
                    "i=1; dkim=pass header.d=unrelated.example"
                ),
                "X-Fake": "dkim=pass header.d=amazon.example.invalid; arc=pass",
                "X-Forwarded-To": adult_a_user["email"],
            },
        },
    }
    retrieve = AsyncMock(side_effect=lambda email_id: messages[email_id])
    monkeypatch.setattr("app.services.inbound_email._retrieve_email", retrieve)

    personal_payload = {
        "email_id": "finance-personal-1",
        "message_id": "<demo-person-19@example.invalid>",
        "from": "Amazon Orders <orders@amazon.example.invalid>",
        "to": [adult_a_alias["address"], ordinary_address],
        "subject": "Your Amazon order",
    }
    async with standalone_db(initialized_db) as db:
        parsed = await process_received_email(personal_payload, db)
        duplicate = await process_received_email(personal_payload, db)
    assert parsed["status"] == "parsed"
    assert duplicate == {
        "status": "duplicate",
        "finance_source_id": parsed["finance_source_id"],
    }
    assert retrieve.await_count == 1

    private_source = await client.get(
        f"/api/finance/purchases/evidence/{parsed['finance_source_id']}",
        headers=adult_a_headers,
    )
    assert private_source.status_code == 200, private_source.text
    assert private_source.json()["files"][0]["storage_status"] == "STORED"
    private_leak = await client.get(
        f"/api/finance/purchases/evidence/{parsed['finance_source_id']}",
        headers=adult_b_headers,
    )
    assert private_leak.status_code == 404
    assert "School shoes" not in private_leak.text

    household_payload = {
        "email_id": "finance-household-1",
        "message_id": "<demo-person-15@example.invalid>",
        "from": "Amazon Orders <orders@amazon.example.invalid>",
        "to": [household_alias["address"]],
        "subject": "A household Amazon order",
    }
    async with standalone_db(initialized_db) as db:
        household_parsed = await process_received_email(household_payload, db)
    assert household_parsed["status"] == "parsed"

    health = await client.get(
        f"/api/finance/email-addresses/{adult_a_alias['id']}/health",
        headers=adult_a_headers,
    )
    assert health.status_code == 200
    assert health.json()["alias"]["last_parsed_at"] is not None
    assert health.json()["enrollments"][0]["status"] == "ACTIVE"

    rotated = await client.post(
        f"/api/finance/email-addresses/{adult_a_alias['id']}/rotate",
        headers=adult_a_headers,
    )
    assert rotated.status_code == 201, rotated.text
    rotated_alias = rotated.json()
    assert rotated_alias["address"] != adult_a_alias["address"]

    retrieve.reset_mock()
    async with standalone_db(initialized_db) as db:
        retired_result = await process_received_email(
            {
                "email_id": "retired-alias-delivery",
                "from": adult_a_user["email"],
                "to": [adult_a_alias["address"], ordinary_address],
                "subject": "Must not escape Finance",
            },
            db,
        )
    assert retired_result == {
        "status": "ignored",
        "reason": "inactive_finance_recipient",
    }
    retrieve.assert_not_awaited()

    new_enrollment = await client.post(
        f"/api/finance/email-addresses/{rotated_alias['id']}/enrollments",
        json=enrollment_body,
        headers=adult_a_headers,
    )
    assert new_enrollment.status_code == 201
    messages["finance-arc-spoof"]["to"] = [rotated_alias["address"]]
    retrieve.reset_mock()
    async with standalone_db(initialized_db) as db:
        quarantined = await process_received_email(
            {
                "email_id": "finance-arc-spoof",
                "message_id": "<demo-person-28@example.invalid>",
                "from": "Amazon Orders <orders@amazon.example.invalid>",
                "to": [rotated_alias["address"], ordinary_address],
                "subject": "Spoofed Amazon order",
            },
            db,
        )
    assert quarantined["status"] == "quarantined"
    quarantined_source = await client.get(
        f"/api/finance/purchases/evidence/{quarantined['finance_source_id']}",
        headers=adult_a_headers,
    )
    assert quarantined_source.status_code == 200
    quarantine_body = quarantined_source.json()
    assert quarantine_body["issues"][0]["code"] == "email_origin_unverified"
    assert any(
        item["filename"] == "receipt.exe"
        and item["storage_status"] == "REJECTED_TYPE"
        for item in quarantine_body["files"]
    )

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        counts = {}
        for table in (
            "documents",
            "tasks",
            "capture_suggestions",
            "inbound_email_messages",
            "finance_email_messages",
            "finance_purchase_sources",
            "finance_purchase_records",
        ):
            row = await (await db.execute(f"SELECT COUNT(*) AS count FROM {table}")).fetchone()
            counts[table] = row["count"]
        household_source = await (
            await db.execute(
                "SELECT created_by FROM finance_purchase_sources WHERE id = ?",
                (household_parsed["finance_source_id"],),
            )
        ).fetchone()
        personal_storage_keys = [
            row[0]
            for row in await (
                await db.execute(
                    "SELECT storage_key FROM finance_purchase_source_files "
                    "WHERE space_id IN (?, ?) AND storage_key IS NOT NULL",
                    (adult_a_alias["space_id"], rotated_alias["space_id"]),
                )
            ).fetchall()
        ]
        household_storage_keys = [
            row[0]
            for row in await (
                await db.execute(
                    "SELECT storage_key FROM finance_purchase_source_files "
                    "WHERE space_id = ? AND storage_key IS NOT NULL",
                    (household_alias["space_id"],),
                )
            ).fetchall()
        ]

    assert counts == {
        "documents": 0,
        "tasks": 0,
        "capture_suggestions": 0,
        "inbound_email_messages": 0,
        "finance_email_messages": 3,
        "finance_purchase_sources": 3,
        "finance_purchase_records": 2,
    }
    assert household_source["created_by"] == adult_a_user["id"]
    stored_files = [
        path
        for path in Path(settings.document_storage_path).rglob("*")
        if path.is_file()
    ]
    assert stored_files
    assert all("finance-evidence" in path.parts for path in stored_files)

    deleted = await client.delete("/api/auth/me", headers=adult_a_headers)
    assert deleted.status_code == 204
    storage_root = Path(settings.document_storage_path)
    assert personal_storage_keys
    assert all(not (storage_root / key).exists() for key in personal_storage_keys)
    assert household_storage_keys
    assert all((storage_root / key).is_file() for key in household_storage_keys)


@pytest.mark.asyncio
async def test_redacted_sample_retailer_layouts_extract_exact_lines_and_quarantine_drift(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    alias = (await client.get("/api/finance/email-addresses", headers=adult_a_headers)).json()[
        "addresses"
    ][0]
    for domain in ("amazon.example.invalid", "tesco.example.invalid", "shop.example.invalid"):
        enrolled = await client.post(
            f"/api/finance/email-addresses/{alias['id']}/enrollments",
            headers=adult_a_headers,
            json={
                "expected_forwarder_address": adult_a_user["email"],
                "retailer_domain": domain,
                "transport_marker": adult_a_user["email"],
            },
        )
        assert enrolled.status_code == 201, enrolled.text

    fixtures = {
        "sample-amazon-order": {
            "from": "Amazon Orders <orders@amazon.example.invalid>",
            "subject": "Your Amazon order confirmation",
            "text": (FIXTURE_DIR / "amazon_order_split.txt").read_text(),
            "html": None,
        },
        "sample-amazon-refund": {
            "from": "Amazon Returns <returns@amazon.example.invalid>",
            "subject": "Your Amazon refund has been processed",
            "text": (FIXTURE_DIR / "amazon_refund.txt").read_text(),
            "html": None,
        },
        "sample-tesco-order": {
            "from": "Tesco Orders <orders@tesco.example.invalid>",
            "subject": "Your Tesco order receipt",
            "text": "",
            "html": (FIXTURE_DIR / "tesco_order.html").read_text(),
        },
        "sample-generic-receipt": {
            "from": "Example Stationery <receipts@shop.example.invalid>",
            "subject": "Your order confirmation and receipt",
            "text": (FIXTURE_DIR / "generic_receipt.txt").read_text(),
            "html": None,
        },
        "changed-amazon-layout": {
            "from": "Amazon Orders <orders@amazon.example.invalid>",
            "subject": "Your Amazon order is confirmed",
            "text": (FIXTURE_DIR / "amazon_changed_layout.txt").read_text(),
            "html": None,
        },
    }
    for email_id, message in fixtures.items():
        domain = message["from"].split("@", 1)[1].rstrip(">")
        message.update(
            {
                "id": email_id,
                "to": [alias["address"]],
                "attachments": [],
                "headers": {
                    "Authentication-Results": f"mx; dkim=pass header.d={domain}",
                    "X-Forwarded-To": adult_a_user["email"],
                },
            }
        )
    monkeypatch.setattr(
        "app.services.inbound_email._retrieve_email",
        AsyncMock(side_effect=lambda email_id: fixtures[email_id]),
    )

    results = {}
    async with standalone_db(initialized_db) as db:
        for email_id, message in fixtures.items():
            results[email_id] = await process_received_email(
                {
                    "email_id": email_id,
                    "from": message["from"],
                    "to": [alias["address"]],
                    "subject": message["subject"],
                },
                db,
            )

    assert results["sample-amazon-order"]["status"] == "parsed"
    amazon = (
        await client.get(
            f"/api/finance/purchases/{results['sample-amazon-order']['purchase_id']}",
            headers=adult_a_headers,
        )
    ).json()
    assert amazon["source_kind"] == "amazon_email"
    assert amazon["status"] == "pending"
    assert amazon["final_total_minor"] == 3549
    assert amazon["shipping_minor"] == 399
    assert amazon["order_discount_minor"] == 200
    assert amazon["vat_included_minor"] == 591
    assert [line["line_net_minor"] for line in amazon["lines"]] == [2500, 850]
    assert [line["shipment_reference"] for line in amazon["lines"]] == [
        "REDACTED-PARCEL-A",
        "REDACTED-PARCEL-B",
    ]
    assert sorted(tender["amount_minor"] for tender in amazon["tenders"]) == [1049, 2500]

    assert results["sample-amazon-refund"]["status"] == "parsed"
    refund = (
        await client.get(
            f"/api/finance/purchases/{results['sample-amazon-refund']['purchase_id']}",
            headers=adult_a_headers,
        )
    ).json()
    assert refund["status"] == "refunded"
    assert refund["final_total_minor"] == refund["refunded_minor"] == 2500
    assert refund["behavioural_net_minor"] == 0
    assert refund["refunds"][0]["line_ref"].startswith("REDACTED-AMZ-ORDER-001")

    assert results["sample-tesco-order"]["status"] == "parsed"
    tesco = (
        await client.get(
            f"/api/finance/purchases/{results['sample-tesco-order']['purchase_id']}",
            headers=adult_a_headers,
        )
    ).json()
    assert tesco["source_kind"] == "tesco_batch"
    assert tesco["final_total_minor"] == 770
    assert tesco["shipping_minor"] == 300
    assert tesco["order_discount_minor"] == 100
    assert [line["quantity_decimal"] for line in tesco["lines"]] == ["2", "1"]

    assert results["sample-generic-receipt"]["status"] == "parsed"
    generic = (
        await client.get(
            f"/api/finance/purchases/{results['sample-generic-receipt']['purchase_id']}",
            headers=adult_a_headers,
        )
    ).json()
    assert generic["source_kind"] == "e_receipt"
    assert generic["merchant"] == "Example Stationery"
    assert generic["final_total_minor"] == 999
    assert [line["raw_description"] for line in generic["lines"]] == [
        "Family planner notebook",
        "Blue pens",
    ]

    changed = results["changed-amazon-layout"]
    assert changed["status"] == "quarantined"
    changed_source = (
        await client.get(
            f"/api/finance/purchases/evidence/{changed['finance_source_id']}",
            headers=adult_a_headers,
        )
    ).json()
    assert changed_source["source_kind"] == "amazon_email"
    assert changed_source["issues"] == [
        {
            "code": "retailer_email_items_missing",
            "message": "No confidently labelled Amazon item rows were found.",
        }
    ]


@pytest.mark.asyncio
async def test_trusted_labelled_retailer_email_offers_delivery_without_adding_it(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    addresses = await client.get("/api/finance/email-addresses", headers=adult_a_headers)
    alias = addresses.json()["addresses"][0]
    enrollment = await client.post(
        f"/api/finance/email-addresses/{alias['id']}/enrollments",
        headers=adult_a_headers,
        json={
            "expected_forwarder_address": adult_a_user["email"],
            "retailer_domain": "amazon.example.invalid",
            "transport_marker": adult_a_user["email"],
        },
    )
    assert enrollment.status_code == 201, enrollment.text

    body = (
        "Your parcel has left the depot.\n"
        "Expected delivery date: 15 August 2026\n"
        "Delivery window: 09:00–11:30"
    )
    messages = {
        "trusted-parcel-delivery": {
            "id": "trusted-parcel-delivery",
            "from": "Amazon Dispatch <dispatch@amazon.example.invalid>",
            "to": [alias["address"]],
            "subject": "Your parcel is coming",
            "text": body,
            "html": None,
            "attachments": [],
            "headers": {
                "Authentication-Results": "mx; dkim=pass header.d=amazon.example.invalid",
                "X-Forwarded-To": adult_a_user["email"],
            },
        },
        "untrusted-parcel-delivery": {
            "id": "untrusted-parcel-delivery",
            "from": "Amazon Dispatch <dispatch@amazon.example.invalid>",
            "to": [alias["address"]],
            "subject": "A copied delivery message",
            "text": body,
            "html": None,
            "attachments": [],
            "headers": {
                "Authentication-Results": "mx; dkim=pass header.d=unrelated.example",
                "X-Forwarded-To": adult_a_user["email"],
            },
        },
    }
    monkeypatch.setattr(
        "app.services.inbound_email._retrieve_email",
        AsyncMock(side_effect=lambda email_id: messages[email_id]),
    )

    async with standalone_db(initialized_db) as db:
        trusted = await process_received_email(
            {
                "email_id": "trusted-parcel-delivery",
                "from": "Amazon Dispatch <dispatch@amazon.example.invalid>",
                "to": [alias["address"]],
                "subject": "Your parcel is coming",
            },
            db,
        )
        untrusted = await process_received_email(
            {
                "email_id": "untrusted-parcel-delivery",
                "from": "Amazon Dispatch <dispatch@amazon.example.invalid>",
                "to": [alias["address"]],
                "subject": "A copied delivery message",
            },
            db,
        )

    assert trusted["status"] == "unsupported"
    trusted_prefill = await client.get(
        "/api/finance/calendar-items/prefill",
        params={"source_id": trusted["finance_source_id"]},
        headers=adult_a_headers,
    )
    assert trusted_prefill.json() == {
        "item_kind": "PARCEL_DELIVERY",
        "starts_at": "2026-08-15T09:00:00+01:00",
        "ends_at": "2026-08-15T11:30:00+01:00",
        "all_day": False,
    }
    saved = await client.get(
        "/api/finance/calendar-items",
        params={"source_id": trusted["finance_source_id"]},
        headers=adult_a_headers,
    )
    assert saved.json() == []

    assert untrusted["status"] == "quarantined"
    untrusted_prefill = await client.get(
        "/api/finance/calendar-items/prefill",
        params={"source_id": untrusted["finance_source_id"]},
        headers=adult_a_headers,
    )
    assert untrusted_prefill.json() is None

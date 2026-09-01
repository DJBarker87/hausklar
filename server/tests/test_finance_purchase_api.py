from datetime import date, datetime, timezone

import aiosqlite
import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.ledger import (
    create_finance_account,
    import_source_transactions,
)



@pytest.mark.asyncio
async def test_purchase_evidence_is_private_exact_idempotent_and_reconciled(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_spaces_response = await client.get("/api/finance/spaces", headers=adult_a_headers)
    assert adult_a_spaces_response.status_code == 200
    adult_a_space_id = next(
        item["id"]
        for item in adult_a_spaces_response.json()
        if item["kind"] == "personal"
    )

    enabled_dom = adult_a_user
    async with standalone_db(initialized_db) as db:
        account = await create_finance_account(
            db,
            user=enabled_dom,
            space_id=adult_a_space_id,
            body=FinanceAccountCreate(
                label="Private card",
                institution="Fixture Bank",
                account_type="CREDIT_CARD",
                currency="GBP",
                last_four="4321",
            ),
        )
        imported = await import_source_transactions(
            db,
            user=enabled_dom,
            space_id=adult_a_space_id,
            account_id=account.id,
            observations=[
                NormalisedSourceTransaction(
                    source_kind="MANUAL",
                    source_batch_id="purchase-api-fixture",
                    source_transaction_id="private-card-charge",
                    booking_date=date(2026, 7, 20),
                    pending_status="POSTED",
                    amount_minor=-1_600,
                    currency="GBP",
                    description="Example Shop",
                    merchant_text="Example Shop",
                    observed_at=datetime(2026, 7, 20, 12, tzinfo=timezone.utc),
                )
            ],
        )
    transaction_id = imported.transaction_ids[0]

    payload = {
        "source_id": "private-receipt-1",
        "purchase_reference": "purchase-1",
        "merchant": "Example Shop",
        "purchased_at": "2026-07-20",
        "currency": "GBP",
        "lines": [
            {
                "line_reference": "line-a",
                "description": "Item A",
                "gross_minor": 1_200,
                "discount_minor": 200,
                "net_minor": 1_000,
            },
            {
                "line_reference": "line-b",
                "description": "Item B",
                "net_minor": 500,
            },
        ],
        "shipping_minor": 200,
        "order_discount_minor": 100,
        "vat_included_minor": 267,
        "final_total_minor": 1_600,
        "tenders": [
            {
                "id": "card-1",
                "kind": "card",
                "amount_minor": 1_600,
                "card_suffix": "4321",
            }
        ],
    }
    intake = {
        "external_source_id": "private-receipt-1",
        "adapter": "e_receipt",
        "reviewed": True,
        "payload": payload,
    }
    created = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": adult_a_space_id},
        json=intake,
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    created_body = created.json()
    assert created_body["duplicate"] is False
    assert created_body["source"]["extraction_status"] == "PARSED"
    assert created_body["source"]["storage_area"] == "finance-evidence"
    assert created_body["source"]["raw_payload"] == payload
    purchase = created_body["purchase"]
    assert purchase["lines_subtotal_minor"] == 1_500
    assert purchase["shipping_minor"] == 200
    assert purchase["order_discount_minor"] == 100
    assert purchase["vat_included_minor"] == 267
    assert purchase["final_total_minor"] == 1_600
    assert [line["line_net_minor"] for line in purchase["lines"]] == [1_000, 500]
    assert purchase["match_status"] == "MATCHED"
    assert purchase["cashflow_source"] == "canonical_transactions"
    assert purchase["purchase_total_added_to_cashflow"] is False
    assert purchase["payment_allocations"] == [
        {
            "id": purchase["payment_allocations"][0]["id"],
            "allocation_ref": f"auto-charge:{transaction_id}",
            "transaction_id": transaction_id,
            "line_id": None,
            "tender_kind": "card",
            "allocated_minor": 1_600,
            "transaction_amount_minor": -1_600,
            "transaction_date": "2026-07-20",
            "match_method": "AUTO_EXACT",
            "status": "CONFIRMED",
        }
    ]

    duplicate = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": adult_a_space_id},
        json=intake,
        headers=adult_a_headers,
    )
    assert duplicate.status_code == 201
    assert duplicate.json()["duplicate"] is True
    assert duplicate.json()["source"]["id"] == created_body["source"]["id"]
    assert duplicate.json()["purchase"]["id"] == purchase["id"]

    private_list = await client.get(
        "/api/finance/purchases",
        params={"space_id": adult_a_space_id},
        headers=adult_b_headers,
    )
    assert private_list.status_code == 404
    assert "Example Shop" not in private_list.text
    private_detail = await client.get(
        f"/api/finance/purchases/{purchase['id']}",
        headers=adult_b_headers,
    )
    assert private_detail.status_code == 404
    assert "Example Shop" not in private_detail.text

    listed = await client.get(
        "/api/finance/purchases",
        params={"space_id": adult_a_space_id},
        headers=adult_a_headers,
    )
    assert listed.status_code == 200
    assert [item["id"] for item in listed.json()] == [purchase["id"]]
    detail = await client.get(
        f"/api/finance/purchases/{purchase['id']}", headers=adult_a_headers
    )
    assert detail.status_code == 200
    assert detail.json()["evidence"]["raw_payload"] == payload
    assert detail.json()["tenders"][0]["card_suffix"] == "4321"
    assert detail.json()["payment_allocations"][0]["transaction_id"] == transaction_id

    by_source = await client.get(
        f"/api/finance/purchases/by-source/{created_body['source']['id']}",
        headers=adult_a_headers,
    )
    assert by_source.status_code == 200
    assert by_source.json()["id"] == purchase["id"]
    by_transaction = await client.get(
        f"/api/finance/purchases/by-transaction/{transaction_id}",
        headers=adult_a_headers,
    )
    assert by_transaction.status_code == 200
    assert by_transaction.json()["id"] == purchase["id"]
    by_line = await client.get(
        f"/api/finance/purchases/by-line/{purchase['lines'][0]['id']}",
        headers=adult_a_headers,
    )
    assert by_line.status_code == 200
    assert by_line.json()["id"] == purchase["id"]
    assert (
        await client.get(
            f"/api/finance/purchases/by-source/{created_body['source']['id']}",
            headers=adult_b_headers,
        )
    ).status_code == 404
    assert (
        await client.get(
            f"/api/finance/purchases/by-transaction/{transaction_id}",
            headers=adult_b_headers,
        )
    ).status_code == 404
    assert (
        await client.get(
            f"/api/finance/purchases/by-line/{purchase['lines'][0]['id']}",
            headers=adult_b_headers,
        )
    ).status_code == 404

    ledger_summary = await client.get(
        "/api/finance/summary",
        params={"space_id": adult_a_space_id},
        headers=adult_a_headers,
    )
    assert ledger_summary.status_code == 200
    assert ledger_summary.json()["currencies"][0]["gross_spending_minor"] == 1_600

    malformed = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": adult_a_space_id},
        json={
            "external_source_id": "bad-receipt",
            "adapter": "e_receipt",
            "reviewed": True,
            "payload": {
                "source_id": "bad-receipt",
                "merchant": "Bad Totals",
                "purchased_at": "2026-07-20",
                "lines": [
                    {
                        "line_reference": "bad-line",
                        "description": "Impossible item",
                        "net_minor": 2_000,
                    }
                ],
                "final_total_minor": 1_000,
            },
        },
        headers=adult_a_headers,
    )
    assert malformed.status_code == 201, malformed.text
    assert malformed.json()["source"]["extraction_status"] == "QUARANTINED"
    assert malformed.json()["purchase"] is None
    assert malformed.json()["exception"]["exception_kind"] == "QUARANTINED_EVIDENCE"

    inbox = await client.get(
        "/api/finance/purchases/inbox",
        params={"space_id": adult_a_space_id},
        headers=adult_a_headers,
    )
    assert inbox.status_code == 200
    assert [item["source_id"] for item in inbox.json()] == [
        malformed.json()["source"]["id"]
    ]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        counts = {}
        for table in (
            "finance_purchase_sources",
            "finance_purchase_records",
            "finance_purchase_payments",
            "documents",
            "tasks",
        ):
            row = await (await db.execute(f"SELECT COUNT(*) AS count FROM {table}")).fetchone()
            counts[table] = row["count"]
        health = await (
            await db.execute(
                """
                SELECT health_status, consecutive_failures, latest_issue_code
                FROM finance_purchase_source_health
                WHERE space_id = ? AND source_kind = 'e_receipt' AND deleted_at IS NULL
                """,
                (adult_a_space_id,),
            )
        ).fetchone()
    assert counts == {
        "finance_purchase_sources": 2,
        "finance_purchase_records": 1,
        "finance_purchase_payments": 1,
        "documents": 0,
        "tasks": 0,
    }
    assert dict(health) == {
        "health_status": "QUARANTINED",
        "consecutive_failures": 1,
        "latest_issue_code": "malformed_evidence",
    }

    correction_payload = {
        **payload,
        "source_id": "private-receipt-1-correction",
        "lines": [
            {**payload["lines"][0], "description": "Corrected Item A"},
            payload["lines"][1],
        ],
    }
    correction_intake = {
        "external_source_id": "private-receipt-1-correction",
        "adapter": "e_receipt",
        "reviewed": True,
        "corrects_source_id": created_body["source"]["id"],
        "payload": correction_payload,
    }
    corrected = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": adult_a_space_id},
        json=correction_intake,
        headers=adult_a_headers,
    )
    assert corrected.status_code == 201, corrected.text
    corrected_body = corrected.json()
    assert corrected_body["duplicate"] is False
    assert corrected_body["purchase"]["supersedes_purchase_id"] == purchase["id"]
    assert corrected_body["purchase"]["lines"][0]["raw_description"] == "Corrected Item A"

    correction_retry = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": adult_a_space_id},
        json=correction_intake,
        headers=adult_a_headers,
    )
    assert correction_retry.status_code == 201
    assert correction_retry.json()["duplicate"] is True
    assert correction_retry.json()["source"]["id"] == corrected_body["source"]["id"]
    assert correction_retry.json()["purchase"]["id"] == corrected_body["purchase"]["id"]

    changed_retry = {
        **correction_intake,
        "payload": {**correction_payload, "merchant": "Changed Facts"},
    }
    changed = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": adult_a_space_id},
        json=changed_retry,
        headers=adult_a_headers,
    )
    assert changed.status_code == 409

    competing_correction = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": adult_a_space_id},
        json={
            **correction_intake,
            "external_source_id": "competing-correction",
            "payload": {**correction_payload, "source_id": "competing-correction"},
        },
        headers=adult_a_headers,
    )
    assert competing_correction.status_code == 409

    async with standalone_db(initialized_db) as db:
        grouped_import = await import_source_transactions(
            db,
            user=enabled_dom,
            space_id=adult_a_space_id,
            account_id=account.id,
            observations=[
                NormalisedSourceTransaction(
                    source_kind="MANUAL",
                    source_batch_id="purchase-api-fixture",
                    source_transaction_id="grouped-card-charge",
                    booking_date=date(2026, 7, 21),
                    pending_status="POSTED",
                    amount_minor=-10_000,
                    currency="GBP",
                    description="Grouped Shop",
                    merchant_text="Grouped Shop",
                    observed_at=datetime(2026, 7, 21, 12, tzinfo=timezone.utc),
                )
            ],
        )
    grouped_transaction_id = grouped_import.transaction_ids[0]

    grouped_purchases = []
    for suffix, amount in (("a", 6_000), ("b", 4_000)):
        source_id = f"grouped-receipt-{suffix}"
        response = await client.post(
            "/api/finance/purchases/evidence",
            params={"space_id": adult_a_space_id},
            json={
                "external_source_id": source_id,
                "adapter": "e_receipt",
                "reviewed": True,
                "payload": {
                    "source_id": source_id,
                    "purchase_reference": f"grouped-purchase-{suffix}",
                    "merchant": "Grouped Shop",
                    "purchased_at": "2026-07-21",
                    "currency": "GBP",
                    "lines": [
                        {
                            "line_reference": f"grouped-line-{suffix}",
                            "description": f"Grouped item {suffix}",
                            "net_minor": amount,
                        }
                    ],
                    "final_total_minor": amount,
                },
            },
            headers=adult_a_headers,
        )
        assert response.status_code == 201, response.text
        assert response.json()["purchase"]["match_status"] == "UNMATCHED"
        assert response.json()["exception"]["exception_kind"] == "AMBIGUOUS_MATCH"
        grouped_purchases.append(response.json()["purchase"])

    private_match = await client.post(
        f"/api/finance/purchases/{grouped_purchases[0]['id']}/match",
        json={
            "reviewed": True,
            "allocations": [
                {
                    "transaction_id": grouped_transaction_id,
                    "allocated_minor": 6_000,
                }
            ],
        },
        headers=adult_b_headers,
    )
    assert private_match.status_code == 404
    assert "Grouped Shop" not in private_match.text

    first_match_request = {
        "reviewed": True,
        "allocations": [
            {
                "transaction_id": grouped_transaction_id,
                "allocated_minor": 6_000,
            }
        ],
    }
    first_match = await client.post(
        f"/api/finance/purchases/{grouped_purchases[0]['id']}/match",
        json=first_match_request,
        headers=adult_a_headers,
    )
    assert first_match.status_code == 200, first_match.text
    assert first_match.json()["match_status"] == "MATCHED"
    assert first_match.json()["payment_allocations"][0]["match_method"] == "REVIEWED"
    first_allocation_id = first_match.json()["payment_allocations"][0]["id"]

    overallocated = await client.post(
        f"/api/finance/purchases/{grouped_purchases[1]['id']}/match",
        json={
            "reviewed": True,
            "allocations": [
                {
                    "transaction_id": grouped_transaction_id,
                    "allocated_minor": 5_000,
                }
            ],
        },
        headers=adult_a_headers,
    )
    assert overallocated.status_code == 422

    second_match = await client.post(
        f"/api/finance/purchases/{grouped_purchases[1]['id']}/match",
        json={
            "reviewed": True,
            "allocations": [
                {
                    "transaction_id": grouped_transaction_id,
                    "allocated_minor": 4_000,
                }
            ],
        },
        headers=adult_a_headers,
    )
    assert second_match.status_code == 200, second_match.text
    assert second_match.json()["match_status"] == "MATCHED"

    first_match_retry = await client.post(
        f"/api/finance/purchases/{grouped_purchases[0]['id']}/match",
        json=first_match_request,
        headers=adult_a_headers,
    )
    assert first_match_retry.status_code == 200
    assert first_match_retry.json()["payment_allocations"][0]["id"] == first_allocation_id

    resolved_inbox = await client.get(
        "/api/finance/purchases/inbox",
        params={"space_id": adult_a_space_id},
        headers=adult_a_headers,
    )
    assert resolved_inbox.status_code == 200
    assert [item["source_id"] for item in resolved_inbox.json()] == [
        malformed.json()["source"]["id"]
    ]
    final_summary = await client.get(
        "/api/finance/summary",
        params={"space_id": adult_a_space_id},
        headers=adult_a_headers,
    )
    assert final_summary.status_code == 200
    assert final_summary.json()["currencies"][0]["gross_spending_minor"] == 11_600

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        grouped_allocation = await (
            await db.execute(
                """
                SELECT COUNT(*) AS count, SUM(allocated_minor) AS total
                FROM finance_purchase_payments
                WHERE transaction_id = ? AND status = 'CONFIRMED'
                  AND deleted_at IS NULL
                """,
                (grouped_transaction_id,),
            )
        ).fetchone()
        current_corrections = await (
            await db.execute(
                """
                SELECT COUNT(*) AS count FROM finance_purchase_records
                WHERE supersedes_purchase_id = ? AND superseded_by_id IS NULL
                  AND deleted_at IS NULL
                """,
                (purchase["id"],),
            )
        ).fetchone()
        ordinary_rows = {}
        for table in ("documents", "tasks"):
            row = await (
                await db.execute(f"SELECT COUNT(*) AS count FROM {table}")
            ).fetchone()
            ordinary_rows[table] = row["count"]
    assert dict(grouped_allocation) == {"count": 2, "total": 10_000}
    assert current_corrections["count"] == 1
    assert ordinary_rows == {"documents": 0, "tasks": 0}

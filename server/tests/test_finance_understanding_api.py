from datetime import date, datetime, timezone

import aiosqlite
import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.ledger import create_finance_account, import_source_transactions
from app.services.finance.understanding import purchase_itemisation_coverage



def _amazon_intake(
    source_id: str,
    order: str,
    *,
    shoe_minor: int = 6_000,
    purchased_at: str = "2026-07-08",
):
    return {
        "external_source_id": source_id,
        "adapter": "amazon_email",
        "reviewed": True,
        "payload": {
            "source_id": source_id,
            "event_type": "dispatch",
            "order_reference": order,
            "merchant": "Amazon UK",
            "purchased_at": purchased_at,
            "currency": "GBP",
            "lines": [
                {
                    "line_reference": "shoes",
                    "kind": "product",
                    "description": "School Shoes Kids Navy",
                    "net_minor": shoe_minor,
                },
                {
                    "line_reference": "backup",
                    "kind": "service",
                    "description": "Annual Cloud Backup",
                    "net_minor": 4_000,
                },
            ],
            "charges": [
                {"id": "charge", "kind": "card", "amount_minor": shoe_minor + 4_000}
            ],
            "final_total_minor": shoe_minor + 4_000,
        },
    }


@pytest.mark.asyncio
async def test_mixed_lines_feedback_exact_analysis_owned_evidence_and_strict_fields(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    space_id = next(item["id"] for item in spaces if item["kind"] == "personal")
    async with standalone_db(initialized_db) as db:
        account = await create_finance_account(
            db,
            user=adult_a_user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Current",
                account_type="CURRENT",
                currency="GBP",
            ),
        )
        imported = await import_source_transactions(
            db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account.id,
            observations=[
                NormalisedSourceTransaction(
                    source_kind="MANUAL",
                    source_batch_id="coverage",
                    source_transaction_id="broad-unitemised",
                    booking_date=date(2026, 7, 20),
                    pending_status="POSTED",
                    amount_minor=-15_000,
                    currency="GBP",
                    description="Broad retailer purchase without receipt",
                    merchant_text="Broad Retailer",
                    observed_at=datetime(2026, 7, 20, 12, tzinfo=timezone.utc),
                )
            ],
        )
        await db.execute(
            """
            INSERT INTO finance_merchants
                (id, space_id, name, merchant_kind, family_id, created_by)
            VALUES ('broad-retailer', ?, 'Broad Retailer', 'BROAD_RETAILER', ?, ?)
            """,
            (space_id, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            "UPDATE finance_transactions SET merchant_id = 'broad-retailer' WHERE id = ?",
            (imported.transaction_ids[0],),
        )
        await db.commit()

    ingested = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": space_id},
        json=_amazon_intake("amazon-mixed-1", "ORDER-MIXED-1"),
        headers=adult_a_headers,
    )
    assert ingested.status_code == 201, ingested.text
    lines = ingested.json()["purchase"]["lines"]
    shoes, backup = lines
    assert [line["raw_description"] for line in lines] == [
        "School Shoes Kids Navy",
        "Annual Cloud Backup",
    ]
    review = await client.get(
        "/api/finance/purchases/review/high-impact",
        params={"space_id": space_id, "minimum_impact_minor": 3_000},
        headers=adult_a_headers,
    )
    assert review.status_code == 200
    assert {item["line_id"] for item in review.json()} == {shoes["id"], backup["id"]}

    first_shoes = await client.put(
        f"/api/finance/purchase-lines/{shoes['id']}/assessment",
        json={
            "normalized_item_name": "Children's school footwear",
            "beneficiary": "Child 1",
            "purpose": "school",
            "plannedness": "planned",
            "utility": "essential",
            "decision_quality": "sensible",
            "value_for_money": "fair",
            "outcome_state": "valued",
        },
        headers=adult_a_headers,
    )
    assert first_shoes.status_code == 200, first_shoes.text
    corrected = await client.put(
        f"/api/finance/purchase-lines/{shoes['id']}/assessment",
        json={
            "normalized_item_name": "School shoes",
            "value_for_money": "good",
            "correction_reason": "The sale price was better than first judged",
        },
        headers=adult_a_headers,
    )
    assert corrected.status_code == 200, corrected.text
    assert corrected.json()["source_description"] == "School Shoes Kids Navy"
    assert corrected.json()["normalized_item_name"] == "School shoes"
    assert corrected.json()["value_for_money"] == "good"
    assert corrected.json()["feedback_recorded"] == 2

    assessed_backup = await client.put(
        f"/api/finance/purchase-lines/{backup['id']}/assessment",
        json={
            "normalized_item_name": "Cloud backup",
            "beneficiary": "Household",
            "purpose": "data safety",
            "plannedness": "routine",
            "utility": "useful",
            "decision_quality": "sensible",
            "value_for_money": "fair",
            "outcome_state": "valued",
        },
        headers=adult_a_headers,
    )
    assert assessed_backup.status_code == 200, assessed_backup.text

    prior = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": space_id},
        json=_amazon_intake(
            "amazon-mixed-prior",
            "ORDER-MIXED-PRIOR",
            shoe_minor=1_000,
            purchased_at="2026-06-08",
        ),
        headers=adult_a_headers,
    )
    assert prior.status_code == 201, prior.text

    analysis_request = {
        "space_id": space_id,
        "basis": "PURCHASE_LINES",
        "start_date": "2026-07-01",
        "end_date": "2026-07-31",
        "currency": "GBP",
        "grouping": "PURPOSE",
        "measure": "SPEND",
        "comparison": "PREVIOUS_PERIOD",
        "filters": {},
        "save_as": "July purchase purposes",
    }
    analysis = await client.post(
        "/api/finance/analysis", json=analysis_request, headers=adult_a_headers
    )
    assert analysis.status_code == 200, analysis.text
    result = analysis.json()
    assert result["total"] == {"numerator": 10_000, "denominator": 1}
    assert {
        group["key"]: group["value"] for group in result["groups"]
    } == {
        "data safety": {"numerator": 4_000, "denominator": 1},
        "school": {"numerator": 6_000, "denominator": 1},
    }
    assert result["data_through"] == "2026-07-08"
    assert result["comparison_total"] == {"numerator": 5_000, "denominator": 1}
    assert {
        group["key"]: group["value"] for group in result["comparison_groups"]
    } == {
        "data safety": {"numerator": 4_000, "denominator": 1},
        "school": {"numerator": 1_000, "denominator": 1},
    }
    assert result["itemisation_coverage"] == {
        "eligible_minor": 15_000,
        "itemised_minor": 10_000,
        "coverage_bps": 6_666,
    }
    async with standalone_db(initialized_db) as db:
        lightweight_coverage = await purchase_itemisation_coverage(
            db,
            user=adult_a_user,
            space_id=space_id,
            currency="GBP",
            start_date=date(2026, 7, 1),
            end_date=date(2026, 7, 31),
        )
    assert lightweight_coverage.model_dump() == result["itemisation_coverage"]
    assert len(result["evidence"]) == 4
    assert result["saved_view"]["deep_link"].startswith(
        "/?view=finance&section=explore&analysis="
    )

    owned = await client.get(
        f"/api/finance/analysis/evidence/purchase-line/{shoes['id']}",
        headers=adult_a_headers,
    )
    assert owned.status_code == 200
    assert owned.json()["source_description"] == "School Shoes Kids Navy"
    private = await client.get(
        f"/api/finance/analysis/evidence/purchase-line/{shoes['id']}",
        headers=adult_b_headers,
    )
    assert private.status_code == 404
    assert "School Shoes" not in private.text

    malicious = await client.post(
        "/api/finance/analysis",
        json={**analysis_request, "save_as": None, "sql": "DROP TABLE finance_transactions"},
        headers=adult_a_headers,
    )
    assert malicious.status_code == 422

    unreconciled = await client.post(
        "/api/finance/analysis",
        json={
            **analysis_request,
            "basis": "RECONCILED_PURCHASE_LINES",
            "comparison": "NONE",
            "save_as": None,
        },
        headers=adult_a_headers,
    )
    assert unreconciled.status_code == 200, unreconciled.text
    assert unreconciled.json()["total"] == {"numerator": 0, "denominator": 1}
    assert unreconciled.json()["itemisation_coverage"] == {
        "eligible_minor": 15_000,
        "itemised_minor": 0,
        "coverage_bps": 0,
    }

    future = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": space_id},
        json=_amazon_intake("amazon-mixed-2", "ORDER-MIXED-2", shoe_minor=1_000),
        headers=adult_a_headers,
    )
    assert future.status_code == 201, future.text
    future_shoes = future.json()["purchase"]["lines"][0]
    learned = await client.get(
        f"/api/finance/purchase-lines/{future_shoes['id']}/assessment",
        headers=adult_a_headers,
    )
    assert learned.status_code == 200, learned.text
    assert learned.json()["classification_source"] == "LEARNED"
    assert learned.json()["normalized_item_name"] == "School shoes"
    assert learned.json()["value_for_money"] == "good"

    async with aiosqlite.connect(initialized_db) as db:
        raw = await (
            await db.execute(
                "SELECT raw_description FROM finance_purchase_lines WHERE id = ?",
                (shoes["id"],),
            )
        ).fetchone()
        feedback_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM finance_purchase_classification_feedback WHERE line_id = ?",
                    (shoes["id"],),
                )
            ).fetchone()
        )[0]
    assert raw[0] == "School Shoes Kids Navy"
    assert feedback_count == 10


@pytest.mark.asyncio
async def test_large_transaction_history_still_returns_the_exact_analysis(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    space_id = next(item["id"] for item in spaces if item["kind"] == "personal")
    async with standalone_db(initialized_db) as db:
        account = await create_finance_account(
            db,
            user=adult_a_user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Current",
                account_type="CURRENT",
                currency="GBP",
            ),
        )
        observed_at = "2026-07-31T12:00:00+00:00"
        await db.executemany(
            """
            INSERT INTO finance_transactions
                (id, space_id, account_id, canonical_date, amount_minor, currency,
                 state, source_kind, description, cleaned_description,
                 data_through_at, family_id, created_by)
            VALUES (?, ?, ?, '2026-07-31', -100, 'GBP', 'POSTED', 'MANUAL',
                    'Family purchase', 'Family purchase', ?, ?, ?)
            """,
            [
                (
                    f"large-history-{index:05d}",
                    space_id,
                    account.id,
                    observed_at,
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                )
                for index in range(5_001)
            ],
        )
        await db.commit()

    response = await client.post(
        "/api/finance/analysis",
        headers=adult_a_headers,
        json={
            "space_id": space_id,
            "basis": "TRANSACTIONS",
            "start_date": "2026-07-01",
            "end_date": "2026-07-31",
            "currency": "GBP",
            "grouping": "TOTAL",
            "measure": "SPEND",
            "comparison": "NONE",
            "filters": {},
        },
    )

    assert response.status_code == 200, response.text
    result = response.json()
    assert result["total"] == {"numerator": 500_100, "denominator": 1}
    assert result["groups"] == [
        {
            "key": "total",
            "value": {"numerator": 500_100, "denominator": 1},
            "record_count": 5_001,
            "evidence_handles": [
                f"transaction:large-history-{index:05d}" for index in range(5_001)
            ],
        }
    ]
    assert len(result["evidence"]) == 5_001

"""Focused contract check for product comparisons and read-only asset snapshots."""

from datetime import date, timedelta

import aiosqlite
import pytest



def _research_payload(**updates):
    payload = {
        "normalized_need": "Oat cereal",
        "brand_variant": "plain",
        "quantity": "2",
        "pack_quantity": "500",
        "pack_unit": "g",
        "unit_basis": "g",
        "quality_constraints": ["no added sugar"],
        "substitution_constraints": ["oat based"],
        "fulfilment_assumption": "DELIVERY",
        "approximate_travel_minutes": 0,
    }
    payload.update(updates)
    return payload


def _result_payload(*, price_minor: int, product_name: str):
    return {
        "reviewed": True,
        "match_kind": "EXACT",
        "retailer_name": "Aldi",
        "product_name": product_name,
        "brand_variant": "plain",
        "pack_quantity": "500",
        "pack_unit": "g",
        "comparable_quantity": "500",
        "unit_basis": "g",
        "price_minor": price_minor,
        "currency": "GBP",
        "observed_on": "2026-07-20",
        "delivery_low_minor": 0,
        "delivery_high_minor": 0,
        "travel_low_minor": 0,
        "travel_high_minor": 0,
        "likely_waste_low_bps": 0,
        "likely_waste_high_bps": 0,
        "inconvenience_note": "Same delivery window",
        "confidence_bps": 9500,
        "source_label": "Reviewed retailer result",
    }


@pytest.mark.asyncio
async def test_reviewed_product_and_watch_only_asset_contracts(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    space_id = next(space["id"] for space in spaces if space["kind"] == "personal")

    intake = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": space_id},
        headers=adult_a_headers,
        json={
            "external_source_id": "product-history-source",
            "adapter": "amazon_email",
            "reviewed": True,
            "payload": {
                "source_id": "product-history-source",
                "event_type": "dispatch",
                "order_reference": "CEREAL-1",
                "merchant": "Example Grocer",
                "purchased_at": "2026-07-20",
                "currency": "GBP",
                "lines": [
                    {
                        "line_reference": "cereal",
                        "kind": "product",
                        "description": "Oat cereal",
                        "quantity": "2",
                        "unit": "500g",
                        "net_minor": 500,
                    }
                ],
                "charges": [{"id": "cash", "kind": "cash", "amount_minor": 500}],
                "final_total_minor": 500,
            },
        },
    )
    assert intake.status_code == 201, intake.text
    purchase = intake.json()["purchase"]
    line_id = purchase["lines"][0]["id"]

    blank = await client.put(
        f"/api/finance/purchase-lines/{line_id}/assessment",
        headers=adult_a_headers,
        json={"purpose": None},
    )
    assert blank.status_code == 422
    partial = await client.put(
        f"/api/finance/purchase-lines/{line_id}/assessment",
        headers=adult_a_headers,
        json={"purpose": "breakfast"},
    )
    assert partial.status_code == 200
    assert partial.json()["review_status"] == "NEEDS_REVIEW"
    assert partial.json()["confidence_bps"] < 10_000
    review = await client.get(
        "/api/finance/purchases/review/high-impact",
        params={"space_id": space_id, "minimum_impact_minor": 1},
        headers=adult_a_headers,
    )
    assert line_id in {item["line_id"] for item in review.json()}

    complete = await client.put(
        f"/api/finance/purchase-lines/{line_id}/assessment",
        headers=adult_a_headers,
        json={
            "normalized_item_name": "Oat cereal",
            "beneficiary": "Household",
            "plannedness": "routine",
            "utility": "useful",
            "decision_quality": "sensible",
            "value_for_money": "fair",
            "outcome_state": "valued",
        },
    )
    assert complete.status_code == 200, complete.text
    assert complete.json()["review_status"] == "CONFIRMED"
    assert complete.json()["confidence_bps"] == 10_000
    item_id = complete.json()["normalized_item_id"]
    no_op = await client.put(
        f"/api/finance/purchase-lines/{line_id}/assessment",
        headers=adult_a_headers,
        json={"purpose": "breakfast"},
    )
    assert no_op.status_code == 422

    rebuilt = await client.post(
        "/api/finance/product-prices/rebuild",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert rebuilt.status_code == 200, rebuilt.text
    assert rebuilt.json()["updated_observation_count"] == 1
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO finance_line_refunds
                (id, space_id, source_id, purchase_id, line_id, refund_ref,
                 amount_minor, quantity_decimal, source_refs_json, family_id, created_by)
            VALUES ('refund-product-history', ?, ?, ?, ?, 'partial-refund', 250,
                    '1', '[]', ?, ?)
            """,
            (
                space_id,
                intake.json()["source"]["id"],
                purchase["id"],
                line_id,
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()
    rebuilt_after_refund = await client.post(
        "/api/finance/product-prices/rebuild",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert rebuilt_after_refund.status_code == 200, rebuilt_after_refund.text
    assert rebuilt_after_refund.json()["updated_observation_count"] == 1
    history = await client.get(
        f"/api/finance/items/{item_id}/product-price-history",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert history.status_code == 200, history.text
    assert history.json()["observations"][0]["comparable_quantity"] == "500"
    assert history.json()["observations"][0]["price_minor"] == 250

    wrong_item = await client.post(
        "/api/finance/retailer-research/requests",
        params={"space_id": space_id, "normalized_item_id": item_id},
        headers=adult_a_headers,
        json=_research_payload(normalized_need="Unrelated cereal"),
    )
    assert wrong_item.status_code == 422
    named_context = await client.post(
        "/api/finance/retailer-research/requests",
        params={"space_id": space_id, "normalized_item_id": item_id},
        headers=adult_a_headers,
        json=_research_payload(quality_constraints=["Alex preferred"]),
    )
    assert named_context.status_code == 422
    requested = await client.post(
        "/api/finance/retailer-research/requests",
        params={"space_id": space_id, "normalized_item_id": item_id},
        headers=adult_a_headers,
        json=_research_payload(),
    )
    assert requested.status_code == 201, requested.text
    request_body = requested.json()
    assert request_body["fulfilment_mode"] == "MANUAL_REVIEW"
    assert "Automatic retailer lookup is not configured" in request_body["message"]
    review_payload = request_body["review_payload"]
    assert set(review_payload) == {
        "normalized_need",
        "brand_variant",
        "quantity",
        "pack_quantity",
        "pack_unit",
        "unit_basis",
        "quality_constraints",
        "substitution_constraints",
        "fulfilment_assumption",
        "approximate_travel_minutes",
    }
    assert not any(key.endswith("_id") for key in review_payload)

    future_result_payload = _result_payload(
        price_minor=150,
        product_name="Future plain oat cereal",
    )
    future_result_payload["observed_on"] = (date.today() + timedelta(days=1)).isoformat()
    future_result = await client.post(
        f"/api/finance/retailer-research/requests/{requested.json()['request_id']}/results",
        headers=adult_a_headers,
        json=future_result_payload,
    )
    assert future_result.status_code == 422

    result = await client.post(
        f"/api/finance/retailer-research/requests/{requested.json()['request_id']}/results",
        headers=adult_a_headers,
        json=_result_payload(price_minor=150, product_name="Plain oat cereal"),
    )
    assert result.status_code == 201, result.text
    assert result.json()["source_label"] == "Reviewed retailer result"
    result_retry = await client.post(
        f"/api/finance/retailer-research/requests/{requested.json()['request_id']}/results",
        headers=adult_a_headers,
        json=_result_payload(price_minor=150, product_name="Plain oat cereal"),
    )
    assert result_retry.status_code == 201, result_retry.text
    assert result_retry.json()["id"] == result.json()["id"]
    comparison = await client.post(
        "/api/finance/product-comparisons",
        params={"space_id": space_id},
        headers=adult_a_headers,
        json={
            "normalized_item_id": item_id,
            "research_result_id": result.json()["id"],
            "period_start": "2026-07-20",
            "period_end": "2026-07-20",
        },
    )
    assert comparison.status_code == 201, comparison.text
    assert comparison.json()["comparison_mode"] == "EXACT"
    assert comparison.json()["currency"] == "GBP"
    assert comparison.json()["confidence_bps"] == 9500
    assert comparison.json()["candidate_low_minor"] == 150
    assert comparison.json()["saving_low_minor"] == 100
    accepted = await client.post(
        f"/api/finance/product-comparisons/{comparison.json()['id']}/accept",
        headers=adult_a_headers,
        json={"action_kind": "PREFERENCE"},
    )
    assert accepted.status_code == 200, accepted.text
    assert accepted.json()["status"] == "CREATED"
    assert accepted.json()["target_preference_id"]

    second_result = await client.post(
        f"/api/finance/retailer-research/requests/{requested.json()['request_id']}/results",
        headers=adult_a_headers,
        json=_result_payload(price_minor=140, product_name="Another oat cereal"),
    )
    assert second_result.status_code == 201, second_result.text
    second_comparison = await client.post(
        "/api/finance/product-comparisons",
        params={"space_id": space_id},
        headers=adult_a_headers,
        json={
            "normalized_item_id": item_id,
            "research_result_id": second_result.json()["id"],
            "period_start": "2026-07-20",
            "period_end": "2026-07-20",
        },
    )
    assert second_comparison.status_code == 409

    cash_only = await client.post(
        "/api/finance/assets/hl/import-preview",
        params={"space_id": space_id},
        headers=adult_a_headers,
        json={
            "label": "HL ISA",
            "account_wrapper": "ISA",
            "as_of_date": "2026-07-01",
            "currency": "GBP",
            "cash_value_minor": 10_000,
            "reported_total_minor": 10_000,
            "holdings": [],
            "activities": [
                {
                    "activity_type": "CONTRIBUTION",
                    "occurred_on": "2026-06-01",
                    "amount_minor": 10_000,
                    "currency": "GBP",
                    "description": "Reviewed cash contribution",
                }
            ],
        },
    )
    assert cash_only.status_code == 201, cash_only.text
    assert cash_only.json()["can_confirm"] is True
    confirmed = await client.post(
        f"/api/finance/assets/hl/previews/{cash_only.json()['id']}/confirm",
        headers=adult_a_headers,
        json={"reviewed": True},
    )
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()["position_count"] == 1

    unreconciled = await client.post(
        "/api/finance/assets/hl/import-preview",
        params={"space_id": space_id},
        headers=adult_a_headers,
        json={
            "label": "HL general",
            "account_wrapper": "GENERAL",
            "as_of_date": "2026-07-02",
            "currency": "GBP",
            "cash_value_minor": 0,
            "reported_total_minor": 200,
            "holdings": [
                {
                    "asset_key": "fund:one",
                    "asset_name": "Example fund",
                    "asset_class": "BROKERAGE_INVESTMENT",
                    "quantity": "1",
                    "quantity_unit": "unit",
                    "value_minor": 100,
                    "price_source": "Reviewed report",
                }
            ],
        },
    )
    assert unreconciled.status_code == 201, unreconciled.text
    assert unreconciled.json()["can_confirm"] is False
    rejected_confirm = await client.post(
        f"/api/finance/assets/hl/previews/{unreconciled.json()['id']}/confirm",
        headers=adult_a_headers,
        json={"reviewed": True},
    )
    assert rejected_confirm.status_code == 409

    rejected_secret = await client.post(
        "/api/finance/assets/watch-addresses",
        params={"space_id": space_id},
        headers=adult_a_headers,
        json={
            "source_kind": "SOLANA_PUBLIC",
            "label": "seed phrase backup",
            "public_address": "11111111111111111111111111111111",
        },
    )
    assert rejected_secret.status_code == 422
    wrong_length_key = await client.post(
        "/api/finance/assets/watch-addresses",
        params={"space_id": space_id},
        headers=adult_a_headers,
        json={
            "source_kind": "SOLANA_PUBLIC",
            "label": "Looks public but decodes wrongly",
            "public_address": "21111111111111111111111111111111",
        },
    )
    assert wrong_length_key.status_code == 422
    watch = await client.post(
        "/api/finance/assets/watch-addresses",
        params={"space_id": space_id},
        headers=adult_a_headers,
        json={
            "source_kind": "SOLANA_PUBLIC",
            "label": "Public Solana wallet",
            "public_address": "11111111111111111111111111111111",
        },
    )
    assert watch.status_code == 201, watch.text
    empty_snapshot = await client.post(
        f"/api/finance/assets/sources/{watch.json()['id']}/snapshots",
        headers=adult_a_headers,
        json={
            "reviewed": True,
            "as_of_at": "2026-07-20T12:00:00+00:00",
            "currency": "GBP",
            "positions": [],
        },
    )
    assert empty_snapshot.status_code == 201, empty_snapshot.text
    assert empty_snapshot.json()["data_status"] == "COMPLETE"
    assert empty_snapshot.json()["position_count"] == 0
    watch_snapshot_body = {
        "reviewed": True,
        "as_of_at": "2026-07-21T12:00:00+00:00",
        "currency": "GBP",
        "positions": [
            {
                "asset_key": "solana:SOL",
                "asset_name": "Solana",
                "asset_class": "VOLATILE_CRYPTO",
                "quantity": "1.5",
                "quantity_unit": "SOL",
                "value_minor": None,
            }
        ],
    }
    snapshot = await client.post(
        f"/api/finance/assets/sources/{watch.json()['id']}/snapshots",
        headers=adult_a_headers,
        json=watch_snapshot_body,
    )
    assert snapshot.status_code == 201, snapshot.text
    assert snapshot.json()["data_status"] == "PARTIAL"
    private = await client.post(
        f"/api/finance/assets/sources/{watch.json()['id']}/snapshots",
        headers=adult_b_headers,
        json={**watch_snapshot_body, "as_of_at": "2026-07-22T12:00:00+00:00"},
    )
    assert private.status_code == 404
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE finance_asset_sources SET status = 'PAUSED' WHERE id = ?",
            (watch.json()["id"],),
        )
        await db.commit()
    summary = await client.get(
        "/api/finance/assets/summary",
        params={"space_id": space_id, "currency": "GBP"},
        headers=adult_a_headers,
    )
    assert summary.status_code == 200, summary.text
    assert summary.json()["total_net_worth_minor"] == 10_000
    assert summary.json()["known_net_worth_minor"] == 10_000
    assert summary.json()["data_through"].startswith("2026-07-01")
    volatile = next(
        layer for layer in summary.json()["layers"] if layer["layer"] == "VOLATILE_CRYPTO"
    )
    assert volatile["amount_minor"] == 0
    assert volatile["unknown_component_count"] == 1
    assert "paused" in volatile["note"]

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO finance_categories
                (id, space_id, name, family_id, created_by)
            VALUES ('category-breakfast', ?, 'Breakfast', ?, ?)
            """,
            (space_id, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_merchants
                (id, space_id, name, family_id, created_by)
            VALUES ('merchant-assigned', ?, 'Assigned grocer', ?, ?)
            """,
            (space_id, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.executemany(
            """
            INSERT INTO finance_assignments
                (id, space_id, target_type, target_id, assignment_type,
                 assigned_value_id, source, status, confidence_bps, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, 'USER', 'CONFIRMED', 10000, ?, ?, ?, ?)
            """,
            [
                (
                    "line-category-assignment",
                    space_id,
                    "PURCHASE_LINE",
                    line_id,
                    "CATEGORY",
                    "category-breakfast",
                    adult_a_user["family_id"],
                    "2026-07-20T10:00:00Z",
                    "2026-07-20T10:00:00Z",
                    adult_a_user["id"],
                ),
                (
                    "purchase-merchant-assignment",
                    space_id,
                    "PURCHASE",
                    purchase["id"],
                    "MERCHANT",
                    "merchant-assigned",
                    adult_a_user["family_id"],
                    "2026-07-20T10:00:00Z",
                    "2026-07-20T10:00:00Z",
                    adult_a_user["id"],
                ),
            ],
        )
        await db.commit()

    for grouping, expected in (
        ("CATEGORY", "Breakfast"),
        ("MERCHANT", "Assigned grocer"),
        ("DECISION_QUALITY", "sensible"),
        ("OUTCOME", "valued"),
        ("ITEMISATION", "ITEMISED"),
    ):
        analysis = await client.post(
            "/api/finance/analysis",
            headers=adult_a_headers,
            json={
                "space_id": space_id,
                "basis": "PURCHASE_LINES",
                "start_date": "2026-07-20",
                "end_date": "2026-07-20",
                "currency": "GBP",
                "grouping": grouping,
                "measure": "SPEND",
                "refund_policy": "NET",
            },
        )
        assert analysis.status_code == 200, analysis.text
        assert analysis.json()["groups"][0]["key"] == expected
        assert analysis.json()["groups"][0]["value"] == {
            "numerator": 250,
            "denominator": 1,
        }

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO finance_accounts
                (id, space_id, label, account_type, purpose, currency,
                 family_id, created_by)
            VALUES ('analysis-current', ?, 'Analysis current', 'CURRENT',
                    'OPERATING_CURRENT', 'GBP', ?, ?)
            """,
            (space_id, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.executemany(
            """
            INSERT INTO finance_transactions
                (id, space_id, account_id, canonical_date, amount_minor, currency,
                 state, source_kind, description, cleaned_description,
                 data_through_at, family_id, created_by)
            VALUES (?, ?, 'analysis-current', '2026-07-20', ?, 'GBP', 'POSTED',
                    'MANUAL', ?, ?, '2026-07-20T12:00:00Z', ?, ?)
            """,
            [
                (
                    "analysis-spend",
                    space_id,
                    -1_000,
                    "Original purchase",
                    "Original purchase",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
                (
                    "analysis-refund",
                    space_id,
                    200,
                    "Partial refund",
                    "Partial refund",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
                (
                    "analysis-income",
                    space_id,
                    5_000,
                    "Salary credit",
                    "Salary credit",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            ],
        )
        await db.execute(
            """
            INSERT INTO finance_transaction_relations
                (id, space_id, from_transaction_id, to_transaction_id,
                 relation_type, status, method, confidence_bps, family_id, created_by)
            VALUES ('analysis-refund-link', ?, 'analysis-spend', 'analysis-refund',
                    'REFUND', 'CONFIRMED', 'REVIEWED', 10000, ?, ?)
            """,
            (space_id, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    spending = await client.post(
        "/api/finance/analysis",
        headers=adult_a_headers,
        json={
            "space_id": space_id,
            "basis": "TRANSACTIONS",
            "start_date": "2026-07-20",
            "end_date": "2026-07-20",
            "currency": "GBP",
            "grouping": "TOTAL",
            "measure": "MEAN_SPEND",
            "refund_policy": "NET",
        },
    )
    assert spending.status_code == 200, spending.text
    assert spending.json()["total"] == {"numerator": 400, "denominator": 1}
    assert spending.json()["groups"][0]["record_count"] == 2
    assert {item["record_id"] for item in spending.json()["evidence"]} == {
        "analysis-spend",
        "analysis-refund",
    }
    income = await client.post(
        "/api/finance/analysis",
        headers=adult_a_headers,
        json={
            "space_id": space_id,
            "basis": "TRANSACTIONS",
            "start_date": "2026-07-20",
            "end_date": "2026-07-20",
            "currency": "GBP",
            "grouping": "TOTAL",
            "measure": "INCOME",
            "refund_policy": "NET",
        },
    )
    assert income.status_code == 200, income.text
    assert income.json()["total"] == {"numerator": 5_000, "denominator": 1}
    assert income.json()["groups"][0]["record_count"] == 1
    assert [item["record_id"] for item in income.json()["evidence"]] == [
        "analysis-income"
    ]

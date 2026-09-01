from datetime import date, datetime, timezone

import aiosqlite
import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.ledger import create_finance_account, import_source_transactions



def _source(
    source_id: str,
    day: date,
    amount_minor: int,
    description: str,
    *,
    merchant: str | None = None,
) -> NormalisedSourceTransaction:
    return NormalisedSourceTransaction(
        source_kind="PROVIDER",
        source_batch_id="pattern-fixture",
        source_transaction_id=source_id,
        booking_date=day,
        pending_status="POSTED",
        amount_minor=amount_minor,
        currency="GBP",
        description=description,
        merchant_text=merchant,
        observed_at=datetime(2026, 8, 1, 12, tzinfo=timezone.utc),
    )


async def _add_purchase_evidence(
    db_path: str,
    *,
    user: dict,
    space_id: str,
) -> None:
    now = "2026-08-01T12:00:00+00:00"
    family_id = user["family_id"]
    async with aiosqlite.connect(db_path) as db:
        for position, (day, amount, unit_price, outcome, plannedness) in enumerate(
            (
                ("2025-12-10", 5_000, 1_000, "neutral", "planned"),
                ("2026-01-10", 1_000, 1_100, "returned", "replacement"),
                ("2026-02-01", 1_100, 1_200, "returned", "replacement"),
                ("2026-03-01", 1_200, 1_300, "regretted", "replacement"),
            )
        ):
            source_id = f"gadget-source-{position}"
            purchase_id = f"gadget-purchase-{position}"
            line_id = f"gadget-line-{position}"
            await db.execute(
                """
                INSERT INTO finance_purchase_sources
                    (id, space_id, external_source_id, source_kind,
                     extraction_status, confidence_bps, raw_payload_json,
                     received_at, parsed_at, family_id, created_by)
                VALUES (?, ?, ?, 'amazon_email', 'PARSED', 10000, '{}', ?, ?, ?, ?)
                """,
                (source_id, space_id, source_id, now, now, family_id, user["id"]),
            )
            await db.execute(
                """
                INSERT INTO finance_purchase_records
                    (id, space_id, source_id, purchase_ref, merchant_name,
                     purchased_on, currency, lines_subtotal_minor,
                     final_total_minor, status, source_kind,
                     extraction_confidence_bps, family_id, created_by)
                VALUES (?, ?, ?, ?, 'Example Shop', ?, 'GBP', ?, ?, 'fulfilled',
                        'amazon_email', 10000, ?, ?)
                """,
                (
                    purchase_id,
                    space_id,
                    source_id,
                    purchase_id,
                    day,
                    amount,
                    amount,
                    family_id,
                    user["id"],
                ),
            )
            await db.execute(
                """
                INSERT INTO finance_purchase_lines
                    (id, space_id, source_id, purchase_id, source_line_reference,
                     line_position, line_kind, raw_description, quantity_decimal,
                     unit_description, unit_price_minor, line_gross_minor,
                     line_discount_minor, line_net_minor, evidence_status,
                     source_refs_json, replaces_description, family_id, created_by)
                VALUES (?, ?, ?, ?, ?, 0, 'product', 'Small gadget', '1', 'each',
                        ?, ?, 0, ?, 'user_confirmed', '[]', ?, ?, ?)
                """,
                (
                    line_id,
                    space_id,
                    source_id,
                    purchase_id,
                    line_id,
                    unit_price,
                    amount,
                    amount,
                    "Earlier gadget" if position else None,
                    family_id,
                    user["id"],
                ),
            )
            await db.execute(
                """
                INSERT INTO finance_purchase_line_assessments
                    (id, space_id, line_id, normalized_item_id, beneficiary,
                     purpose, plannedness, utility, decision_quality,
                     value_for_money, outcome_state, classification_source,
                     confidence_bps, review_status, family_id, created_by)
                VALUES (?, ?, ?, 'gadget-item', 'Household', 'convenience', ?,
                        'optional', 'questionable', 'poor', ?, 'USER', 10000,
                        'CONFIRMED', ?, ?)
                """,
                (
                    f"gadget-assessment-{position}",
                    space_id,
                    line_id,
                    plannedness,
                    outcome,
                    family_id,
                    user["id"],
                ),
            )

        await db.execute(
            """
            INSERT INTO finance_normalized_purchase_items
                (id, space_id, identity_key, display_name, item_kind,
                 family_id, created_by)
            VALUES ('gadget-item', ?, 'small_gadget', 'Small gadget', 'product', ?, ?)
            """,
            (space_id, family_id, user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_purchase_sources
                (id, space_id, external_source_id, source_kind,
                 extraction_status, confidence_bps, raw_payload_json,
                 received_at, parsed_at, family_id, created_by)
            VALUES ('large-source', ?, 'large-source', 'natural_language',
                    'PARSED', 10000, '{}', ?, ?, ?, ?)
            """,
            (space_id, now, now, family_id, user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_purchase_records
                (id, space_id, source_id, purchase_ref, merchant_name,
                 purchased_on, currency, lines_subtotal_minor,
                 final_total_minor, status, source_kind,
                 extraction_confidence_bps, family_id, created_by)
            VALUES ('large-purchase', ?, 'large-source', 'large-purchase',
                    'Broad Retailer', '2026-07-25', 'GBP', 30000, 30000,
                    'fulfilled', 'natural_language', 10000, ?, ?)
            """,
            (space_id, family_id, user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_purchase_lines
                (id, space_id, source_id, purchase_id, source_line_reference,
                 line_position, line_kind, raw_description, quantity_decimal,
                 line_gross_minor, line_discount_minor, line_net_minor,
                 evidence_status, source_refs_json, family_id, created_by)
            VALUES ('large-line', ?, 'large-source', 'large-purchase', 'remainder',
                    0, 'unknown', 'Unitemised remainder', '1', 30000, 0, 30000,
                    'unitemised', '[]', ?, ?)
            """,
            (space_id, family_id, user["id"]),
        )
        await db.commit()


@pytest.mark.asyncio
async def test_saved_patterns_opportunities_and_material_questions_are_actionable(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    space_id = next(item["id"] for item in spaces if item["kind"] == "personal")
    await client.get("/api/finance/spaces", headers=adult_b_headers)

    protected = await client.post(
        "/api/finance/preferences",
        params={"space_id": space_id},
        json={
            "preference_key": "protect.coffee",
            "statement": "Coffee is a protected daily quality-of-life cost.",
            "value_kind": "PROTECTED",
        },
        headers=adult_a_headers,
    )
    assert protected.status_code == 201
    confirmed = await client.post(
        f"/api/finance/preferences/{protected.json()['id']}/confirm",
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 200

    async with standalone_db(initialized_db) as db:
        account = await create_finance_account(
            db,
            user=adult_a_user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Current account",
                institution="Fixture Bank",
                account_type="CURRENT",
                currency="GBP",
            ),
        )
        sources = []
        salary_dates = (
            date(2026, 1, 30),
            date(2026, 2, 27),
            date(2026, 3, 31),
            date(2026, 4, 30),
            date(2026, 5, 29),
            date(2026, 6, 30),
            date(2026, 7, 31),
        )
        for index, day in enumerate(salary_dates):
            sources.append(
                _source(
                    f"salary-{index}",
                    day,
                    500_000,
                    "Monthly pay",
                    merchant="Example School Payroll",
                )
            )
            sources.append(
                _source(
                    f"energy-{index}",
                    day,
                    -(10_000 + index * 500),
                    "Direct Debit Energy",
                    merchant="British Gas",
                )
            )
            sources.append(
                _source(
                    f"spotify-{index}",
                    day,
                    -1_199,
                    "Music subscription",
                    merchant="Spotify",
                )
            )
        for index, day in enumerate(
            (
                date(2026, 4, 1),
                date(2026, 4, 29),
                date(2026, 5, 27),
                date(2026, 6, 24),
                date(2026, 7, 22),
            )
        ):
            sources.append(
                _source(f"cleaner-{index}", day, -4_000, "Family cleaner")
            )
        for index, day in enumerate(
            (date(2025, 7, 15), date(2026, 7, 15))
        ):
            sources.append(
                _source(f"insurance-{index}", day, -75_000, "Annual Insurance")
            )
        for index, day in enumerate(
            (date(2026, 1, 6), date(2026, 4, 6), date(2026, 7, 6))
        ):
            sources.append(
                _source(f"nursery-{index}", day, -90_000, "Nursery Fees")
            )
        for index, (day, amount) in enumerate(
            (
                (date(2026, 2, 10), -1_000),
                (date(2026, 3, 10), -1_000),
                (date(2026, 4, 10), -1_000),
                (date(2026, 5, 10), -2_500),
                (date(2026, 6, 10), -2_500),
                (date(2026, 7, 10), -2_500),
            )
        ):
            sources.append(_source(f"snack-{index}", day, amount, "Snack"))
            sources.append(_source(f"coffee-{index}", day, -2_500, "Coffee"))
        for index, day in enumerate(
            (date(2026, 5, 4), date(2026, 6, 4), date(2026, 7, 4))
        ):
            sources.append(
                _source(
                    f"unknown-income-{index}",
                    day,
                    30_000,
                    "Family credit",
                )
            )
        sources.append(
            _source(
                "card-repayment",
                date(2026, 7, 20),
                -25_000,
                "Amex card repayment",
            )
        )
        await import_source_transactions(
            db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account.id,
            observations=sources,
        )
    await _add_purchase_evidence(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
    )

    response = await client.post(
        "/api/finance/patterns/scan",
        params={"space_id": space_id, "as_of": "2026-08-01"},
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    scan = response.json()
    assert scan["data_through_date"] == "2026-07-31"
    assert scan["combined_saving_low_minor"] == 0
    assert scan["combined_saving_high_minor"] == 0

    recurring = scan["recurring_series"]
    salary = next(item for item in recurring if item["series_type"] == "SALARY")
    assert salary["interval_kind"] == "MONTHLY"
    assert salary["next_expected_date"] == "2026-08-28"
    assert salary["low_minor"] == salary["high_minor"] == 500_000
    assert any(
        item["series_type"] == "BILL" and item["interval_kind"] == "MONTHLY"
        for item in recurring
    )
    assert any(
        item["series_type"] == "SUBSCRIPTION" for item in recurring
    )
    assert any(item["interval_kind"] == "FOUR_WEEKLY" for item in recurring)
    assert any(item["interval_kind"] == "ANNUAL" for item in recurring)
    assert any(item["interval_kind"] == "IRREGULAR" for item in recurring)
    assert all("FAMILY CREDIT" not in item["detection_key"] for item in recurring)

    findings = scan["findings"]
    finding_types = {item["finding_type"] for item in findings}
    assert {
        "TREND_CHANGE",
        "ANNUALISED_SMALL_COST",
        "SEASONAL",
        "PRICE_DRIFT",
        "DUPLICATE_REPLACEMENT",
        "REPEATED_RETURN",
    } <= finding_types
    assert not any("coffee" in item["title"].lower() for item in findings)
    assert all(
        item["saving_low_minor"] == item["saving_high_minor"] == 0
        for item in findings
    )
    snack_groups = {
        item["overlap_group"]
        for item in findings
        if "snack" in item["title"].lower()
    }
    assert snack_groups == {"cost:snack"}

    questions = {item["question_kind"]: item for item in scan["questions"]}
    assert set(questions) == {
        "SALARY",
        "NURSERY",
        "MISSING_CARD",
        "LARGE_UNITEMISED_PURCHASE",
    }
    assert questions["SALARY"]["next_action_route"].endswith(
        f"/questions/{questions['SALARY']['id']}/confirm"
    )
    assert questions["MISSING_CARD"]["next_action_route"] == (
        "/?view=finance&section=setup"
    )
    assert questions["LARGE_UNITEMISED_PURCHASE"]["next_action_route"].endswith(
        "/large-source"
    )

    private_probe = await client.get(
        "/api/finance/questions",
        params={"space_id": space_id},
        headers=adult_b_headers,
    )
    assert private_probe.status_code == 404

    salary_answer = await client.post(
        f"/api/finance/questions/{questions['SALARY']['id']}/confirm",
        json={"answer_text": "Yes"},
        headers=adult_a_headers,
    )
    assert salary_answer.status_code == 200
    assert salary_answer.json()["status"] == "CONFIRMED"
    series_after_confirm = await client.get(
        "/api/finance/recurring-series",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    saved_salary = next(
        item for item in series_after_confirm.json() if item["id"] == salary["id"]
    )
    assert saved_salary["status"] == "CONFIRMED"

    nursery_answer = await client.put(
        f"/api/finance/questions/{questions['NURSERY']['id']}/correct",
        json={
            "answer_text": "The confirmed nursery plan.",
            "nursery_expected_minor": 85_000,
            "nursery_due_dates": ["2026-09-01", "2026-10-01"],
        },
        headers=adult_a_headers,
    )
    assert nursery_answer.status_code == 200, nursery_answer.text
    assert nursery_answer.json()["status"] == "CORRECTED"
    facts = await client.get(
        "/api/finance/facts",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    nursery_fact = next(item for item in facts.json() if item["fact_key"] == "nursery.schedule")
    assert nursery_fact["status"] == "CONFIRMED"
    commitments = await client.get(
        "/api/finance/commitments",
        params={"space_id": space_id, "as_of": "2026-08-01"},
        headers=adult_a_headers,
    )
    nursery_commitment = next(item for item in commitments.json() if item["name"] == "Nursery")
    assert nursery_commitment["exact_minor"] == 85_000
    assert nursery_commitment["reviewed_dates"] == ["2026-09-01", "2026-10-01"]

    card_before = await client.post(
        f"/api/finance/questions/{questions['MISSING_CARD']['id']}/confirm",
        json={},
        headers=adult_a_headers,
    )
    assert card_before.status_code == 409
    item_before = await client.post(
        f"/api/finance/questions/{questions['LARGE_UNITEMISED_PURCHASE']['id']}/confirm",
        json={},
        headers=adult_a_headers,
    )
    assert item_before.status_code == 409

    async with standalone_db(initialized_db) as db:
        await create_finance_account(
            db,
            user=adult_a_user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Credit card",
                institution="Fixture Bank",
                account_type="CREDIT_CARD",
                currency="GBP",
            ),
        )
        await db.execute(
            "UPDATE finance_purchase_lines SET evidence_status = 'user_confirmed', "
            "raw_description = 'Furniture and household items' WHERE id = 'large-line'",
        )
        await db.commit()

    card_after = await client.post(
        f"/api/finance/questions/{questions['MISSING_CARD']['id']}/confirm",
        json={},
        headers=adult_a_headers,
    )
    assert card_after.status_code == 200
    item_after = await client.post(
        f"/api/finance/questions/{questions['LARGE_UNITEMISED_PURCHASE']['id']}/confirm",
        json={},
        headers=adult_a_headers,
    )
    assert item_after.status_code == 200

    subscription = next(
        item for item in recurring if item["series_type"] == "SUBSCRIPTION"
    )
    dismissed = await client.post(
        f"/api/finance/recurring-series/{subscription['id']}/dismiss",
        headers=adult_a_headers,
    )
    assert dismissed.status_code == 200
    assert dismissed.json()["status"] == "REJECTED"

    rescanned = await client.post(
        "/api/finance/patterns/scan",
        params={"space_id": space_id, "as_of": "2026-08-01"},
        headers=adult_a_headers,
    )
    assert rescanned.status_code == 200, rescanned.text
    all_series = await client.get(
        "/api/finance/recurring-series",
        params={"space_id": space_id, "include_inactive": True},
        headers=adult_a_headers,
    )
    rejected = next(item for item in all_series.json() if item["id"] == subscription["id"])
    assert rejected["status"] == "REJECTED"
    async with aiosqlite.connect(initialized_db) as db:
        history_tables = {
            row[0]
            for row in await (
                await db.execute(
                    "SELECT DISTINCT table_name FROM record_history "
                    "WHERE table_name IN ('finance_recurring_series', 'finance_findings')"
                )
            ).fetchall()
        }
    assert history_tables == {"finance_recurring_series", "finance_findings"}

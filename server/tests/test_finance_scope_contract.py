import pytest

from app.database import standalone_db
from app.services.finance.foundation import accessible_finance_spaces


async def _spaces(db_path: str, user: dict) -> dict[str, str]:
    async with standalone_db(db_path) as db:
        return {
            space.kind: space.id
            for space in await accessible_finance_spaces(db, user=user)
        }


async def _ledger_row(
    db,
    *,
    user: dict,
    space_id: str,
    prefix: str,
    amount_minor: int,
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
        VALUES (?, ?, ?, '2026-08-01', ?, 'GBP', 'POSTED', 'CASEY',
                'MANUAL', ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            f"{prefix}-transaction",
            space_id,
            f"{prefix}-account",
            amount_minor,
            description,
            description.upper(),
            now,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )


@pytest.mark.asyncio
async def test_my_finances_combines_own_and_household_without_partner_or_double_counting(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
):
    adult_a_spaces = await _spaces(initialized_db, adult_a_user)
    adult_b_spaces = await _spaces(initialized_db, adult_b_user)
    now = "2026-08-03T08:00:00+00:00"
    async with standalone_db(initialized_db) as db:
        await _ledger_row(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["personal"],
            prefix="dom",
            amount_minor=-1_000,
            description="Alex private",
        )
        await _ledger_row(
            db,
            user=adult_b_user,
            space_id=adult_b_spaces["personal"],
            prefix="kat",
            amount_minor=-9_000,
            description="Morgan private",
        )
        await _ledger_row(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["household"],
            prefix="household",
            amount_minor=-2_000,
            description="Household original",
        )
        await _ledger_row(
            db,
            user=adult_a_user,
            space_id=adult_a_spaces["household"],
            prefix="dom-shared-copy",
            amount_minor=-1_000,
            description="Alex private shared copy",
        )
        await db.execute(
            """
            INSERT INTO finance_share_actions
                (id, owner_user_id, source_space_id, household_space_id,
                 share_kind, source_record_type, source_record_id,
                 selection_json, selection_digest, status,
                 household_record_type, household_record_id, family_id,
                 created_at, updated_at, created_by)
            VALUES ('dom-share', ?, ?, ?, 'TRANSACTION', 'transaction',
                    'dom-transaction', '[]', '', 'COMPLETED', 'transaction',
                    'dom-shared-copy-transaction', ?, ?, ?, ?)
            """,
            (
                adult_a_user["id"],
                adult_a_spaces["personal"],
                adult_a_spaces["household"],
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_share_copy_links
                (id, share_action_id, source_space_id, source_record_type,
                 source_record_id, household_space_id, household_record_type,
                 household_record_id, family_id, created_at, updated_at, created_by)
            VALUES ('dom-copy-link', 'dom-share', ?, 'transaction',
                    'dom-transaction', ?, 'transaction',
                    'dom-shared-copy-transaction', ?, ?, ?, ?)
            """,
            (
                adult_a_spaces["personal"],
                adult_a_spaces["household"],
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        for identifier, space_id, name, target in (
            ("personal-goal", adult_a_spaces["personal"], "Personal buffer", 10_000),
            ("household-goal", adult_a_spaces["household"], "Family holiday", 20_000),
        ):
            await db.execute(
                """
                INSERT INTO finance_goals
                    (id, space_id, name, target_minor, deadline,
                     currently_allocated_minor, currency, priority,
                     allowed_funding_sources_json, emergency_buffer_minor, status,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, '2027-08-01', 0, 'GBP', 'IMPORTANT',
                        '[]', 0, 'ACTIVE', ?, ?, ?, ?)
                """,
                (
                    identifier,
                    space_id,
                    name,
                    target,
                    adult_a_user["family_id"],
                    now,
                    now,
                    adult_a_user["id"],
                ),
            )
        await db.commit()

    mine = await client.get(
        "/api/finance/summary",
        params={"space_id": adult_a_spaces["personal"], "scope": "mine"},
        headers=adult_a_headers,
    )
    household = await client.get(
        "/api/finance/summary",
        params={"space_id": adult_a_spaces["household"], "scope": "household"},
        headers=adult_a_headers,
    )
    partner_selector = await client.get(
        "/api/finance/summary",
        params={"space_id": adult_b_spaces["personal"], "scope": "mine"},
        headers=adult_a_headers,
    )
    assert mine.status_code == household.status_code == 200
    assert partner_selector.status_code == 422
    assert mine.json()["space_ids"] == [
        adult_a_spaces["personal"],
        adult_a_spaces["household"],
    ]
    assert mine.json()["currencies"][0]["gross_spending_minor"] == 3_000
    assert household.json()["currencies"][0]["gross_spending_minor"] == 3_000

    analysis = await client.post(
        "/api/finance/analysis",
        json={
            "space_id": adult_a_spaces["personal"],
            "scope": "mine",
            "basis": "TRANSACTIONS",
            "start_date": "2026-08-01",
            "end_date": "2026-08-03",
            "currency": "GBP",
            "grouping": "ACCOUNT",
        },
        headers=adult_a_headers,
    )
    assert analysis.status_code == 200
    assert analysis.json()["total"] == {"numerator": 3_000, "denominator": 1}
    evidence = {item["record_id"] for item in analysis.json()["evidence"]}
    assert evidence == {"dom-transaction", "household-transaction"}
    assert "kat-transaction" not in evidence
    assert "dom-shared-copy-transaction" not in evidence

    personal_goals = await client.get(
        "/api/finance/goals",
        params={"space_id": adult_a_spaces["personal"], "as_of": "2026-08-03"},
        headers=adult_a_headers,
    )
    household_goals = await client.get(
        "/api/finance/goals",
        params={"space_id": adult_a_spaces["household"], "as_of": "2026-08-03"},
        headers=adult_a_headers,
    )
    assert {goal["name"] for goal in personal_goals.json()} == {"Personal buffer"}
    assert {goal["name"] for goal in household_goals.json()} == {"Family holiday"}


@pytest.mark.asyncio
async def test_my_finances_purchase_analysis_excludes_partner_and_own_household_copy(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_spaces = await _spaces(initialized_db, adult_a_user)
    adult_b_spaces = await _spaces(initialized_db, adult_b_user)

    async def add_purchase(
        *,
        headers: dict,
        space_id: str,
        source_id: str,
        description: str,
        amount_minor: int,
    ):
        response = await client.post(
            "/api/finance/purchases/evidence",
            params={"space_id": space_id},
            headers=headers,
            json={
                "external_source_id": source_id,
                "adapter": "e_receipt",
                "reviewed": True,
                "payload": {
                    "source_id": source_id,
                    "purchase_reference": source_id,
                    "merchant": "Scope Test Shop",
                    "purchased_at": "2026-08-02",
                    "currency": "GBP",
                    "lines": [
                        {
                            "line_reference": "line-1",
                            "description": description,
                            "net_minor": amount_minor,
                        }
                    ],
                    "final_total_minor": amount_minor,
                },
            },
        )
        assert response.status_code == 201, response.text
        return response.json()["purchase"]

    personal = await add_purchase(
        headers=adult_a_headers,
        space_id=adult_a_spaces["personal"],
        source_id="dom-scope-purchase",
        description="Alex private purchase",
        amount_minor=1_000,
    )
    partner = await add_purchase(
        headers=adult_b_headers,
        space_id=adult_b_spaces["personal"],
        source_id="kat-scope-purchase",
        description="Morgan private purchase",
        amount_minor=9_000,
    )
    household = await add_purchase(
        headers=adult_a_headers,
        space_id=adult_a_spaces["household"],
        source_id="household-scope-purchase",
        description="Household purchase",
        amount_minor=2_000,
    )
    shared = await client.post(
        f"/api/finance/shares/purchases/{personal['id']}",
        headers=adult_a_headers,
        json={
            "mode": "SELECTED_LINES",
            "line_ids": [personal["lines"][0]["id"]],
        },
    )
    assert shared.status_code == 200, shared.text

    request = {
        "basis": "PURCHASE_LINES",
        "start_date": "2026-08-01",
        "end_date": "2026-08-03",
        "currency": "GBP",
        "grouping": "TOTAL",
        "measure": "SPEND",
        "comparison": "NONE",
        "filters": {},
    }
    mine = await client.post(
        "/api/finance/analysis",
        headers=adult_a_headers,
        json={
            **request,
            "space_id": adult_a_spaces["personal"],
            "scope": "mine",
        },
    )
    household_only = await client.post(
        "/api/finance/analysis",
        headers=adult_a_headers,
        json={
            **request,
            "space_id": adult_a_spaces["household"],
            "scope": "household",
        },
    )

    assert mine.status_code == household_only.status_code == 200
    assert mine.json()["total"] == {"numerator": 3_000, "denominator": 1}
    assert household_only.json()["total"] == {
        "numerator": 3_000,
        "denominator": 1,
    }
    mine_evidence = {item["record_id"] for item in mine.json()["evidence"]}
    assert personal["lines"][0]["id"] in mine_evidence
    assert household["lines"][0]["id"] in mine_evidence
    assert partner["lines"][0]["id"] not in mine_evidence

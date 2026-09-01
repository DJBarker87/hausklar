from datetime import date, datetime, timezone

import aiosqlite
import pytest

from app.database import init_db, standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.categorisation import ensure_default_categories
from app.services.finance.foundation import accessible_finance_spaces
from app.services.finance.ledger import create_finance_account, import_source_transactions
from app.services.finance import monthly_overview


async def _personal_space(db_path: str, user: dict) -> str:
    async with standalone_db(db_path) as db:
        spaces = await accessible_finance_spaces(db, user=user)
    return next(space.id for space in spaces if space.kind == "personal")


async def _account(db_path: str, user: dict, space_id: str):
    async with standalone_db(db_path) as db:
        return await create_finance_account(
            db,
            user=user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Current account",
                institution="Fixture Bank",
                account_type="CURRENT",
                currency="GBP",
            ),
        )


def _source(
    identifier: str,
    *,
    amount_minor: int,
    description: str,
    merchant_text: str | None = None,
    bank_code: str | None = None,
    bank_sub_code: str | None = None,
    merchant_category_code: str | None = None,
) -> NormalisedSourceTransaction:
    return NormalisedSourceTransaction(
        source_kind="PROVIDER",
        source_batch_id="categorisation-test",
        source_transaction_id=identifier,
        booking_date=date(2026, 8, 5),
        pending_status="POSTED",
        amount_minor=amount_minor,
        currency="GBP",
        description=description,
        merchant_text=merchant_text,
        bank_code=bank_code,
        bank_sub_code=bank_sub_code,
        merchant_category_code=merchant_category_code,
        observed_at=datetime(2026, 8, 5, 12, 0, tzinfo=timezone.utc),
    )


@pytest.mark.asyncio
async def test_provider_classification_is_retained_and_drives_the_visible_category(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = await _personal_space(initialized_db, adult_a_user)
    account = await _account(initialized_db, adult_a_user, space_id)
    async with standalone_db(initialized_db) as db:
        imported = await import_source_transactions(
            db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account.id,
            observations=[
                _source(
                    "provider-groceries",
                    amount_minor=-4275,
                    description="A broad retailer description",
                    merchant_text="Example shop",
                    bank_code="PURCHASE",
                    bank_sub_code="Food shopping",
                )
            ],
        )

    response = await client.get(
        "/api/finance/transactions",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    assert response.json()[0]["primary_category_name"] == "Food shopping"
    assert response.json()[0]["primary_spending_type"] == "FLEXIBLE"

    async with aiosqlite.connect(initialized_db) as db:
        source = await (
            await db.execute(
                """
                SELECT bank_code, bank_sub_code
                FROM finance_source_transactions
                WHERE source_transaction_id = 'provider-groceries'
                """
            )
        ).fetchone()
        assignment = await (
            await db.execute(
                """
                SELECT source, status, confidence_bps
                FROM finance_assignments
                WHERE target_type = 'TRANSACTION' AND target_id = ?
                  AND assignment_type = 'CATEGORY'
                """,
                (imported.transaction_ids[0],),
            )
        ).fetchone()
    assert source == ("PURCHASE", "Food shopping")
    assert assignment == ("RULE", "CONFIRMED", 9500)


@pytest.mark.asyncio
async def test_monthly_spending_uses_categories_but_excludes_saving_and_transfers(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(monthly_overview, "_today", lambda _timezone: date(2026, 8, 10))
    space_id = await _personal_space(initialized_db, adult_a_user)
    account = await _account(initialized_db, adult_a_user, space_id)
    async with standalone_db(initialized_db) as db:
        await import_source_transactions(
            db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account.id,
            observations=[
                _source(
                    "netflix",
                    amount_minor=-999,
                    description="NETFLIX.COM",
                    merchant_text="Netflix",
                ),
                _source(
                    "unknown",
                    amount_minor=-1200,
                    description="Unrecognised local merchant",
                ),
                _source(
                    "hl-saving",
                    amount_minor=-5000,
                    description="HLAM REGULAR SAVING INITIAL PAYMENT",
                ),
                _source(
                    "own-transfer",
                    amount_minor=-1000,
                    description="TO A C JOINT ACCOUNT VIA MOBILE XFER",
                    bank_code="TRANSFER",
                ),
            ],
        )

    response = await client.get(
        "/api/finance/overview",
        params={"scope": "mine"},
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    overview = response.json()
    assert overview["spending_minor"] == 2199
    assert {
        item["name"]: item["spent_minor"] for item in overview["spending_by_category"]
    } == {
        "Other": 1200,
        "Entertainment & subscriptions": 999,
    }
    assert sum(item["share_bps"] for item in overview["spending_by_category"]) == 10_000


@pytest.mark.asyncio
async def test_startup_backfill_is_idempotent_and_preserves_manual_splits(
    initialized_db,
    adult_a_user,
):
    space_id = await _personal_space(initialized_db, adult_a_user)
    account = await _account(initialized_db, adult_a_user, space_id)
    now = "2026-08-10T08:00:00+00:00"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO finance_categories
                (id, space_id, name, spending_type, family_id,
                 created_at, updated_at, created_by)
            VALUES ('manual-category', ?, 'Family choice', 'FLEXIBLE', ?, ?, ?, ?)
            """,
            (space_id, adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        for identifier, description, amount in (
            ("legacy-tesco", "TESCO GROCERY", -2500),
            ("legacy-unknown", "A genuinely unknown merchant", -1800),
            ("legacy-split", "TESCO GROCERY", -900),
        ):
            await db.execute(
                """
                INSERT INTO finance_transactions
                    (id, space_id, account_id, canonical_date, amount_minor,
                     currency, state, source_kind, description, cleaned_description,
                     data_through_at, family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, '2026-08-05', ?, 'GBP', 'POSTED', 'PROVIDER',
                        ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    identifier,
                    space_id,
                    account.id,
                    amount,
                    description,
                    description,
                    now,
                    adult_a_user["family_id"],
                    now,
                    now,
                    adult_a_user["id"],
                ),
            )
        await db.execute(
            """
            INSERT INTO finance_transaction_splits
                (id, space_id, transaction_id, amount_minor, category_id,
                 family_id, created_at, updated_at, created_by)
            VALUES ('manual-split', ?, 'legacy-split', -900, 'manual-category',
                    ?, ?, ?, ?)
            """,
            (space_id, adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.commit()

    await init_db(initialized_db)
    await init_db(initialized_db)

    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                """
                SELECT tx.id, category.name
                FROM finance_transactions tx
                LEFT JOIN finance_categories category
                  ON category.id = tx.primary_category_id
                WHERE tx.id LIKE 'legacy-%'
                ORDER BY tx.id
                """
            )
        ).fetchall()
        assignments = (
            await (
                await db.execute(
                    """
                    SELECT COUNT(*) FROM finance_assignments
                    WHERE target_type = 'TRANSACTION'
                      AND target_id IN ('legacy-tesco', 'legacy-unknown')
                      AND source = 'RULE' AND status = 'CONFIRMED'
                    """
                )
            ).fetchone()
        )[0]
        history = (
            await (
                await db.execute(
                    """
                    SELECT COUNT(*) FROM record_history
                    WHERE table_name = 'finance_transactions'
                      AND record_id IN ('legacy-tesco', 'legacy-unknown')
                    """
                )
            ).fetchone()
        )[0]
    assert rows == [
        ("legacy-split", None),
        ("legacy-tesco", "Food shopping"),
        ("legacy-unknown", "Other"),
    ]
    assert assignments == 2
    assert history == 2


@pytest.mark.asyncio
async def test_provider_replay_can_replace_only_a_weaker_automatic_fallback(
    initialized_db,
    adult_a_user,
):
    space_id = await _personal_space(initialized_db, adult_a_user)
    account = await _account(initialized_db, adult_a_user, space_id)
    initial = _source(
        "classification-later",
        amount_minor=-3200,
        description="Unknown payment envelope",
    )
    async with standalone_db(initialized_db) as db:
        imported = await import_source_transactions(
            db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account.id,
            observations=[initial],
        )
        replayed = await import_source_transactions(
            db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account.id,
            observations=[initial.model_copy(update={"bank_sub_code": "Food & Dining/Delivery"})],
        )

    assert replayed.duplicates == 1
    async with aiosqlite.connect(initialized_db) as db:
        category = await (
            await db.execute(
                """
                SELECT category.name
                FROM finance_transactions tx
                JOIN finance_categories category ON category.id = tx.primary_category_id
                WHERE tx.id = ?
                """,
                (imported.transaction_ids[0],),
            )
        ).fetchone()
        history = (
            await (
                await db.execute(
                    """
                    SELECT COUNT(*) FROM record_history
                    WHERE table_name = 'finance_transactions' AND record_id = ?
                    """,
                    (imported.transaction_ids[0],),
                )
            ).fetchone()
        )[0]
    assert category == ("Eating out",)
    assert history == 1


@pytest.mark.asyncio
async def test_defaults_adopt_matching_categories_without_reversing_user_exclusions(
    initialized_db,
    adult_a_user,
):
    space_id = await _personal_space(initialized_db, adult_a_user)
    now = "2026-08-10T08:00:00+00:00"
    async with standalone_db(initialized_db) as db:
        await db.executemany(
            """
            INSERT INTO finance_categories
                (id, space_id, name, spending_type, counts_as_spending,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, 'FLEXIBLE', ?, ?, ?, ?, ?)
            """,
            [
                (
                    "existing-groceries",
                    space_id,
                    "Food shopping",
                    0,
                    adult_a_user["family_id"],
                    now,
                    now,
                    adult_a_user["id"],
                ),
                (
                    "existing-transfers",
                    space_id,
                    "Transfers",
                    1,
                    adult_a_user["family_id"],
                    now,
                    now,
                    adult_a_user["id"],
                ),
            ],
        )
        first = await ensure_default_categories(
            db,
            space_id=space_id,
            family_id=adult_a_user["family_id"],
            actor_id=adult_a_user["id"],
        )
        second = await ensure_default_categories(
            db,
            space_id=space_id,
            family_id=adult_a_user["family_id"],
            actor_id=adult_a_user["id"],
        )
        rows = await (
            await db.execute(
                """
                SELECT id, system_key, counts_as_spending
                FROM finance_categories
                WHERE id IN ('existing-groceries', 'existing-transfers')
                ORDER BY id
                """
            )
        ).fetchall()
        history_count = (
            await (
                await db.execute(
                    """
                    SELECT COUNT(*) FROM record_history
                    WHERE table_name = 'finance_categories'
                      AND record_id IN ('existing-groceries', 'existing-transfers')
                    """
                )
            ).fetchone()
        )[0]

    assert first == second
    assert first["groceries"] == "existing-groceries"
    assert first["transfers"] == "existing-transfers"
    assert [tuple(row) for row in rows] == [
        ("existing-groceries", "groceries", 0),
        ("existing-transfers", "transfers", 0),
    ]
    assert history_count == 2

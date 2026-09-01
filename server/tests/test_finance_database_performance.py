from datetime import date, datetime, timedelta, timezone

import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.foundation import accessible_finance_spaces
from app.services.finance.ledger import (
    FinanceImportConflictError,
    create_finance_account,
    finance_ledger_summary,
    import_source_transactions,
)
from app.services.finance.purchase_evidence import list_purchases


class _CountingConnection:
    def __init__(self, connection):
        self._connection = connection
        self.execute_count = 0

    async def execute(self, sql, parameters=None):
        self.execute_count += 1
        if parameters is None:
            return await self._connection.execute(sql)
        return await self._connection.execute(sql, parameters)

    async def executemany(self, sql, parameters):
        self.execute_count += 1
        return await self._connection.executemany(sql, parameters)

    def __getattr__(self, name):
        return getattr(self._connection, name)


async def _personal_space_and_account(db_path: str, user: dict):
    async with standalone_db(db_path) as db:
        spaces = await accessible_finance_spaces(db, user=user)
        space_id = next(space.id for space in spaces if space.kind == "personal")
        account = await create_finance_account(
            db,
            user=user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Performance fixture",
                account_type="CURRENT",
                currency="GBP",
            ),
        )
    return space_id, account.id


@pytest.mark.asyncio
async def test_large_import_uses_batched_lookups_and_preserves_replay_deduplication(
    initialized_db,
    adult_a_user,
):
    space_id, account_id = await _personal_space_and_account(initialized_db, adult_a_user)
    observed_at = datetime(2026, 8, 1, 12, tzinfo=timezone.utc)
    observations = [
        NormalisedSourceTransaction(
            source_kind="PROVIDER",
            source_batch_id="query-count-fixture",
            source_transaction_id=f"provider-{index}",
            booking_date=date(2026, 7, 1) + timedelta(days=index % 28),
            pending_status="POSTED",
            amount_minor=-(1_000 + index),
            currency="GBP",
            description=f"Unique debit {index}",
            observed_at=observed_at,
        )
        for index in range(100)
    ]

    async with standalone_db(initialized_db) as raw_db:
        db = _CountingConnection(raw_db)
        created = await import_source_transactions(
            db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account_id,
            observations=observations,
        )
    assert created.canonical_created == 100
    # The old implementation exceeded eleven statements per observation.
    # Core immutable inserts remain individual, but all identity, merchant,
    # pending and relation-source lookups are now shared across the batch.
    assert db.execute_count <= 120

    async with standalone_db(initialized_db) as raw_db:
        replay_db = _CountingConnection(raw_db)
        replayed = await import_source_transactions(
            replay_db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account_id,
            observations=observations,
        )
    assert replayed.canonical_created == 0
    assert replayed.duplicates == 100
    assert replayed.transaction_ids == created.transaction_ids
    assert replay_db.execute_count <= 12


@pytest.mark.asyncio
async def test_import_batch_keeps_pending_audit_and_rolls_back_before_a_late_conflict(
    initialized_db,
    adult_a_user,
):
    space_id, account_id = await _personal_space_and_account(initialized_db, adult_a_user)
    observed_at = datetime(2026, 8, 1, 12, tzinfo=timezone.utc)
    pending = NormalisedSourceTransaction(
        source_kind="PROVIDER",
        source_batch_id="pending-batch",
        source_transaction_id="pending-source",
        booking_date=date(2026, 8, 1),
        pending_status="PENDING",
        amount_minor=-4_599,
        currency="GBP",
        description="Amazon pending",
        observed_at=observed_at,
    )
    posted = pending.model_copy(
        update={
            "source_transaction_id": "posted-source",
            "replaces_source_transaction_id": "pending-source",
            "pending_status": "POSTED",
        }
    )
    async with standalone_db(initialized_db) as db:
        result = await import_source_transactions(
            db,
            user=adult_a_user,
            space_id=space_id,
            account_id=account_id,
            observations=[pending, posted],
        )
        rows = await (
            await db.execute(
                "SELECT id, state, superseded_by_id FROM finance_transactions "
                "WHERE account_id = ? ORDER BY created_at, id",
                (account_id,),
            )
        ).fetchall()
        rows_by_id = {row["id"]: row for row in rows}
        pending_row = rows_by_id[result.transaction_ids[0]]
        posted_row = rows_by_id[result.transaction_ids[1]]
        history_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history "
                    "WHERE table_name = 'finance_transactions' AND record_id = ?",
                    (pending_row["id"],),
                )
            ).fetchone()
        )[0]

    assert result.canonical_created == 2
    assert result.pending_superseded == 1
    assert pending_row["state"] == "SUPERSEDED"
    assert posted_row["state"] == "POSTED"
    assert pending_row["superseded_by_id"] == posted_row["id"]
    assert history_count == 1

    new_before_conflict = posted.model_copy(
        update={
            "source_transaction_id": "must-roll-back",
            "replaces_source_transaction_id": None,
            "booking_date": date(2026, 8, 2),
        }
    )
    conflicting_replay = posted.model_copy(update={"amount_minor": -9_999})
    async with standalone_db(initialized_db) as db:
        with pytest.raises(FinanceImportConflictError):
            await import_source_transactions(
                db,
                user=adult_a_user,
                space_id=space_id,
                account_id=account_id,
                observations=[new_before_conflict, conflicting_replay],
            )
        rolled_back = await (
            await db.execute(
                "SELECT COUNT(*) FROM finance_source_transactions "
                "WHERE account_id = ? AND source_transaction_id = 'must-roll-back'",
                (account_id,),
            )
        ).fetchone()

    assert rolled_back[0] == 0


@pytest.mark.asyncio
async def test_purchase_page_hydration_has_constant_query_count(
    initialized_db,
    adult_a_user,
):
    space_id, _ = await _personal_space_and_account(initialized_db, adult_a_user)
    now = "2026-08-01T12:00:00+00:00"
    purchase_rows = []
    line_rows = []
    payment_rows = []
    for index in range(25):
        purchase_id = f"purchase-{index:02d}"
        source_id = f"source-{index:02d}"
        purchase_rows.append(
            (
                purchase_id,
                space_id,
                source_id,
                f"reference-{index:02d}",
                f"Merchant {index:02d}",
                f"2026-07-{index + 1:02d}",
                adult_a_user["family_id"],
                now,
                now,
            )
        )
        for position in (1, 0):
            line_rows.append(
                (
                    f"line-{index:02d}-{position}",
                    space_id,
                    source_id,
                    purchase_id,
                    f"line-reference-{position}",
                    position,
                    f"Item {index:02d}/{position}",
                    adult_a_user["family_id"],
                )
            )
        payment_rows.append(
            (
                f"payment-{index:02d}",
                space_id,
                purchase_id,
                f"allocation-{index:02d}",
                1_000 if index % 2 == 0 else 400,
                adult_a_user["family_id"],
            )
        )

    async with standalone_db(initialized_db) as db:
        await db.executemany(
            """
            INSERT INTO finance_purchase_records
                (id, space_id, source_id, purchase_ref, merchant_name, purchased_on,
                 currency, lines_subtotal_minor, final_total_minor, status, source_kind,
                 extraction_confidence_bps, family_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, 'GBP', 1000, 1000, 'fulfilled', 'e_receipt',
                    10000, ?, ?, ?)
            """,
            purchase_rows,
        )
        await db.executemany(
            """
            INSERT INTO finance_purchase_lines
                (id, space_id, source_id, purchase_id, source_line_reference,
                 line_position, line_kind, raw_description, quantity_decimal,
                 evidence_status, source_refs_json, family_id)
            VALUES (?, ?, ?, ?, ?, ?, 'product', ?, '1',
                    'observed_structured', '[]', ?)
            """,
            line_rows,
        )
        await db.executemany(
            """
            INSERT INTO finance_purchase_payments
                (id, space_id, purchase_id, allocation_ref, tender_kind,
                 allocated_minor, match_method, status, family_id)
            VALUES (?, ?, ?, ?, 'cash', ?, 'EVIDENCED_NON_BANK', 'CONFIRMED', ?)
            """,
            payment_rows,
        )
        await db.commit()

    async with standalone_db(initialized_db) as raw_db:
        db = _CountingConnection(raw_db)
        purchases = await list_purchases(
            db,
            user=adult_a_user,
            space_id=space_id,
            offset=0,
            limit=25,
        )

    assert len(purchases) == 25
    assert db.execute_count == 4
    by_merchant = {purchase.merchant: purchase for purchase in purchases}
    assert by_merchant["Merchant 00"].item_descriptions == ["Item 00/0", "Item 00/1"]
    assert by_merchant["Merchant 00"].match_status == "MATCHED"
    assert by_merchant["Merchant 01"].match_status == "PARTIAL"


@pytest.mark.asyncio
async def test_ledger_summary_is_one_set_based_query_with_exact_accounting_semantics(
    initialized_db,
    adult_a_user,
):
    space_id, account_id = await _personal_space_and_account(initialized_db, adult_a_user)
    through = "2026-08-01T12:00:00+00:00"
    transactions = [
        ("spend", -1_000, "GBP", "CASEY"),
        ("fee", -100, "GBP", "FEE"),
        ("income", 3_000, "GBP", "CASEY"),
        ("refund", 200, "GBP", "CASEY"),
        ("reimbursement", 300, "GBP", "CASEY"),
        ("transfer-out", -500, "GBP", "CASEY"),
        ("transfer-in", 500, "GBP", "CASEY"),
        ("shared-neutral", -700, "GBP", "CASEY"),
        ("eur-income", 1_000, "EUR", "CASEY"),
    ]
    async with standalone_db(initialized_db) as db:
        await db.executemany(
            """
            INSERT INTO finance_transactions
                (id, space_id, account_id, canonical_date, amount_minor, currency,
                 state, transaction_kind, source_kind, description, cleaned_description,
                 data_through_at, family_id)
            VALUES (?, ?, ?, '2026-08-01', ?, ?, 'POSTED', ?, 'MANUAL', ?, ?, ?, ?)
            """,
            [
                (
                    identifier,
                    space_id,
                    account_id,
                    amount,
                    currency,
                    kind,
                    identifier,
                    identifier.upper(),
                    through,
                    adult_a_user["family_id"],
                )
                for identifier, amount, currency, kind in transactions
            ],
        )
        await db.executemany(
            """
            INSERT INTO finance_transaction_relations
                (id, space_id, from_transaction_id, to_transaction_id, relation_type,
                 status, method, confidence_bps, family_id)
            VALUES (?, ?, ?, ?, ?, 'CONFIRMED', 'fixture', 10000, ?)
            """,
            [
                (
                    "transfer-relation",
                    space_id,
                    "transfer-out",
                    "transfer-in",
                    "INTERNAL_TRANSFER",
                    adult_a_user["family_id"],
                ),
                (
                    "refund-relation",
                    space_id,
                    "spend",
                    "refund",
                    "REFUND",
                    adult_a_user["family_id"],
                ),
                (
                    "reimbursement-relation",
                    space_id,
                    "spend",
                    "reimbursement",
                    "REIMBURSEMENT",
                    adult_a_user["family_id"],
                ),
            ],
        )
        await db.execute(
            """
            INSERT INTO finance_share_copy_links
                (id, share_action_id, source_space_id, source_record_type,
                 source_record_id, household_space_id, household_record_type,
                 household_record_id, accounting_treatment, family_id)
            VALUES ('neutral-link', 'fixture-action', ?, 'transaction',
                    'fixture-source', ?, 'transaction', 'shared-neutral',
                    'NEUTRAL_TRANSFER', ?)
            """,
            (space_id, space_id, adult_a_user["family_id"]),
        )
        await db.commit()

    async with standalone_db(initialized_db) as raw_db:
        db = _CountingConnection(raw_db)
        summary = await finance_ledger_summary(
            db,
            user=adult_a_user,
            space_id=space_id,
        )

    assert db.execute_count == 2
    assert summary.data_through_at == through
    by_currency = {item.currency: item for item in summary.currencies}
    assert by_currency["GBP"].model_dump() == {
        "currency": "GBP",
        "account_movement_minor": 1_700,
        "income_minor": 3_000,
        "gross_spending_minor": 1_100,
        "refunds_minor": 200,
        "reimbursements_minor": 300,
        "fees_minor": 100,
        "net_household_cost_minor": 600,
    }
    assert by_currency["EUR"].income_minor == 1_000


@pytest.mark.asyncio
async def test_transfer_exclusion_plan_uses_endpoint_indexes(initialized_db):
    async with standalone_db(initialized_db) as db:
        plan = await (
            await db.execute(
                """
                EXPLAIN QUERY PLAN
                SELECT tx.id FROM finance_transactions tx
                WHERE tx.space_id = ? AND tx.family_id = ? AND tx.currency = 'GBP'
                  AND tx.state = 'POSTED' AND tx.deleted_at IS NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM finance_transaction_relations relation
                      WHERE relation.space_id = tx.space_id
                        AND relation.family_id = tx.family_id
                        AND relation.status = 'CONFIRMED'
                        AND relation.relation_type IN (
                            'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                        )
                        AND relation.deleted_at IS NULL
                        AND relation.from_transaction_id = tx.id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM finance_transaction_relations relation
                      WHERE relation.space_id = tx.space_id
                        AND relation.family_id = tx.family_id
                        AND relation.status = 'CONFIRMED'
                        AND relation.relation_type IN (
                            'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                        )
                        AND relation.deleted_at IS NULL
                        AND relation.to_transaction_id = tx.id
                  )
                """,
                ("space", "family"),
            )
        ).fetchall()

    detail = " ".join(row["detail"] for row in plan)
    assert "idx_finance_relations_from_confirmed" in detail
    assert "idx_finance_relations_to_confirmed" in detail

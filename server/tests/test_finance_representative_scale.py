from time import perf_counter

import pytest

from app.database import standalone_db
from app.models.finance_understanding import FinanceAnalysisRequest
from app.services.finance.coach import FinanceLedgerQueryExecutor
from app.services.finance.ledger import finance_ledger_summary
from app.services.finance.understanding import run_saved_finance_analysis
from finance_scale_fixture import (
    SCALE_ACCOUNT_COUNT,
    SCALE_DAY_COUNT,
    SCALE_END,
    SCALE_START,
    SCALE_TRANSACTION_COUNT,
    seed_representative_finance_scale,
)


class _CountingConnection:
    def __init__(self, connection):
        self._connection = connection
        self.execute_count = 0

    async def execute(self, sql, parameters=None):
        self.execute_count += 1
        if parameters is None:
            return await self._connection.execute(sql)
        return await self._connection.execute(sql, parameters)

    def __getattr__(self, name):
        return getattr(self._connection, name)


@pytest.mark.asyncio
async def test_five_year_ten_account_queries_remain_bounded(
    initialized_db,
    adult_a_user,
    record_testsuite_property,
):
    async with standalone_db(initialized_db) as db:
        personal_id, household_id = await seed_representative_finance_scale(
            db, user=adult_a_user
        )

    async with standalone_db(initialized_db) as raw_db:
        count = (
            await (
                await raw_db.execute(
                    "SELECT COUNT(*) FROM finance_transactions WHERE id LIKE 'scale-tx-%'"
                )
            ).fetchone()
        )[0]
        assert count == SCALE_TRANSACTION_COUNT
        assert SCALE_DAY_COUNT >= 1_825

        summary_db = _CountingConnection(raw_db)
        started = perf_counter()
        summary = await finance_ledger_summary(
            summary_db,
            user=adult_a_user,
            space_id=personal_id,
            scope="mine",
        )
        summary_ms = (perf_counter() - started) * 1_000
        assert summary_db.execute_count <= 3
        assert summary.space_ids == [personal_id, household_id]
        assert summary.currencies[0].gross_spending_minor > 0

        analysis_db = _CountingConnection(raw_db)
        started = perf_counter()
        analysis = await run_saved_finance_analysis(
            analysis_db,
            user=adult_a_user,
            body=FinanceAnalysisRequest(
                space_id=personal_id,
                scope="mine",
                basis="TRANSACTIONS",
                start_date=SCALE_START,
                end_date=SCALE_END,
                currency="GBP",
                grouping="ACCOUNT",
            ),
        )
        analysis_ms = (perf_counter() - started) * 1_000
        assert analysis_db.execute_count <= 5
        assert len(analysis.groups) == SCALE_ACCOUNT_COUNT

        search_db = _CountingConnection(raw_db)
        started = perf_counter()
        searched = await FinanceLedgerQueryExecutor(search_db).execute(
            operation="search_transactions",
            arguments={"search_text": "Scale marker", "limit": 20},
            principal=adult_a_user,
            space_ids=(personal_id, household_id),
        )
        search_ms = (perf_counter() - started) * 1_000
        assert search_db.execute_count <= 3
        assert len(searched["transactions"]) == 1
        assert searched["transactions"][0]["description"].startswith("Scale marker")

        indexes = {
            row["name"]
            for row in await (
                await raw_db.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'index' "
                    "AND tbl_name = 'finance_transactions'"
                )
            ).fetchall()
        }
        assert "idx_finance_transactions_space_state_date" in indexes
        assert "idx_finance_transactions_account_date" in indexes

    # These diagnostics are intentionally not laptop-dependent assertions.
    # CI trend data can detect regressions while query-count bounds stay stable.
    record_testsuite_property("finance_scale_transactions", SCALE_TRANSACTION_COUNT)
    record_testsuite_property("finance_summary_ms", round(summary_ms, 3))
    record_testsuite_property("finance_analysis_ms", round(analysis_ms, 3))
    record_testsuite_property("finance_search_ms", round(search_ms, 3))

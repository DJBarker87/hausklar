"""Read-only aggregate inventory for the Finance Tesco kill-test gate.

The database path is always supplied by the caller.  This module never falls
back to the application database or a production host path, and its CLI opens
the supplied SQLite file with ``mode=ro&immutable=1``.

Usage from ``server/``::

    python -m app.db.finance_data_gate --database /path/to/read-only-export.db

Optionally pass ``--family-id`` when an export contains more than one family.
The JSON output contains counts, dates, and priced totals only; it never reads
or emits grocery item names, raw purchase names, notes, or descriptions.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from dataclasses import asdict, dataclass
from datetime import date
from pathlib import Path
from typing import Sequence


READY = "READY"
DATA_INSUFFICIENT = "DATA_INSUFFICIENT"
REQUIRED_CONTINUOUS_MONTHS = 3
REQUIRED_DATE_SPAN_DAYS = 84


@dataclass(frozen=True)
class FinanceDataGateResult:
    """Aggregate-only result safe to print in build output."""

    status: str
    reason: str | None
    required_continuous_months: int
    required_date_span_days: int
    active_batch_count: int
    dated_batch_count: int
    active_line_count: int
    priced_line_count: int
    unpriced_line_count: int
    priced_total_pence: int
    first_purchase_date: str | None
    last_purchase_date: str | None
    date_span_days: int
    continuous_month_count: int
    continuous_start_month: str | None
    continuous_end_month: str | None

    @classmethod
    def insufficient(cls, reason: str) -> "FinanceDataGateResult":
        return cls(
            status=DATA_INSUFFICIENT,
            reason=reason,
            required_continuous_months=REQUIRED_CONTINUOUS_MONTHS,
            required_date_span_days=REQUIRED_DATE_SPAN_DAYS,
            active_batch_count=0,
            dated_batch_count=0,
            active_line_count=0,
            priced_line_count=0,
            unpriced_line_count=0,
            priced_total_pence=0,
            first_purchase_date=None,
            last_purchase_date=None,
            date_span_days=0,
            continuous_month_count=0,
            continuous_start_month=None,
            continuous_end_month=None,
        )

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))


def _month_number(month: str) -> int:
    year_text, month_text = month.split("-", 1)
    return int(year_text) * 12 + int(month_text) - 1


def _longest_continuous_month_run(months: Sequence[str]) -> tuple[int, str | None, str | None]:
    """Return the longest run of consecutive calendar months with a Tesco batch."""

    ordered = sorted(set(months))
    if not ordered:
        return 0, None, None

    best_start = ordered[0]
    best_end = ordered[0]
    best_length = 1
    run_start = ordered[0]
    run_end = ordered[0]
    run_length = 1

    for month in ordered[1:]:
        if _month_number(month) == _month_number(run_end) + 1:
            run_end = month
            run_length += 1
        else:
            run_start = month
            run_end = month
            run_length = 1

        if run_length > best_length:
            best_start = run_start
            best_end = run_end
            best_length = run_length

    return best_length, best_start, best_end


def _has_required_schema(connection: sqlite3.Connection) -> bool:
    required_columns = {
        "purchase_batches": {"id", "purchased_at", "source", "family_id", "deleted_at"},
        "purchases": {"purchase_batch_id", "price_pence", "deleted_at"},
    }
    for table, expected in required_columns.items():
        columns = {
            str(row[1])
            for row in connection.execute(f"PRAGMA table_info({table})").fetchall()
        }
        if not expected.issubset(columns):
            return False
    return True


def inspect_tesco_finance_data(
    database: str | Path,
    *,
    family_id: str | None = None,
) -> FinanceDataGateResult:
    """Inspect an explicitly supplied SQLite export without modifying it.

    READY requires three consecutive ``YYYY-MM`` calendar buckets that each
    contain an active Tesco batch and at least 84 inclusive days between the
    first and last active Tesco batch.
    """

    database_path = Path(database).expanduser()
    if not database_path.is_file():
        return FinanceDataGateResult.insufficient("DATABASE_NOT_FOUND")

    uri = f"{database_path.resolve().as_uri()}?mode=ro&immutable=1"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=1.0)
    except sqlite3.Error:
        return FinanceDataGateResult.insufficient("DATABASE_UNREADABLE")

    try:
        connection.execute("PRAGMA query_only = ON")
        if not _has_required_schema(connection):
            return FinanceDataGateResult.insufficient("SCHEMA_MISSING")

        batch_where = "deleted_at IS NULL AND LOWER(source) = 'tesco'"
        batch_params: tuple[str, ...] = ()
        if family_id is not None:
            batch_where += " AND family_id = ?"
            batch_params = (family_id,)

        batch_row = connection.execute(
            f"""
            SELECT
                COUNT(*) AS active_batch_count,
                COUNT(DATE(purchased_at)) AS dated_batch_count,
                MIN(DATE(purchased_at)) AS first_purchase_date,
                MAX(DATE(purchased_at)) AS last_purchase_date
            FROM purchase_batches
            WHERE {batch_where}
            """,
            batch_params,
        ).fetchone()

        line_where = (
            "p.deleted_at IS NULL "
            "AND b.deleted_at IS NULL "
            "AND LOWER(b.source) = 'tesco'"
        )
        line_params: tuple[str, ...] = ()
        if family_id is not None:
            line_where += " AND b.family_id = ?"
            line_params = (family_id,)

        line_row = connection.execute(
            f"""
            SELECT
                COUNT(*) AS active_line_count,
                COUNT(p.price_pence) AS priced_line_count,
                COALESCE(SUM(p.price_pence), 0) AS priced_total_pence
            FROM purchases AS p
            JOIN purchase_batches AS b ON b.id = p.purchase_batch_id
            WHERE {line_where}
            """,
            line_params,
        ).fetchone()

        month_rows = connection.execute(
            f"""
            SELECT DISTINCT STRFTIME('%Y-%m', purchased_at) AS purchase_month
            FROM purchase_batches
            WHERE {batch_where} AND DATE(purchased_at) IS NOT NULL
            ORDER BY purchase_month
            """,
            batch_params,
        ).fetchall()
    except sqlite3.Error:
        return FinanceDataGateResult.insufficient("DATABASE_UNREADABLE")
    finally:
        connection.close()

    active_batch_count = int(batch_row[0])
    dated_batch_count = int(batch_row[1])
    first_purchase_date = str(batch_row[2]) if batch_row[2] is not None else None
    last_purchase_date = str(batch_row[3]) if batch_row[3] is not None else None
    active_line_count = int(line_row[0])
    priced_line_count = int(line_row[1])
    priced_total_pence = int(line_row[2])
    continuous_count, continuous_start, continuous_end = _longest_continuous_month_run(
        [str(row[0]) for row in month_rows if row[0] is not None]
    )

    date_span_days = 0
    if first_purchase_date is not None and last_purchase_date is not None:
        date_span_days = (
            date.fromisoformat(last_purchase_date) - date.fromisoformat(first_purchase_date)
        ).days + 1

    if continuous_count < REQUIRED_CONTINUOUS_MONTHS:
        status = DATA_INSUFFICIENT
        reason = "NOT_ENOUGH_CONTINUOUS_MONTHS"
    elif date_span_days < REQUIRED_DATE_SPAN_DAYS:
        status = DATA_INSUFFICIENT
        reason = "NOT_ENOUGH_DATE_SPAN"
    else:
        status = READY
        reason = None

    return FinanceDataGateResult(
        status=status,
        reason=reason,
        required_continuous_months=REQUIRED_CONTINUOUS_MONTHS,
        required_date_span_days=REQUIRED_DATE_SPAN_DAYS,
        active_batch_count=active_batch_count,
        dated_batch_count=dated_batch_count,
        active_line_count=active_line_count,
        priced_line_count=priced_line_count,
        unpriced_line_count=active_line_count - priced_line_count,
        priced_total_pence=priced_total_pence,
        first_purchase_date=first_purchase_date,
        last_purchase_date=last_purchase_date,
        date_span_days=date_span_days,
        continuous_month_count=continuous_count,
        continuous_start_month=continuous_start,
        continuous_end_month=continuous_end,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inspect aggregate Tesco history in an explicit read-only SQLite export."
    )
    parser.add_argument(
        "--database",
        required=True,
        help="Path to the SQLite export to inspect (there is no default).",
    )
    parser.add_argument(
        "--family-id",
        help="Optional family ID when the export contains multiple families.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    result = inspect_tesco_finance_data(args.database, family_id=args.family_id)
    print(result.to_json())
    return 0 if result.status == READY else 2


if __name__ == "__main__":
    raise SystemExit(main())

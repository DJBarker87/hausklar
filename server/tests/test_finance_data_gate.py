"""Focused tests for the read-only Finance Tesco inventory gate."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from app.db.finance_data_gate import (
    DATA_INSUFFICIENT,
    READY,
    inspect_tesco_finance_data,
)


def _create_grocery_db(path: Path) -> None:
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        CREATE TABLE purchase_batches (
            id TEXT PRIMARY KEY,
            purchased_at TEXT NOT NULL,
            source TEXT NOT NULL,
            family_id TEXT,
            deleted_at TEXT
        );
        CREATE TABLE purchases (
            id TEXT PRIMARY KEY,
            purchase_batch_id TEXT NOT NULL,
            price_pence INTEGER,
            deleted_at TEXT
        );
        """
    )
    connection.commit()
    connection.close()


def _insert_batch(
    path: Path,
    *,
    batch_id: str,
    purchased_at: str,
    prices: list[int | None],
    family_id: str = "family-a",
    source: str = "tesco",
    deleted_at: str | None = None,
) -> None:
    connection = sqlite3.connect(path)
    connection.execute(
        """
        INSERT INTO purchase_batches (
            id, purchased_at, source, family_id, deleted_at
        ) VALUES (?, ?, ?, ?, ?)
        """,
        (batch_id, purchased_at, source, family_id, deleted_at),
    )
    for index, price in enumerate(prices):
        connection.execute(
            """
            INSERT INTO purchases (id, purchase_batch_id, price_pence, deleted_at)
            VALUES (?, ?, ?, NULL)
            """,
            (f"{batch_id}-line-{index}", batch_id, price),
        )
    connection.commit()
    connection.close()


def test_insufficient_when_three_month_span_has_a_gap(tmp_path: Path) -> None:
    database = tmp_path / "tesco.db"
    _create_grocery_db(database)
    _insert_batch(database, batch_id="jan", purchased_at="2026-01-04T10:00:00Z", prices=[120])
    _insert_batch(database, batch_id="mar", purchased_at="2026-03-20T10:00:00Z", prices=[180, None])

    result = inspect_tesco_finance_data(database, family_id="family-a")

    assert result.status == DATA_INSUFFICIENT
    assert result.reason == "NOT_ENOUGH_CONTINUOUS_MONTHS"
    assert result.active_batch_count == 2
    assert result.active_line_count == 3
    assert result.priced_line_count == 2
    assert result.unpriced_line_count == 1
    assert result.priced_total_pence == 300
    assert result.first_purchase_date == "2026-01-04"
    assert result.last_purchase_date == "2026-03-20"
    assert result.date_span_days == 76
    assert result.continuous_month_count == 1


def test_ready_for_three_consecutive_calendar_months_with_aggregate_counts(
    tmp_path: Path,
) -> None:
    database = tmp_path / "tesco.db"
    _create_grocery_db(database)
    _insert_batch(database, batch_id="dec", purchased_at="2025-12-01T23:00:00Z", prices=[100, None])
    _insert_batch(database, batch_id="jan", purchased_at="2026-01-15T10:00:00Z", prices=[250])
    _insert_batch(database, batch_id="feb", purchased_at="2026-02-23T08:00:00Z", prices=[300, 50])
    _insert_batch(
        database,
        batch_id="deleted",
        purchased_at="2026-02-10T08:00:00Z",
        prices=[999],
        deleted_at="2026-02-11T00:00:00Z",
    )
    _insert_batch(
        database,
        batch_id="other-source",
        purchased_at="2026-03-01T08:00:00Z",
        prices=[888],
        source="manual",
    )
    _insert_batch(
        database,
        batch_id="other-family",
        purchased_at="2026-03-01T08:00:00Z",
        prices=[777],
        family_id="family-b",
    )

    result = inspect_tesco_finance_data(database, family_id="family-a")

    assert result.status == READY
    assert result.reason is None
    assert result.active_batch_count == 3
    assert result.dated_batch_count == 3
    assert result.active_line_count == 5
    assert result.priced_line_count == 4
    assert result.unpriced_line_count == 1
    assert result.priced_total_pence == 700
    assert result.required_date_span_days == 84
    assert result.first_purchase_date == "2025-12-01"
    assert result.last_purchase_date == "2026-02-23"
    assert result.date_span_days == 85
    assert result.continuous_month_count == 3
    assert result.continuous_start_month == "2025-12"
    assert result.continuous_end_month == "2026-02"


def test_insufficient_when_three_month_buckets_cover_only_33_days(tmp_path: Path) -> None:
    database = tmp_path / "tesco.db"
    _create_grocery_db(database)
    _insert_batch(database, batch_id="dec", purchased_at="2025-12-31T23:00:00Z", prices=[100])
    _insert_batch(database, batch_id="jan", purchased_at="2026-01-15T10:00:00Z", prices=[250])
    _insert_batch(database, batch_id="feb", purchased_at="2026-02-01T08:00:00Z", prices=[300])

    result = inspect_tesco_finance_data(database, family_id="family-a")

    assert result.status == DATA_INSUFFICIENT
    assert result.reason == "NOT_ENOUGH_DATE_SPAN"
    assert result.continuous_month_count == 3
    assert result.date_span_days == 33
    assert result.required_date_span_days == 84


def test_missing_and_empty_databases_return_stable_insufficient_result(
    tmp_path: Path,
) -> None:
    missing = tmp_path / "missing.db"
    missing_result = inspect_tesco_finance_data(missing)

    assert missing_result.status == DATA_INSUFFICIENT
    assert missing_result.reason == "DATABASE_NOT_FOUND"
    assert missing_result.active_batch_count == 0
    assert not missing.exists()

    empty = tmp_path / "empty.db"
    sqlite3.connect(empty).close()
    empty_result = inspect_tesco_finance_data(empty)

    assert empty_result.status == DATA_INSUFFICIENT
    assert empty_result.reason == "SCHEMA_MISSING"
    assert empty_result.active_batch_count == 0
    assert empty_result.active_line_count == 0
    assert empty_result.priced_total_pence == 0


def test_inspection_does_not_mutate_database_or_create_sidecars(tmp_path: Path) -> None:
    database = tmp_path / "tesco.db"
    _create_grocery_db(database)
    _insert_batch(database, batch_id="jan", purchased_at="2026-01-01", prices=[123])
    before_bytes = database.read_bytes()
    before_files = {path.name for path in tmp_path.iterdir()}

    inspect_tesco_finance_data(database, family_id="family-a")

    assert database.read_bytes() == before_bytes
    assert {path.name for path in tmp_path.iterdir()} == before_files

"""Focused bounded Finance analysis tests."""

from datetime import date
from fractions import Fraction

from app.services.finance.analytics import (
    AnalysisFilters,
    AnalysisSpec,
    PurchaseLineRecord,
    TransactionRecord,
    analyse_finance,
)
from app.services.finance.money import Money


def test_exact_space_date_currency_filters_comparison_and_evidence_totals():
    transactions = [
        TransactionRecord(
            "jan-food",
            "dom",
            date(2026, 1, 10),
            Money(-1_200, "GBP"),
            "current",
            merchant="Tesco",
            category="food",
            evidence_ids=("bank:jan",),
        ),
        TransactionRecord(
            "feb-food",
            "dom",
            date(2026, 2, 10),
            Money(-1_500, "GBP"),
            "current",
            merchant="Tesco",
            category="food",
            evidence_ids=("bank:feb",),
        ),
        TransactionRecord(
            "private-partner",
            "kat",
            date(2026, 2, 11),
            Money(-9_999, "GBP"),
            "private",
            category="food",
            evidence_ids=("private:evidence",),
        ),
        TransactionRecord(
            "wrong-currency",
            "dom",
            date(2026, 2, 12),
            Money(-500, "EUR"),
            "revolut-eur",
            category="food",
        ),
    ]
    spec = AnalysisSpec(
        basis="TRANSACTIONS",
        start_date=date(2026, 2, 1),
        end_date=date(2026, 2, 28),
        currency="GBP",
        allowed_space_ids=("dom",),
        grouping="CATEGORY",
        measure="SPEND",
        comparison="PREVIOUS_PERIOD",
        filters=AnalysisFilters(categories=("food",)),
    )

    result = analyse_finance(spec, transactions=transactions)

    assert result.total == Fraction(1_500)
    assert result.groups[0].key == "food"
    assert result.groups[0].value == Fraction(1_500)
    assert result.evidence_ids == ("bank:feb",)
    assert result.comparison_start_date == date(2026, 1, 4)
    assert result.comparison_end_date == date(2026, 1, 31)
    assert result.comparison_total == Fraction(1_200)
    assert "private:evidence" not in result.evidence_ids


def test_purchase_line_grouping_treats_malicious_text_as_an_ordinary_label():
    malicious = "x'); DROP TABLE finance_transactions; --"
    lines = [
        PurchaseLineRecord(
            "line-1",
            "dom",
            date(2026, 3, 1),
            Money(425, "GBP"),
            merchant=malicious,
            category="household",
            normalized_item="cable",
            evidence_ids=("receipt:1",),
        ),
        PurchaseLineRecord(
            "refund",
            "dom",
            date(2026, 3, 2),
            Money(-100, "GBP"),
            merchant=malicious,
            category="household",
            normalized_item="cable",
            evidence_ids=("refund:1",),
        ),
    ]
    spec = AnalysisSpec(
        basis="PURCHASE_LINES",
        start_date=date(2026, 3, 1),
        end_date=date(2026, 3, 31),
        currency="GBP",
        allowed_space_ids=("dom",),
        grouping="MERCHANT",
        measure="SPEND",
        filters=AnalysisFilters(merchants=(malicious,)),
    )

    result = analyse_finance(spec, purchase_lines=lines)

    assert result.total == Fraction(325)
    assert result.groups == (
        result.groups[0].__class__(
            key=malicious,
            value=Fraction(325),
            record_count=2,
            evidence_ids=("receipt:1", "refund:1"),
        ),
    )

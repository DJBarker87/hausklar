"""Typed, bounded, deterministic Finance analysis over normalized records."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from fractions import Fraction
from typing import Literal

from app.services.finance.money import Money, normalise_currency

AnalysisBasis = Literal["TRANSACTIONS", "PURCHASE_LINES", "RECONCILED_PURCHASE_LINES"]
AnalysisGrouping = Literal[
    "TOTAL",
    "DAY",
    "WEEK",
    "MONTH",
    "ACCOUNT",
    "MERCHANT",
    "CATEGORY",
    "LINE_KIND",
    "ITEM",
    "PURPOSE",
    "RECIPIENT",
    "PLANNEDNESS",
    "UTILITY",
    "VALUE_FOR_MONEY",
    "DECISION_QUALITY",
    "OUTCOME",
    "ITEMISATION",
]
AnalysisMeasure = Literal[
    "SPEND",
    "INCOME",
    "COUNT",
    "MEAN_SPEND",
    "MEDIAN_SPEND",
    "MIN_SPEND",
    "MAX_SPEND",
    "SHARE_OF_SPEND",
    "MEAN_UNIT_PRICE",
]
ComparisonKind = Literal["NONE", "PREVIOUS_PERIOD", "SAME_PERIOD_LAST_YEAR"]

_BASES = {"TRANSACTIONS", "PURCHASE_LINES", "RECONCILED_PURCHASE_LINES"}
_GROUPINGS = {
    "TOTAL",
    "DAY",
    "WEEK",
    "MONTH",
    "ACCOUNT",
    "MERCHANT",
    "CATEGORY",
    "LINE_KIND",
    "ITEM",
    "PURPOSE",
    "RECIPIENT",
    "PLANNEDNESS",
    "UTILITY",
    "VALUE_FOR_MONEY",
    "DECISION_QUALITY",
    "OUTCOME",
    "ITEMISATION",
}
_MEASURES = {
    "SPEND",
    "INCOME",
    "COUNT",
    "MEAN_SPEND",
    "MEDIAN_SPEND",
    "MIN_SPEND",
    "MAX_SPEND",
    "SHARE_OF_SPEND",
    "MEAN_UNIT_PRICE",
}
_COMPARISONS = {"NONE", "PREVIOUS_PERIOD", "SAME_PERIOD_LAST_YEAR"}


@dataclass(frozen=True, slots=True)
class TransactionRecord:
    id: str
    space_id: str
    day: date
    amount: Money
    account_id: str
    merchant: str | None = None
    category: str | None = None
    transaction_type: str = "card"
    evidence_ids: tuple[str, ...] = ()
    recurring_key: str | None = None
    is_refund: bool = False

    def __post_init__(self) -> None:
        if not self.id or not self.space_id or not self.account_id:
            raise ValueError("Transaction id, space_id and account_id are required")
        object.__setattr__(self, "evidence_ids", tuple(self.evidence_ids) or (self.id,))


@dataclass(frozen=True, slots=True)
class PurchaseLineRecord:
    id: str
    space_id: str
    day: date
    net_amount: Money
    merchant: str | None = None
    category: str | None = None
    line_kind: str = "product"
    normalized_item: str | None = None
    purpose: str | None = None
    recipient: str | None = None
    plannedness: str | None = None
    utility: str | None = None
    decision_quality: str | None = None
    value_for_money: str | None = None
    outcome: str | None = None
    itemisation: str = "ITEMISED"
    unit_price_minor: int | None = None
    tags: tuple[str, ...] = ()
    evidence_ids: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.id or not self.space_id:
            raise ValueError("Purchase line id and space_id are required")
        object.__setattr__(self, "tags", tuple(self.tags))
        object.__setattr__(self, "evidence_ids", tuple(self.evidence_ids) or (self.id,))


@dataclass(frozen=True, slots=True)
class AnalysisFilters:
    account_ids: tuple[str, ...] = ()
    merchants: tuple[str, ...] = ()
    categories: tuple[str, ...] = ()
    transaction_types: tuple[str, ...] = ()
    line_kinds: tuple[str, ...] = ()
    normalized_items: tuple[str, ...] = ()
    purposes: tuple[str, ...] = ()
    recipients: tuple[str, ...] = ()
    plannedness: tuple[str, ...] = ()
    utilities: tuple[str, ...] = ()
    decision_qualities: tuple[str, ...] = ()
    value_for_money: tuple[str, ...] = ()
    outcomes: tuple[str, ...] = ()
    itemisation: tuple[str, ...] = ()
    tags: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        for field_name in self.__dataclass_fields__:
            object.__setattr__(self, field_name, tuple(getattr(self, field_name)))


@dataclass(frozen=True, slots=True)
class AnalysisSpec:
    basis: AnalysisBasis
    start_date: date
    end_date: date
    currency: str
    allowed_space_ids: tuple[str, ...]
    grouping: AnalysisGrouping = "TOTAL"
    measure: AnalysisMeasure = "SPEND"
    comparison: ComparisonKind = "NONE"
    filters: AnalysisFilters = AnalysisFilters()

    def __post_init__(self) -> None:
        if self.basis not in _BASES:
            raise ValueError("Unsupported analysis basis")
        if self.grouping not in _GROUPINGS:
            raise ValueError("Unsupported analysis grouping")
        if self.measure not in _MEASURES:
            raise ValueError("Unsupported analysis measure")
        if self.comparison not in _COMPARISONS:
            raise ValueError("Unsupported comparison kind")
        if self.end_date < self.start_date:
            raise ValueError("Analysis end_date must not precede start_date")
        if not self.allowed_space_ids:
            raise ValueError("Analysis requires at least one authorized Finance space")
        object.__setattr__(self, "allowed_space_ids", tuple(self.allowed_space_ids))
        object.__setattr__(self, "currency", normalise_currency(self.currency))


@dataclass(frozen=True, slots=True)
class AnalysisGroup:
    key: str
    value: Fraction
    record_count: int
    evidence_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class AnalysisResult:
    spec: AnalysisSpec
    groups: tuple[AnalysisGroup, ...]
    total: Fraction
    evidence_ids: tuple[str, ...]
    comparison_start_date: date | None
    comparison_end_date: date | None
    comparison_groups: tuple[AnalysisGroup, ...]
    comparison_total: Fraction | None


NormalizedRecord = TransactionRecord | PurchaseLineRecord


def _matches(record: NormalizedRecord, filters: AnalysisFilters) -> bool:
    def selected(values: tuple[str, ...], value: str | None) -> bool:
        return not values or value in values

    if isinstance(record, TransactionRecord):
        return (
            selected(filters.account_ids, record.account_id)
            and selected(filters.merchants, record.merchant)
            and selected(filters.categories, record.category)
            and selected(filters.transaction_types, record.transaction_type)
            and not any(
                (
                    filters.line_kinds,
                    filters.normalized_items,
                    filters.purposes,
                    filters.recipients,
                    filters.plannedness,
                    filters.utilities,
                    filters.decision_qualities,
                    filters.value_for_money,
                    filters.outcomes,
                    filters.itemisation,
                    filters.tags,
                )
            )
        )
    return (
        not filters.account_ids
        and not filters.transaction_types
        and selected(filters.merchants, record.merchant)
        and selected(filters.categories, record.category)
        and selected(filters.line_kinds, record.line_kind)
        and selected(filters.normalized_items, record.normalized_item)
        and selected(filters.purposes, record.purpose)
        and selected(filters.recipients, record.recipient)
        and selected(filters.plannedness, record.plannedness)
        and selected(filters.utilities, record.utility)
        and selected(filters.decision_qualities, record.decision_quality)
        and selected(filters.value_for_money, record.value_for_money)
        and selected(filters.outcomes, record.outcome)
        and selected(filters.itemisation, record.itemisation)
        and (not filters.tags or bool(set(filters.tags) & set(record.tags)))
    )


def _relevant_to_measure(record: NormalizedRecord, measure: AnalysisMeasure) -> bool:
    """Exclude records that would otherwise contribute a misleading synthetic zero."""
    if measure == "COUNT":
        return True
    if measure == "MEAN_UNIT_PRICE":
        return isinstance(record, PurchaseLineRecord) and record.unit_price_minor is not None
    if measure == "INCOME":
        return (
            isinstance(record, TransactionRecord)
            and not record.is_refund
            and record.amount.minor_units > 0
        )
    if isinstance(record, PurchaseLineRecord):
        return True
    return record.is_refund or record.amount.minor_units < 0


def _group_key(record: NormalizedRecord, grouping: AnalysisGrouping) -> str:
    if grouping == "TOTAL":
        return "total"
    if grouping == "DAY":
        return record.day.isoformat()
    if grouping == "WEEK":
        iso_year, iso_week, _ = record.day.isocalendar()
        return f"{iso_year:04d}-W{iso_week:02d}"
    if grouping == "MONTH":
        return f"{record.day.year:04d}-{record.day.month:02d}"
    if grouping == "MERCHANT":
        return record.merchant or "(unknown)"
    if grouping == "CATEGORY":
        return record.category or "(unknown)"
    if grouping == "ACCOUNT":
        return record.account_id if isinstance(record, TransactionRecord) else "(unknown)"
    if not isinstance(record, PurchaseLineRecord):
        return "(unknown)"
    if grouping == "ITEM":
        return record.normalized_item or "(unknown)"
    if grouping == "LINE_KIND":
        return record.line_kind
    if grouping == "PURPOSE":
        return record.purpose or "(unknown)"
    if grouping == "RECIPIENT":
        return record.recipient or "(unknown)"
    if grouping == "PLANNEDNESS":
        return record.plannedness or "(unknown)"
    if grouping == "UTILITY":
        return record.utility or "(unknown)"
    if grouping == "VALUE_FOR_MONEY":
        return record.value_for_money or "(unknown)"
    if grouping == "DECISION_QUALITY":
        return record.decision_quality or "(unknown)"
    if grouping == "OUTCOME":
        return record.outcome or "(unknown)"
    return record.itemisation


def _spend_value(record: NormalizedRecord) -> int:
    if isinstance(record, TransactionRecord):
        if record.is_refund:
            return -max(0, record.amount.minor_units)
        return max(0, -record.amount.minor_units)
    return record.net_amount.minor_units


def _income_value(record: NormalizedRecord) -> int:
    if isinstance(record, TransactionRecord):
        if record.is_refund:
            return 0
        return max(0, record.amount.minor_units)
    return 0


def _aggregate_value(records: list[NormalizedRecord], measure: AnalysisMeasure) -> Fraction:
    if measure == "COUNT":
        return Fraction(len(records))
    if measure == "MEAN_UNIT_PRICE":
        unit_prices = [
            record.unit_price_minor
            for record in records
            if isinstance(record, PurchaseLineRecord) and record.unit_price_minor is not None
        ]
        return Fraction(sum(unit_prices), len(unit_prices)) if unit_prices else Fraction(0)
    values = [
        _income_value(record) if measure == "INCOME" else _spend_value(record)
        for record in records
    ]
    if not values:
        return Fraction(0)
    if measure in {"SPEND", "INCOME", "SHARE_OF_SPEND"}:
        return Fraction(sum(values))
    if measure == "MEAN_SPEND":
        return Fraction(sum(values), len(values))
    ordered = sorted(values)
    if measure == "MEDIAN_SPEND":
        midpoint = len(ordered) // 2
        if len(ordered) % 2:
            return Fraction(ordered[midpoint])
        return Fraction(ordered[midpoint - 1] + ordered[midpoint], 2)
    if measure == "MIN_SPEND":
        return Fraction(ordered[0])
    return Fraction(ordered[-1])


def _aggregate(
    records: list[NormalizedRecord],
    grouping: AnalysisGrouping,
    measure: AnalysisMeasure,
) -> tuple[AnalysisGroup, ...]:
    grouped: dict[str, list[NormalizedRecord]] = {}
    for record in records:
        grouped.setdefault(_group_key(record, grouping), []).append(record)
    groups = tuple(
        AnalysisGroup(
            key=key,
            value=_aggregate_value(grouped[key], measure),
            record_count=len(grouped[key]),
            evidence_ids=tuple(
                sorted(
                    {
                        evidence_id
                        for record in grouped[key]
                        for evidence_id in record.evidence_ids
                    }
                )
            ),
        )
        for key in sorted(grouped)
    )
    if measure != "SHARE_OF_SPEND":
        return groups
    total_spend = sum((group.value for group in groups), Fraction(0))
    return tuple(
        AnalysisGroup(
            key=group.key,
            value=(group.value / total_spend if total_spend else Fraction(0)),
            record_count=group.record_count,
            evidence_ids=group.evidence_ids,
        )
        for group in groups
    )


def _comparison_period(spec: AnalysisSpec) -> tuple[date, date] | None:
    if spec.comparison == "NONE":
        return None
    if spec.comparison == "PREVIOUS_PERIOD":
        days = (spec.end_date - spec.start_date).days + 1
        comparison_end = spec.start_date - timedelta(days=1)
        return comparison_end - timedelta(days=days - 1), comparison_end

    def prior_year(day: date) -> date:
        try:
            return day.replace(year=day.year - 1)
        except ValueError:
            return day.replace(year=day.year - 1, day=28)

    return prior_year(spec.start_date), prior_year(spec.end_date)


def analyse_finance(
    spec: AnalysisSpec,
    *,
    transactions: tuple[TransactionRecord, ...] | list[TransactionRecord] = (),
    purchase_lines: tuple[PurchaseLineRecord, ...] | list[PurchaseLineRecord] = (),
) -> AnalysisResult:
    """Execute a bounded analysis specification without SQL or dynamic expressions."""

    source: tuple[NormalizedRecord, ...]
    if spec.basis == "TRANSACTIONS":
        source = tuple(transactions)
    else:
        source = tuple(purchase_lines)
    allowed_spaces = set(spec.allowed_space_ids)

    def records_between(start: date, end: date) -> list[NormalizedRecord]:
        return [
            record
            for record in source
            if record.space_id in allowed_spaces
            and start <= record.day <= end
            and (
                record.amount.currency
                if isinstance(record, TransactionRecord)
                else record.net_amount.currency
            )
            == spec.currency
            and _matches(record, spec.filters)
            and _relevant_to_measure(record, spec.measure)
        ]

    current = records_between(spec.start_date, spec.end_date)
    groups = _aggregate(current, spec.grouping, spec.measure)
    evidence_ids = tuple(
        sorted(
            {
                evidence_id
                for record in current
                for evidence_id in record.evidence_ids
            }
        )
    )
    comparison_period = _comparison_period(spec)
    comparison_groups: tuple[AnalysisGroup, ...] = ()
    comparison_total = None
    comparison_start = None
    comparison_end = None
    if comparison_period is not None:
        comparison_start, comparison_end = comparison_period
        previous = records_between(comparison_start, comparison_end)
        comparison_groups = _aggregate(previous, spec.grouping, spec.measure)
        comparison_total = _aggregate_value(previous, spec.measure)

    total = _aggregate_value(current, spec.measure)
    if spec.measure == "SHARE_OF_SPEND":
        total = Fraction(1 if current else 0)
    if spec.measure == "SHARE_OF_SPEND" and comparison_total is not None:
        comparison_total = Fraction(1 if previous else 0)
    return AnalysisResult(
        spec=spec,
        groups=groups,
        total=total,
        evidence_ids=evidence_ids,
        comparison_start_date=comparison_start,
        comparison_end_date=comparison_end,
        comparison_groups=comparison_groups,
        comparison_total=comparison_total,
    )

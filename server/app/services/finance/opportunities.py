"""Pure aggregate, habit, opportunity, and product-value calculations."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from fractions import Fraction
from typing import Literal

from app.services.finance.analytics import PurchaseLineRecord
from app.services.finance.money import Money, normalise_currency


def _exact_fraction(value: int | str | Decimal | Fraction, *, label: str) -> Fraction:
    if isinstance(value, bool) or isinstance(value, float):
        raise TypeError(f"{label} must be exact, not a binary float")
    try:
        return value if isinstance(value, Fraction) else Fraction(value)
    except (TypeError, ValueError, ZeroDivisionError) as exc:
        raise ValueError(f"{label} must be exact") from exc


def _median(values: list[int]) -> Fraction:
    ordered = sorted(values)
    midpoint = len(ordered) // 2
    if len(ordered) % 2:
        return Fraction(ordered[midpoint])
    return Fraction(ordered[midpoint - 1] + ordered[midpoint], 2)


@dataclass(frozen=True, slots=True)
class SeasonalPattern:
    key: str
    peak_months: tuple[int, ...]
    peak_total_minor: int
    typical_other_month_minor: Fraction
    evidence_ids: tuple[str, ...]


def detect_seasonal_patterns(
    lines: tuple[PurchaseLineRecord, ...] | list[PurchaseLineRecord],
    *,
    allowed_space_ids: tuple[str, ...] | list[str],
    currency: str,
) -> tuple[SeasonalPattern, ...]:
    """Detect strong month-of-year concentration for category/item labels."""

    spaces = set(allowed_space_ids)
    grouped: dict[str, list[PurchaseLineRecord]] = {}
    for line in lines:
        if line.space_id not in spaces or line.net_amount.currency != currency:
            continue
        key = line.category or line.normalized_item
        if key and line.net_amount.minor_units > 0:
            grouped.setdefault(key, []).append(line)

    patterns: list[SeasonalPattern] = []
    for key in sorted(grouped):
        monthly = {month: 0 for month in range(1, 13)}
        observed_months: set[tuple[int, int]] = set()
        for line in grouped[key]:
            monthly[line.day.month] += line.net_amount.minor_units
            observed_months.add((line.day.year, line.day.month))
        if len(observed_months) < 4:
            continue
        peak = max(monthly.values())
        other_nonzero = [value for value in monthly.values() if 0 < value < peak]
        if not other_nonzero:
            continue
        typical = _median(other_nonzero)
        if peak < 2 * typical:
            continue
        peak_months = tuple(
            month
            for month, value in monthly.items()
            if value >= Fraction(peak * 3, 4) and value >= 2 * typical
        )
        patterns.append(
            SeasonalPattern(
                key=key,
                peak_months=peak_months,
                peak_total_minor=peak,
                typical_other_month_minor=typical,
                evidence_ids=tuple(
                    sorted(
                        {
                            evidence_id
                            for line in grouped[key]
                            if line.day.month in peak_months
                            for evidence_id in line.evidence_ids
                        }
                    )
                ),
            )
        )
    return tuple(patterns)


@dataclass(frozen=True, slots=True)
class RepeatedPurchasePattern:
    item: str
    purchase_count: int
    returned_count: int
    duplicate_count: int
    total_minor: int
    evidence_ids: tuple[str, ...]


def detect_repeated_purchase_patterns(
    lines: tuple[PurchaseLineRecord, ...] | list[PurchaseLineRecord],
    *,
    allowed_space_ids: tuple[str, ...] | list[str],
    currency: str,
    minimum_count: int = 3,
) -> tuple[RepeatedPurchasePattern, ...]:
    spaces = set(allowed_space_ids)
    grouped: dict[str, list[PurchaseLineRecord]] = {}
    for line in lines:
        if (
            line.space_id in spaces
            and line.net_amount.currency == currency
            and line.normalized_item
            and line.net_amount.minor_units > 0
        ):
            grouped.setdefault(line.normalized_item, []).append(line)
    return tuple(
        RepeatedPurchasePattern(
            item=item,
            purchase_count=len(grouped[item]),
            returned_count=sum(line.outcome == "returned" for line in grouped[item]),
            duplicate_count=sum("duplicate_item" in line.tags for line in grouped[item]),
            total_minor=sum(line.net_amount.minor_units for line in grouped[item]),
            evidence_ids=tuple(
                sorted(
                    {
                        evidence_id
                        for line in grouped[item]
                        for evidence_id in line.evidence_ids
                    }
                )
            ),
        )
        for item in sorted(grouped)
        if len(grouped[item]) >= minimum_count
    )


@dataclass(frozen=True, slots=True)
class HabitFilter:
    categories: tuple[str, ...] = ()
    normalized_items: tuple[str, ...] = ()
    plannedness: tuple[str, ...] = ()
    outcomes: tuple[str, ...] = ()
    tags: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class HabitSpec:
    id: str
    baseline_start: date
    baseline_end: date
    observation_start: date
    observation_end: date
    currency: str
    allowed_space_ids: tuple[str, ...]
    filters: HabitFilter

    def __post_init__(self) -> None:
        if self.baseline_end < self.baseline_start:
            raise ValueError("Habit baseline dates are invalid")
        if self.observation_end < self.observation_start:
            raise ValueError("Habit observation dates are invalid")
        if not self.allowed_space_ids:
            raise ValueError("Habit measurement requires an authorized Finance space")
        object.__setattr__(self, "currency", normalise_currency(self.currency))


@dataclass(frozen=True, slots=True)
class HabitMeasurement:
    habit_id: str
    baseline_spend_minor: int
    observation_spend_minor: int
    baseline_daily_minor: Fraction
    observation_daily_minor: Fraction
    expected_observation_baseline_minor: Fraction
    estimated_saving_minor: Fraction
    baseline_evidence_ids: tuple[str, ...]
    observation_evidence_ids: tuple[str, ...]


def _habit_matches(line: PurchaseLineRecord, filters: HabitFilter) -> bool:
    return (
        (not filters.categories or line.category in filters.categories)
        and (
            not filters.normalized_items
            or line.normalized_item in filters.normalized_items
        )
        and (not filters.plannedness or line.plannedness in filters.plannedness)
        and (not filters.outcomes or line.outcome in filters.outcomes)
        and (not filters.tags or bool(set(filters.tags) & set(line.tags)))
    )


def measure_habit(
    spec: HabitSpec,
    lines: tuple[PurchaseLineRecord, ...] | list[PurchaseLineRecord],
) -> HabitMeasurement:
    spaces = set(spec.allowed_space_ids)
    eligible = [
        line
        for line in lines
        if line.space_id in spaces
        and line.net_amount.currency == spec.currency
        and _habit_matches(line, spec.filters)
    ]
    baseline = [
        line for line in eligible if spec.baseline_start <= line.day <= spec.baseline_end
    ]
    observation = [
        line
        for line in eligible
        if spec.observation_start <= line.day <= spec.observation_end
    ]
    baseline_total = sum(line.net_amount.minor_units for line in baseline)
    observation_total = sum(line.net_amount.minor_units for line in observation)
    baseline_days = (spec.baseline_end - spec.baseline_start).days + 1
    observation_days = (spec.observation_end - spec.observation_start).days + 1
    baseline_daily = Fraction(baseline_total, baseline_days)
    observation_daily = Fraction(observation_total, observation_days)
    expected = baseline_daily * observation_days
    return HabitMeasurement(
        habit_id=spec.id,
        baseline_spend_minor=baseline_total,
        observation_spend_minor=observation_total,
        baseline_daily_minor=baseline_daily,
        observation_daily_minor=observation_daily,
        expected_observation_baseline_minor=expected,
        estimated_saving_minor=max(Fraction(0), expected - observation_total),
        baseline_evidence_ids=tuple(
            sorted({evidence for line in baseline for evidence in line.evidence_ids})
        ),
        observation_evidence_ids=tuple(
            sorted({evidence for line in observation for evidence in line.evidence_ids})
        ),
    )


@dataclass(frozen=True, slots=True)
class OpportunityCandidate:
    id: str
    saving_low_minor: int
    saving_high_minor: int
    confidence: Fraction
    effort: int
    evidence_ids: tuple[str, ...]
    overlap_group: str | None = None

    def __post_init__(self) -> None:
        if self.saving_low_minor < 0 or self.saving_high_minor < self.saving_low_minor:
            raise ValueError("Opportunity saving range is invalid")
        confidence = _exact_fraction(self.confidence, label="confidence")
        object.__setattr__(self, "confidence", confidence)
        if not 0 <= confidence <= 1:
            raise ValueError("Opportunity confidence must be between zero and one")
        if self.effort < 1:
            raise ValueError("Opportunity effort must be positive")

    @property
    def score(self) -> Fraction:
        return (
            Fraction(self.saving_low_minor + self.saving_high_minor, 2)
            * self.confidence
            / self.effort
        )


@dataclass(frozen=True, slots=True)
class OpportunityRanking:
    selected: tuple[OpportunityCandidate, ...]
    suppressed_ids: tuple[str, ...]
    combined_saving_low_minor: int
    combined_saving_high_minor: int


def rank_opportunities(
    candidates: tuple[OpportunityCandidate, ...] | list[OpportunityCandidate],
) -> OpportunityRanking:
    ordered = sorted(candidates, key=lambda item: (-item.score, item.id))
    used_overlap_groups: set[str] = set()
    selected: list[OpportunityCandidate] = []
    suppressed: list[str] = []
    for candidate in ordered:
        if candidate.overlap_group and candidate.overlap_group in used_overlap_groups:
            suppressed.append(candidate.id)
            continue
        selected.append(candidate)
        if candidate.overlap_group:
            used_overlap_groups.add(candidate.overlap_group)
    return OpportunityRanking(
        selected=tuple(selected),
        suppressed_ids=tuple(sorted(suppressed)),
        combined_saving_low_minor=sum(item.saving_low_minor for item in selected),
        combined_saving_high_minor=sum(item.saving_high_minor for item in selected),
    )


MatchKind = Literal["EXACT", "REALISTIC", "AMBIGUOUS"]
ComparisonStatus = Literal[
    "BETTER_VALUE",
    "NOT_WORTH_SPLIT_SHOP",
    "NO_SAVING",
    "NO_ACCEPTABLE_MATCH",
    "UNKNOWN",
]


@dataclass(frozen=True, slots=True)
class ProductPriceObservation:
    id: str
    normalized_item: str
    retailer: str
    brand: str | None
    observed_on: date
    price: Money
    pack_quantity: int | str | Decimal | Fraction
    unit: str
    match_kind: MatchKind = "EXACT"
    allergens: tuple[str, ...] = ()
    evidence_ids: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        quantity = _exact_fraction(self.pack_quantity, label="pack_quantity")
        if quantity <= 0 or self.price.minor_units <= 0:
            raise ValueError("Product pack quantity and price must be positive")
        if not self.id or not self.normalized_item or not self.retailer or not self.unit:
            raise ValueError("Product identity, retailer and unit are required")
        if self.match_kind not in {"EXACT", "REALISTIC", "AMBIGUOUS"}:
            raise ValueError("Unknown product match kind")
        object.__setattr__(self, "pack_quantity", quantity)
        object.__setattr__(self, "allergens", tuple(self.allergens))
        object.__setattr__(self, "evidence_ids", tuple(self.evidence_ids) or (self.id,))

    @property
    def unit_price_minor(self) -> Fraction:
        return Fraction(self.price.minor_units) / self.pack_quantity


@dataclass(frozen=True, slots=True)
class UnitPriceDrift:
    normalized_item: str
    retailer: str
    unit: str
    first_observed_on: date
    latest_observed_on: date
    first_unit_price_minor: Fraction
    latest_unit_price_minor: Fraction
    change_minor: Fraction
    evidence_ids: tuple[str, ...]


def detect_unit_price_drift(
    observations: tuple[ProductPriceObservation, ...] | list[ProductPriceObservation],
) -> tuple[UnitPriceDrift, ...]:
    grouped: dict[tuple[str, str, str, str], list[ProductPriceObservation]] = {}
    for observation in observations:
        key = (
            observation.normalized_item,
            observation.retailer,
            observation.unit,
            observation.price.currency,
        )
        grouped.setdefault(key, []).append(observation)

    drifts: list[UnitPriceDrift] = []
    for key in sorted(grouped):
        ordered = sorted(grouped[key], key=lambda item: (item.observed_on, item.id))
        if len(ordered) < 2:
            continue
        first = ordered[0]
        latest = ordered[-1]
        change = latest.unit_price_minor - first.unit_price_minor
        if change <= 0:
            continue
        drifts.append(
            UnitPriceDrift(
                normalized_item=key[0],
                retailer=key[1],
                unit=key[2],
                first_observed_on=first.observed_on,
                latest_observed_on=latest.observed_on,
                first_unit_price_minor=first.unit_price_minor,
                latest_unit_price_minor=latest.unit_price_minor,
                change_minor=change,
                evidence_ids=tuple(
                    sorted(
                        {
                            evidence
                            for observation in ordered
                            for evidence in observation.evidence_ids
                        }
                    )
                ),
            )
        )
    return tuple(drifts)


@dataclass(frozen=True, slots=True)
class ProductComparisonConstraints:
    as_of: date
    max_price_age_days: int = 30
    locked_brand: str | None = None
    prohibited_allergens: tuple[str, ...] = ()
    split_shop_hassle_minor: int = 0
    minimum_split_shop_saving_minor: int = 1_500

    def __post_init__(self) -> None:
        if self.max_price_age_days < 0:
            raise ValueError("max_price_age_days cannot be negative")
        if self.split_shop_hassle_minor < 0 or self.minimum_split_shop_saving_minor < 0:
            raise ValueError("Split-shop costs and threshold cannot be negative")
        object.__setattr__(self, "prohibited_allergens", tuple(self.prohibited_allergens))


@dataclass(frozen=True, slots=True)
class ProductComparisonResult:
    status: ComparisonStatus
    source_id: str
    candidate_id: str | None
    source_unit_price_minor: Fraction
    candidate_unit_price_minor: Fraction | None
    gross_saving_minor: Fraction | None
    net_saving_minor: Fraction | None
    evidence_ids: tuple[str, ...]
    reason: str | None


def compare_product_prices(
    source: ProductPriceObservation,
    candidates: tuple[ProductPriceObservation, ...] | list[ProductPriceObservation],
    constraints: ProductComparisonConstraints,
) -> ProductComparisonResult:
    """Compare exact normalized units while honoring explicit household constraints."""

    source_age = (constraints.as_of - source.observed_on).days
    if not 0 <= source_age <= constraints.max_price_age_days:
        return ProductComparisonResult(
            "UNKNOWN",
            source.id,
            None,
            source.unit_price_minor,
            None,
            None,
            None,
            source.evidence_ids,
            "SOURCE_PRICE_STALE",
        )

    prohibited = set(constraints.prohibited_allergens)
    eligible: list[tuple[Fraction, ProductPriceObservation, Fraction, Fraction]] = []
    uncertain_seen = False
    constraint_exclusion_seen = False
    for candidate in candidates:
        if candidate.price.currency != source.price.currency:
            continue
        if candidate.normalized_item != source.normalized_item or candidate.unit != source.unit:
            uncertain_seen = True
            continue
        if candidate.match_kind == "AMBIGUOUS":
            uncertain_seen = True
            continue
        candidate_age = (constraints.as_of - candidate.observed_on).days
        if not 0 <= candidate_age <= constraints.max_price_age_days:
            uncertain_seen = True
            continue
        if constraints.locked_brand and candidate.brand != constraints.locked_brand:
            constraint_exclusion_seen = True
            continue
        if prohibited & set(candidate.allergens):
            constraint_exclusion_seen = True
            continue
        comparable_cost = candidate.unit_price_minor * source.pack_quantity
        gross_saving = Fraction(source.price.minor_units) - comparable_cost
        hassle = (
            constraints.split_shop_hassle_minor
            if candidate.retailer != source.retailer
            else 0
        )
        net_saving = gross_saving - hassle
        eligible.append((net_saving, candidate, comparable_cost, gross_saving))

    if not eligible:
        reason = "MATCH_OR_PRICE_UNCERTAIN" if uncertain_seen else "HOUSEHOLD_CONSTRAINT"
        status: ComparisonStatus = "UNKNOWN" if uncertain_seen else "NO_ACCEPTABLE_MATCH"
        if not uncertain_seen and not constraint_exclusion_seen:
            reason = "NO_COMPARABLE_PRICE"
            status = "UNKNOWN"
        return ProductComparisonResult(
            status,
            source.id,
            None,
            source.unit_price_minor,
            None,
            None,
            None,
            source.evidence_ids,
            reason,
        )

    net_saving, candidate, _, gross_saving = sorted(
        eligible,
        key=lambda item: (-item[0], item[1].retailer, item[1].id),
    )[0]
    evidence_ids = tuple(sorted(set(source.evidence_ids + candidate.evidence_ids)))
    if net_saving <= 0:
        status = "NO_SAVING"
        reason = "ALTERNATIVE_NOT_CHEAPER"
    elif (
        candidate.retailer != source.retailer
        and net_saving < constraints.minimum_split_shop_saving_minor
    ):
        status = "NOT_WORTH_SPLIT_SHOP"
        reason = "BELOW_SPLIT_SHOP_THRESHOLD"
    else:
        status = "BETTER_VALUE"
        reason = None
    return ProductComparisonResult(
        status=status,
        source_id=source.id,
        candidate_id=candidate.id,
        source_unit_price_minor=source.unit_price_minor,
        candidate_unit_price_minor=candidate.unit_price_minor,
        gross_saving_minor=gross_saving,
        net_saving_minor=net_saving,
        evidence_ids=evidence_ids,
        reason=reason,
    )

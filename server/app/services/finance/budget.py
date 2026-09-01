"""Exact minimal-disruption Finance budget allocator."""

from __future__ import annotations

import heapq
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from decimal import Decimal
from fractions import Fraction
from typing import Literal

ExactWeight = int | str | Decimal | Fraction
BudgetStatus = Literal["FEASIBLE", "INFEASIBLE", "FORECAST_INFEASIBLE"]


def _exact_fraction(value: ExactWeight, *, label: str) -> Fraction:
    if isinstance(value, bool) or isinstance(value, float):
        raise TypeError(f"{label} must be exact, not a binary float")
    try:
        return value if isinstance(value, Fraction) else Fraction(value)
    except (TypeError, ValueError, ZeroDivisionError) as exc:
        raise ValueError(f"{label} must be an exact number") from exc


def _minor_units(value: int, *, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{label} must be integer minor units")
    return value


@dataclass(frozen=True, slots=True)
class BudgetCategory:
    id: str
    baseline_minor: int
    floor_minor: int
    weight: ExactWeight = 1
    protected: bool = False

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id:
            raise ValueError("Budget category IDs must be non-empty strings")
        _minor_units(self.baseline_minor, label=f"baseline for {self.id}")
        _minor_units(self.floor_minor, label=f"floor for {self.id}")
        if self.baseline_minor < 0 or self.floor_minor < 0:
            raise ValueError("Budget baselines and floors cannot be negative")
        if self.floor_minor > self.baseline_minor:
            raise ValueError("Budget floor cannot exceed baseline")
        if _exact_fraction(self.weight, label=f"weight for {self.id}") <= 0:
            raise ValueError("Budget weights must be positive")
        if not isinstance(self.protected, bool):
            raise TypeError("protected must be a boolean")

    @property
    def cut_cap_minor(self) -> int:
        return 0 if self.protected else self.baseline_minor - self.floor_minor

    @property
    def normalisation_minor(self) -> int:
        return max(self.baseline_minor, 1)

    @property
    def exact_weight(self) -> Fraction:
        return _exact_fraction(self.weight, label=f"weight for {self.id}")


@dataclass(frozen=True, slots=True)
class ForecastValidationResult:
    passed: bool
    limiting_event_id: str | None = None
    limiting_date: str | None = None
    detail: str | None = None


@dataclass(frozen=True, slots=True)
class BudgetAllocation:
    category_id: str
    baseline_minor: int
    floor_minor: int
    cut_cap_minor: int
    continuous_reduction: Fraction
    reduction_minor: int
    budget_minor: int


@dataclass(frozen=True, slots=True)
class BudgetResult:
    status: BudgetStatus
    required_reduction_minor: int
    achieved_reduction_minor: int
    shortfall_minor: int
    allocations: tuple[BudgetAllocation, ...]
    objective: Fraction
    forecast_validation: ForecastValidationResult | None

    @property
    def reductions(self) -> dict[str, int]:
        return {
            allocation.category_id: allocation.reduction_minor
            for allocation in self.allocations
        }

    @property
    def budgets(self) -> dict[str, int]:
        return {
            allocation.category_id: allocation.budget_minor
            for allocation in self.allocations
        }


ForecastValidator = Callable[
    [Mapping[str, int]],
    ForecastValidationResult | bool,
]


def _continuous_kkt(
    categories: tuple[BudgetCategory, ...],
    required_reduction_minor: int,
) -> dict[str, Fraction]:
    reductions = {category.id: Fraction(0) for category in categories}
    active = {
        category.id: category for category in categories if category.cut_cap_minor > 0
    }
    remaining = Fraction(required_reduction_minor)

    while remaining > 0:
        if not active:
            raise AssertionError("Feasibility must be checked before KKT allocation")
        coefficients = {
            category_id: Fraction(category.normalisation_minor**2, 1)
            / (2 * category.exact_weight)
            for category_id, category in active.items()
        }
        coefficient_total = sum(coefficients.values(), Fraction(0))
        proposed = {
            category_id: remaining * coefficient / coefficient_total
            for category_id, coefficient in coefficients.items()
        }
        capped = [
            category_id
            for category_id, share in proposed.items()
            if share >= active[category_id].cut_cap_minor
        ]
        if not capped:
            for category_id, share in proposed.items():
                reductions[category_id] = share
            remaining = Fraction(0)
            break

        for category_id in sorted(capped):
            cap = active[category_id].cut_cap_minor
            reductions[category_id] = Fraction(cap)
            remaining -= cap
            del active[category_id]

    return reductions


def _next_marginal_cost(category: BudgetCategory, reduction_minor: int) -> Fraction:
    return (
        category.exact_weight
        * (2 * reduction_minor + 1)
        / (category.normalisation_minor**2)
    )


def _integer_completion(
    categories: tuple[BudgetCategory, ...],
    continuous: Mapping[str, Fraction],
    required_reduction_minor: int,
) -> dict[str, int]:
    by_id = {category.id: category for category in categories}
    reductions = {
        category.id: continuous[category.id].numerator
        // continuous[category.id].denominator
        for category in categories
    }
    remaining = required_reduction_minor - sum(reductions.values())
    if not 0 <= remaining < max(1, len(categories)):
        raise AssertionError("KKT penny remainder must be smaller than category count")

    heap: list[tuple[Fraction, str]] = []
    for category in categories:
        current = reductions[category.id]
        if current < category.cut_cap_minor:
            heapq.heappush(
                heap,
                (_next_marginal_cost(category, current), category.id),
            )

    # The exact continuous reductions sum to an integer, so this runs at most n - 1 times.
    for _ in range(remaining):
        if not heap:
            raise AssertionError("Integer completion ran out of category capacity")
        _, category_id = heapq.heappop(heap)
        reductions[category_id] += 1
        category = by_id[category_id]
        if reductions[category_id] < category.cut_cap_minor:
            heapq.heappush(
                heap,
                (
                    _next_marginal_cost(category, reductions[category_id]),
                    category_id,
                ),
            )
    return reductions


def budget_objective(
    categories: tuple[BudgetCategory, ...],
    reductions: Mapping[str, int],
) -> Fraction:
    return sum(
        (
            category.exact_weight
            * reductions[category.id] ** 2
            / category.normalisation_minor**2
            for category in categories
        ),
        Fraction(0),
    )


def _allocations(
    categories: tuple[BudgetCategory, ...],
    continuous: Mapping[str, Fraction],
    reductions: Mapping[str, int],
) -> tuple[BudgetAllocation, ...]:
    return tuple(
        BudgetAllocation(
            category_id=category.id,
            baseline_minor=category.baseline_minor,
            floor_minor=category.floor_minor,
            cut_cap_minor=category.cut_cap_minor,
            continuous_reduction=continuous[category.id],
            reduction_minor=reductions[category.id],
            budget_minor=category.baseline_minor - reductions[category.id],
        )
        for category in categories
    )


def _normalise_validation(
    value: ForecastValidationResult | bool,
) -> ForecastValidationResult:
    if isinstance(value, ForecastValidationResult):
        return value
    if isinstance(value, bool):
        return ForecastValidationResult(passed=value)
    raise TypeError("forecast_validator must return bool or ForecastValidationResult")


def allocate_minimal_disruption_budget(
    categories: tuple[BudgetCategory, ...] | list[BudgetCategory],
    required_reduction_minor: int,
    *,
    forecast_validator: ForecastValidator | None = None,
) -> BudgetResult:
    """Solve the clipped rational KKT objective and exact integer completion."""

    required_reduction_minor = _minor_units(
        required_reduction_minor,
        label="required_reduction_minor",
    )
    if required_reduction_minor < 0:
        raise ValueError("required_reduction_minor cannot be negative")
    ordered = tuple(sorted(tuple(categories), key=lambda category: category.id))
    if len({category.id for category in ordered}) != len(ordered):
        raise ValueError("Budget category IDs must be unique")

    total_capacity = sum(category.cut_cap_minor for category in ordered)
    if required_reduction_minor > total_capacity:
        reductions = {category.id: category.cut_cap_minor for category in ordered}
        continuous = {
            category.id: Fraction(category.cut_cap_minor) for category in ordered
        }
        return BudgetResult(
            status="INFEASIBLE",
            required_reduction_minor=required_reduction_minor,
            achieved_reduction_minor=total_capacity,
            shortfall_minor=required_reduction_minor - total_capacity,
            allocations=_allocations(ordered, continuous, reductions),
            objective=budget_objective(ordered, reductions),
            forecast_validation=None,
        )

    continuous = _continuous_kkt(ordered, required_reduction_minor)
    reductions = _integer_completion(ordered, continuous, required_reduction_minor)
    allocations = _allocations(ordered, continuous, reductions)
    validation = None
    status: BudgetStatus = "FEASIBLE"
    if forecast_validator is not None:
        budgets = {
            allocation.category_id: allocation.budget_minor for allocation in allocations
        }
        validation = _normalise_validation(forecast_validator(budgets))
        if not validation.passed:
            status = "FORECAST_INFEASIBLE"

    return BudgetResult(
        status=status,
        required_reduction_minor=required_reduction_minor,
        achieved_reduction_minor=sum(reductions.values()),
        shortfall_minor=0,
        allocations=allocations,
        objective=budget_objective(ordered, reductions),
        forecast_validation=validation,
    )

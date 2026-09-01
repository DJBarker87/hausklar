"""Focused exact minimal-disruption budget tests."""

from fractions import Fraction
from itertools import product

from app.services.finance.budget import (
    BudgetCategory,
    ForecastValidationResult,
    allocate_minimal_disruption_budget,
    budget_objective,
)


def _brute_force_best(categories: tuple[BudgetCategory, ...], required: int) -> Fraction:
    candidates = []
    ranges = [range(category.cut_cap_minor + 1) for category in categories]
    for reductions_tuple in product(*ranges):
        if sum(reductions_tuple) != required:
            continue
        reductions = {
            category.id: reduction
            for category, reduction in zip(categories, reductions_tuple, strict=True)
        }
        candidates.append(budget_objective(categories, reductions))
    return min(candidates)


def test_exact_kkt_integer_result_matches_small_brute_force_and_stable_ties():
    categories = (
        BudgetCategory("b", baseline_minor=7, floor_minor=1, weight=1),
        BudgetCategory("a", baseline_minor=7, floor_minor=1, weight=1),
        BudgetCategory("c", baseline_minor=5, floor_minor=2, weight=2),
    )

    result = allocate_minimal_disruption_budget(categories, 5)

    ordered = tuple(sorted(categories, key=lambda category: category.id))
    assert result.status == "FEASIBLE"
    assert result.achieved_reduction_minor == 5
    assert result.objective == _brute_force_best(ordered, 5)
    assert sum(result.reductions.values()) == 5

    tie = allocate_minimal_disruption_budget(
        [
            BudgetCategory("b", baseline_minor=10, floor_minor=0),
            BudgetCategory("a", baseline_minor=10, floor_minor=0),
        ],
        1,
    )
    assert tie.reductions == {"a": 1, "b": 0}


def test_integer_solution_has_no_improving_one_penny_exchange():
    categories = (
        BudgetCategory("food", 20, 5, weight=3),
        BudgetCategory("fun", 15, 0, weight=1),
        BudgetCategory("home", 17, 4, weight=2),
    )
    result = allocate_minimal_disruption_budget(categories, 19)
    current = result.objective

    for source in categories:
        if result.reductions[source.id] == 0:
            continue
        for destination in categories:
            if source.id == destination.id:
                continue
            if result.reductions[destination.id] >= destination.cut_cap_minor:
                continue
            exchanged = dict(result.reductions)
            exchanged[source.id] -= 1
            exchanged[destination.id] += 1
            assert budget_objective(categories, exchanged) >= current


def test_floors_protections_and_exact_infeasibility_shortfall():
    categories = (
        BudgetCategory("children", 1_000, 500, protected=True),
        BudgetCategory("optional", 900, 400, weight=1),
    )

    feasible = allocate_minimal_disruption_budget(categories, 500)
    assert feasible.status == "FEASIBLE"
    assert feasible.reductions == {"children": 0, "optional": 500}
    assert feasible.budgets == {"children": 1_000, "optional": 400}

    infeasible = allocate_minimal_disruption_budget(categories, 650)
    assert infeasible.status == "INFEASIBLE"
    assert infeasible.achieved_reduction_minor == 500
    assert infeasible.shortfall_minor == 150
    assert infeasible.reductions == {"children": 0, "optional": 500}


def test_large_shortfall_completion_is_bounded_and_forecast_hook_is_reported():
    categories = (
        BudgetCategory("a", 10**12, 0, weight=1),
        BudgetCategory("b", 10**12, 0, weight=2),
        BudgetCategory("c", 10**12, 0, weight=3),
    )

    result = allocate_minimal_disruption_budget(
        categories,
        10**12 + 1,
        forecast_validator=lambda budgets: ForecastValidationResult(
            passed=False,
            limiting_event_id="nursery",
            limiting_date="2026-09-01",
            detail=f"Validated {len(budgets)} category budgets",
        ),
    )

    assert result.status == "FORECAST_INFEASIBLE"
    assert result.achieved_reduction_minor == 10**12 + 1
    assert result.forecast_validation is not None
    assert result.forecast_validation.limiting_event_id == "nursery"
    assert result.forecast_validation.limiting_date == "2026-09-01"

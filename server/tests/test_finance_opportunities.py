"""Focused deterministic opportunity, habit, and product comparison tests."""

from datetime import date
from fractions import Fraction

from app.services.finance.analytics import PurchaseLineRecord
from app.services.finance.money import Money
from app.services.finance.opportunities import (
    HabitFilter,
    HabitSpec,
    OpportunityCandidate,
    ProductComparisonConstraints,
    ProductPriceObservation,
    compare_product_prices,
    detect_repeated_purchase_patterns,
    detect_seasonal_patterns,
    detect_unit_price_drift,
    measure_habit,
    rank_opportunities,
)


def _line(
    line_id: str,
    day: date,
    amount: int,
    *,
    category: str,
    item: str,
    outcome: str | None = None,
    tags: tuple[str, ...] = (),
) -> PurchaseLineRecord:
    return PurchaseLineRecord(
        line_id,
        "dom",
        day,
        Money(amount, "GBP"),
        category=category,
        normalized_item=item,
        outcome=outcome,
        tags=tags,
        evidence_ids=(f"evidence:{line_id}",),
    )


def test_december_garden_seasonality_and_repeated_gadget_returns():
    lines = [
        _line("xmas-jan", date(2026, 1, 5), 100, category="christmas", item="gift"),
        _line("xmas-feb", date(2026, 2, 5), 100, category="christmas", item="gift"),
        _line("xmas-mar", date(2026, 3, 5), 100, category="christmas", item="gift"),
        _line("xmas-dec", date(2026, 12, 5), 1_000, category="christmas", item="gift"),
        _line("garden-apr", date(2026, 4, 1), 100, category="garden", item="garden"),
        _line("garden-may", date(2026, 5, 1), 100, category="garden", item="garden"),
        _line("garden-jun", date(2026, 6, 1), 700, category="garden", item="garden"),
        _line("garden-jul", date(2026, 7, 1), 800, category="garden", item="garden"),
        _line("garden-aug", date(2026, 8, 1), 700, category="garden", item="garden"),
        _line("garden-sep", date(2026, 9, 1), 100, category="garden", item="garden"),
        _line("gadget-1", date(2026, 1, 10), 2_000, category="home", item="gadget", tags=("duplicate_item",)),
        _line("gadget-2", date(2026, 3, 10), 2_500, category="home", item="gadget", outcome="returned"),
        _line("gadget-3", date(2026, 7, 10), 1_500, category="home", item="gadget", tags=("duplicate_item",)),
        _line("gadget-4", date(2026, 11, 10), 3_000, category="home", item="gadget"),
    ]

    seasonal = {
        pattern.key: pattern
        for pattern in detect_seasonal_patterns(
            lines,
            allowed_space_ids=("dom",),
            currency="GBP",
        )
    }
    assert seasonal["christmas"].peak_months == (12,)
    assert seasonal["garden"].peak_months == (6, 7, 8)

    repeated = detect_repeated_purchase_patterns(
        lines,
        allowed_space_ids=("dom",),
        currency="GBP",
    )
    gadget = next(pattern for pattern in repeated if pattern.item == "gadget")
    assert gadget.purchase_count == 4
    assert gadget.duplicate_count == 2
    assert gadget.returned_count == 1
    assert gadget.total_minor == 9_000


def test_habit_measurement_and_overlap_suppression_do_not_double_count_savings():
    lines = [
        _line("baseline", date(2026, 1, 15), 3_100, category="home", item="gadget", tags=("optional",)),
        _line("observed", date(2026, 2, 15), 1_400, category="home", item="gadget", tags=("optional",)),
    ]
    measurement = measure_habit(
        HabitSpec(
            id="pause-gadgets",
            baseline_start=date(2026, 1, 1),
            baseline_end=date(2026, 1, 31),
            observation_start=date(2026, 2, 1),
            observation_end=date(2026, 2, 28),
            currency="GBP",
            allowed_space_ids=("dom",),
            filters=HabitFilter(tags=("optional",)),
        ),
        lines,
    )
    assert measurement.baseline_daily_minor == Fraction(100)
    assert measurement.expected_observation_baseline_minor == Fraction(2_800)
    assert measurement.estimated_saving_minor == Fraction(1_400)

    ranking = rank_opportunities(
        [
            OpportunityCandidate("cereal-item", 1_700, 2_200, Fraction(9, 10), 1, ("cereal",), "grocery-switch"),
            OpportunityCandidate("whole-basket", 5_000, 7_000, Fraction(3, 4), 3, ("basket",), "grocery-switch"),
            OpportunityCandidate("cancel-subscription", 3_000, 3_000, Fraction(1), 1, ("sub",)),
        ]
    )
    assert [item.id for item in ranking.selected] == ["cancel-subscription", "cereal-item"]
    assert ranking.suppressed_ids == ("whole-basket",)
    assert ranking.combined_saving_low_minor == 4_700
    assert ranking.combined_saving_high_minor == 5_200


def _price(
    price_id: str,
    retailer: str,
    brand: str,
    observed_on: date,
    price_minor: int,
    quantity: int,
    *,
    match_kind: str = "EXACT",
    allergens: tuple[str, ...] = (),
) -> ProductPriceObservation:
    return ProductPriceObservation(
        id=price_id,
        normalized_item="shredded_wheat_cereal",
        retailer=retailer,
        brand=brand,
        observed_on=observed_on,
        price=Money(price_minor, "GBP"),
        pack_quantity=quantity,
        unit="g",
        match_kind=match_kind,
        allergens=allergens,
    )


def test_shreddies_lock_substitution_staleness_unit_drift_and_split_shop_threshold():
    source = _price("tesco", "Tesco", "Shreddies", date(2026, 7, 20), 4_000, 5_000)
    aldi = _price("aldi", "Aldi", "Harvest Morn", date(2026, 7, 21), 2_000, 5_000)

    locked = compare_product_prices(
        source,
        [aldi],
        ProductComparisonConstraints(as_of=date(2026, 7, 25), locked_brand="Shreddies"),
    )
    assert locked.status == "NO_ACCEPTABLE_MATCH"
    assert locked.reason == "HOUSEHOLD_CONSTRAINT"

    allergy_locked = compare_product_prices(
        source,
        [
            _price(
                "allergen",
                "Aldi",
                "Harvest Morn",
                date(2026, 7, 21),
                2_000,
                5_000,
                allergens=("nuts",),
            )
        ],
        ProductComparisonConstraints(
            as_of=date(2026, 7, 25),
            prohibited_allergens=("nuts",),
        ),
    )
    assert allergy_locked.status == "NO_ACCEPTABLE_MATCH"

    substitution = compare_product_prices(
        source,
        [aldi],
        ProductComparisonConstraints(
            as_of=date(2026, 7, 25),
            split_shop_hassle_minor=200,
            minimum_split_shop_saving_minor=1_500,
        ),
    )
    assert substitution.status == "BETTER_VALUE"
    assert substitution.gross_saving_minor == Fraction(2_000)
    assert substitution.net_saving_minor == Fraction(1_800)

    below_threshold = compare_product_prices(
        source,
        [_price("aldi-close", "Aldi", "Harvest Morn", date(2026, 7, 21), 2_600, 5_000)],
        ProductComparisonConstraints(
            as_of=date(2026, 7, 25),
            minimum_split_shop_saving_minor=1_500,
        ),
    )
    assert below_threshold.status == "NOT_WORTH_SPLIT_SHOP"

    stale = compare_product_prices(
        source,
        [aldi],
        ProductComparisonConstraints(as_of=date(2026, 9, 1), max_price_age_days=30),
    )
    assert stale.status == "UNKNOWN"
    assert stale.reason == "SOURCE_PRICE_STALE"

    ambiguous = compare_product_prices(
        source,
        [_price("maybe", "Aldi", "Maybe cereal", date(2026, 7, 21), 1_000, 5_000, match_kind="AMBIGUOUS")],
        ProductComparisonConstraints(as_of=date(2026, 7, 25)),
    )
    assert ambiguous.status == "UNKNOWN"

    drift = detect_unit_price_drift(
        [
            _price("old", "Tesco", "Shreddies", date(2025, 7, 1), 350, 500),
            _price("new", "Tesco", "Shreddies", date(2026, 7, 1), 400, 500),
        ]
    )
    assert drift[0].first_unit_price_minor == Fraction(7, 10)
    assert drift[0].latest_unit_price_minor == Fraction(4, 5)
    assert drift[0].change_minor == Fraction(1, 10)

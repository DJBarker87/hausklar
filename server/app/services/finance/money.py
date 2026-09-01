"""Exact money and ordinary proportional-allocation primitives."""

import re
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal
from fractions import Fraction

_CURRENCY_PATTERN = re.compile(r"^[A-Z]{3}$")
ExactNumber = int | str | Decimal | Fraction


class CurrencyMismatchError(ValueError):
    """An operation mixed currencies without an explicit conversion."""


class AllocationError(ValueError):
    """An exact allocation request is impossible or malformed."""


def normalise_currency(value: str) -> str:
    if not isinstance(value, str):
        raise ValueError("Currency must be a three-letter code")
    currency = value.strip().upper()
    if not _CURRENCY_PATTERN.fullmatch(currency):
        raise ValueError("Currency must be a three-letter code")
    return currency


def _as_fraction(value: ExactNumber, *, label: str) -> Fraction:
    if isinstance(value, bool) or isinstance(value, float):
        raise TypeError(f"{label} must be an exact number, not a binary float")
    try:
        return value if isinstance(value, Fraction) else Fraction(value)
    except (TypeError, ValueError, ZeroDivisionError) as exc:
        raise ValueError(f"{label} must be an exact number") from exc


def _round_half_away_from_zero(value: Fraction) -> int:
    sign = -1 if value < 0 else 1
    numerator = abs(value.numerator)
    quotient, remainder = divmod(numerator, value.denominator)
    if remainder * 2 >= value.denominator:
        quotient += 1
    return sign * quotient


@dataclass(frozen=True, slots=True)
class Money:
    minor_units: int
    currency: str

    def __post_init__(self) -> None:
        if isinstance(self.minor_units, bool) or not isinstance(self.minor_units, int):
            raise TypeError("Money minor_units must be an integer")
        object.__setattr__(self, "currency", normalise_currency(self.currency))

    @classmethod
    def from_major(
        cls,
        amount: ExactNumber,
        currency: str,
        *,
        minor_unit_digits: int = 2,
    ) -> "Money":
        if isinstance(minor_unit_digits, bool) or not isinstance(minor_unit_digits, int):
            raise TypeError("minor_unit_digits must be an integer")
        if not 0 <= minor_unit_digits <= 6:
            raise ValueError("minor_unit_digits must be between 0 and 6")
        scaled = _as_fraction(amount, label="amount") * (10**minor_unit_digits)
        if scaled.denominator != 1:
            raise ValueError("Amount is not exact in the currency's minor units")
        return cls(scaled.numerator, currency)

    def to_major(self, *, minor_unit_digits: int = 2) -> Decimal:
        if isinstance(minor_unit_digits, bool) or not isinstance(minor_unit_digits, int):
            raise TypeError("minor_unit_digits must be an integer")
        if not 0 <= minor_unit_digits <= 6:
            raise ValueError("minor_unit_digits must be between 0 and 6")
        return Decimal(self.minor_units) / Decimal(10**minor_unit_digits)

    def _require_same_currency(self, other: "Money") -> None:
        if self.currency != other.currency:
            raise CurrencyMismatchError(
                f"Cannot combine {self.currency} and {other.currency} without conversion"
            )

    def __add__(self, other: object) -> "Money":
        if not isinstance(other, Money):
            return NotImplemented
        self._require_same_currency(other)
        return Money(self.minor_units + other.minor_units, self.currency)

    def __sub__(self, other: object) -> "Money":
        if not isinstance(other, Money):
            return NotImplemented
        self._require_same_currency(other)
        return Money(self.minor_units - other.minor_units, self.currency)

    def __neg__(self) -> "Money":
        return Money(-self.minor_units, self.currency)

    def __mul__(self, multiplier: object) -> "Money":
        if isinstance(multiplier, bool) or not isinstance(multiplier, int):
            return NotImplemented
        return Money(self.minor_units * multiplier, self.currency)

    __rmul__ = __mul__


@dataclass(frozen=True, slots=True)
class MoneyConversion:
    """An explicit conversion that retains the authoritative source amount."""

    source: Money
    converted: Money
    target_minor_per_source_minor: Fraction


def convert_money(
    source: Money,
    target_currency: str,
    *,
    target_minor_per_source_minor: ExactNumber,
) -> MoneyConversion:
    rate = _as_fraction(
        target_minor_per_source_minor,
        label="target_minor_per_source_minor",
    )
    if rate <= 0:
        raise ValueError("Conversion rate must be positive")
    converted = Money(
        _round_half_away_from_zero(source.minor_units * rate),
        target_currency,
    )
    return MoneyConversion(
        source=source,
        converted=converted,
        target_minor_per_source_minor=rate,
    )


def _validate_integer_bound(value: int | None, *, label: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{label} must be an integer minor-unit amount")
    return value


def allocate_minor_units(
    total: int,
    weights: Mapping[str, ExactNumber],
    *,
    lower_bounds: Mapping[str, int] | None = None,
    upper_bounds: Mapping[str, int] | None = None,
) -> dict[str, int]:
    """Allocate a signed total with stable Hamilton/largest-remainder rounding."""
    if isinstance(total, bool) or not isinstance(total, int):
        raise TypeError("total must be integer minor units")
    if any(not isinstance(key, str) or not key for key in weights):
        raise AllocationError("Allocation item IDs must be non-empty strings")

    keys = sorted(weights)
    exact_weights = {
        key: _as_fraction(weights[key], label=f"weight for {key}") for key in keys
    }
    if any(weight < 0 for weight in exact_weights.values()):
        raise AllocationError("Allocation weights cannot be negative")

    lower_bounds = lower_bounds or {}
    upper_bounds = upper_bounds or {}
    unknown_bounds = (set(lower_bounds) | set(upper_bounds)) - set(keys)
    if unknown_bounds:
        raise AllocationError("Bounds reference an unknown allocation item")

    signed_lower: dict[str, int | None] = {}
    signed_upper: dict[str, int | None] = {}
    for key in keys:
        lower = _validate_integer_bound(lower_bounds.get(key), label=f"lower bound for {key}")
        upper = _validate_integer_bound(upper_bounds.get(key), label=f"upper bound for {key}")
        if lower is not None and upper is not None and lower > upper:
            raise AllocationError(f"Lower bound exceeds upper bound for {key}")
        signed_lower[key] = lower
        signed_upper[key] = upper

    if total == 0:
        for key in keys:
            lower = signed_lower[key]
            upper = signed_upper[key]
            if (lower is not None and lower > 0) or (upper is not None and upper < 0):
                raise AllocationError("Zero total is outside the requested bounds")
        return {key: 0 for key in keys}
    if not keys:
        raise AllocationError("A non-zero total requires allocation items")

    magnitude = abs(total)
    magnitude_lower: dict[str, int] = {}
    magnitude_upper: dict[str, int | None] = {}
    for key in keys:
        lower = signed_lower[key]
        upper = signed_upper[key]
        if total > 0:
            item_lower = max(0, lower or 0)
            item_upper = upper
        else:
            item_lower = max(0, -upper if upper is not None else 0)
            item_upper = -lower if lower is not None else None
        if item_upper is not None and item_lower > item_upper:
            raise AllocationError(f"Bounds are incompatible with the total sign for {key}")
        magnitude_lower[key] = item_lower
        magnitude_upper[key] = item_upper

    allocated = dict(magnitude_lower)
    remaining = magnitude - sum(allocated.values())
    if remaining < 0:
        raise AllocationError("Lower bounds exceed the amount to allocate")
    if all(limit is not None for limit in magnitude_upper.values()):
        if sum(limit for limit in magnitude_upper.values() if limit is not None) < magnitude:
            raise AllocationError("Upper bounds cannot hold the amount to allocate")

    capacities: dict[str, int | None] = {
        key: (
            None
            if magnitude_upper[key] is None
            else magnitude_upper[key] - magnitude_lower[key]
        )
        for key in keys
    }

    while remaining:
        active = [
            key
            for key in keys
            if exact_weights[key] > 0 and (capacities[key] is None or capacities[key] > 0)
        ]
        total_weight = sum((exact_weights[key] for key in active), Fraction(0))
        if not active or total_weight == 0:
            raise AllocationError("Positive weight capacity is insufficient for the remainder")

        exact_shares = {
            key: Fraction(remaining) * exact_weights[key] / total_weight for key in active
        }
        capped = [
            key
            for key in active
            if capacities[key] is not None and exact_shares[key] > capacities[key]
        ]
        if capped:
            for key in capped:
                capacity = capacities[key]
                assert capacity is not None
                allocated[key] += capacity
                remaining -= capacity
                capacities[key] = 0
            continue

        floors: dict[str, int] = {}
        for key in active:
            floor_share = exact_shares[key].numerator // exact_shares[key].denominator
            capacity = capacities[key]
            if capacity is not None:
                floor_share = min(floor_share, capacity)
            floors[key] = floor_share
            allocated[key] += floor_share
            if capacity is not None:
                capacities[key] -= floor_share

        remaining -= sum(floors.values())
        if remaining:
            eligible = [
                key
                for key in active
                if capacities[key] is None or capacities[key] > 0
            ]
            ranked = sorted(
                eligible,
                key=lambda key: (-(exact_shares[key] - floors[key]), key),
            )
            if remaining > len(ranked):
                raise AllocationError("Allocation remainder exceeds available capacity")
            for key in ranked[:remaining]:
                allocated[key] += 1
                if capacities[key] is not None:
                    capacities[key] -= 1
            remaining = 0

    result = {
        key: value if total > 0 else -value for key, value in allocated.items()
    }
    if sum(result.values()) != total:
        raise AssertionError("Exact allocation invariant failed")
    return result

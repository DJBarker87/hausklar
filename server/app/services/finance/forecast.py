"""Pure, deterministic daily Finance forecast engine."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Literal

from app.services.finance.dates import household_zone
from app.services.finance.money import Money, normalise_currency

EventKind = Literal[
    "income",
    "expense",
    "commitment",
    "reserve",
    "goal",
    "planned",
    "transfer",
    "card_purchase",
    "refund",
]

_EVENT_KINDS = {
    "income",
    "expense",
    "commitment",
    "reserve",
    "goal",
    "planned",
    "transfer",
    "card_purchase",
    "refund",
}


def _require_minor_units(value: int, *, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{label} must be integer minor units")
    return value


@dataclass(frozen=True, slots=True)
class ForecastAccount:
    id: str
    opening_balance: Money
    floor_minor: int = 0
    include_in_household: bool = True

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id:
            raise ValueError("Forecast account IDs must be non-empty strings")
        _require_minor_units(self.floor_minor, label=f"floor for {self.id}")
        if not isinstance(self.include_in_household, bool):
            raise TypeError("include_in_household must be a boolean")


@dataclass(frozen=True, slots=True)
class ForecastEvent:
    id: str
    day: date
    account_id: str
    amount: Money
    kind: EventKind
    destination_account_id: str | None = None
    sequence: int = 0

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id:
            raise ValueError("Forecast event IDs must be non-empty strings")
        if isinstance(self.day, datetime) or not isinstance(self.day, date):
            raise TypeError("Forecast event day must be a date")
        if not isinstance(self.account_id, str) or not self.account_id:
            raise ValueError("Forecast events require an account ID")
        if self.kind not in _EVENT_KINDS:
            raise ValueError(f"Unsupported forecast event kind: {self.kind}")
        if isinstance(self.sequence, bool) or not isinstance(self.sequence, int):
            raise TypeError("Forecast event sequence must be an integer")
        if self.kind == "transfer":
            if not self.destination_account_id:
                raise ValueError("Transfer events require a destination account")
            if self.destination_account_id == self.account_id:
                raise ValueError("Transfer source and destination must differ")
            if self.amount.minor_units >= 0:
                raise ValueError("Transfer amount must be negative on the source account")
        elif self.destination_account_id is not None:
            raise ValueError("Only transfer events may name a destination account")


@dataclass(frozen=True, slots=True)
class ForecastSnapshot:
    start_date: date
    end_date: date
    timezone: str
    currency: str
    accounts: tuple[ForecastAccount, ...]
    events: tuple[ForecastEvent, ...] = ()
    household_buffer_minor: int = 0
    engine_version: str = "finance-forecast-v1"
    non_monotone_rule_ids: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if (
            isinstance(self.start_date, datetime)
            or not isinstance(self.start_date, date)
            or isinstance(self.end_date, datetime)
            or not isinstance(self.end_date, date)
        ):
            raise TypeError("Forecast dates must be date values")
        if self.end_date < self.start_date:
            raise ValueError("Forecast end_date must not precede start_date")
        household_zone(self.timezone)
        object.__setattr__(self, "currency", normalise_currency(self.currency))
        object.__setattr__(self, "accounts", tuple(self.accounts))
        object.__setattr__(self, "events", tuple(self.events))
        object.__setattr__(self, "non_monotone_rule_ids", tuple(self.non_monotone_rule_ids))
        _require_minor_units(self.household_buffer_minor, label="household buffer")
        if self.household_buffer_minor < 0:
            raise ValueError("Household buffer cannot be negative")
        if not isinstance(self.engine_version, str) or not self.engine_version:
            raise ValueError("Forecast engine_version is required")

        account_ids = [account.id for account in self.accounts]
        if len(set(account_ids)) != len(account_ids):
            raise ValueError("Forecast account IDs must be unique")
        if not account_ids:
            raise ValueError("Forecast requires at least one account")
        accounts_by_id = {account.id: account for account in self.accounts}
        for account in self.accounts:
            if account.opening_balance.currency != self.currency:
                raise ValueError("Forecast account currency does not match snapshot currency")

        event_ids = [event.id for event in self.events]
        if len(set(event_ids)) != len(event_ids):
            raise ValueError("Forecast event IDs must be unique")
        for event in self.events:
            if not self.start_date <= event.day <= self.end_date:
                raise ValueError(f"Forecast event {event.id} falls outside the snapshot")
            if event.account_id not in accounts_by_id:
                raise ValueError(f"Unknown forecast account: {event.account_id}")
            if event.amount.currency != self.currency:
                raise ValueError("Forecast event currency does not match snapshot currency")
            if event.destination_account_id is not None:
                destination = accounts_by_id.get(event.destination_account_id)
                if destination is None:
                    raise ValueError(
                        f"Unknown forecast destination account: {event.destination_account_id}"
                    )
                if destination.opening_balance.currency != event.amount.currency:
                    raise ValueError("Transfer accounts must use the same currency")

        if any(
            not isinstance(rule_id, str) or not rule_id for rule_id in self.non_monotone_rule_ids
        ):
            raise ValueError("Non-monotone rule IDs must be non-empty strings")


@dataclass(frozen=True, slots=True)
class ForecastLimit:
    kind: Literal["ACCOUNT_FLOOR", "HOUSEHOLD_BUFFER"]
    day: date
    event_id: str | None
    account_id: str | None
    required_minor: int
    actual_minor: int
    shortfall_minor: int


@dataclass(frozen=True, slots=True)
class AccountDayBalance:
    account_id: str
    balance_minor: int
    floor_minor: int
    headroom_minor: int


@dataclass(frozen=True, slots=True)
class ForecastDay:
    day: date
    accounts: tuple[AccountDayBalance, ...]
    household_liquid_minor: int
    household_free_minor: int
    constraints_passed_through_day: bool


@dataclass(frozen=True, slots=True)
class ForecastResult:
    snapshot_digest: str
    engine_version: str
    currency: str
    start_date: date
    end_date: date
    days: tuple[ForecastDay, ...]
    passed: bool
    limiting_event: ForecastLimit | None
    minimum_household_free_minor: int
    minimum_household_free_date: date


def canonical_snapshot_payload(snapshot: ForecastSnapshot) -> dict[str, object]:
    """Return the canonical primitive payload used for reproducibility."""

    return {
        "accounts": [
            {
                "floor_minor": account.floor_minor,
                "id": account.id,
                "include_in_household": account.include_in_household,
                "opening_balance_minor": account.opening_balance.minor_units,
            }
            for account in sorted(snapshot.accounts, key=lambda item: item.id)
        ],
        "currency": snapshot.currency,
        "end_date": snapshot.end_date.isoformat(),
        "engine_version": snapshot.engine_version,
        "events": [
            {
                "account_id": event.account_id,
                "amount_minor": event.amount.minor_units,
                "day": event.day.isoformat(),
                "destination_account_id": event.destination_account_id,
                "id": event.id,
                "kind": event.kind,
                "sequence": event.sequence,
            }
            for event in sorted(
                snapshot.events,
                key=lambda item: (item.day, item.sequence, item.id),
            )
        ],
        "household_buffer_minor": snapshot.household_buffer_minor,
        "non_monotone_rule_ids": sorted(snapshot.non_monotone_rule_ids),
        "start_date": snapshot.start_date.isoformat(),
        "timezone": snapshot.timezone,
    }


def canonical_snapshot_json(snapshot: ForecastSnapshot) -> str:
    return json.dumps(
        canonical_snapshot_payload(snapshot),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )


def snapshot_digest(snapshot: ForecastSnapshot) -> str:
    return hashlib.sha256(canonical_snapshot_json(snapshot).encode("utf-8")).hexdigest()


def _constraint_failure(
    *,
    snapshot: ForecastSnapshot,
    accounts_by_id: dict[str, ForecastAccount],
    balances: dict[str, int],
    day: date,
    event_id: str | None,
) -> ForecastLimit | None:
    for account_id in sorted(accounts_by_id):
        account = accounts_by_id[account_id]
        actual = balances[account_id]
        if actual < account.floor_minor:
            return ForecastLimit(
                kind="ACCOUNT_FLOOR",
                day=day,
                event_id=event_id,
                account_id=account_id,
                required_minor=account.floor_minor,
                actual_minor=actual,
                shortfall_minor=account.floor_minor - actual,
            )

    household_headroom = sum(
        balances[account_id] - account.floor_minor
        for account_id, account in accounts_by_id.items()
        if account.include_in_household
    )
    if household_headroom < snapshot.household_buffer_minor:
        return ForecastLimit(
            kind="HOUSEHOLD_BUFFER",
            day=day,
            event_id=event_id,
            account_id=None,
            required_minor=snapshot.household_buffer_minor,
            actual_minor=household_headroom,
            shortfall_minor=snapshot.household_buffer_minor - household_headroom,
        )
    return None


def run_forecast(snapshot: ForecastSnapshot) -> ForecastResult:
    """Run an exact event-ordered daily forecast from an immutable snapshot."""

    accounts_by_id = {account.id: account for account in snapshot.accounts}
    balances = {account.id: account.opening_balance.minor_units for account in snapshot.accounts}
    events_by_day: dict[date, list[ForecastEvent]] = {}
    for event in snapshot.events:
        events_by_day.setdefault(event.day, []).append(event)
    for events in events_by_day.values():
        events.sort(key=lambda item: (item.sequence, item.id))

    limiting_event = _constraint_failure(
        snapshot=snapshot,
        accounts_by_id=accounts_by_id,
        balances=balances,
        day=snapshot.start_date,
        event_id=None,
    )
    days: list[ForecastDay] = []
    minimum_household_free: int | None = None
    minimum_household_free_date = snapshot.start_date
    current_day = snapshot.start_date

    while current_day <= snapshot.end_date:
        for event in events_by_day.get(current_day, ()):  # already deterministically sorted
            balances[event.account_id] += event.amount.minor_units
            if event.destination_account_id is not None:
                balances[event.destination_account_id] -= event.amount.minor_units
            if limiting_event is None:
                limiting_event = _constraint_failure(
                    snapshot=snapshot,
                    accounts_by_id=accounts_by_id,
                    balances=balances,
                    day=current_day,
                    event_id=event.id,
                )

        account_days = tuple(
            AccountDayBalance(
                account_id=account_id,
                balance_minor=balances[account_id],
                floor_minor=accounts_by_id[account_id].floor_minor,
                headroom_minor=(balances[account_id] - accounts_by_id[account_id].floor_minor),
            )
            for account_id in sorted(accounts_by_id)
        )
        household_liquid = sum(
            balances[account_id]
            for account_id, account in accounts_by_id.items()
            if account.include_in_household
        )
        protected_account_floors = sum(
            account.floor_minor
            for account in accounts_by_id.values()
            if account.include_in_household
        )
        household_free = (
            household_liquid - protected_account_floors - snapshot.household_buffer_minor
        )
        if minimum_household_free is None or household_free < minimum_household_free:
            minimum_household_free = household_free
            minimum_household_free_date = current_day
        days.append(
            ForecastDay(
                day=current_day,
                accounts=account_days,
                household_liquid_minor=household_liquid,
                household_free_minor=household_free,
                constraints_passed_through_day=limiting_event is None,
            )
        )
        current_day += timedelta(days=1)

    assert minimum_household_free is not None
    return ForecastResult(
        snapshot_digest=snapshot_digest(snapshot),
        engine_version=snapshot.engine_version,
        currency=snapshot.currency,
        start_date=snapshot.start_date,
        end_date=snapshot.end_date,
        days=tuple(days),
        passed=limiting_event is None,
        limiting_event=limiting_event,
        minimum_household_free_minor=minimum_household_free,
        minimum_household_free_date=minimum_household_free_date,
    )

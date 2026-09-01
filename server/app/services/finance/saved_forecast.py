"""Build deterministic forecasts from one authorised Finance space."""

from __future__ import annotations

import calendar
import json
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app.models.finance import FinanceForecastGenerate
from app.services.finance.forecast import ForecastAccount, ForecastEvent, ForecastSnapshot
from app.services.finance.money import Money

_CASH_ACCOUNT_TYPES = {"CURRENT", "SAVINGS", "CASH"}
_CASH_PURPOSES = {"OPERATING_CURRENT", "SAVINGS", "GOAL"}
_MAX_EVENTS = 2_000
_DEFAULT_HORIZON_MONTHS = 18
_MAX_HORIZON_MONTHS = 120


class SavedForecastError(ValueError):
    """Saved records cannot produce a meaningful forecast."""


@dataclass(frozen=True, slots=True)
class SavedForecastBuild:
    snapshot: ForecastSnapshot
    event_provenance: tuple[tuple[str, str], ...]
    data_through_at: datetime | None
    data_status: str
    input_notes: tuple[str, ...]
    unsafe_safe_to_spend_routes: tuple[str, ...]
    card_routes: tuple[tuple[str, str, int, int], ...]


def _household_today(timezone_name: str, now: datetime) -> date:
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("Forecast creation time must include a timezone")
    return now.astimezone(ZoneInfo(timezone_name)).date()


def _parse_instant(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed.astimezone(timezone.utc)


def _month_occurrence(anchor: date, offset: int) -> date:
    month_number = anchor.year * 12 + anchor.month - 1 + offset
    year, zero_based_month = divmod(month_number, 12)
    month = zero_based_month + 1
    return date(year, month, min(anchor.day, calendar.monthrange(year, month)[1]))


def _year_occurrence(anchor: date, offset: int) -> date:
    try:
        return anchor.replace(year=anchor.year + offset)
    except ValueError:
        return anchor.replace(year=anchor.year + offset, day=28)


def _next_month(year: int, month: int) -> tuple[int, int]:
    return (year + 1, 1) if month == 12 else (year, month + 1)


def _next_calendar_day(start: date, calendar_day: int) -> date:
    candidate = date(
        start.year,
        start.month,
        min(calendar_day, calendar.monthrange(start.year, start.month)[1]),
    )
    if candidate >= start:
        return candidate
    year, month = _next_month(start.year, start.month)
    return date(year, month, min(calendar_day, calendar.monthrange(year, month)[1]))


def _recurring_dates(
    *, anchor: date, interval_kind: str, start_date: date, end_date: date
) -> tuple[date, ...]:
    if interval_kind == "IRREGULAR":
        return (anchor,) if start_date <= anchor <= end_date else ()

    occurrences: list[date] = []
    offset = 0
    while True:
        if interval_kind == "FOUR_WEEKLY":
            occurrence = anchor + timedelta(days=28 * offset)
        elif interval_kind == "MONTHLY":
            occurrence = _month_occurrence(anchor, offset)
        elif interval_kind == "ANNUAL":
            occurrence = _year_occurrence(anchor, offset)
        else:
            return ()
        if occurrence > end_date:
            break
        if occurrence >= start_date:
            occurrences.append(occurrence)
        offset += 1
        if offset > _MAX_EVENTS:
            raise SavedForecastError("The saved repeating schedule is too long to forecast")
    return tuple(occurrences)


def _evidence_account_refs(evidence_json: str) -> tuple[set[str], set[str]]:
    try:
        values = json.loads(evidence_json)
    except (TypeError, json.JSONDecodeError):
        return set(), set()
    if not isinstance(values, list):
        return set(), set()
    account_ids: set[str] = set()
    transaction_ids: set[str] = set()
    for value in values:
        if not isinstance(value, str) or not value:
            continue
        if value.startswith("account:"):
            account_ids.add(value.removeprefix("account:"))
        elif value.startswith("transaction:"):
            transaction_ids.add(value.removeprefix("transaction:"))
        else:
            transaction_ids.add(value)
    return account_ids, transaction_ids


async def _transaction_accounts(
    db,
    *,
    space_id: str,
    family_id: str,
    transaction_ids: set[str],
) -> set[str]:
    if not transaction_ids:
        return set()
    placeholders = ",".join("?" for _ in transaction_ids)
    rows = await (
        await db.execute(
            f"""
            SELECT DISTINCT account_id FROM finance_transactions
            WHERE id IN ({placeholders}) AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            """,
            [*sorted(transaction_ids), space_id, family_id],
        )
    ).fetchall()
    return {row["account_id"] for row in rows}


async def _recurring_account_id(
    db,
    *,
    row: dict,
    space_id: str,
    family_id: str,
    included_account_ids: set[str],
) -> str | None:
    account_refs, transaction_refs = _evidence_account_refs(row["evidence_json"])
    routed_accounts = account_refs | await _transaction_accounts(
        db,
        space_id=space_id,
        family_id=family_id,
        transaction_ids=transaction_refs,
    )
    visible_routes = routed_accounts & included_account_ids
    return next(iter(visible_routes)) if len(visible_routes) == 1 else None


def _commitment_amount(row: dict) -> int:
    if row["amount_mode"] == "EXACT":
        return row["exact_minor"]
    if row["amount_mode"] == "RANGE":
        return row["high_minor"]
    return row["expected_minor"]


def _loaded_ids(value: str) -> set[str]:
    try:
        loaded = json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return set()
    if not isinstance(loaded, list):
        return set()
    return {item for item in loaded if isinstance(item, str) and item}


async def build_saved_forecast(
    db,
    *,
    user: dict,
    space_id: str,
    request: FinanceForecastGenerate,
    timezone_name: str,
    now: datetime | None = None,
) -> SavedForecastBuild:
    """Use only rows in one authorised space to build a persisted snapshot."""
    observed_now = now or datetime.now(timezone.utc)
    start_date = _household_today(timezone_name, observed_now)
    if request.end_date < start_date:
        raise SavedForecastError("Forecast end_date must be today or later")
    maximum_end = _month_occurrence(start_date, _MAX_HORIZON_MONTHS)
    if request.end_date > maximum_end:
        raise SavedForecastError("Forecast end_date cannot be more than 10 years ahead")
    required_end = _month_occurrence(start_date, _DEFAULT_HORIZON_MONTHS)
    goal_horizon = await (
        await db.execute(
            "SELECT MAX(deadline) FROM finance_goals WHERE space_id = ? "
            "AND family_id = ? AND currency = ? AND status = 'ACTIVE' "
            "AND deleted_at IS NULL",
            (space_id, user["family_id"], request.currency),
        )
    ).fetchone()
    if goal_horizon is not None and goal_horizon[0]:
        required_end = max(required_end, date.fromisoformat(goal_horizon[0]))
    commitment_horizons = await (
        await db.execute(
            "SELECT reviewed_dates_json FROM finance_commitments WHERE space_id = ? "
            "AND family_id = ? AND currency = ? AND status = 'ACTIVE' "
            "AND deleted_at IS NULL",
            (space_id, user["family_id"], request.currency),
        )
    ).fetchall()
    for row in commitment_horizons:
        try:
            reviewed_dates = json.loads(row["reviewed_dates_json"])
        except (TypeError, json.JSONDecodeError):
            continue
        for value in reviewed_dates if isinstance(reviewed_dates, list) else ():
            try:
                required_end = max(required_end, date.fromisoformat(value))
            except (TypeError, ValueError):
                continue
    horizon_capped = required_end > maximum_end
    forecast_end = min(max(request.end_date, required_end), maximum_end)
    horizon_extended = forecast_end > request.end_date

    rows = await (
        await db.execute(
            """
            SELECT account.*, balance.booked_minor, balance.available_minor,
                   balance.credit_limit_minor, balance.provider_at,
                   balance.observed_at AS balance_observed_at
            FROM finance_accounts account
            LEFT JOIN finance_balance_snapshots balance ON balance.id = (
                SELECT candidate.id FROM finance_balance_snapshots candidate
                WHERE candidate.account_id = account.id
                  AND candidate.space_id = account.space_id
                  AND candidate.family_id = account.family_id
                  AND candidate.deleted_at IS NULL
                ORDER BY candidate.observed_at DESC, candidate.created_at DESC,
                         candidate.id DESC
                LIMIT 1
            )
            WHERE account.space_id = ? AND account.family_id = ?
              AND account.currency = ? AND account.include_in_cashflow = 1
              AND (
                    (account.account_type IN ('CURRENT', 'SAVINGS', 'CASH')
                     AND account.purpose IN ('OPERATING_CURRENT', 'SAVINGS', 'GOAL'))
                 OR (account.account_type = 'CREDIT_CARD'
                     AND account.purpose NOT IN ('IGNORED', 'INVESTMENT_LIKE'))
              )
              AND account.deleted_at IS NULL
            ORDER BY account.id
            """,
            (space_id, user["family_id"], request.currency),
        )
    ).fetchall()
    eligible = [dict(row) for row in rows]
    usable = [row for row in eligible if row["booked_minor"] is not None]
    usable_cash = [row for row in usable if row["account_type"] in _CASH_ACCOUNT_TYPES]
    if not usable_cash:
        raise SavedForecastError(
            f"No included current, savings, or cash account has a saved {request.currency} balance"
        )

    notes: list[str] = []
    if horizon_extended:
        notes.append(
            f"The forecast was extended through {forecast_end.isoformat()} to cover the standard 18-month outlook and dated plans."
        )
    if horizon_capped:
        notes.append(
            "A saved goal or commitment lies beyond the supported 10-year forecast horizon."
        )
    partial = False
    unsafe_routes: set[str] = set()
    missing_balance_count = len(eligible) - len(usable)
    if missing_balance_count:
        partial = True
        unsafe_routes.update(("direct", "full_repayment_card"))
        noun = "account was" if missing_balance_count == 1 else "accounts were"
        notes.append(
            f"{missing_balance_count} included {noun} left out because no balance has been saved."
        )

    balance_instants: list[datetime] = []
    for row in usable:
        freshness_value = row["provider_at"] or row["balance_observed_at"]
        parsed_freshness = _parse_instant(freshness_value)
        if parsed_freshness is None:
            partial = True
            unsafe_routes.update(("direct", "full_repayment_card"))
            notes.append("A saved balance has no usable timestamp, so its age is unknown.")
        else:
            balance_instants.append(parsed_freshness)
    data_through = min(balance_instants) if balance_instants else None
    stale = False
    if data_through is not None:
        data_date = data_through.astimezone(ZoneInfo(timezone_name)).date()
        if data_date < start_date:
            stale = True
            notes.append(
                f"Balances are only current through {data_date.isoformat()}; changes since then are not estimated."
            )

    included_by_id = {row["id"]: row for row in usable}
    included_ids = set(included_by_id)
    included_cash_ids = {row["id"] for row in usable_cash}
    default_accounts = {row["id"] for row in usable_cash if bool(row["primary_spending_account"])}
    floor_additions = {account_id: 0 for account_id in included_ids}
    household_hold_minor = 0

    reserve_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_reserves
            WHERE space_id = ? AND family_id = ? AND currency = ?
              AND status = 'ACTIVE' AND allocated_minor > 0 AND deleted_at IS NULL
            ORDER BY id
            """,
            (space_id, user["family_id"], request.currency),
        )
    ).fetchall()
    linked_reserve_count = 0
    household_reserve_count = 0
    skipped_reserve_count = 0
    for source in reserve_rows:
        row = dict(source)
        account_id = row["linked_account_id"]
        if account_id is None:
            household_hold_minor += row["allocated_minor"]
            household_reserve_count += 1
        elif account_id in included_cash_ids:
            floor_additions[account_id] += row["allocated_minor"]
            linked_reserve_count += 1
        else:
            skipped_reserve_count += 1
    if linked_reserve_count:
        notes.append("Linked active reserves are protected on their saved cash accounts.")
    if household_reserve_count:
        notes.append("Unlinked active reserves are held from space-wide free cash.")
    if skipped_reserve_count:
        partial = True
        unsafe_routes.update(("direct", "full_repayment_card"))
        noun = "reserve was" if skipped_reserve_count == 1 else "reserves were"
        notes.append(
            f"{skipped_reserve_count} active {noun} left out because its linked account is not included."
        )

    goal_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_goals
            WHERE space_id = ? AND family_id = ? AND currency = ?
              AND status = 'ACTIVE' AND deleted_at IS NULL
            ORDER BY id
            """,
            (space_id, user["family_id"], request.currency),
        )
    ).fetchall()
    linked_goal_count = 0
    household_goal_count = 0
    for source in goal_rows:
        row = dict(source)
        allocated = row["currently_allocated_minor"]
        funding_sources = _loaded_ids(row["allowed_funding_sources_json"])
        if allocated > 0 and len(funding_sources) == 1 and funding_sources <= included_cash_ids:
            floor_additions[next(iter(funding_sources))] += allocated
            linked_goal_count += 1
        elif allocated > 0:
            household_hold_minor += allocated
            household_goal_count += 1
        household_hold_minor += row["emergency_buffer_minor"]
    if linked_goal_count:
        notes.append("Allocated goal savings are protected on their single saved funding account.")
    if household_goal_count:
        notes.append(
            "Goal savings without one usable funding account are held from space-wide free cash."
        )

    accounts: list[ForecastAccount] = []
    for row in usable:
        if row["account_type"] == "CREDIT_CARD":
            opening_minor = -abs(row["booked_minor"])
            if row["credit_limit_minor"] is None:
                partial = True
                unsafe_routes.add("full_repayment_card")
                floor_minor = opening_minor
                notes.append(
                    "A credit card has no saved credit limit, so additional card spending cannot be assessed."
                )
            else:
                floor_minor = -abs(row["credit_limit_minor"])
            include_in_household = False
        else:
            opening_minor = (
                row["available_minor"]
                if row["available_minor"] is not None
                else row["booked_minor"]
            )
            floor_minor = row["minimum_balance_minor"] + floor_additions[row["id"]]
            include_in_household = True
        accounts.append(
            ForecastAccount(
                id=row["id"],
                opening_balance=Money(opening_minor, request.currency),
                floor_minor=floor_minor,
                include_in_household=include_in_household,
            )
        )

    event_provenance: list[tuple[str, str]] = []
    events: list[ForecastEvent] = []
    contribution_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_declared_contributions
            WHERE space_id = ? AND family_id = ? AND currency = ?
              AND status = 'ACTIVE' AND contribution_date BETWEEN ? AND ?
              AND deleted_at IS NULL
            ORDER BY contribution_date, id
            """,
            (
                space_id,
                user["family_id"],
                request.currency,
                start_date.isoformat(),
                forecast_end.isoformat(),
            ),
        )
    ).fetchall()
    contribution_account_id = None
    if len(default_accounts) == 1:
        contribution_account_id = next(iter(default_accounts))
    elif len(included_cash_ids) == 1:
        contribution_account_id = next(iter(included_cash_ids))
    balance_data_date = (
        data_through.astimezone(ZoneInfo(timezone_name)).date()
        if data_through is not None
        else None
    )
    unrouted_contributions = 0
    already_observed_contributions = 0
    for contribution in contribution_rows:
        contribution_day = date.fromisoformat(contribution["contribution_date"])
        # A dated contribution at or before the saved balance date is already
        # represented by that balance and must not be added a second time.
        if balance_data_date is not None and contribution_day <= balance_data_date:
            already_observed_contributions += 1
            continue
        if contribution_account_id is None:
            unrouted_contributions += 1
            continue
        event_id = f"declared-contribution:{contribution['id']}"
        events.append(
            ForecastEvent(
                id=event_id,
                day=contribution_day,
                account_id=contribution_account_id,
                amount=Money(contribution["amount_minor"], request.currency),
                # `planned` changes the forecast balance without classifying
                # the private-space transfer as household income.
                kind="planned",
                sequence=90,
            )
        )
        event_provenance.append((event_id, "declared-contribution"))
    if contribution_rows:
        notes.append(
            "Declared personal-space contributions are included as neutral household plan inflows."
        )
    if already_observed_contributions:
        notes.append(
            "Declared contributions on or before the saved balance date are not added again."
        )
    if unrouted_contributions:
        partial = True
        unsafe_routes.update(("direct", "full_repayment_card"))
        notes.append(
            "A declared contribution was left out because no single included household cash account can receive it."
        )
    card_routes: dict[str, tuple[str, int, int]] = {}
    for row in usable:
        if row["account_type"] != "CREDIT_CARD":
            continue
        route_is_complete = (
            bool(row["card_paid_in_full"])
            and row["card_settlement_account_id"] in included_cash_ids
            and row["card_statement_close_day"] is not None
            and row["card_repayment_day"] is not None
        )
        if route_is_complete:
            card_routes[row["id"]] = (
                row["card_settlement_account_id"],
                row["card_statement_close_day"],
                row["card_repayment_day"],
            )
        if row["booked_minor"] == 0:
            continue
        if not bool(row["card_paid_in_full"]):
            partial = True
            unsafe_routes.update(("direct", "full_repayment_card"))
            notes.append(
                "An existing credit-card balance was not routed because full repayment is not confirmed."
            )
            continue
        if not route_is_complete:
            partial = True
            unsafe_routes.update(("direct", "full_repayment_card"))
            notes.append(
                "An existing credit-card balance was not routed because its settlement account or card timing is missing."
            )
            continue
        repayment_date = _next_calendar_day(start_date, row["card_repayment_day"])
        if repayment_date > forecast_end:
            forecast_end = repayment_date + timedelta(days=1)
            notes.append(
                f"The forecast was extended through {forecast_end.isoformat()} to include a saved card repayment."
            )
        event_id = f"card-repayment:{row['id']}:{repayment_date.isoformat()}"
        events.append(
            ForecastEvent(
                id=event_id,
                day=repayment_date,
                account_id=row["card_settlement_account_id"],
                destination_account_id=row["id"],
                amount=Money(-abs(row["booked_minor"]), request.currency),
                kind="transfer",
                sequence=250,
            )
        )
        event_provenance.append((event_id, f"card-repayment:{row['id']}"))

    commitment_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_commitments
            WHERE space_id = ? AND family_id = ? AND currency = ?
              AND status = 'ACTIVE' AND deleted_at IS NULL
            ORDER BY id
            """,
            (space_id, user["family_id"], request.currency),
        )
    ).fetchall()
    unrouted_commitments = 0
    reserved_commitment_count = 0
    for source in commitment_rows:
        row = dict(source)
        account_id = row["funding_account_id"]
        if account_id is None and len(default_accounts) == 1:
            account_id = next(iter(default_accounts))
        if account_id not in included_cash_ids:
            unrouted_commitments += 1
            continue
        if row["already_reserved_minor"] > 0:
            reserved_commitment_count += 1
        amount_minor = _commitment_amount(row)
        try:
            reviewed_dates = json.loads(row["reviewed_dates_json"])
        except (TypeError, json.JSONDecodeError):
            unrouted_commitments += 1
            continue
        for value in reviewed_dates:
            try:
                due_date = date.fromisoformat(value)
            except (TypeError, ValueError):
                partial = True
                unsafe_routes.update(("direct", "full_repayment_card"))
                notes.append("A commitment has an invalid reviewed date and was left out.")
                continue
            if start_date <= due_date <= forecast_end:
                event_id = f"commitment:{row['id']}:{due_date.isoformat()}"
                events.append(
                    ForecastEvent(
                        id=event_id,
                        day=due_date,
                        account_id=account_id,
                        amount=Money(-amount_minor, request.currency),
                        kind="commitment",
                        sequence=300,
                    )
                )
                event_provenance.append((event_id, f"commitment:{row['id']}"))
    if reserved_commitment_count:
        notes.append(
            "Commitment set-asides are not added as a second reserve; their full reviewed payments remain forecast."
        )
    if unrouted_commitments:
        partial = True
        unsafe_routes.update(("direct", "full_repayment_card"))
        noun = "commitment was" if unrouted_commitments == 1 else "commitments were"
        notes.append(
            f"{unrouted_commitments} active {noun} left out because no included cash funding account is set."
        )

    recurring_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_recurring_series
            WHERE space_id = ? AND family_id = ? AND currency = ?
              AND status IN ('CANDIDATE', 'CONFIRMED') AND deleted_at IS NULL
            ORDER BY id
            """,
            (space_id, user["family_id"], request.currency),
        )
    ).fetchall()
    candidate_count = sum(row["status"] == "CANDIDATE" for row in recurring_rows)
    if candidate_count:
        partial = True
        noun = "candidate is" if candidate_count == 1 else "candidates are"
        notes.append(f"{candidate_count} unconfirmed repeating-payment {noun} not included.")

    confirmed_count = 0
    cautious_count = 0
    unrouted_series = 0
    card_series_count = 0
    for source in recurring_rows:
        row = dict(source)
        if row["status"] != "CONFIRMED":
            continue
        confirmed_count += 1
        expected = row["expected_minor"]
        is_uncertain = any(
            bound is not None and bound != expected
            for bound in (row["low_minor"], row["high_minor"])
        )
        account_id = await _recurring_account_id(
            db,
            row=row,
            space_id=space_id,
            family_id=user["family_id"],
            included_account_ids=included_ids,
        )
        if account_id is None:
            unrouted_series += 1
            continue
        if included_by_id[account_id]["account_type"] == "CREDIT_CARD":
            card_series_count += 1
            continue
        try:
            next_date = date.fromisoformat(row["next_expected_date"])
        except (TypeError, ValueError):
            unrouted_series += 1
            continue
        amount_minor = abs(expected)
        if is_uncertain:
            cautious_count += 1
            if row["series_type"] == "SALARY" and row["low_minor"] is not None:
                amount_minor = abs(row["low_minor"])
            elif row["series_type"] != "SALARY" and row["high_minor"] is not None:
                amount_minor = abs(row["high_minor"])
        if amount_minor == 0:
            unsafe_routes.update(("direct", "full_repayment_card"))
            continue
        signed_amount = amount_minor if row["series_type"] == "SALARY" else -amount_minor
        kind = "income" if row["series_type"] == "SALARY" else "expense"
        sequence = 100 if kind == "income" else 200
        for due_date in _recurring_dates(
            anchor=next_date,
            interval_kind=row["interval_kind"],
            start_date=start_date,
            end_date=forecast_end,
        ):
            event_id = f"recurring:{row['id']}:{due_date.isoformat()}"
            events.append(
                ForecastEvent(
                    id=event_id,
                    day=due_date,
                    account_id=account_id,
                    amount=Money(signed_amount, request.currency),
                    kind=kind,
                    sequence=sequence,
                )
            )
            event_provenance.append((event_id, f"recurring:{row['id']}"))

    if confirmed_count == 0:
        partial = True
        notes.append("No confirmed repeating income or spending has been saved.")
    if cautious_count:
        partial = True
        noun = "series uses" if cautious_count == 1 else "series use"
        notes.append(
            f"{cautious_count} confirmed but variable repeating {noun} cautious low-income or high-cost amounts."
        )
    if unrouted_series:
        partial = True
        unsafe_routes.update(("direct", "full_repayment_card"))
        noun = "series was" if unrouted_series == 1 else "series were"
        notes.append(
            f"{unrouted_series} confirmed repeating {noun} left out because no single included account is evidenced."
        )
    if card_series_count:
        partial = True
        unsafe_routes.update(("direct", "full_repayment_card"))
        noun = "series was" if card_series_count == 1 else "series were"
        notes.append(
            f"{card_series_count} confirmed repeating card {noun} left out because its future statement repayment is not saved."
        )
    if len(events) > _MAX_EVENTS:
        raise SavedForecastError("The saved Finance records produce too many forecast events")

    snapshot = ForecastSnapshot(
        start_date=start_date,
        end_date=forecast_end,
        timezone=timezone_name,
        currency=request.currency,
        accounts=tuple(accounts),
        events=tuple(sorted(events, key=lambda item: (item.day, item.sequence, item.id))),
        household_buffer_minor=request.household_buffer_minor + household_hold_minor,
    )
    data_status = "PARTIAL" if partial else "STALE" if stale else "CURRENT"
    return SavedForecastBuild(
        snapshot=snapshot,
        event_provenance=tuple(sorted(event_provenance)),
        data_through_at=data_through,
        data_status=data_status,
        input_notes=tuple(dict.fromkeys(notes)),
        unsafe_safe_to_spend_routes=tuple(sorted(unsafe_routes)),
        card_routes=tuple(
            (card_id, settlement_id, close_day, repayment_day)
            for card_id, (settlement_id, close_day, repayment_day) in sorted(card_routes.items())
        ),
    )

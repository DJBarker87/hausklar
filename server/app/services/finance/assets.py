"""Reviewed investment reports, watch-only public assets, and honest net worth."""

import json
import re
import uuid
from datetime import datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

from app.models.finance_products_assets import (
    FinanceAssetHoldingInput,
    FinanceAssetPriceRefreshResponse,
    FinanceAssetSnapshotResponse,
    FinanceAssetSourceResponse,
    FinanceHLImportConfirm,
    FinanceHLImportPreviewCreate,
    FinanceHLImportPreviewResponse,
    FinanceManualAssetValueCreate,
    FinanceManualAssetValueResponse,
    FinanceNetWorthLayerResponse,
    FinanceNetWorthResponse,
    FinanceWatchAddressCreate,
    FinanceWatchSnapshotCreate,
)
from app.services.finance.foundation import require_finance_space
from app.services.finance.money import normalise_currency
from app.services.finance.market_prices import (
    MarketPriceUnavailable,
    MarketQuote,
    MarketQuoteProvider,
    close_market_quote_provider,
    configured_market_quote_provider,
)
from app.services.finance.public_asset_adapters import (
    PublicAssetAdapterError,
    PublicAssetAdapterRegistry,
)
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

_SOLANA_PUBLIC = re.compile(r"^[1-9A-HJ-NP-Za-km-z]{32,44}$")
_HYPERLIQUID_PUBLIC = re.compile(r"^0x[0-9a-fA-F]{40}$")
_BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
_LAYERS = (
    "OPERATING_CASH",
    "PROTECTED_RESERVE",
    "GOAL_CASH",
    "ACCESSIBLE_SAVINGS",
    "BROKERAGE_INVESTMENT",
    "PENSION_LOCKED",
    "STABLE_CRYPTO",
    "VOLATILE_CRYPTO",
    "PROPERTY",
    "OTHER_ASSET",
    "LIABILITY",
)


class FinanceAssetError(ValueError):
    """An asset request is invalid or not supported by reviewed evidence."""


class FinanceAssetNotFoundError(FinanceAssetError):
    """An authorised Finance asset record was not found."""


class FinanceAssetConflictError(FinanceAssetError):
    """The asset request conflicts with already confirmed state."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _decimal_text(value: Decimal) -> str:
    if not value.is_finite():
        raise FinanceAssetError("Asset quantities must be finite")
    return format(value.normalize(), "f")


def _solana_public_key_bytes(value: str) -> int:
    number = 0
    try:
        for character in value:
            number = number * 58 + _BASE58_ALPHABET.index(character)
    except ValueError:
        return 0
    decoded_length = (number.bit_length() + 7) // 8 if number else 0
    return len(value) - len(value.lstrip("1")) + decoded_length


def _source_response(row: dict) -> FinanceAssetSourceResponse:
    return FinanceAssetSourceResponse(
        id=row["id"],
        space_id=row["space_id"],
        source_kind=row["source_kind"],
        label=row["label"],
        public_address=row["public_address"],
        status=row["status"],
    )


async def list_asset_sources(
    db,
    *,
    user: dict,
    space_id: str,
) -> list[FinanceAssetSourceResponse]:
    """List active saved sources in one caller-authorised Finance space."""
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_asset_sources
            WHERE space_id = ? AND family_id = ? AND status = 'ACTIVE'
              AND deleted_at IS NULL
            ORDER BY source_kind, label COLLATE NOCASE, id
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_source_response(dict(row)) for row in rows]


async def pause_asset_source(
    db,
    *,
    user: dict,
    source_id: str,
) -> FinanceAssetSourceResponse:
    """Stop a saved watch-only source without deleting its reviewed history."""
    source = await _authorised_source(db, user=user, source_id=source_id)
    if source["source_kind"] not in {"SOLANA_PUBLIC", "HYPERLIQUID_PUBLIC"}:
        raise FinanceAssetConflictError("Only watch-only asset sources can be disconnected")
    if source["status"] == "PAUSED":
        return _source_response(source)
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_asset_sources",
            source_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_asset_sources SET status = 'PAUSED', updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (now, source_id, user["family_id"]),
        )
    source.update(status="PAUSED", updated_at=now)
    return _source_response(source)


async def _authorised_source(db, *, user: dict, source_id: str) -> dict:
    row = await (
        await db.execute(
            """
            SELECT source.* FROM finance_asset_sources source
            JOIN finance_spaces space
              ON space.id = source.space_id AND space.family_id = source.family_id
             AND space.deleted_at IS NULL
            WHERE source.id = ? AND source.family_id = ? AND source.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            """,
            (source_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceAssetNotFoundError("Finance asset source not found")
    return dict(row)


async def _authorised_preview(db, *, user: dict, preview_id: str) -> dict:
    row = await (
        await db.execute(
            """
            SELECT preview.* FROM finance_asset_import_previews preview
            JOIN finance_spaces space
              ON space.id = preview.space_id AND space.family_id = preview.family_id
             AND space.deleted_at IS NULL
            WHERE preview.id = ? AND preview.family_id = ? AND preview.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            """,
            (preview_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceAssetNotFoundError("HL report preview not found")
    return dict(row)


def _preview_response(row: dict) -> FinanceHLImportPreviewResponse:
    unknown_count = row["unknown_value_count"]
    difference = row["reconciliation_difference_minor"]
    can_confirm = row["reported_total_minor"] is None or (unknown_count == 0 and difference == 0)
    return FinanceHLImportPreviewResponse(
        id=row["id"],
        label=row["label"],
        account_wrapper=row["account_wrapper"],
        as_of_date=row["as_of_date"],
        currency=row["currency"],
        cash_value_minor=row["cash_value_minor"],
        reported_total_minor=row["reported_total_minor"],
        calculated_known_total_minor=row["calculated_known_total_minor"],
        unknown_value_count=unknown_count,
        reconciliation_difference_minor=difference,
        can_confirm=can_confirm,
        holdings=[
            FinanceAssetHoldingInput.model_validate(item)
            for item in json.loads(row["holdings_json"])
        ],
        activities=json.loads(row["activities_json"]),
        expires_at=row["expires_at"],
    )


async def preview_hl_report(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceHLImportPreviewCreate,
) -> FinanceHLImportPreviewResponse:
    """Persist a reviewable HL report without broker access or credentials."""
    await require_finance_space(db, user=user, space_id=space_id)
    expected_class = "PENSION_LOCKED" if body.account_wrapper == "SIPP" else "BROKERAGE_INVESTMENT"
    for holding in body.holdings:
        if holding.asset_class != expected_class:
            raise FinanceAssetError("HL holding layer must match the report account wrapper")
        if (
            holding.position_kind != "HOLDING"
            or not holding.include_in_net_worth
            or holding.quantity < 0
            or (holding.value_minor is not None and holding.value_minor < 0)
            or holding.asset_key == "hl:cash"
        ):
            raise FinanceAssetError("HL reports may contain non-negative holdings only")
    known_total = body.cash_value_minor + sum(holding.value_minor or 0 for holding in body.holdings)
    unknown_count = sum(holding.value_minor is None for holding in body.holdings)
    difference = (
        None if body.reported_total_minor is None else body.reported_total_minor - known_total
    )
    identifier = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(hours=24)
    holdings_json = json.dumps(
        [holding.model_dump(mode="json") for holding in body.holdings],
        sort_keys=True,
    )
    activities_json = json.dumps(
        [activity.model_dump(mode="json") for activity in body.activities],
        sort_keys=True,
    )
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_asset_import_previews
                (id, space_id, source_kind, label, account_wrapper, as_of_date,
                 currency, cash_value_minor, holdings_json, activities_json,
                 reported_total_minor, calculated_known_total_minor,
                 unknown_value_count, reconciliation_difference_minor, status,
                 expires_at, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, 'HL_REPORT', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    'PREVIEWED', ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                body.label.strip(),
                body.account_wrapper,
                body.as_of_date.isoformat(),
                body.currency,
                body.cash_value_minor,
                holdings_json,
                activities_json,
                body.reported_total_minor,
                known_total,
                unknown_count,
                difference,
                expires_at.isoformat(),
                user["family_id"],
                now.isoformat(),
                now.isoformat(),
                user["id"],
            ),
        )
    return _preview_response(await _authorised_preview(db, user=user, preview_id=identifier))


async def insert_asset_snapshot(
    db,
    *,
    user: dict,
    source: dict,
    as_of_at: str,
    snapshot_kind: str,
    currency: str,
    positions: list[FinanceAssetHoldingInput],
) -> tuple[str, str]:
    position_keys = {
        (position.asset_key.casefold(), position.position_kind) for position in positions
    }
    if len(position_keys) != len(positions):
        raise FinanceAssetError("Asset snapshot positions must be unique")
    snapshot_id = str(uuid.uuid4())
    now = _now()
    data_status = (
        "PARTIAL" if any(position.value_minor is None for position in positions) else "COMPLETE"
    )
    await db.execute(
        """
        INSERT INTO finance_asset_snapshots
            (id, space_id, source_id, as_of_at, snapshot_kind, data_status,
             family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            snapshot_id,
            source["space_id"],
            source["id"],
            as_of_at,
            snapshot_kind,
            data_status,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    for position in positions:
        position_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO finance_positions
                (id, space_id, snapshot_id, asset_key, asset_name, asset_class,
                 position_kind, include_in_net_worth, quantity_decimal,
                 quantity_unit, instrument_id_kind, instrument_id, quote_symbol,
                 quote_currency, cost_basis_minor, cost_basis_currency,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                position_id,
                source["space_id"],
                snapshot_id,
                position.asset_key,
                position.asset_name.strip(),
                position.asset_class,
                position.position_kind,
                int(position.include_in_net_worth),
                _decimal_text(position.quantity),
                position.quantity_unit.strip(),
                position.instrument_id_kind,
                position.instrument_id,
                position.quote_symbol,
                position.quote_currency,
                position.cost_basis_minor,
                position.cost_basis_currency,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_valuations
                (id, space_id, position_id, valuation_status, value_minor,
                 currency, unit_price_minor, price_source, observed_at, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                source["space_id"],
                position_id,
                "KNOWN" if position.value_minor is not None else "UNKNOWN",
                position.value_minor,
                currency,
                position.unit_price_minor,
                position.price_source,
                as_of_at,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    return snapshot_id, data_status


async def confirm_hl_report(
    db,
    *,
    user: dict,
    preview_id: str,
    body: FinanceHLImportConfirm,
) -> FinanceAssetSnapshotResponse:
    del body  # Literal true is validated at the API boundary.
    preview = await _authorised_preview(db, user=user, preview_id=preview_id)
    if preview["status"] != "PREVIEWED":
        raise FinanceAssetConflictError("HL report preview is no longer confirmable")
    now_dt = datetime.now(timezone.utc)
    if datetime.fromisoformat(preview["expires_at"]) <= now_dt:
        async with serialized_create(db):
            await save_history(
                db,
                "finance_asset_import_previews",
                preview_id,
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                "UPDATE finance_asset_import_previews SET status = 'EXPIRED', "
                "updated_at = ? WHERE id = ?",
                (now_dt.isoformat(), preview_id),
            )
        raise FinanceAssetConflictError("HL report preview has expired")
    response = _preview_response(preview)
    if not response.can_confirm:
        raise FinanceAssetConflictError(
            "HL report totals do not reconcile; review the report before confirming"
        )
    holdings = list(response.holdings)
    cash_class = (
        "PENSION_LOCKED" if preview["account_wrapper"] == "SIPP" else "BROKERAGE_INVESTMENT"
    )
    holdings.insert(
        0,
        FinanceAssetHoldingInput(
            asset_key="hl:cash",
            asset_name=f"{preview['account_wrapper']} cash",
            asset_class=cash_class,
            quantity=Decimal(preview["cash_value_minor"]),
            quantity_unit=f"{preview['currency']} minor",
            value_minor=preview["cash_value_minor"],
            unit_price_minor=1,
            price_source="Reviewed Hargreaves Lansdown report",
        ),
    )
    as_of_at = datetime.combine(response.as_of_date, time.max, tzinfo=timezone.utc).isoformat()
    async with serialized_create(db):
        source_row = await (
            await db.execute(
                """
                SELECT * FROM finance_asset_sources
                WHERE space_id = ? AND family_id = ? AND source_kind = 'HL_REPORT'
                  AND label = ? AND deleted_at IS NULL ORDER BY created_at LIMIT 1
                """,
                (preview["space_id"], user["family_id"], preview["label"]),
            )
        ).fetchone()
        if source_row is None:
            source = {
                "id": str(uuid.uuid4()),
                "space_id": preview["space_id"],
                "source_kind": "HL_REPORT",
                "label": preview["label"],
                "public_address": None,
                "status": "ACTIVE",
            }
            await db.execute(
                """
                INSERT INTO finance_asset_sources
                    (id, space_id, source_kind, label, public_address, status,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, 'HL_REPORT', ?, NULL, 'ACTIVE', ?, ?, ?, ?)
                """,
                (
                    source["id"],
                    source["space_id"],
                    source["label"],
                    user["family_id"],
                    now_dt.isoformat(),
                    now_dt.isoformat(),
                    user["id"],
                ),
            )
        else:
            source = dict(source_row)
        duplicate = await (
            await db.execute(
                """
                SELECT id FROM finance_asset_snapshots
                WHERE source_id = ? AND as_of_at = ? AND deleted_at IS NULL
                """,
                (source["id"], as_of_at),
            )
        ).fetchone()
        if duplicate is not None:
            raise FinanceAssetConflictError("This dated HL report has already been confirmed")
        snapshot_id, data_status = await insert_asset_snapshot(
            db,
            user=user,
            source=source,
            as_of_at=as_of_at,
            snapshot_kind="REVIEWED_REPORT",
            currency=preview["currency"],
            positions=holdings,
        )
        for activity in response.activities:
            await db.execute(
                """
                INSERT INTO finance_asset_report_activities
                    (id, space_id, snapshot_id, activity_type, occurred_on,
                     amount_minor, currency, description, family_id, created_at,
                     updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    preview["space_id"],
                    snapshot_id,
                    activity.activity_type,
                    activity.occurred_on.isoformat(),
                    activity.amount_minor,
                    activity.currency,
                    activity.description,
                    user["family_id"],
                    now_dt.isoformat(),
                    now_dt.isoformat(),
                    user["id"],
                ),
            )
        await save_history(
            db,
            "finance_asset_import_previews",
            preview_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_asset_import_previews
            SET status = 'CONFIRMED', updated_at = ? WHERE id = ?
            """,
            (now_dt.isoformat(), preview_id),
        )
    return FinanceAssetSnapshotResponse(
        id=snapshot_id,
        source=_source_response(source),
        as_of_at=as_of_at,
        snapshot_kind="REVIEWED_REPORT",
        data_status=data_status,
        position_count=len(holdings),
    )


async def create_watch_address(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceWatchAddressCreate,
) -> FinanceAssetSourceResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    address_pattern = _SOLANA_PUBLIC if body.source_kind == "SOLANA_PUBLIC" else _HYPERLIQUID_PUBLIC
    if not address_pattern.fullmatch(body.public_address) or (
        body.source_kind == "SOLANA_PUBLIC" and _solana_public_key_bytes(body.public_address) != 32
    ):
        raise FinanceAssetError(
            "Only a correctly formatted public address is accepted; private keys are forbidden"
        )
    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_asset_sources
                WHERE space_id = ? AND family_id = ? AND source_kind = ?
                  AND public_address = ? AND deleted_at IS NULL
                """,
                (space_id, user["family_id"], body.source_kind, body.public_address),
            )
        ).fetchone()
        if existing is not None:
            source = dict(existing)
            if source["status"] == "PAUSED":
                await save_history(
                    db,
                    "finance_asset_sources",
                    source["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    "UPDATE finance_asset_sources SET status = 'ACTIVE', label = ?, "
                    "updated_at = ? WHERE id = ? AND space_id = ? AND family_id = ? "
                    "AND status = 'PAUSED' AND deleted_at IS NULL",
                    (
                        body.label.strip(),
                        now,
                        source["id"],
                        space_id,
                        user["family_id"],
                    ),
                )
                source.update(status="ACTIVE", label=body.label.strip(), updated_at=now)
            return _source_response(source)
        await db.execute(
            """
            INSERT INTO finance_asset_sources
                (id, space_id, source_kind, label, public_address, status,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, 'ACTIVE', ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                body.source_kind,
                body.label.strip(),
                body.public_address,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    return FinanceAssetSourceResponse(
        id=identifier,
        space_id=space_id,
        source_kind=body.source_kind,
        label=body.label.strip(),
        public_address=body.public_address,
        status="ACTIVE",
    )


def _validate_watch_positions(source: dict, positions: list[FinanceAssetHoldingInput]) -> None:
    prefix = "solana:" if source["source_kind"] == "SOLANA_PUBLIC" else "hyperliquid:"
    for position in positions:
        if not position.asset_key.casefold().startswith(prefix):
            raise FinanceAssetError("Watch-only positions must match their public source")
        if position.asset_class not in {
            "STABLE_CRYPTO",
            "VOLATILE_CRYPTO",
            "LIABILITY",
        }:
            raise FinanceAssetError("Watch-only sources may contain crypto or liabilities only")
        if source["source_kind"] == "SOLANA_PUBLIC" and position.position_kind != "HOLDING":
            raise FinanceAssetError("Solana watch-only snapshots contain holdings only")
        if (
            position.position_kind in {"EXPOSURE", "UNREALISED_PNL"}
            and position.include_in_net_worth
        ):
            raise FinanceAssetError("Exposure and PnL rows cannot be added again to net worth")


async def record_watch_snapshot(
    db,
    *,
    user: dict,
    source_id: str,
    body: FinanceWatchSnapshotCreate,
) -> FinanceAssetSnapshotResponse:
    source = await _authorised_source(db, user=user, source_id=source_id)
    if source["source_kind"] not in {"SOLANA_PUBLIC", "HYPERLIQUID_PUBLIC"} or source[
        "status"
    ] != "ACTIVE":
        raise FinanceAssetError("Asset source is not an active watch-only address")
    _validate_watch_positions(source, body.positions)
    as_of_at = body.as_of_at.astimezone(timezone.utc).isoformat()
    async with serialized_create(db):
        duplicate = await (
            await db.execute(
                """
                SELECT id FROM finance_asset_snapshots
                WHERE source_id = ? AND as_of_at = ? AND deleted_at IS NULL
                """,
                (source_id, as_of_at),
            )
        ).fetchone()
        if duplicate is not None:
            raise FinanceAssetConflictError(
                "A snapshot already exists for this source and timestamp"
            )
        snapshot_id, data_status = await insert_asset_snapshot(
            db,
            user=user,
            source=source,
            as_of_at=as_of_at,
            snapshot_kind="WATCH_ONLY",
            currency=body.currency,
            positions=body.positions,
        )
    return FinanceAssetSnapshotResponse(
        id=snapshot_id,
        source=_source_response(source),
        as_of_at=as_of_at,
        snapshot_kind="WATCH_ONLY",
        data_status=data_status,
        position_count=len(body.positions),
    )


async def refresh_watch_source(
    db,
    *,
    user: dict,
    source_id: str,
    adapter_registry: PublicAssetAdapterRegistry | None = None,
) -> FinanceAssetSnapshotResponse:
    """Refresh through a closed, public-read registry; callers cannot choose a URL."""
    source = await _authorised_source(db, user=user, source_id=source_id)
    if source["source_kind"] not in {"SOLANA_PUBLIC", "HYPERLIQUID_PUBLIC"} or source[
        "status"
    ] != "ACTIVE":
        raise FinanceAssetError("Asset source is not an active watch-only address")
    registry = adapter_registry or PublicAssetAdapterRegistry()
    try:
        public_snapshot = await registry.for_source_kind(source["source_kind"]).fetch(
            source["public_address"]
        )
    except PublicAssetAdapterError as exc:
        raise FinanceAssetError(str(exc)) from exc
    positions = list(public_snapshot.positions)
    _validate_watch_positions(source, positions)
    return await record_watch_snapshot(
        db,
        user=user,
        source_id=source_id,
        body=FinanceWatchSnapshotCreate(
            reviewed=True,
            as_of_at=public_snapshot.as_of_at,
            currency=public_snapshot.currency,
            positions=positions,
        ),
    )


def _quote_minor(
    *,
    price: Decimal,
    quote_currency: str,
    currency: str,
    exchange_rate: Decimal | None = None,
) -> int:
    if quote_currency == "GBX":
        if currency == "GBP":
            factor = Decimal(1)
        elif exchange_rate is not None:
            # A GBX quote is already expressed in sterling minor units. Applying
            # the usual major-to-minor factor here would multiply the converted
            # value by another 100.
            factor = exchange_rate
        else:
            raise MarketPriceUnavailable("The public quote uses another currency")
    elif quote_currency == currency:
        factor = Decimal(100)
    elif exchange_rate is not None:
        factor = Decimal(100) * exchange_rate
    else:
        raise MarketPriceUnavailable("The public quote uses another currency")
    return int((price * factor).to_integral_value(rounding=ROUND_HALF_UP))


async def refresh_securities_prices(
    db,
    *,
    user: dict,
    source_id: str,
    provider: MarketQuoteProvider | None = None,
) -> FinanceAssetPriceRefreshResponse:
    """Cache public end-of-day prices, retaining every previous value on failure."""
    source = await _authorised_source(db, user=user, source_id=source_id)
    if source["source_kind"] not in {"HL_REPORT", "MANUAL_PORTFOLIO"} or source[
        "status"
    ] != "ACTIVE":
        raise FinanceAssetError("Asset source is not an active securities portfolio")
    snapshot = await (
        await db.execute(
            """
            SELECT * FROM finance_asset_snapshots
            WHERE source_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY as_of_at DESC, id DESC LIMIT 1
            """,
            (source_id, source["space_id"], user["family_id"]),
        )
    ).fetchone()
    if snapshot is None:
        raise FinanceAssetNotFoundError("Securities portfolio has no saved holdings")
    rows = await (
        await db.execute(
            """
            SELECT position.asset_key, position.quote_symbol,
                   position.quote_currency, valuation.currency
            FROM finance_positions position
            JOIN finance_valuations valuation
              ON valuation.position_id = position.id
             AND valuation.space_id = position.space_id
             AND valuation.family_id = position.family_id
             AND valuation.deleted_at IS NULL
            WHERE position.snapshot_id = ? AND position.space_id = ?
              AND position.family_id = ? AND position.deleted_at IS NULL
              AND position.include_in_net_worth = 1
              AND position.asset_key != 'hl:cash'
            ORDER BY position.asset_key
            """,
            (snapshot["id"], source["space_id"], user["family_id"]),
        )
    ).fetchall()
    owns_provider = provider is None
    quote_provider = provider or configured_market_quote_provider()
    quote_cache: dict[str, MarketQuote | None] = {}
    exchange_cache: dict[tuple[str, str], tuple[Decimal, str, str] | None] = {}
    priced = 0
    retained = 0
    observed_times: list[str] = []
    sources: set[str] = set()
    observations: list[tuple[object, ...]] = []
    try:
        for raw in rows:
            row = dict(raw)
            symbol = row["quote_symbol"]
            quote_currency = row["quote_currency"]
            if not symbol or not quote_currency:
                retained += 1
                continue
            if symbol not in quote_cache:
                try:
                    quote_cache[symbol] = await quote_provider.fetch(symbol)
                except (MarketPriceUnavailable, ValueError):
                    quote_cache[symbol] = None
            quote = quote_cache[symbol]
            if quote is None:
                retained += 1
                continue
            exchange_rate = None
            price_source = quote.source_label
            observed_at_dt = quote.observed_at.astimezone(timezone.utc)
            target_currency = row["currency"]
            base_currency = "GBP" if quote_currency == "GBX" else quote_currency
            if base_currency != target_currency:
                exchange_key = (base_currency, target_currency)
                if exchange_key not in exchange_cache:
                    fetch_exchange_rate = getattr(
                        quote_provider,
                        "fetch_exchange_rate",
                        None,
                    )
                    if fetch_exchange_rate is None:
                        exchange_cache[exchange_key] = None
                    else:
                        try:
                            exchange = await fetch_exchange_rate(*exchange_key)
                            exchange_cache[exchange_key] = (
                                exchange.rate,
                                exchange.observed_at.astimezone(timezone.utc).isoformat(),
                                exchange.source_label,
                            )
                        except (MarketPriceUnavailable, ValueError):
                            exchange_cache[exchange_key] = None
                exchange_result = exchange_cache[exchange_key]
                if exchange_result is None:
                    retained += 1
                    continue
                exchange_rate, exchange_observed_at, exchange_source = exchange_result
                observed_at_dt = min(
                    observed_at_dt,
                    datetime.fromisoformat(exchange_observed_at),
                )
                price_source = f"{quote.source_label}; {exchange_source}"
            try:
                unit_price_minor = _quote_minor(
                    price=quote.price,
                    quote_currency=quote_currency,
                    currency=target_currency,
                    exchange_rate=exchange_rate,
                )
            except (MarketPriceUnavailable, ValueError):
                retained += 1
                continue
            observed_at = observed_at_dt.isoformat()
            observations.append(
                (
                    str(uuid.uuid4()),
                    source["space_id"],
                    source_id,
                    row["asset_key"],
                    symbol,
                    quote_currency,
                    target_currency,
                    unit_price_minor,
                    observed_at,
                    price_source,
                    user["family_id"],
                    user["id"],
                )
            )
            priced += 1
            observed_times.append(observed_at)
            sources.add(price_source)
    finally:
        if owns_provider:
            try:
                await close_market_quote_provider(quote_provider)
            except Exception:
                # Keep successfully fetched prices even if transport cleanup fails.
                pass

    if observations:
        now = _now()
        persisted = [(*values[:11], now, now, values[11]) for values in observations]
        async with serialized_create(db):
            await db.executemany(
                """
                INSERT OR IGNORE INTO finance_market_price_observations
                    (id, space_id, source_id, asset_key, quote_symbol,
                     quote_currency, currency, unit_price_minor, observed_at,
                     source_label, family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                persisted,
            )

    if not observed_times:
        latest = await (
            await db.execute(
                """
                SELECT observed_at, source_label
                FROM finance_market_price_observations
                WHERE source_id = ? AND space_id = ? AND family_id = ?
                  AND deleted_at IS NULL
                ORDER BY observed_at DESC, id DESC LIMIT 1
                """,
                (source_id, source["space_id"], user["family_id"]),
            )
        ).fetchone()
        if latest is not None:
            observed_times.append(latest["observed_at"])
            sources.add(latest["source_label"])
        else:
            observed_times.append(snapshot["as_of_at"])
            sources.add(
                "Reviewed Hargreaves Lansdown report"
                if source["source_kind"] == "HL_REPORT"
                else "User-entered savings portfolio"
            )
    return FinanceAssetPriceRefreshResponse(
        source_id=source_id,
        source_label=source["label"],
        priced_holding_count=priced,
        retained_holding_count=retained,
        price_observed_at=max(observed_times, default=None),
        price_sources=sorted(sources),
    )


async def refresh_hl_prices(
    db,
    *,
    user: dict,
    source_id: str,
    provider: MarketQuoteProvider | None = None,
) -> FinanceAssetPriceRefreshResponse:
    """Compatibility wrapper for the existing HL-specific API route."""
    source = await _authorised_source(db, user=user, source_id=source_id)
    if source["source_kind"] != "HL_REPORT":
        raise FinanceAssetError("Asset source is not an active HL report")
    return await refresh_securities_prices(
        db,
        user=user,
        source_id=source_id,
        provider=provider,
    )


async def refresh_hl_portfolio_prices(
    db,
    *,
    user: dict,
    space_id: str,
    provider: MarketQuoteProvider | None = None,
) -> list[FinanceAssetPriceRefreshResponse]:
    """Refresh every HL source in one space with one quote cache and request budget."""
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT id FROM finance_asset_sources
            WHERE space_id = ? AND family_id = ? AND source_kind = 'HL_REPORT'
              AND status = 'ACTIVE' AND deleted_at IS NULL
            ORDER BY id
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    owns_provider = provider is None
    quote_provider = provider or configured_market_quote_provider()
    try:
        return [
            await refresh_securities_prices(
                db,
                user=user,
                source_id=row["id"],
                provider=quote_provider,
            )
            for row in rows
        ]
    finally:
        if owns_provider:
            try:
                await close_market_quote_provider(quote_provider)
            except Exception:
                # Child refreshes have completed; cleanup must not replace results.
                pass


def _manual_value_response(row: dict) -> FinanceManualAssetValueResponse:
    return FinanceManualAssetValueResponse(
        id=row["value_id"],
        item_id=row["item_id"],
        space_id=row["space_id"],
        name=row["name"],
        asset_class=row["asset_class"],
        as_of_at=row["as_of_at"],
        value_minor=row["value_minor"],
        currency=row["currency"],
        source_label=row["source_label"],
    )


async def record_manual_asset_value(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceManualAssetValueCreate,
) -> FinanceManualAssetValueResponse:
    """Record a reviewed property, pension, other asset or debt value."""
    await require_finance_space(db, user=user, space_id=space_id)
    now = _now()
    as_of_at = body.as_of_at.astimezone(timezone.utc).isoformat()
    async with serialized_create(db):
        if body.item_id is None:
            item_id = str(uuid.uuid4())
            await db.execute(
                """
                INSERT INTO finance_manual_assets
                    (id, space_id, name, asset_class, status, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, 'ACTIVE', ?, ?, ?, ?)
                """,
                (
                    item_id,
                    space_id,
                    body.name,
                    body.asset_class,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
        else:
            item_id = body.item_id
            item = await (
                await db.execute(
                    """
                    SELECT item.* FROM finance_manual_assets item
                    JOIN finance_spaces space
                      ON space.id = item.space_id AND space.family_id = item.family_id
                     AND space.deleted_at IS NULL
                    WHERE item.id = ? AND item.space_id = ? AND item.family_id = ?
                      AND item.status = 'ACTIVE' AND item.deleted_at IS NULL
                      AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                           OR (space.kind = 'household' AND space.owner_user_id IS NULL))
                    """,
                    (item_id, space_id, user["family_id"], user["id"]),
                )
            ).fetchone()
            if item is None:
                raise FinanceAssetNotFoundError("Manual asset not found")
            if item["name"] != body.name or item["asset_class"] != body.asset_class:
                raise FinanceAssetConflictError("The name and type must match the saved asset")
        existing = await (
            await db.execute(
                """
                SELECT value.id AS value_id, value.item_id, value.space_id,
                       item.name, item.asset_class, value.as_of_at,
                       value.value_minor, value.currency, value.source_label
                FROM finance_manual_asset_values value
                JOIN finance_manual_assets item ON item.id = value.item_id
                WHERE value.item_id = ? AND value.as_of_at = ?
                  AND value.deleted_at IS NULL
                """,
                (item_id, as_of_at),
            )
        ).fetchone()
        if existing is not None:
            if (
                existing["value_minor"] != body.value_minor
                or existing["currency"] != body.currency
                or existing["source_label"] != body.source_label
            ):
                raise FinanceAssetConflictError("A different value is already saved for this date")
            return _manual_value_response(dict(existing))
        value_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO finance_manual_asset_values
                (id, space_id, item_id, as_of_at, value_minor, currency,
                 source_label, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                value_id,
                space_id,
                item_id,
                as_of_at,
                body.value_minor,
                body.currency,
                body.source_label,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    return FinanceManualAssetValueResponse(
        id=value_id,
        item_id=item_id,
        space_id=space_id,
        name=body.name,
        asset_class=body.asset_class,
        as_of_at=as_of_at,
        value_minor=body.value_minor,
        currency=body.currency,
        source_label=body.source_label,
    )


def _account_layer(row: dict) -> str:
    if row["account_type"] == "CREDIT_CARD":
        return "LIABILITY"
    if row["account_type"] == "INVESTMENT" or row["purpose"] == "INVESTMENT_LIKE":
        return "BROKERAGE_INVESTMENT"
    if row["account_type"] == "CRYPTO":
        return "VOLATILE_CRYPTO"
    if row["purpose"] == "GOAL":
        return "GOAL_CASH"
    if row["account_type"] == "SAVINGS" or row["purpose"] == "SAVINGS":
        return "ACCESSIBLE_SAVINGS"
    return "OPERATING_CASH"


async def net_worth_summary(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
) -> FinanceNetWorthResponse:
    """Combine dated saved balances and valuations without treating unknown as zero."""
    currency = normalise_currency(currency)
    await require_finance_space(db, user=user, space_id=space_id)
    buckets = {
        layer: {
            "known": 0,
            "unknown": 0,
            "dates": [],
            "included": True,
            "paused": 0,
        }
        for layer in _LAYERS
    }
    # Reserves are labelled allocations within cash accounts.  Showing them is
    # useful, but including them again would double-count the underlying cash.
    buckets["PROTECTED_RESERVE"]["included"] = False

    accounts = await (
        await db.execute(
            """
            SELECT account.*, balance.booked_minor, balance.currency AS balance_currency,
                   balance.observed_at
            FROM finance_accounts account
            LEFT JOIN finance_balance_snapshots balance ON balance.id = (
                SELECT latest.id FROM finance_balance_snapshots latest
                WHERE latest.account_id = account.id AND latest.space_id = account.space_id
                  AND latest.family_id = account.family_id AND latest.deleted_at IS NULL
                ORDER BY latest.observed_at DESC, latest.id DESC LIMIT 1
            )
            WHERE account.space_id = ? AND account.family_id = ?
              AND account.include_in_net_worth = 1 AND account.deleted_at IS NULL
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    for raw in accounts:
        row = dict(raw)
        layer = _account_layer(row)
        bucket = buckets[layer]
        if row["observed_at"] is not None:
            bucket["dates"].append(row["observed_at"])
        if row["booked_minor"] is None or row["balance_currency"] != currency:
            bucket["unknown"] += 1
            continue
        value = row["booked_minor"]
        bucket["known"] += -abs(value) if layer == "LIABILITY" else value

    reserves = await (
        await db.execute(
            """
            SELECT allocated_minor, currency, updated_at FROM finance_reserves
            WHERE space_id = ? AND family_id = ? AND status = 'ACTIVE'
              AND deleted_at IS NULL
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    reserve_bucket = buckets["PROTECTED_RESERVE"]
    for row in reserves:
        reserve_bucket["dates"].append(row["updated_at"])
        if row["currency"] != currency:
            reserve_bucket["unknown"] += 1
        else:
            reserve_bucket["known"] += row["allocated_minor"]

    positions = await (
        await db.execute(
            """
            SELECT position.asset_class, position.quantity_decimal,
                   valuation.valuation_status, valuation.value_minor,
                   valuation.currency, valuation.observed_at,
                   market_price.unit_price_minor AS market_unit_price_minor,
                   market_price.currency AS market_currency,
                   market_price.observed_at AS market_observed_at,
                   source.status AS source_status
            FROM finance_asset_sources source
            JOIN finance_asset_snapshots snapshot ON snapshot.id = (
                SELECT latest.id FROM finance_asset_snapshots latest
                WHERE latest.source_id = source.id AND latest.space_id = source.space_id
                  AND latest.family_id = source.family_id AND latest.deleted_at IS NULL
                ORDER BY latest.as_of_at DESC, latest.id DESC LIMIT 1
            )
            JOIN finance_positions position
              ON position.snapshot_id = snapshot.id AND position.space_id = snapshot.space_id
             AND position.family_id = snapshot.family_id AND position.deleted_at IS NULL
             AND position.include_in_net_worth = 1
            JOIN finance_valuations valuation
              ON valuation.position_id = position.id AND valuation.space_id = position.space_id
             AND valuation.family_id = position.family_id AND valuation.deleted_at IS NULL
            LEFT JOIN finance_market_price_observations market_price
              ON market_price.id = (
                  SELECT latest_price.id
                  FROM finance_market_price_observations latest_price
                  WHERE latest_price.source_id = source.id
                    AND latest_price.space_id = source.space_id
                    AND latest_price.family_id = source.family_id
                    AND latest_price.asset_key = position.asset_key
                    AND latest_price.quote_symbol = position.quote_symbol
                    AND (
                        source.source_kind = 'MANUAL_PORTFOLIO'
                        OR latest_price.observed_at >= snapshot.as_of_at
                    )
                    AND latest_price.deleted_at IS NULL
                  ORDER BY latest_price.observed_at DESC, latest_price.id DESC LIMIT 1
              )
            WHERE source.space_id = ? AND source.family_id = ?
              AND source.deleted_at IS NULL
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    for raw in positions:
        row = dict(raw)
        bucket = buckets[row["asset_class"]]
        has_market_price = (
            row["market_unit_price_minor"] is not None and row["market_currency"] == currency
        )
        observed_at = row["market_observed_at"] if has_market_price else row["observed_at"]
        bucket["dates"].append(observed_at)
        if row["source_status"] == "PAUSED":
            bucket["paused"] += 1
        if has_market_price:
            value = int(
                (
                    Decimal(row["quantity_decimal"]) * Decimal(row["market_unit_price_minor"])
                ).to_integral_value(rounding=ROUND_HALF_UP)
            )
        elif row["valuation_status"] == "KNOWN" and row["currency"] == currency:
            value = row["value_minor"]
        else:
            bucket["unknown"] += 1
            continue
        bucket["known"] += -abs(value) if row["asset_class"] == "LIABILITY" else value

    manual_values = await (
        await db.execute(
            """
            SELECT item.asset_class, value.value_minor, value.currency,
                   value.as_of_at
            FROM finance_manual_assets item
            JOIN finance_manual_asset_values value ON value.id = (
                SELECT latest.id FROM finance_manual_asset_values latest
                WHERE latest.item_id = item.id AND latest.space_id = item.space_id
                  AND latest.family_id = item.family_id AND latest.deleted_at IS NULL
                ORDER BY latest.as_of_at DESC, latest.id DESC LIMIT 1
            )
            WHERE item.space_id = ? AND item.family_id = ?
              AND item.status = 'ACTIVE' AND item.deleted_at IS NULL
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    for row in manual_values:
        bucket = buckets[row["asset_class"]]
        bucket["dates"].append(row["as_of_at"])
        if row["currency"] != currency:
            bucket["unknown"] += 1
            continue
        value = row["value_minor"]
        bucket["known"] += -abs(value) if row["asset_class"] == "LIABILITY" else value

    layers = []
    all_dates: list[str] = []
    known_total = 0
    for layer in _LAYERS:
        bucket = buckets[layer]
        data_through = min(bucket["dates"], default=None)
        all_dates.extend(bucket["dates"])
        if bucket["included"]:
            known_total += bucket["known"]
        note = None
        if layer == "PROTECTED_RESERVE":
            note = "Allocation shown separately; already represented by cash accounts."
        if bucket["unknown"]:
            note = "One or more values are unknown or use another currency."
        if bucket["paused"]:
            paused_note = "Includes the latest dated value from a paused watch source."
            note = f"{note} {paused_note}" if note else paused_note
        layers.append(
            FinanceNetWorthLayerResponse(
                layer=layer,
                amount_minor=bucket["known"],
                known_components_minor=bucket["known"],
                unknown_component_count=bucket["unknown"],
                included_in_total=bucket["included"],
                data_through=data_through,
                note=note,
            )
        )
    return FinanceNetWorthResponse(
        space_id=space_id,
        currency=currency,
        total_net_worth_minor=known_total,
        known_net_worth_minor=known_total,
        data_through=min(all_dates, default=None),
        layers=layers,
    )

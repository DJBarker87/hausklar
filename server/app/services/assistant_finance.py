"""Bounded, identifier-redacted Finance reads for explicit assistant messages."""

from __future__ import annotations

import re
from datetime import date, timedelta
from typing import Any

from app.services.ai_consent import has_current_ai_consent


_IDENTIFIER_PATTERNS = (
    re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b", flags=re.IGNORECASE),
    re.compile(r"(?<!\d)\d{8}(?!\d)"),
    re.compile(r"(?<!\d)\d{2}[ -]\d{2}[ -]\d{2}(?!\d)"),
    re.compile(r"\b0x[a-f0-9]{40}\b", flags=re.IGNORECASE),
    re.compile(r"\b(?:bc1|[13])[a-zA-HJ-NP-Z0-9]{25,62}\b", flags=re.IGNORECASE),
    re.compile(r"\b[1-9A-HJ-NP-Za-km-z]{32,44}\b"),
)


def _redact_identifier_text(value: Any) -> Any:
    """Remove account and public-wallet identifiers embedded in display text."""
    if isinstance(value, str):
        for pattern in _IDENTIFIER_PATTERNS:
            value = pattern.sub("[identifier redacted]", value)
        return value
    if isinstance(value, list):
        return [_redact_identifier_text(item) for item in value]
    if isinstance(value, dict):
        return {key: _redact_identifier_text(item) for key, item in value.items()}
    return value


async def _rows(db, query: str, params: tuple = ()) -> list[dict]:
    cursor = await db.execute(query, params)
    return [dict(row) for row in await cursor.fetchall()]


async def _visible_space_ids(db, *, user: dict) -> tuple[list[str], list[dict]]:
    spaces = await _rows(
        db,
        """
        SELECT id, kind
        FROM finance_spaces
        WHERE family_id = ? AND deleted_at IS NULL
          AND ((kind = 'personal' AND owner_user_id = ?)
               OR (kind = 'household' AND owner_user_id IS NULL))
        ORDER BY CASE kind WHEN 'personal' THEN 0 ELSE 1 END, id
        """,
        (user["family_id"], user["id"]),
    )
    household_allowed = True
    if any(item["kind"] == "household" for item in spaces):
        adults = await _rows(
            db,
            """
            SELECT ai_consent_version, ai_consent_at, ai_consent_revoked_at
            FROM users
            WHERE family_id = ? AND deleted_at IS NULL
            """,
            (user["family_id"],),
        )
        household_allowed = bool(adults) and all(has_current_ai_consent(adult) for adult in adults)
    allowed = [item for item in spaces if item["kind"] == "personal" or household_allowed]
    return [item["id"] for item in allowed], allowed


async def build_assistant_finance_snapshot(
    db,
    *,
    user: dict,
    today: date,
) -> list[dict]:
    """Read caller-visible Finance facts without account or wallet identifiers."""
    space_ids, spaces = await _visible_space_ids(db, user=user)
    if not space_ids:
        return []
    placeholders = ",".join("?" for _ in space_ids)
    scoped = (*space_ids, user["family_id"])
    accounts = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, a.label, a.institution, a.account_type,
               a.purpose, a.currency, a.include_in_cashflow, a.include_in_net_worth,
               a.minimum_balance_minor, b.booked_minor, b.available_minor,
               b.credit_limit_minor, b.observed_at, a.data_through_at
        FROM finance_accounts a
        JOIN finance_spaces fs ON fs.id = a.space_id AND fs.deleted_at IS NULL
        LEFT JOIN finance_balance_snapshots b ON b.id = (
            SELECT latest.id FROM finance_balance_snapshots latest
            WHERE latest.account_id = a.id AND latest.space_id = a.space_id
              AND latest.family_id = a.family_id AND latest.deleted_at IS NULL
            ORDER BY latest.observed_at DESC, latest.created_at DESC LIMIT 1
        )
        WHERE a.space_id IN ({placeholders}) AND a.family_id = ?
          AND a.deleted_at IS NULL
        ORDER BY fs.kind, a.label
        LIMIT 50
        """,
        scoped,
    )
    start = (today - timedelta(days=90)).isoformat()
    transactions = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, t.canonical_date, t.amount_minor,
               t.currency, t.state, t.transaction_kind, t.description,
               t.merchant_text, c.name AS category, t.user_note, t.data_through_at
        FROM finance_transactions t
        JOIN finance_spaces fs ON fs.id = t.space_id AND fs.deleted_at IS NULL
        LEFT JOIN finance_categories c ON c.id = t.primary_category_id
          AND c.deleted_at IS NULL
        WHERE t.space_id IN ({placeholders}) AND t.family_id = ?
          AND t.state IN ('PENDING','POSTED') AND t.deleted_at IS NULL
          AND t.canonical_date >= ?
        ORDER BY t.canonical_date DESC, t.created_at DESC
        LIMIT 60
        """,
        (*scoped, start),
    )
    recurring = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, r.name, r.series_type, r.interval_kind,
               r.expected_minor, r.low_minor, r.high_minor, r.currency,
               r.next_expected_date, r.status, r.confidence_bps
        FROM finance_recurring_series r
        JOIN finance_spaces fs ON fs.id = r.space_id AND fs.deleted_at IS NULL
        WHERE r.space_id IN ({placeholders}) AND r.family_id = ?
          AND r.status IN ('CANDIDATE','CONFIRMED') AND r.deleted_at IS NULL
        ORDER BY r.next_expected_date, r.name
        LIMIT 50
        """,
        scoped,
    )
    commitments = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, c.name, c.amount_mode, c.exact_minor,
               c.expected_minor, c.low_minor, c.high_minor, c.currency,
               c.recurrence, c.priority, c.status, c.notes
        FROM finance_commitments c
        JOIN finance_spaces fs ON fs.id = c.space_id AND fs.deleted_at IS NULL
        WHERE c.space_id IN ({placeholders}) AND c.family_id = ?
          AND c.status IN ('ACTIVE','PAUSED') AND c.deleted_at IS NULL
        ORDER BY c.priority, c.updated_at DESC
        LIMIT 50
        """,
        scoped,
    )
    goals = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, g.name, g.target_minor, g.deadline,
               g.currently_allocated_minor, g.currency, g.priority, g.status, g.notes
        FROM finance_goals g
        JOIN finance_spaces fs ON fs.id = g.space_id AND fs.deleted_at IS NULL
        WHERE g.space_id IN ({placeholders}) AND g.family_id = ?
          AND g.status IN ('ACTIVE','PAUSED') AND g.deleted_at IS NULL
        ORDER BY g.deadline, g.priority
        LIMIT 30
        """,
        scoped,
    )
    reserves = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, r.name, r.allocated_minor,
               r.target_minor, r.currency, r.status
        FROM finance_reserves r
        JOIN finance_spaces fs ON fs.id = r.space_id AND fs.deleted_at IS NULL
        WHERE r.space_id IN ({placeholders}) AND r.family_id = ?
          AND r.status IN ('ACTIVE','PAUSED') AND r.deleted_at IS NULL
        ORDER BY r.updated_at DESC
        LIMIT 30
        """,
        scoped,
    )
    facts = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, f.fact_key, f.statement, f.confirmed_at
        FROM finance_facts f
        JOIN finance_spaces fs ON fs.id = f.space_id AND fs.deleted_at IS NULL
        WHERE f.space_id IN ({placeholders}) AND f.family_id = ?
          AND f.status = 'CONFIRMED' AND f.deleted_at IS NULL
        ORDER BY f.updated_at DESC
        LIMIT 30
        """,
        scoped,
    )
    preferences = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, p.preference_key, p.statement,
               p.value_kind, p.confirmed_at
        FROM finance_preferences p
        JOIN finance_spaces fs ON fs.id = p.space_id AND fs.deleted_at IS NULL
        WHERE p.space_id IN ({placeholders}) AND p.family_id = ?
          AND p.status = 'CONFIRMED' AND p.deleted_at IS NULL
        ORDER BY p.updated_at DESC
        LIMIT 30
        """,
        scoped,
    )
    positions = await _rows(
        db,
        f"""
        SELECT fs.kind AS space_kind, src.label AS source_label, src.source_kind,
               snap.as_of_at, snap.data_status, p.asset_name, p.asset_class,
               p.position_kind, p.quantity_decimal, p.quantity_unit,
               p.quote_symbol, v.valuation_status, v.value_minor, v.currency,
               v.observed_at
        FROM finance_positions p
        JOIN finance_asset_snapshots snap ON snap.id = p.snapshot_id
          AND snap.deleted_at IS NULL
        JOIN finance_asset_sources src ON src.id = snap.source_id
          AND src.deleted_at IS NULL
        JOIN finance_spaces fs ON fs.id = p.space_id AND fs.deleted_at IS NULL
        LEFT JOIN finance_valuations v ON v.position_id = p.id AND v.deleted_at IS NULL
        WHERE p.space_id IN ({placeholders}) AND p.family_id = ?
          AND p.deleted_at IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM finance_asset_snapshots newer
              WHERE newer.source_id = snap.source_id AND newer.deleted_at IS NULL
                AND (newer.as_of_at > snap.as_of_at
                     OR (newer.as_of_at = snap.as_of_at AND newer.id > snap.id))
          )
        ORDER BY fs.kind, src.label, p.asset_name
        LIMIT 100
        """,
        scoped,
    )
    return [
        _redact_identifier_text(
            {
                "scope": [item["kind"] for item in spaces],
                "identifiers_redacted": True,
                "redaction_note": (
                    "Bank account and sort-code identifiers, provider identifiers, "
                    "wallet addresses, credentials and signing material are withheld. "
                    "Balances, holdings and transactions remain readable."
                ),
                "accounts_and_balances": accounts,
                "recent_transactions": transactions,
                "recurring_series": recurring,
                "commitments": commitments,
                "goals": goals,
                "reserves": reserves,
                "confirmed_facts": facts,
                "confirmed_preferences": preferences,
                "latest_positions_and_values": positions,
            }
        )
    ]

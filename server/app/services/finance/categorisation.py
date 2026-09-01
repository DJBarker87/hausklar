"""Deterministic transaction categorisation for calm monthly spending views."""

import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

from app.services.record_history import save_history


@dataclass(frozen=True, slots=True)
class DefaultFinanceCategory:
    key: str
    name: str
    spending_type: str
    counts_as_spending: bool = True


@dataclass(frozen=True, slots=True)
class FinanceCategoryMatch:
    key: str
    confidence_bps: int


DEFAULT_FINANCE_CATEGORIES = (
    DefaultFinanceCategory("bills_utilities", "Bills & utilities", "FIXED"),
    DefaultFinanceCategory("groceries", "Food shopping", "FLEXIBLE"),
    DefaultFinanceCategory("food_dining", "Eating out", "DISCRETIONARY"),
    DefaultFinanceCategory("transport", "Transport", "FLEXIBLE"),
    DefaultFinanceCategory("shopping", "Shopping", "FLEXIBLE"),
    DefaultFinanceCategory("home_garden", "Home & garden", "FLEXIBLE"),
    DefaultFinanceCategory("health_personal", "Health & personal care", "FLEXIBLE"),
    DefaultFinanceCategory("children_education", "Children & education", "FLEXIBLE"),
    DefaultFinanceCategory(
        "entertainment", "Entertainment & subscriptions", "DISCRETIONARY"
    ),
    DefaultFinanceCategory("software", "Software & online services", "FLEXIBLE"),
    DefaultFinanceCategory("travel", "Travel", "DISCRETIONARY"),
    DefaultFinanceCategory("gifts_charity", "Gifts & charity", "DISCRETIONARY"),
    DefaultFinanceCategory("insurance_tax", "Insurance & tax", "FIXED"),
    DefaultFinanceCategory("pets", "Pets", "FLEXIBLE"),
    DefaultFinanceCategory("fees", "Fees & charges", "FIXED"),
    DefaultFinanceCategory("services", "Services", "FLEXIBLE"),
    DefaultFinanceCategory("housing", "Housing", "FIXED"),
    DefaultFinanceCategory("cash", "Cash", "FLEXIBLE"),
    DefaultFinanceCategory("gambling", "Gambling", "DISCRETIONARY"),
    DefaultFinanceCategory(
        "savings_investments",
        "Savings & investments",
        "FLEXIBLE",
        counts_as_spending=False,
    ),
    DefaultFinanceCategory(
        "transfers", "Transfers", "FLEXIBLE", counts_as_spending=False
    ),
    DefaultFinanceCategory("other", "Other", "FLEXIBLE"),
)

_CATEGORY_BY_KEY = {category.key: category for category in DEFAULT_FINANCE_CATEGORIES}
_NON_ALPHANUMERIC = re.compile(r"[^A-Z0-9]+")


def _normalise(value: str | None) -> str:
    expanded = (value or "").upper().replace("&", " AND ")
    return " ".join(_NON_ALPHANUMERIC.sub(" ", expanded).split())


def _matches(text: str, patterns: tuple[str, ...]) -> bool:
    return any(re.search(pattern, text) is not None for pattern in patterns)


_DESCRIPTION_RULES: tuple[tuple[str, int, tuple[str, ...]], ...] = (
    (
        "savings_investments",
        9200,
        (
            r"\bHLAM\b",
            r"\bHARGREAVES\s+LANSDOWN\b",
            r"\bREGULAR\s+SAVIN(?:G|GS)?\b",
            r"\bTRADING\s*212\b",
            r"\bVANGUARD\s+INVESTOR\b",
        ),
    ),
    (
        "children_education",
        9000,
        (
            r"\bCHILDCARE\b",
            r"\bNURSERY\b",
            r"\bPRE\s*SCHOOL\b",
            r"\bPRESCHOOL\b",
            r"\bBABYSITTING\b",
            r"\bSCHOOL\b",
            r"\bTUITION\b",
            r"\bSTUDENT\s+LOAN\b",
            r"\bPTA\b",
        ),
    ),
    (
        "insurance_tax",
        9000,
        (
            r"\bINSURANCE\b",
            r"\bPETPLAN\b",
            r"\bCOUNCIL\s+TAX\b",
            r"\bHMRC\b",
            r"\bBUPA\b",
        ),
    ),
    (
        "fees",
        9200,
        (
            r"\bNON\s+STERLING\s+TRANSACTION\s+FEE\b",
            r"\bSERVICE\s+FEE\b",
            r"\bBANK\s+FEE\b",
            r"\bLATE\s+FEE\b",
            r"\bFINANCE\s+CHARGE\b",
        ),
    ),
    (
        "groceries",
        8800,
        (
            r"\bTESCO(?:\s+GROCERY|\s+STORES?|\s+EXPRESS)?\b",
            r"\bSAINSBURY(?:S)?\b",
            r"\bALDI\b",
            r"\bLIDL\b",
            r"\bWAITROSE\b",
            r"\bMORRISONS\b",
            r"\bASDA\b",
            r"\bOCADO\b",
            r"\bBUDGENS\b",
            r"\bCO\s*OP(?:ERATIVE)?\b",
            r"\bSUPERMARKET\b",
        ),
    ),
    (
        "food_dining",
        8600,
        (
            r"\bUBER\s+EATS\b",
            r"\bDELIVEROO\b",
            r"\bJUST\s+EAT\b",
            r"\bMCDONALD(?:S)?\b",
            r"\bGREGGS\b",
            r"\bRESTAURANT\b",
            r"\bCOFFEE\b",
            r"\bCAFE\b",
            r"\bTORTILLA\b",
            r"\bPUB\b",
            r"\bBIER\s+HAUS\b",
            r"\bWINE\s+SOCIETY\b",
        ),
    ),
    (
        "bills_utilities",
        8800,
        (
            r"\bEDF\s+ENERGY\b",
            r"\bBRITISH\s+GAS\b",
            r"\bOCTOPUS\s+ENERGY\b",
            r"\bTHAMES\s+WATER\b",
            r"\bVIRGIN\s+MEDIA\b",
            r"\bVODAFONE\b",
            r"\bH3G\b",
            r"\bTALKTALK\b",
            r"\bBROADBAND\b",
            r"\bMOBILE\s+PHONE\b",
        ),
    ),
    (
        "software",
        8800,
        (
            r"\bOPENAI\b",
            r"\bCHATGPT\b",
            r"\bANTHROPIC\b",
            r"\bCLAUDE\s+(?:AI|SUB)\b",
            r"\bMIDJOURNEY\b",
            r"\bRUNWAY\s+PRO\b",
            r"\bHETZNER\b",
            r"\bPINATA\s+CLOUD\b",
            r"\bNORD\s*VPN\b",
            r"\bLUDO\s+AI\b",
        ),
    ),
    (
        "entertainment",
        8600,
        (
            r"\bSPOTIFY\b",
            r"\bNETFLIX\b",
            r"\bAUDIBLE\b",
            r"\bPLAYSTATION\b",
            r"\bPATREON\b",
            r"\bAMAZON\s+PRIME\b",
            r"\bAPPLE\s+COM\s+BILL\b",
            r"\bCINEMA\b",
        ),
    ),
    (
        "health_personal",
        8700,
        (
            r"\bPHARMACY\b",
            r"\bOPTICIAN(?:S)?\b",
            r"\bSPECSAVERS\b",
            r"\bDENT(?:AL|IST)\b",
            r"\bDOCTOR\b",
            r"\bHOSPITAL\b",
            r"\bGYM\b",
        ),
    ),
    (
        "transport",
        8400,
        (
            r"\bNCP\b",
            r"\bPARKING\b",
            r"\bTRAINLINE\b",
            r"\bTRANSPORT\s+FOR\s+LONDON\b",
            r"\bTFL\b",
            r"\bUBER\b(?!\s+EATS)",
            r"\bPETROL\b",
            r"\bFUEL\b",
            r"\bDVLA\b",
        ),
    ),
    (
        "home_garden",
        8400,
        (
            r"\bIKEA\b",
            r"\bB\s+Q\b",
            r"\bHOMEBASE\b",
            r"\bWICKES\b",
            r"\bGARDEN\b",
            r"\bFURNITURE\b",
            r"\bROBERT\s+DYAS\b",
            r"\bMIELE\b",
        ),
    ),
    (
        "travel",
        8400,
        (
            r"\bCHANNEL\s+TUNNEL\b",
            r"\bHOTEL\b",
            r"\bAIRWAYS\b",
            r"\bAIRLINES?\b",
            r"\bEASYJET\b",
            r"\bRYANAIR\b",
        ),
    ),
    (
        "pets",
        8400,
        (
            r"\bPET\s+PLANET\b",
            r"\bPETS\s+AT\s+HOME\b",
            r"\bVET(?:ERINARY)?\b",
        ),
    ),
    (
        "shopping",
        7600,
        (
            r"\bAMAZON\b",
            r"\bAMZN\b",
            r"\bAMZNMKTPLACE\b",
            r"\bSPORTS\s*DIRECT\b",
            r"\bCREW\s+CLOTHING\b",
            r"\bCURRYS\b",
            r"\bRAY\s*BAN\b",
            r"\bCARD\s+FACTORY\b",
            r"\bTHE\s+WORKS\b",
            r"\bCOSTCO\b",
        ),
    ),
    (
        "transfers",
        7000,
        (
            r"\bVIA\s+MOBILE\s+XFER\b",
            r"^TO\s+A\s+C\b",
        ),
    ),
)


_PROVIDER_CLASSIFICATION_KEYS = {
    "ENTERTAINMENT": "entertainment",
    "EDUCATION": "children_education",
    "PERSONAL CARE": "health_personal",
    "HEALTH AND FITNESS": "health_personal",
    "FOOD AND DINING": "food_dining",
    "GIFTS AND DONATIONS": "gifts_charity",
    "INVESTMENTS": "savings_investments",
    "BILLS AND UTILITIES": "bills_utilities",
    "AUTO AND TRANSPORT": "transport",
    "TRAVEL": "travel",
    "FEES AND CHARGES": "fees",
    "BUSINESS SERVICES": "services",
    "PERSONAL SERVICES": "services",
    "TAXES": "insurance_tax",
    "GAMBLING": "gambling",
    "HOME": "housing",
    "PENSIONS AND INSURANCES": "insurance_tax",
    "GROCERIES": "groceries",
    "FOOD SHOPPING": "groceries",
}


def _provider_classification_match(value: str | None) -> FinanceCategoryMatch | None:
    parts = [_normalise(part) for part in (value or "").split("/") if _normalise(part)]
    if not parts:
        return None
    top = parts[0]
    subcategory = parts[1] if len(parts) > 1 else ""
    if top == "SHOPPING":
        if subcategory == "GROCERIES":
            key = "groceries"
        elif subcategory == "PETS":
            key = "pets"
        elif subcategory == "HOME":
            key = "home_garden"
        else:
            key = "shopping"
    elif top == "HEALTH AND FITNESS" and subcategory == "PETS":
        key = "pets"
    elif top == "PENSIONS AND INSURANCES" and "PENSION" in subcategory:
        key = "savings_investments"
    elif top == "UNCATEGORIZED" and subcategory == "CASH AND ATM":
        key = "cash"
    else:
        key = _PROVIDER_CLASSIFICATION_KEYS.get(top)
    return FinanceCategoryMatch(key, 9500) if key else None


def _mcc_match(value: str | None) -> FinanceCategoryMatch | None:
    digits = "".join(character for character in (value or "") if character.isdigit())
    if len(digits) < 4:
        return None
    code = int(digits[:4])
    if code in {5411, 5422, 5441, 5451, 5462, 5499}:
        key = "groceries"
    elif code in {5811, 5812, 5813, 5814}:
        key = "food_dining"
    elif code in {4111, 4112, 4121, 4131, 4789, 5511, 5532, 5533, 5541, 5542, 7523}:
        key = "transport"
    elif code in {4812, 4814, 4816, 4821, 4899, 4900}:
        key = "bills_utilities"
    elif code == 5912 or 8011 <= code <= 8099:
        key = "health_personal"
    elif 8211 <= code <= 8299 or code == 8351:
        key = "children_education"
    elif code in {6300, 6381, 6399, 9311}:
        key = "insurance_tax"
    elif code in {6010, 6011}:
        key = "cash"
    elif code in {7995, 7800, 7801, 7802}:
        key = "gambling"
    elif code in {7011, 7512, 4722}:
        key = "travel"
    else:
        return None
    return FinanceCategoryMatch(key, 9000)


def classify_transaction(
    *,
    amount_minor: int,
    description: str,
    merchant_text: str | None = None,
    transaction_kind: str = "CASEY",
    provider_category: str | None = None,
    provider_classification: str | None = None,
    merchant_category_code: str | None = None,
) -> FinanceCategoryMatch | None:
    """Return a conservative category match for an outgoing transaction."""
    if amount_minor >= 0:
        return None
    if transaction_kind == "FEE":
        return FinanceCategoryMatch("fees", 10000)
    provider_match = _provider_classification_match(provider_classification)
    if provider_match:
        return provider_match
    mcc_match = _mcc_match(merchant_category_code)
    if mcc_match:
        return mcc_match
    text = _normalise(" ".join(value for value in (merchant_text, description) if value))
    for key, confidence_bps, patterns in _DESCRIPTION_RULES:
        if _matches(text, patterns):
            return FinanceCategoryMatch(key, confidence_bps)
    category = _normalise(provider_category)
    if category in {"ATM", "CASH", "CASHBACK"}:
        return FinanceCategoryMatch("cash", 8500)
    if category == "FEE CHARGE":
        return FinanceCategoryMatch("fees", 9000)
    if category == "TRANSFER":
        return FinanceCategoryMatch("transfers", 8000)
    if category in {"BILL PAYMENT", "DIRECT DEBIT"}:
        return FinanceCategoryMatch("bills_utilities", 6500)
    return FinanceCategoryMatch("other", 2500)


async def ensure_default_categories(
    db,
    *,
    space_id: str,
    family_id: str,
    actor_id: str,
) -> dict[str, str]:
    """Return category IDs, creating only missing defaults in this Finance space."""
    rows = await (
        await db.execute(
            """
            SELECT id, system_key, name, counts_as_spending
            FROM finance_categories
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY created_at, id
            """,
            (space_id, family_id),
        )
    ).fetchall()
    by_key = {row["system_key"]: row["id"] for row in rows if row["system_key"]}
    by_name = {row["name"].casefold(): row for row in rows}
    result: dict[str, str] = {}
    now = datetime.now(timezone.utc).isoformat()
    insert_rows: list[tuple] = []
    for category in DEFAULT_FINANCE_CATEGORIES:
        category_id = by_key.get(category.key)
        matching_name = by_name.get(category.name.casefold())
        if category_id is None and matching_name is not None:
            category_id = matching_name["id"]
            # Adopt an exact pre-existing name instead of creating a duplicate.
            # The spending flag is only tightened for non-spending system
            # categories; a user's existing exclusion is never reversed.
            await save_history(
                db,
                "finance_categories",
                category_id,
                actor_id,
                family_id=family_id,
            )
            await db.execute(
                """
                UPDATE finance_categories
                SET system_key = ?,
                    counts_as_spending = CASE
                        WHEN ? = 0 THEN 0 ELSE counts_as_spending
                    END,
                    updated_at = ?
                WHERE id = ? AND space_id = ? AND family_id = ?
                  AND system_key IS NULL AND deleted_at IS NULL
                """,
                (
                    category.key,
                    int(category.counts_as_spending),
                    now,
                    category_id,
                    space_id,
                    family_id,
                ),
            )
        if category_id is None:
            category_id = str(uuid.uuid4())
            insert_rows.append(
                (
                    category_id,
                    space_id,
                    category.name,
                    category.key,
                    category.spending_type,
                    int(category.counts_as_spending),
                    family_id,
                    now,
                    now,
                    actor_id,
                )
            )
        result[category.key] = category_id
    if insert_rows:
        await db.executemany(
            """
            INSERT INTO finance_categories
                (id, space_id, name, system_key, spending_type,
                 counts_as_spending, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            insert_rows,
        )
    return result


async def _record_rule_assignment(
    db,
    *,
    transaction_id: str,
    space_id: str,
    category_id: str,
    confidence_bps: int,
    family_id: str,
    actor_id: str,
) -> None:
    existing = await (
        await db.execute(
            """
            SELECT 1 FROM finance_assignments
            WHERE space_id = ? AND family_id = ?
              AND target_type = 'TRANSACTION' AND target_id = ?
              AND assignment_type = 'CATEGORY' AND assigned_value_id = ?
              AND source = 'RULE' AND status = 'CONFIRMED' AND deleted_at IS NULL
            LIMIT 1
            """,
            (space_id, family_id, transaction_id, category_id),
        )
    ).fetchone()
    if existing is not None:
        return
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO finance_assignments
            (id, space_id, target_type, target_id, assignment_type,
             assigned_value_id, source, status, confidence_bps, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, 'TRANSACTION', ?, 'CATEGORY', ?, 'RULE', 'CONFIRMED',
                ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            space_id,
            transaction_id,
            category_id,
            confidence_bps,
            family_id,
            now,
            now,
            actor_id,
        ),
    )


async def apply_rule_category_to_existing(
    db,
    *,
    transaction_id: str,
    space_id: str,
    category_id: str,
    confidence_bps: int,
    family_id: str,
    actor_id: str,
) -> bool:
    """Apply a stronger automatic category without replacing user work."""
    row = await (
        await db.execute(
            """
            SELECT primary_category_id
            FROM finance_transactions
            WHERE id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            """,
            (transaction_id, space_id, family_id),
        )
    ).fetchone()
    if row is None:
        return False
    split = await (
        await db.execute(
            """
            SELECT 1 FROM finance_transaction_splits
            WHERE transaction_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            LIMIT 1
            """,
            (transaction_id, space_id, family_id),
        )
    ).fetchone()
    if split is not None:
        return False
    user_assignment = await (
        await db.execute(
            """
            SELECT 1 FROM finance_assignments
            WHERE space_id = ? AND family_id = ?
              AND target_type = 'TRANSACTION' AND target_id = ?
              AND assignment_type = 'CATEGORY' AND source = 'USER'
              AND status = 'CONFIRMED' AND deleted_at IS NULL
            LIMIT 1
            """,
            (space_id, family_id, transaction_id),
        )
    ).fetchone()
    if user_assignment is not None:
        return False
    if row["primary_category_id"] is not None:
        if row["primary_category_id"] == category_id:
            return False
        current_rule = await (
            await db.execute(
                """
                SELECT confidence_bps FROM finance_assignments
                WHERE space_id = ? AND family_id = ?
                  AND target_type = 'TRANSACTION' AND target_id = ?
                  AND assignment_type = 'CATEGORY' AND assigned_value_id = ?
                  AND source = 'RULE' AND status = 'CONFIRMED'
                  AND deleted_at IS NULL
                ORDER BY created_at DESC, id DESC
                LIMIT 1
                """,
                (
                    space_id,
                    family_id,
                    transaction_id,
                    row["primary_category_id"],
                ),
            )
        ).fetchone()
        if current_rule is None or (current_rule["confidence_bps"] or 0) >= confidence_bps:
            return False
    await save_history(
        db,
        "finance_transactions",
        transaction_id,
        actor_id,
        family_id=family_id,
    )
    now = datetime.now(timezone.utc).isoformat()
    updated = await db.execute(
        """
        UPDATE finance_transactions
        SET primary_category_id = ?, updated_at = ?
        WHERE id = ? AND space_id = ? AND family_id = ?
          AND deleted_at IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM finance_transaction_splits split
              WHERE split.transaction_id = finance_transactions.id
                AND split.space_id = finance_transactions.space_id
                AND split.family_id = finance_transactions.family_id
                AND split.deleted_at IS NULL
          )
        """,
        (category_id, now, transaction_id, space_id, family_id),
    )
    if updated.rowcount != 1:
        return False
    await _record_rule_assignment(
        db,
        transaction_id=transaction_id,
        space_id=space_id,
        category_id=category_id,
        confidence_bps=confidence_bps,
        family_id=family_id,
        actor_id=actor_id,
    )
    return True


async def record_new_transaction_categories(
    db,
    *,
    space_id: str,
    assignments: list[tuple[str, str, int]],
    family_id: str,
    actor_id: str,
) -> None:
    """Record why newly inserted transactions received their categories."""
    if not assignments:
        return
    now = datetime.now(timezone.utc).isoformat()
    await db.executemany(
        """
        INSERT INTO finance_assignments
            (id, space_id, target_type, target_id, assignment_type,
             assigned_value_id, source, status, confidence_bps, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, 'TRANSACTION', ?, 'CATEGORY', ?, 'RULE', 'CONFIRMED',
                ?, ?, ?, ?, ?)
        """,
        [
            (
                str(uuid.uuid4()),
                space_id,
                transaction_id,
                category_id,
                confidence_bps,
                family_id,
                now,
                now,
                actor_id,
            )
            for transaction_id, category_id, confidence_bps in assignments
        ],
    )


async def backfill_uncategorised_transactions(db) -> int:
    """Categorise existing outflows once, preserving explicit categories and splits."""
    rows = await (
        await db.execute(
            """
            SELECT tx.id, tx.space_id, tx.family_id, tx.amount_minor,
                   tx.description, tx.merchant_text, tx.transaction_kind,
                   tx.created_by, space.owner_user_id, space.created_by AS space_created_by,
                   source.merchant_category_code, source.bank_code, source.bank_sub_code
            FROM finance_transactions tx
            JOIN finance_spaces space
              ON space.id = tx.space_id AND space.family_id = tx.family_id
             AND space.deleted_at IS NULL
            LEFT JOIN finance_transaction_sources link
              ON link.transaction_id = tx.id AND link.is_primary = 1
             AND link.deleted_at IS NULL
            LEFT JOIN finance_source_transactions source
              ON source.id = link.source_transaction_id AND source.deleted_at IS NULL
            WHERE tx.primary_category_id IS NULL
              AND tx.amount_minor < 0
              AND tx.state IN ('POSTED', 'PENDING')
              AND tx.deleted_at IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM finance_transaction_splits split
                  WHERE split.transaction_id = tx.id
                    AND split.space_id = tx.space_id
                    AND split.family_id = tx.family_id
                    AND split.deleted_at IS NULL
              )
            ORDER BY tx.space_id, tx.canonical_date, tx.id
            """
        )
    ).fetchall()
    category_ids_by_space: dict[str, dict[str, str]] = {}
    updated = 0
    for row in rows:
        actor_id = (
            row["owner_user_id"]
            or row["space_created_by"]
            or row["created_by"]
            or "finance-categorisation"
        )
        if row["space_id"] not in category_ids_by_space:
            category_ids_by_space[row["space_id"]] = await ensure_default_categories(
                db,
                space_id=row["space_id"],
                family_id=row["family_id"],
                actor_id=actor_id,
            )
        match = classify_transaction(
            amount_minor=row["amount_minor"],
            description=row["description"],
            merchant_text=row["merchant_text"],
            transaction_kind=row["transaction_kind"],
            provider_category=row["bank_code"],
            provider_classification=row["bank_sub_code"],
            merchant_category_code=row["merchant_category_code"],
        )
        if match is None:
            continue
        changed = await apply_rule_category_to_existing(
            db,
            transaction_id=row["id"],
            space_id=row["space_id"],
            category_id=category_ids_by_space[row["space_id"]][match.key],
            confidence_bps=match.confidence_bps,
            family_id=row["family_id"],
            actor_id=actor_id,
        )
        updated += int(changed)
    return updated


def default_category(key: str) -> DefaultFinanceCategory:
    """Return one declared category; primarily useful to callers and tests."""
    return _CATEGORY_BY_KEY[key]

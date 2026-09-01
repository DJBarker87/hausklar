"""Context, validation, and execution for the private HausKlar assistant."""

from __future__ import annotations

import json
import re
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from dateutil.rrule import rrulestr

from app.database import documents_fts_available
from app.models.assistant import (
    AssistantActionResponse,
    HermesAssistantAction,
    HermesCalendarAction,
    HermesCompleteTaskAction,
    HermesCreateTaskAction,
    HermesLightsAction,
    HermesShoppingAction,
)
from app.services.calendar_recurrence import exception_keys_for_series
from app.services.capture import reference_in_timezone
from app.services.home_assistant import turn_all_lights_for_family
from app.services.record_history import save_history
from app.services.facilities import current_day_rows, day_summary, quick_fact as facility_quick_fact

_HOME_CONTEXT_WORDS = re.compile(
    r"\b(home|house|light|lamp|heating|temperature|door|window|speaker|music|"
    r"switch|turn\s+(?:on|off)|zuhause|haus|licht|lichter|lampe|lampen|heizung|"
    r"temperatur|tür|türen|fenster|lautsprecher|musik|schalter)\b",
    flags=re.IGNORECASE,
)
_CONTEXT_CATEGORY_WORDS = {
    "home": _HOME_CONTEXT_WORDS,
    "fitness": re.compile(
        r"\b(fitness|training|workout|exercise|run|running|strava|strength|"
        r"recovery|readiness|pace|heart\s+rate|cycle|period)\b",
        flags=re.IGNORECASE,
    ),
    "finance": re.compile(
        r"\b(finance|money|bank|balance|transaction|spend|spending|budget|"
        r"saving|savings|investment|holding|crypto|wallet)\b",
        flags=re.IGNORECASE,
    ),
    "facilities": re.compile(
        r"\b(swim|swimming|pool|athens|weights?\s+room|gym|wtr)\b",
        flags=re.IGNORECASE,
    ),
    "schedule": re.compile(
        r"\b(term(?:\s+time)?|holiday|holidays|summer|school\s+date|school\s+dates|"
        r"time\s+off|day\s+off|days\s+off|all\s+free|everyone\s+free|"
        r"ferien|schulferien|schulzeit|unterrichtszeit|frei(?:e[rmn]?)?)\b",
        flags=re.IGNORECASE,
    ),
    "routines": re.compile(
        r"\b(routine|routines|morning\s+routine|bedtime\s+routine|daily\s+routine|"
        r"ablauf|routine(?:n)?|morgenroutine|abendroutine)\b",
        flags=re.IGNORECASE,
    ),
    "documents": re.compile(
        r"\b(document|documents|letter|letters|email|emails|e-mail|invoice|bill|"
        r"receipt|form|forms|attachment|pdf|scan|paperwork|notice|inbox|"
        r"dokument(?:e|en)?|brief(?:e|en)?|rechnung(?:en)?|quittung(?:en)?|"
        r"formular(?:e|en)?|anhang|anhänge|posteingang)\b",
        flags=re.IGNORECASE,
    ),
    "birthdays": re.compile(
        r"\b(birthday|birthdays|date\s+of\s+birth|born|geburtstag|geburtstage|geboren)\b",
        flags=re.IGNORECASE,
    ),
    "presents": re.compile(
        r"\b(present|presents|gift|gifts|birthday\s+idea|geschenk|geschenke)\b",
        flags=re.IGNORECASE,
    ),
    "meals": re.compile(
        r"\b(meal|meals|breakfast|lunch|dinner|supper|food|recipe|recipes|cook|"
        r"shopping|grocery|groceries|ingredient|ingredients|essen|frühstück|"
        r"mittagessen|abendessen|rezept(?:e)?|kochen|einkauf(?:en|sliste)?|"
        r"lebensmittel|zutat(?:en)?)\b",
        flags=re.IGNORECASE,
    ),
    "grocery": re.compile(
        r"\b(pantry|fridge|freezer|stock|use[- ]by|expiry|expired|tesco|"
        r"vorrat|kühlschrank|gefrierschrank|haltbar|abgelaufen)\b",
        flags=re.IGNORECASE,
    ),
    "medicine": re.compile(
        r"\b(medicine|medicines|medication|medications|dose|doses|dosage|calpol|"
        r"paracetamol|ibuprofen|nurofen|antibiotic|antibiotics|medikament(?:e)?|"
        r"medizin|arznei(?:mittel)?|dosis|dosierung)\b",
        flags=re.IGNORECASE,
    ),
    "sleep": re.compile(
        r"\b(sleep|slept|nap|naps|napping|bedtime|awake|woke|wake|schlaf|"
        r"schlafen|geschlafen|nickerchen|mittagsschlaf|wach)\b",
        flags=re.IGNORECASE,
    ),
    "dog": re.compile(
        r"\b(dog|puppy|walk|walked|walking|feed|fed|vet|veterinary|hund|"
        r"welpe|gassi|gefüttert|füttern|tierarzt)\b",
        flags=re.IGNORECASE,
    ),
    "learning": re.compile(
        r"\b(homework|reading|read\s+with|book|books|spelling|spellings|"
        r"star\s+chart|stars|reward|rewards|hausaufgabe(?:n)?|lesen|buch|bücher|"
        r"rechtschreibung|vokabel(?:n)?|stern(?:e)?|belohnung(?:en)?)\b",
        flags=re.IGNORECASE,
    ),
    "illness": re.compile(
        r"\b(ill|illness|unwell|sick|symptom|symptoms|fever|temperature|"
        r"doctor|hospital|krank|krankheit|unwohl|symptom(?:e)?|fieber|arzt|"
        r"ärztin|krankenhaus)\b",
        flags=re.IGNORECASE,
    ),
    "growth": re.compile(
        r"\b(growth|height|weight|weigh|weighed|tall|größe|grösse|gewicht|"
        r"wiegen|gewogen|gewachsen)\b",
        flags=re.IGNORECASE,
    ),
    "health": re.compile(
        r"\b(health|healthkit|heart\s+rate|steps|blood\s+pressure|medical|"
        r"gesundheit|herzfrequenz|schritte|blutdruck|medizinisch)\b",
        flags=re.IGNORECASE,
    ),
    "children_records": re.compile(
        r"\b(milestone|milestones|vaccination|vaccinations|vaccine|photo|photos|"
        r"artwork|drawing|yearbook|meilenstein|impfung|impfungen|foto|fotos|"
        r"kunstwerk|zeichnung|jahrbuch)\b",
        flags=re.IGNORECASE,
    ),
    "renewals": re.compile(
        r"\b(renew|renewal|renewals|expiry|expires|passport|insurance|mot|"
        r"subscription|verlängerung|ablauf|läuft\s+ab|reisepass|versicherung|abo)\b",
        flags=re.IGNORECASE,
    ),
    "library": re.compile(
        r"\b(library|libraries|library\s+book|borrowed|loan|loans|due\s+back|"
        r"bücherei|bibliothek|ausgeliehen|rückgabe)\b",
        flags=re.IGNORECASE,
    ),
    "caregiver": re.compile(
        r"\b(babysitter|caregiver|handover|emergency\s+contact|allergies|"
        r"kinderbetreuung|babysitterin|übergabe|notfallkontakt|allergien)\b",
        flags=re.IGNORECASE,
    ),
}
_WEEKDAYS = {
    "MO": "Monday",
    "TU": "Tuesday",
    "WE": "Wednesday",
    "TH": "Thursday",
    "FR": "Friday",
    "SA": "Saturday",
    "SU": "Sunday",
}
_ALLOWED_RRULE_KEYS = {
    "FREQ",
    "BYDAY",
    "BYMONTHDAY",
    "INTERVAL",
    "COUNT",
    "UNTIL",
}
_ALLOWED_FREQUENCIES = {"DAILY", "WEEKLY", "MONTHLY", "YEARLY"}
_MAX_TERM_TIME_OCCURRENCES = 200
_EXPLICIT_TASK_WORDS = re.compile(
    r"\b(task|to-?do|remind|reminder|aufgabe|erinnere|erinnerung)\b",
    flags=re.IGNORECASE,
)
_LIGHT_OBJECT_WORDS = re.compile(
    r"\b(light|lights|lamp|lamps|licht|lichter|lampe|lampen)\b",
    flags=re.IGNORECASE,
)
_LIGHT_STATE_COMMANDS = {
    "off": re.compile(
        r"(?:\b(?:turn|switch|shut)\s+(?:(?:all|the|house)\s+)*"
        r"(?:lights?|lamps?|them)\s+off\b|"
        r"\b(?:turn|switch|shut)\s+off\s+(?:(?:all|the|house)\s+)*"
        r"(?:lights?|lamps?)\b|"
        r"\b(?:lights?|lamps?)\s+off(?:\s+please)?[.!]?$|"
        r"\b(?:schalt(?:e)?|mach(?:e)?)\s+(?:(?:alle|die)\s+)?"
        r"(?:lichter|lampen|sie)\s+aus\b|"
        r"\b(?:lichter|lampen)\s+aus(?:\s+bitte)?[.!]?$)",
        flags=re.IGNORECASE,
    ),
    "on": re.compile(
        r"(?:\b(?:turn|switch)\s+(?:(?:all|the|house)\s+)*"
        r"(?:lights?|lamps?|them)\s+on\b|"
        r"\b(?:turn|switch)\s+on\s+(?:(?:all|the|house)\s+)*"
        r"(?:lights?|lamps?)\b|"
        r"\b(?:lights?|lamps?)\s+on(?:\s+please)?[.!]?$|"
        r"\b(?:schalt(?:e)?|mach(?:e)?)\s+(?:(?:alle|die)\s+)?"
        r"(?:lichter|lampen|sie)\s+an\b|"
        r"\b(?:lichter|lampen)\s+an(?:\s+bitte)?[.!]?$)",
        flags=re.IGNORECASE,
    ),
}
_SHOPPING_COMMAND_WORDS = re.compile(
    r"\b(add|put|buy|get|pick\s+up|need|shopping\s+list|grocery\s+list|"
    r"hinzufügen|setz(?:e)?|kauf(?:e)?|besorg(?:e)?|brauchen|einkaufsliste)\b",
    flags=re.IGNORECASE,
)
_QUESTION_WORDS = re.compile(
    r"^\s*(what|when|where|which|who|why|how|do|does|did|is|are|was|were|"
    r"can|could|would|should|was|wann|wo|welche|wer|warum|wie|ist|sind|"
    r"hat|haben|kann|könnte|soll)\b",
    flags=re.IGNORECASE,
)
_DOCUMENT_STOP_WORDS = {
    "about",
    "could",
    "family",
    "from",
    "have",
    "hausklar",
    "please",
    "should",
    "that",
    "their",
    "there",
    "these",
    "this",
    "what",
    "when",
    "where",
    "which",
    "with",
    "would",
    "bitte",
    "das",
    "der",
    "die",
    "dieser",
    "für",
    "ist",
    "kann",
    "mit",
    "noch",
    "soll",
    "steht",
    "und",
    "uns",
    "was",
    "welche",
    "wie",
}
_GROUNDING_TYPO_CORRECTIONS = {
    "evry": "every",
    "firday": "friday",
    "saterday": "saturday",
    "thurday": "thursday",
    "tommorow": "tomorrow",
    "tomorow": "tomorrow",
    "tuesay": "tuesday",
    "wedensday": "wednesday",
    "wensday": "wednesday",
}
_FORBIDDEN_ASSISTANT_CONTEXT_FIELDS = {
    "access_token",
    "account_number",
    "bank_code",
    "bank_sub_code",
    "bootstrap_hash",
    "callback_state_hash",
    "credential",
    "credentials",
    "encrypted_provider_secret_ref",
    "encrypted_token_json",
    "iban",
    "mnemonic",
    "password",
    "private_key",
    "provider_account_id",
    "public_address",
    "refresh_token",
    "routing_number",
    "secret",
    "seed_phrase",
    "session_hash",
    "sort_code",
    "token",
    "wallet_address",
    "wifi_password",
}
_SENSITIVE_IDENTIFIER_PATTERNS = (
    re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b", flags=re.IGNORECASE),
    re.compile(r"(?<!\d)\d{8}(?!\d)"),
    re.compile(r"(?<!\d)\d{2}[ -]\d{2}[ -]\d{2}(?!\d)"),
    re.compile(r"\b0x[a-f0-9]{40}\b", flags=re.IGNORECASE),
    re.compile(r"\b(?:bc1|[13])[a-zA-HJ-NP-Z0-9]{25,62}\b", flags=re.IGNORECASE),
    re.compile(r"\b[1-9A-HJ-NP-Za-km-z]{32,44}\b"),
)


async def load_family_people(db, family_id: str) -> list[dict[str, str]]:
    cursor = await db.execute(
        """
        SELECT id, name, 'user' AS person_type
        FROM users
        WHERE family_id = ? AND deleted_at IS NULL
        UNION ALL
        SELECT id, name, 'child' AS person_type
        FROM children
        WHERE family_id = ? AND deleted_at IS NULL
        ORDER BY name
        """,
        (family_id, family_id),
    )
    return [
        {"id": row["id"], "name": row["name"], "person_type": row["person_type"]}
        for row in await cursor.fetchall()
    ]


def _iso_date(value: str) -> date | None:
    try:
        return date.fromisoformat(value[:10])
    except (TypeError, ValueError):
        return None


def _compress_dates(values: list[date]) -> list[dict[str, str]]:
    if not values:
        return []
    periods: list[dict[str, str]] = []
    start = previous = values[0]
    for value in values[1:]:
        if value != previous + timedelta(days=1):
            periods.append({"start": start.isoformat(), "end": previous.isoformat()})
            start = value
        previous = value
    periods.append({"start": start.isoformat(), "end": previous.isoformat()})
    return periods


def _shared_time_off_periods(
    reference: datetime,
    people: list[dict[str, str]],
    term_rows: list[dict],
    holiday_rows: list[dict],
) -> dict:
    names = {person["id"]: person["name"] for person in people}
    terms: dict[str, list[tuple[date, date]]] = defaultdict(list)
    holidays: dict[str, set[date]] = defaultdict(set)

    for row in term_rows:
        start = _iso_date(row["start_date"])
        end = _iso_date(row["end_date"])
        if start and end:
            terms[row["person_id"]].append((start, end))
    for row in holiday_rows:
        holiday = _iso_date(row["date"])
        if holiday:
            holidays[row["person_id"]].add(holiday)

    tracked_ids = sorted(terms)
    if not tracked_ids:
        return {"tracked_people": [], "periods": []}

    coverage = {
        person_id: (
            min(start for start, _ in intervals),
            max(end for _, end in intervals),
        )
        for person_id, intervals in terms.items()
    }
    shared_dates: list[date] = []
    for offset in range(550):
        candidate = reference.date() + timedelta(days=offset)
        if not all(
            coverage[person_id][0] <= candidate <= coverage[person_id][1]
            for person_id in tracked_ids
        ):
            continue
        if all(
            candidate in holidays[person_id]
            or not any(start <= candidate <= end for start, end in terms[person_id])
            for person_id in tracked_ids
        ):
            shared_dates.append(candidate)

    return {
        "tracked_people": [names.get(person_id, person_id) for person_id in tracked_ids],
        "periods": _compress_dates(shared_dates)[:20],
        "note": "Periods are computed only for people with configured term dates.",
    }


async def _query_records(db, query: str, params: tuple = ()) -> list[dict]:
    cursor = await db.execute(query, params)
    return [dict(row) for row in await cursor.fetchall()]


def _assert_assistant_context_is_redacted(value, *, path: str = "context") -> None:
    """Fail closed if a future projection accidentally includes an identifier or secret."""
    if isinstance(value, dict):
        for key, child in value.items():
            snake_key = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", str(key))
            normalized = re.sub(r"[^a-z0-9]+", "_", snake_key.lower()).strip("_")
            if normalized in _FORBIDDEN_ASSISTANT_CONTEXT_FIELDS:
                raise RuntimeError(f"Assistant context contains forbidden field at {path}.{key}")
            _assert_assistant_context_is_redacted(child, path=f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _assert_assistant_context_is_redacted(child, path=f"{path}[{index}]")


def redact_assistant_context(value):
    """Return a copy with account and public-wallet identifiers removed from text."""
    if isinstance(value, str):
        for pattern in _SENSITIVE_IDENTIFIER_PATTERNS:
            value = pattern.sub("[identifier redacted]", value)
        return value
    if isinstance(value, list):
        return [redact_assistant_context(item) for item in value]
    if isinstance(value, dict):
        return {key: redact_assistant_context(item) for key, item in value.items()}
    return value


async def _search_document_text(db, *, family_id: str, terms: list[str]) -> list[dict]:
    """Find documents matching the terms, preferring the FTS index."""
    if await documents_fts_available(db):
        match_query = " OR ".join(f'"{term}"*' for term in terms)
        return await _query_records(
            db,
            """
            SELECT d.id, d.title, d.category, d.document_date,
                   SUBSTR(d.extracted_text, 1, 2000) AS excerpt
            FROM documents_fts
            JOIN documents d ON d.rowid = documents_fts.rowid
            WHERE documents_fts MATCH ? AND d.family_id = ? AND d.deleted_at IS NULL
            ORDER BY d.document_date DESC, d.created_at DESC
            LIMIT 12
            """,
            (match_query, family_id),
        )
    clauses = " OR ".join(
        "(LOWER(title) LIKE ? OR LOWER(extracted_text) LIKE ?)" for _ in terms
    )
    parameters: list[str] = [family_id]
    for term in terms:
        parameters.extend([f"%{term}%", f"%{term}%"])
    return await _query_records(
        db,
        f"""
        SELECT id, title, category, document_date,
               SUBSTR(extracted_text, 1, 2000) AS excerpt
        FROM documents
        WHERE family_id = ? AND deleted_at IS NULL AND ({clauses})
        ORDER BY document_date DESC, created_at DESC
        LIMIT 12
        """,
        tuple(parameters),
    )


def _document_terms(value: str) -> list[str]:
    terms = []
    for word in re.findall(r"[a-z0-9]{4,}", value.lower()):
        if word not in _DOCUMENT_STOP_WORDS and word not in terms:
            terms.append(word)
    return terms[:6]


def _requested_context_categories(message: str, history_text: str) -> set[str]:
    """Derive relevance hints without using wording as a read permission gate."""
    conversation = f"{history_text}\n{message}"
    categories = {
        category
        for category, pattern in _CONTEXT_CATEGORY_WORDS.items()
        if pattern.search(conversation)
    }
    if "health" in categories:
        categories.update({"medicine", "sleep", "illness", "growth"})
    return categories


async def _family_record_snapshot(
    db,
    *,
    family_id: str,
    message: str,
    history_text: str,
    start: str,
    end: str,
) -> dict[str, list[dict]]:
    records: dict[str, list[dict]] = {}
    # An explicit Bismarck message grants read access to the complete bounded
    # family snapshot. Conversation wording is useful for ranking/search, but
    # must never decide which HausKlar modules are visible to the model.
    categories = set(_CONTEXT_CATEGORY_WORDS)

    if "routines" in categories:
        records["routines"] = await _query_records(
            db,
            """
            SELECT person_id, name, days_of_week
            FROM routine_items
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY person_id, sort_order, name
            LIMIT 150
            """,
            (family_id,),
        )

    if "documents" in categories:
        records["recent_documents"] = await _query_records(
            db,
            """
            SELECT id, title, category, status, document_date, notes, created_at,
                   SUBSTR(extracted_text, 1, 1000) AS text_excerpt
            FROM documents
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY created_at DESC
            LIMIT 20
            """,
            (family_id,),
        )
        for item in records["recent_documents"]:
            item["notes"] = item["notes"][:300] if item["notes"] else None

        terms = _document_terms(f"{history_text}\n{message}")
        records["matching_document_text"] = []
        if terms:
            records["matching_document_text"] = await _search_document_text(
                db,
                family_id=family_id,
                terms=terms,
            )

    if "birthdays" in categories:
        records["birthdays"] = await _query_records(
            db,
            """
            SELECT person_name, date_of_birth, relationship
            FROM birthdays
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY date_of_birth
            LIMIT 150
            """,
            (family_id,),
        )
        records["birthday_preparations"] = await _query_records(
            db,
            """
            SELECT bp.id, bp.birthday_id, b.person_name, bp.occurrence_year,
                   bp.card_status, bp.card_message, bp.celebration_status, bp.notes
            FROM birthday_preparations bp
            JOIN birthdays b ON b.id = bp.birthday_id AND b.deleted_at IS NULL
            WHERE bp.family_id = ? AND bp.deleted_at IS NULL
            ORDER BY bp.occurrence_year DESC, b.person_name
            LIMIT 100
            """,
            (family_id,),
        )

    if "presents" in categories:
        records["present_ideas"] = await _query_records(
            db,
            """
            SELECT p.id, p.child_id, c.name AS child_name, p.occasion, p.event_year,
                   p.title, p.status, p.owner_id, p.notes, p.assigned_to, p.retailer,
                   p.budget_minor, p.price_minor, p.currency, p.deadline,
                   p.hiding_location
            FROM present_ideas p
            LEFT JOIN children c ON c.id = p.child_id
            WHERE p.family_id = ? AND p.deleted_at IS NULL
            ORDER BY p.event_year DESC, p.deadline, p.updated_at DESC
            LIMIT 100
            """,
            (family_id,),
        )

    if "meals" in categories:
        records["meal_plan"] = await _query_records(
            db,
            """
            SELECT mp.date, mp.meal_type, mp.notes, mp.tired_household, m.name AS meal_name
            FROM meal_plans mp
            LEFT JOIN meals m ON m.id = mp.meal_id
            WHERE mp.family_id = ? AND mp.deleted_at IS NULL AND mp.date >= ? AND mp.date <= ?
            ORDER BY mp.date, mp.meal_type
            LIMIT 90
            """,
            (family_id, start, end),
        )
        records["meals"] = await _query_records(
            db,
            """
            SELECT id, name, description, tags, ingredients, last_made_at, prep_minutes
            FROM meals
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY COALESCE(last_made_at, created_at) DESC
            LIMIT 100
            """,
            (family_id,),
        )
        for item in records["meals"]:
            item["description"] = item["description"][:300] if item["description"] else None
            item["ingredients"] = item["ingredients"][:1_000] if item["ingredients"] else None
        records["shopping_list"] = await _query_records(
            db,
            """
            SELECT id, name, quantity, category
            FROM shopping_items
            WHERE family_id = ? AND deleted_at IS NULL AND checked = 0
            ORDER BY created_at DESC
            LIMIT 150
            """,
            (family_id,),
        )
        records["recent_meal_ratings"] = await _query_records(
            db,
            """
            SELECT mr.meal_plan_id, mr.child_id, c.name AS child_name,
                   m.name AS meal_name, mp.date, mr.rating
            FROM meal_ratings mr
            JOIN meal_plans mp ON mp.id = mr.meal_plan_id AND mp.deleted_at IS NULL
            LEFT JOIN meals m ON m.id = mp.meal_id AND m.deleted_at IS NULL
            LEFT JOIN children c ON c.id = mr.child_id
            WHERE mr.family_id = ? AND mr.deleted_at IS NULL
            ORDER BY mp.date DESC, c.name
            LIMIT 100
            """,
            (family_id,),
        )

    if "grocery" in categories:
        records["grocery_stock"] = await _query_records(
            db,
            """
            SELECT p.id, p.grocery_item_id, g.name, g.category, p.qty, p.unit,
                   p.use_by_date, p.storage, pb.purchased_at
            FROM purchases p
            JOIN grocery_items g ON g.id = p.grocery_item_id AND g.deleted_at IS NULL
            LEFT JOIN purchase_batches pb ON pb.id = p.purchase_batch_id
            WHERE p.family_id = ? AND p.deleted_at IS NULL
            ORDER BY COALESCE(p.use_by_date, '9999-12-31'), pb.purchased_at DESC
            LIMIT 150
            """,
            (family_id,),
        )
        records["recent_consumption"] = await _query_records(
            db,
            """
            SELECT ce.grocery_item_id, g.name, ce.event_at, ce.amount, ce.unit,
                   ce.event_type, ce.notes
            FROM consumption_events ce
            LEFT JOIN grocery_items g ON g.id = ce.grocery_item_id
            WHERE ce.family_id = ? AND ce.deleted_at IS NULL
            ORDER BY ce.event_at DESC
            LIMIT 100
            """,
            (family_id,),
        )

    if "medicine" in categories:
        records["medicine_types"] = await _query_records(
            db,
            """
            SELECT mt.id, mt.name, mt.child_id, c.name AS child_name,
                   mt.min_hours_between_doses, mt.max_doses_24h, mt.default_dose_amount
            FROM medicine_types mt
            LEFT JOIN children c ON c.id = mt.child_id
            WHERE mt.family_id = ? AND mt.deleted_at IS NULL
            ORDER BY c.name, mt.name
            LIMIT 100
            """,
            (family_id,),
        )
        records["recent_medicine_doses"] = await _query_records(
            db,
            """
            SELECT md.child_id, c.name AS child_name,
                   COALESCE(mt.name, md.medicine_name) AS medicine,
                   md.given_at, md.given_by, md.dose_amount
            FROM medicine_doses md
            LEFT JOIN medicine_types mt ON mt.id = md.medicine_type_id
            LEFT JOIN children c ON c.id = md.child_id
            WHERE md.family_id = ? AND md.deleted_at IS NULL AND md.given_at >= ?
            ORDER BY md.given_at DESC
            LIMIT 100
            """,
            (family_id, start),
        )

    if "sleep" in categories:
        records["recent_sleep"] = await _query_records(
            db,
            """
            SELECT n.child_id, c.name AS child_name, n.started_at, n.ended_at,
                   n.sleep_type, n.location
            FROM naps n
            LEFT JOIN children c ON c.id = n.child_id
            WHERE n.family_id = ? AND n.deleted_at IS NULL AND n.started_at >= ?
            ORDER BY n.started_at DESC
            LIMIT 100
            """,
            (family_id, start),
        )

    if "dog" in categories:
        records["recent_dog_activity"] = await _query_records(
            db,
            """
            SELECT activity_type, started_at, ended_at, done_by, notes
            FROM dog_activities
            WHERE family_id = ? AND deleted_at IS NULL AND started_at >= ?
            ORDER BY started_at DESC
            LIMIT 100
            """,
            (family_id, start),
        )
        records["dog_profile"] = await _query_records(
            db,
            """
            SELECT name, date_of_birth, breed, microchip_number, insurance_provider,
                   insurance_policy_number, vet_name, vet_phone, allergies,
                   medicine_notes, breakfast_window_start, breakfast_window_end,
                   walk_window_start, walk_window_end, dinner_window_start,
                   dinner_window_end
            FROM dog_profiles
            WHERE family_id = ? AND deleted_at IS NULL
            LIMIT 1
            """,
            (family_id,),
        )
        records["dog_vaccinations"] = await _query_records(
            db,
            """
            SELECT id, vaccine_name, given_on, next_due_on, notes
            FROM dog_vaccinations
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY given_on DESC
            LIMIT 50
            """,
            (family_id,),
        )
        records["dog_weights"] = await _query_records(
            db,
            """
            SELECT id, measured_on, weight_kg, notes
            FROM dog_weights
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY measured_on DESC
            LIMIT 50
            """,
            (family_id,),
        )

    if "learning" in categories:
        records["homework_reading"] = await _query_records(
            db,
            """
            SELECT hr.child_id, c.name AS child_name, hr.book_title,
                   hr.minutes, hr.date, hr.notes
            FROM homework_reading hr
            LEFT JOIN children c ON c.id = hr.child_id
            WHERE hr.family_id = ? AND hr.deleted_at IS NULL AND hr.date >= ?
            ORDER BY hr.date DESC
            LIMIT 100
            """,
            (family_id, start),
        )
        records["homework_spellings"] = await _query_records(
            db,
            """
            SELECT hs.child_id, c.name AS child_name, hs.word_list, hs.test_date,
                   hs.score, hs.practice_count
            FROM homework_spellings hs
            LEFT JOIN children c ON c.id = hs.child_id
            WHERE hs.family_id = ? AND hs.deleted_at IS NULL AND hs.test_date >= ?
            ORDER BY hs.test_date
            LIMIT 100
            """,
            (family_id, start),
        )
        records["star_balances"] = await _query_records(
            db,
            """
            SELECT sb.child_id, c.name AS child_name, sb.balance_pence
            FROM star_chart_balances sb
            LEFT JOIN children c ON c.id = sb.child_id
            WHERE sb.family_id = ? AND sb.deleted_at IS NULL
            ORDER BY c.name
            LIMIT 50
            """,
            (family_id,),
        )
        records["star_charts"] = await _query_records(
            db,
            """
            SELECT sc.id, sc.child_id, c.name AS child_name, sc.title, sc.grid_rows,
                   sc.grid_columns, sc.completed_at,
                   (SELECT COUNT(*) FROM star_chart_stars s
                    WHERE s.chart_id = sc.id AND s.deleted_at IS NULL) AS awarded_stars
            FROM star_charts sc
            LEFT JOIN children c ON c.id = sc.child_id
            WHERE sc.family_id = ? AND sc.deleted_at IS NULL
            ORDER BY sc.created_at DESC
            LIMIT 50
            """,
            (family_id,),
        )

    if "illness" in categories:
        records["active_or_recent_illnesses"] = await _query_records(
            db,
            """
            SELECT i.child_id, c.name AS child_name, i.started_at, i.ended_at, i.notes
            FROM illnesses i
            LEFT JOIN children c ON c.id = i.child_id
            WHERE i.family_id = ? AND i.deleted_at IS NULL
              AND (i.ended_at IS NULL OR i.started_at >= ?)
            ORDER BY i.started_at DESC
            LIMIT 50
            """,
            (family_id, start),
        )
        records["recent_temperatures"] = await _query_records(
            db,
            """
            SELECT tr.child_id, c.name AS child_name, tr.illness_id,
                   tr.value_celsius, tr.recorded_at, tr.notes
            FROM temperature_readings tr
            LEFT JOIN children c ON c.id = tr.child_id
            WHERE tr.family_id = ? AND tr.deleted_at IS NULL AND tr.recorded_at >= ?
            ORDER BY tr.recorded_at DESC
            LIMIT 100
            """,
            (family_id, start),
        )

    if "growth" in categories:
        records["recent_growth"] = await _query_records(
            db,
            """
            SELECT g.child_id, c.name AS child_name, g.date, g.height_cm, g.weight_kg
            FROM growth_records g
            LEFT JOIN children c ON c.id = g.child_id
            WHERE g.family_id = ? AND g.deleted_at IS NULL
            ORDER BY g.date DESC
            LIMIT 30
            """,
            (family_id,),
        )

    if "health" in categories:
        records["recent_health"] = await _query_records(
            db,
            """
            SELECT source, data_type, value, unit, recorded_at
            FROM health_data
            WHERE family_id = ? AND deleted_at IS NULL AND recorded_at >= ?
            ORDER BY recorded_at DESC
            LIMIT 100
            """,
            (family_id, start),
        )

    if "children_records" in categories:
        records["children_profiles"] = await _query_records(
            db,
            """
            SELECT id, name, date_of_birth, notes
            FROM children
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY date_of_birth
            LIMIT 20
            """,
            (family_id,),
        )
        records["child_milestones"] = await _query_records(
            db,
            """
            SELECT cm.child_id, c.name AS child_name, cm.milestone_key,
                   cm.achieved_on, cm.note
            FROM child_milestones cm
            LEFT JOIN children c ON c.id = cm.child_id
            WHERE cm.family_id = ? AND cm.deleted_at IS NULL
            ORDER BY cm.achieved_on DESC
            LIMIT 100
            """,
            (family_id,),
        )
        records["child_vaccinations"] = await _query_records(
            db,
            """
            SELECT cv.child_id, c.name AS child_name, cv.vaccine_key,
                   cv.vaccine_name, cv.given_on
            FROM child_vaccinations cv
            LEFT JOIN children c ON c.id = cv.child_id
            WHERE cv.family_id = ? AND cv.deleted_at IS NULL
            ORDER BY cv.given_on DESC
            LIMIT 100
            """,
            (family_id,),
        )
        records["recent_child_media"] = await _query_records(
            db,
            """
            SELECT cp.id, cp.child_id, c.name AS child_name, cp.caption,
                   cp.taken_on, cp.location, cp.story, cp.favourite
            FROM child_photos cp
            LEFT JOIN children c ON c.id = cp.child_id
            WHERE cp.family_id = ? AND cp.deleted_at IS NULL
            ORDER BY cp.taken_on DESC
            LIMIT 50
            """,
            (family_id,),
        )
        records["recent_artworks"] = await _query_records(
            db,
            """
            SELECT a.id, a.child_id, c.name AS child_name, a.title, a.notes,
                   a.medium, a.story, a.child_quote, a.school_year,
                   a.approx_date, a.favourite
            FROM artworks a
            LEFT JOIN children c ON c.id = a.child_id
            WHERE a.family_id = ? AND a.deleted_at IS NULL
            ORDER BY a.approx_date DESC
            LIMIT 50
            """,
            (family_id,),
        )

    if "renewals" in categories:
        records["renewals"] = await _query_records(
            db,
            """
            SELECT id, title, category, due_date, recurrence_months, cost_pence,
                   reminder_days_before, provider, reference, responsible_user_id,
                   reminders_enabled, task_completed_at, notes
            FROM renewals
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY due_date
            LIMIT 100
            """,
            (family_id,),
        )
        records["renewal_checklist"] = await _query_records(
            db,
            """
            SELECT rci.renewal_id, r.title AS renewal_title, rci.title,
                   rci.position, rci.checked_at, rci.checked_by
            FROM renewal_checklist_items rci
            JOIN renewals r ON r.id = rci.renewal_id AND r.deleted_at IS NULL
            WHERE rci.family_id = ? AND rci.deleted_at IS NULL
            ORDER BY r.due_date, rci.position
            LIMIT 150
            """,
            (family_id,),
        )

    if "library" in categories:
        # Catalogue credentials and even their last four characters remain
        # outside the model boundary. Only useful family loan facts enter.
        records["library_loans"] = await _query_records(
            db,
            """
            SELECT loan.id, account.label AS borrowed_by, loan.title, loan.author,
                   loan.material_format, loan.due_date, loan.provider_status,
                   loan.renewable, loan.renewal_count
            FROM library_loans loan
            JOIN library_accounts account
              ON account.id = loan.account_id AND account.deleted_at IS NULL
            WHERE loan.family_id = ? AND loan.deleted_at IS NULL
            ORDER BY loan.due_date, loan.title
            LIMIT 100
            """,
            (family_id,),
        )

    if "caregiver" in categories:
        # Wi-Fi passwords and booking/session hashes are credentials and remain
        # outside every model boundary even though the rest of the handover is
        # useful family context.
        records["caregiver_handover"] = await _query_records(
            db,
            """
            SELECT id, address, wifi_name, emergency_instructions,
                   house_instructions, dog_instructions
            FROM caregiver_handovers
            WHERE family_id = ? AND deleted_at IS NULL
            LIMIT 1
            """,
            (family_id,),
        )
        records["caregiver_child_profiles"] = await _query_records(
            db,
            """
            SELECT ccp.child_id, c.name AS child_name, ccp.care_notes,
                   ccp.allergies, ccp.food, ccp.comfort, ccp.toileting, ccp.bedtime
            FROM caregiver_child_profiles ccp
            LEFT JOIN children c ON c.id = ccp.child_id
            WHERE ccp.family_id = ? AND ccp.deleted_at IS NULL
            ORDER BY c.name
            LIMIT 20
            """,
            (family_id,),
        )
        records["caregiver_contacts"] = await _query_records(
            db,
            """
            SELECT name, phone, relationship, priority
            FROM caregiver_contacts
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY priority, name
            LIMIT 30
            """,
            (family_id,),
        )
        records["caregiver_bookings"] = await _query_records(
            db,
            """
            SELECT label, starts_at, expires_at, child_ids, revoked_at
            FROM caregiver_bookings
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY starts_at DESC
            LIMIT 30
            """,
            (family_id,),
        )

    records["active_family_insights"] = await _query_records(
        db,
        """
        SELECT id, kind, message, detail, target_date, source_document_id
        FROM family_insights
        WHERE family_id = ? AND status = 'active' AND deleted_at IS NULL
        ORDER BY target_date, created_at DESC
        LIMIT 50
        """,
        (family_id,),
    )
    return records


async def build_assistant_context(
    db,
    *,
    family_id: str,
    message: str,
    history_text: str,
    reference: datetime,
    timezone_name: str,
    user_id: str | None = None,
    include_owner_fitness: bool = True,
) -> tuple[dict, list[dict[str, str]]]:
    """Build bounded, family-scoped context without exposing credentials."""
    people = await load_family_people(db, family_id)
    focus_categories = _requested_context_categories(message, history_text)
    context_categories = set(_CONTEXT_CATEGORY_WORDS)
    start = (reference.date() - timedelta(days=14)).isoformat()
    end = (reference.date() + timedelta(days=550)).isoformat()

    event_cursor = await db.execute(
        """
        SELECT ce.id, ce.title, ce.description, ce.start_time, ce.end_time,
               ce.all_day, ce.recurrence_rule,
               ce.location, ce.family_member_ids, ce.assigned_to
        FROM calendar_events ce
        WHERE ce.family_id = ? AND ce.deleted_at IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM calendar_events replacement
              WHERE replacement.overridden_event_id = ce.id
                AND replacement.family_id = ce.family_id
                AND replacement.deleted_at IS NULL
          )
          AND (ce.recurrence_rule IS NOT NULL OR COALESCE(ce.end_time, ce.start_time) >= ?)
          AND ce.start_time <= ?
        ORDER BY ce.start_time
        LIMIT 300
        """,
        (family_id, start, end),
    )
    event_rows = [dict(row) for row in await event_cursor.fetchall()]
    excluded_occurrences = await exception_keys_for_series(
        db,
        family_id=family_id,
        series_ids=[row["id"] for row in event_rows if row["recurrence_rule"]],
    )
    events = []
    for item in event_rows:
        item["title"] = item["title"][:300]
        item["description"] = item["description"][:300] if item["description"] else None
        item["location"] = item["location"][:200] if item["location"] else None
        if item["recurrence_rule"]:
            item["excluded_occurrence_starts"] = sorted(
                excluded_occurrences.get(item["id"], set())
            )
        events.append(item)

    task_cursor = await db.execute(
        """
        SELECT id, title, description, assigned_to, due_date, recurrence_rule, priority
        FROM tasks
        WHERE family_id = ? AND deleted_at IS NULL AND completed_at IS NULL
        ORDER BY CASE WHEN due_date IS NULL THEN 1 ELSE 0 END, due_date, created_at DESC
        LIMIT 100
        """,
        (family_id,),
    )
    tasks = []
    for row in await task_cursor.fetchall():
        item = dict(row)
        item["title"] = item["title"][:300]
        item["description"] = item["description"][:300] if item["description"] else None
        tasks.append(item)

    term_cursor = await db.execute(
        """
        SELECT person_id, label, start_date, end_date
        FROM term_dates
        WHERE family_id = ? AND deleted_at IS NULL AND end_date >= ? AND start_date <= ?
        ORDER BY start_date
        LIMIT 300
        """,
        (family_id, start, end),
    )
    term_rows = [dict(row) for row in await term_cursor.fetchall()]

    holiday_cursor = await db.execute(
        """
        SELECT person_id, date, label
        FROM holiday_dates
        WHERE family_id = ? AND deleted_at IS NULL AND date >= ? AND date <= ?
        ORDER BY date
        LIMIT 500
        """,
        (family_id, start, end),
    )
    holiday_rows = [dict(row) for row in await holiday_cursor.fetchall()]

    family_records = await _family_record_snapshot(
        db,
        family_id=family_id,
        message=message,
        history_text=history_text,
        start=start,
        end=end,
    )
    if user_id and include_owner_fitness:
        # Bismarck may read the authenticated adult's private Fitness facts, but
        # never another adult's. The projection is deliberately smaller than the
        # dedicated Coach context while retaining exact detail for the latest run.
        from app.services.fitness.coach import build_owner_read_snapshot

        family_records["owner_fitness"] = await build_owner_read_snapshot(
            db,
            user={"id": user_id, "family_id": family_id},
            today=reference.date(),
        )
    if user_id:
        from app.services.assistant_finance import build_assistant_finance_snapshot

        family_records["visible_finance"] = await build_assistant_finance_snapshot(
            db,
            user={"id": user_id, "family_id": family_id},
            today=reference.date(),
        )
    quick = await facility_quick_fact(
        db,
        family_id=family_id,
        user_id=user_id or "",
        reference_date=reference.date(),
    )
    if quick.source_title:
        context_categories.add("facilities")
        facility_start = reference.date() - timedelta(days=1)
        facility_end = reference.date() + timedelta(days=180)
        facility_rows = await current_day_rows(
            db,
            family_id=family_id,
            start=facility_start,
            end=facility_end,
        )
        facility_days = [
            day_summary(
                date.fromisoformat(day_value),
                row,
                user_id=user_id or "",
            )
            for day_value, row in sorted(facility_rows.items())
        ]
        family_records["school_facilities"] = {
            "source_title": quick.source_title,
            "source_document_id": quick.source_document_id,
            "data_from": quick.current_from.isoformat() if quick.current_from else None,
            "data_through": quick.current_to.isoformat() if quick.current_to else None,
            "update_due": quick.update_due,
            "days": [day.model_dump(mode="json") for day in facility_days],
        }

    # Home Assistant is another read-only source. Loading it for every explicit
    # message removes the final wording gate; credentials are resolved only by
    # HausKlar and never enter this context.
    home_context = {"requested": True}

    context = {
        "now": reference.isoformat(),
        "timezone": timezone_name,
        "context_categories": sorted(context_categories),
        "focus_categories": sorted(focus_categories),
        "people": people,
        "calendar_events": events,
        "open_tasks": tasks,
        "term_dates": term_rows,
        "holiday_dates": holiday_rows,
        "shared_time_off": _shared_time_off_periods(
            reference,
            people,
            term_rows,
            holiday_rows,
        ),
        "family_records": family_records,
        "home_assistant": home_context,
    }
    context = redact_assistant_context(context)
    _assert_assistant_context_is_redacted(context)
    return context, people


def _normalise_temporal(value: str, reference: datetime) -> str | None:
    try:
        if len(value) == 10:
            return date.fromisoformat(value).isoformat()
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=reference.tzinfo or timezone.utc)
        return parsed.isoformat()
    except ValueError:
        return None


def _normalise_recurrence(value: str | None) -> str | None:
    if not value:
        return None
    value = value.strip().upper().removeprefix("RRULE:")
    if len(value) > 100:
        return None
    parts: dict[str, str] = {}
    for segment in value.split(";"):
        if "=" not in segment:
            return None
        key, part_value = segment.split("=", 1)
        if key in parts or key not in _ALLOWED_RRULE_KEYS or not part_value:
            return None
        parts[key] = part_value
    if parts.get("FREQ") not in _ALLOWED_FREQUENCIES:
        return None
    if "BYDAY" in parts and any(day not in _WEEKDAYS for day in parts["BYDAY"].split(",")):
        return None
    if "BYMONTHDAY" in parts:
        month_days = parts["BYMONTHDAY"].split(",")
        if any(
            not re.fullmatch(r"-?\d{1,2}", item)
            or int(item) == 0
            or not -31 <= int(item) <= 31
            for item in month_days
        ):
            return None
    if "INTERVAL" in parts and (not parts["INTERVAL"].isdigit() or not 1 <= int(parts["INTERVAL"]) <= 52):
        return None
    if "COUNT" in parts and (not parts["COUNT"].isdigit() or not 1 <= int(parts["COUNT"]) <= 500):
        return None
    if "UNTIL" in parts and not re.fullmatch(r"\d{8}(?:T\d{6}Z)?", parts["UNTIL"]):
        return None
    return value


def _display_start(value: str, timezone_name: str, language: str = "en") -> str:
    german_weekdays = {
        0: "Montag",
        1: "Dienstag",
        2: "Mittwoch",
        3: "Donnerstag",
        4: "Freitag",
        5: "Samstag",
        6: "Sonntag",
    }
    german_months = {
        1: "Januar",
        2: "Februar",
        3: "März",
        4: "April",
        5: "Mai",
        6: "Juni",
        7: "Juli",
        8: "August",
        9: "September",
        10: "Oktober",
        11: "November",
        12: "Dezember",
    }
    if len(value) == 10:
        parsed_date = date.fromisoformat(value)
        if language == "de":
            return (
                f"{german_weekdays[parsed_date.weekday()]}, {parsed_date.day}. "
                f"{german_months[parsed_date.month]} {parsed_date.year}"
            )
        return f"{parsed_date.strftime('%A')} {parsed_date.day} {parsed_date.strftime('%B %Y')}"
    parsed = datetime.fromisoformat(value)
    try:
        zone = ZoneInfo(timezone_name)
        if parsed.tzinfo:
            parsed = parsed.astimezone(zone)
    except ZoneInfoNotFoundError:
        pass
    if language == "de":
        time_value = f"{parsed.hour:02d}:{parsed.minute:02d}" if parsed.minute else f"{parsed.hour}"
        return (
            f"{german_weekdays[parsed.weekday()]}, {parsed.day}. "
            f"{german_months[parsed.month]} {parsed.year} um {time_value} Uhr"
        )
    minute = f":{parsed.minute:02d}" if parsed.minute else ""
    marker = "am" if parsed.hour < 12 else "pm"
    hour = parsed.hour % 12 or 12
    return (
        f"{parsed.strftime('%A')} {parsed.day} {parsed.strftime('%B %Y')} "
        f"at {hour}{minute}{marker}"
    )


def _calendar_summary(
    payload: dict,
    people: list[dict[str, str]],
    timezone_name: str,
    language: str = "en",
) -> str:
    names = {person["id"]: person["name"] for person in people}
    if language == "de":
        summary = (
            f"„{payload['title']}“ am "
            f"{_display_start(payload['start_time'], timezone_name, language)} hinzufügen"
        )
        recurrence = payload.get("recurrence_rule")
        if recurrence:
            parts = dict(segment.split("=", 1) for segment in recurrence.split(";"))
            frequencies = {
                "DAILY": "täglich",
                "WEEKLY": "wöchentlich",
                "MONTHLY": "monatlich",
                "YEARLY": "jährlich",
            }
            summary += f", {frequencies.get(parts.get('FREQ'), 'wiederkehrend')}"
        if payload.get("assigned_to") in names:
            summary += f", für {names[payload['assigned_to']]}"
        if payload.get("term_time_only"):
            summary += ", nur während der hinterlegten Schulzeit"
        return summary
    summary = f"Add '{payload['title']}' on {_display_start(payload['start_time'], timezone_name)}"
    recurrence = payload.get("recurrence_rule")
    if recurrence:
        parts = dict(segment.split("=", 1) for segment in recurrence.split(";"))
        if parts.get("FREQ") == "WEEKLY":
            days = ", ".join(_WEEKDAYS[day] for day in parts.get("BYDAY", "").split(",") if day)
            summary += f", repeating weekly{f' on {days}' if days else ''}"
        else:
            summary += f", repeating {parts['FREQ'].lower()}"
    if payload.get("assigned_to") in names:
        summary += f" for {names[payload['assigned_to']]}"
    if payload.get("term_time_only"):
        summary += ", during configured term time"
    return summary


def _calendar_payload(
    action: HermesCalendarAction,
    *,
    people: list[dict[str, str]],
    reference: datetime,
) -> dict | None:
    start_time = _normalise_temporal(action.start_time, reference)
    if not start_time:
        return None
    end_time = _normalise_temporal(action.end_time, reference) if action.end_time else None
    if action.end_time and not end_time:
        return None
    if end_time:
        start_is_date = len(start_time) == 10
        end_is_date = len(end_time) == 10
        if start_is_date != end_is_date:
            return None
        if start_is_date:
            if date.fromisoformat(end_time) < date.fromisoformat(start_time):
                return None
        else:
            start_value = datetime.fromisoformat(start_time)
            end_value = datetime.fromisoformat(end_time)
            if end_value <= start_value:
                return None
    recurrence = _normalise_recurrence(action.recurrence_rule)
    if action.recurrence_rule and not recurrence:
        return None
    valid_people = {person["id"] for person in people}
    if action.assigned_to and action.assigned_to not in valid_people:
        return None
    title = action.title.strip()
    if not title:
        return None
    return {
        "title": title[:300],
        "description": action.description.strip()[:10_000] if action.description else None,
        "start_time": start_time,
        "end_time": end_time,
        "all_day": action.all_day or len(start_time) == 10,
        "recurrence_rule": recurrence,
        "assigned_to": action.assigned_to,
    }


def _grounding_text(request_text: str) -> str:
    value = request_text.lower()
    for typo, correction in _GROUNDING_TYPO_CORRECTIONS.items():
        value = re.sub(rf"\b{typo}\b", correction, value)
    return value


def _evidence_is_present(value: str | None, request_text: str) -> bool:
    if not value:
        return False

    def normalise(text: str) -> str:
        return " ".join(text.casefold().split())

    return normalise(value) in normalise(request_text)


def _calendar_action_is_grounded(action: HermesCalendarAction, request_text: str) -> bool:
    evidence = action.evidence
    if not evidence or not _evidence_is_present(evidence.subject, request_text):
        return False
    if not _evidence_is_present(evidence.date_or_day, request_text):
        return False
    if not action.all_day and not _evidence_is_present(evidence.time, request_text):
        return False
    if action.recurrence_rule and not _evidence_is_present(evidence.recurrence, request_text):
        return False
    if action.assigned_to and not _evidence_is_present(evidence.person, request_text):
        return False
    if action.term_time_only and not _evidence_is_present(evidence.term_time, request_text):
        return False
    return True


def _task_action_is_grounded(action: HermesCreateTaskAction, request_text: str) -> bool:
    evidence = action.evidence
    if not evidence or not _evidence_is_present(evidence.subject, request_text):
        return False
    if action.due_date and not _evidence_is_present(evidence.date_or_day, request_text):
        return False
    if action.recurrence_rule and not _evidence_is_present(evidence.recurrence, request_text):
        return False
    if action.assigned_to and not _evidence_is_present(evidence.person, request_text):
        return False
    return True


def _lights_action_is_grounded(
    action: HermesLightsAction,
    request_message: str,
    request_text: str,
) -> bool:
    """Require a user-authored light command whose requested state matches."""
    current = _grounding_text(request_message)
    if "?" in current or _QUESTION_WORDS.search(current):
        return False
    if not _LIGHT_STATE_COMMANDS[action.state].search(current):
        return False
    return bool(_LIGHT_OBJECT_WORDS.search(_grounding_text(request_text)))


def _normalise_number_words(value: str) -> str:
    words = {
        "one": "1",
        "two": "2",
        "three": "3",
        "four": "4",
        "five": "5",
        "six": "6",
        "seven": "7",
        "eight": "8",
        "nine": "9",
        "ten": "10",
        "ein": "1",
        "eine": "1",
        "einen": "1",
        "zwei": "2",
        "drei": "3",
        "vier": "4",
        "fünf": "5",
        "sechs": "6",
    }
    normalised = _grounding_text(value)
    for word, number in words.items():
        normalised = re.sub(rf"\b{word}\b", number, normalised)
    return " ".join(re.findall(r"[\w]+", normalised, flags=re.UNICODE))


def _shopping_action_is_grounded(
    action: HermesShoppingAction,
    request_message: str,
) -> bool:
    """Require the item and any quantity to come from the current user text."""
    current = _normalise_number_words(request_message)
    name = _normalise_number_words(action.name)
    name_words = [word for word in name.split() if len(word) > 1]
    if not name_words or not all(re.search(rf"\b{re.escape(word)}s?\b", current) for word in name_words):
        return False

    raw_message = request_message.strip()
    is_question = "?" in raw_message or bool(_QUESTION_WORDS.search(raw_message))
    if is_question:
        return False
    terse_item = len(current.split()) <= 4 and not is_question
    if not _SHOPPING_COMMAND_WORDS.search(raw_message) and not terse_item:
        return False

    if action.quantity:
        quantity = _normalise_number_words(action.quantity)
        if quantity and quantity not in current:
            return False
    return True


def _date_is_mentioned(target: date, request_text: str) -> bool:
    text = _grounding_text(request_text)
    month_names = {
        1: ("jan", "january", "januar"),
        2: ("feb", "february", "februar"),
        3: ("mar", "march", "märz"),
        4: ("apr", "april"),
        5: ("may", "mai"),
        6: ("jun", "june", "juni"),
        7: ("jul", "july", "juli"),
        8: ("aug", "august"),
        9: ("sep", "september"),
        10: ("oct", "october", "okt", "oktober"),
        11: ("nov", "november"),
        12: ("dec", "december", "dez", "dezember"),
    }
    names = "|".join(re.escape(value) for value in month_names[target.month])
    day_month = re.compile(
        rf"\b0?{target.day}(?:st|nd|rd|th|\.)?\s+(?:{names})"
        rf"(?:\s+{target.year})?\b",
        flags=re.IGNORECASE,
    )
    numeric = re.compile(
        rf"\b0?{target.day}[./-]0?{target.month}"
        rf"(?:[./-](?:{target.year}|{target.year % 100:02d}))?\b"
    )
    return target.isoformat() in text or bool(day_month.search(text) or numeric.search(text))


async def _completion_action_is_unambiguous(
    db,
    *,
    task,
    family_id: str,
    request_text: str,
) -> bool:
    cursor = await db.execute(
        """
        SELECT id, due_date
        FROM tasks
        WHERE family_id = ? AND deleted_at IS NULL AND completed_at IS NULL
          AND LOWER(TRIM(title)) = LOWER(TRIM(?))
        """,
        (family_id, task["title"]),
    )
    matches = await cursor.fetchall()
    if len(matches) <= 1:
        return True
    target_date = _iso_date(task["due_date"])
    if not target_date or not _date_is_mentioned(target_date, request_text):
        return False
    same_date = [row for row in matches if _iso_date(row["due_date"]) == target_date]
    return len(same_date) == 1


def _task_payload(
    action: HermesCreateTaskAction,
    *,
    people: list[dict[str, str]],
    reference: datetime,
) -> dict | None:
    due_date = _normalise_temporal(action.due_date, reference) if action.due_date else None
    if action.due_date and not due_date:
        return None
    recurrence = _normalise_recurrence(action.recurrence_rule)
    if action.recurrence_rule and not recurrence:
        return None
    valid_people = {person["id"] for person in people}
    if action.assigned_to and action.assigned_to not in valid_people:
        return None
    title = action.title.strip()
    if not title:
        return None
    return {
        "title": title[:300],
        "description": action.description.strip()[:10_000] if action.description else None,
        "due_date": due_date,
        "recurrence_rule": recurrence,
        "assigned_to": action.assigned_to,
        "category": action.category,
        "priority": action.priority,
    }


def _task_summary(
    payload: dict,
    people: list[dict[str, str]],
    timezone_name: str,
    language: str = "en",
) -> str:
    names = {person["id"]: person["name"] for person in people}
    if language == "de":
        summary = f"Aufgabe „{payload['title']}“ erstellen"
        if payload.get("due_date"):
            summary += f", fällig am {_display_start(payload['due_date'], timezone_name, language)}"
        if payload.get("assigned_to") in names:
            summary += f", für {names[payload['assigned_to']]}"
        if payload.get("recurrence_rule"):
            summary += ", wiederkehrend"
        return summary
    summary = f"Create task '{payload['title']}'"
    if payload.get("due_date"):
        summary += f" due {_display_start(payload['due_date'], timezone_name)}"
    if payload.get("assigned_to") in names:
        summary += f" for {names[payload['assigned_to']]}"
    if payload.get("recurrence_rule"):
        summary += f" ({payload['recurrence_rule'].lower()})"
    return summary


def _shopping_summary(payload: dict, language: str = "en") -> str:
    if language == "de":
        summary = f"„{payload['name']}“ zur Einkaufsliste hinzufügen"
    else:
        summary = f"Add '{payload['name']}' to the shopping list"
    if payload.get("quantity"):
        summary += f" ({payload['quantity']})"
    return summary


def assistant_action_preview(action_type: str, payload: dict) -> dict | None:
    """Return only the typed, client-editable fields for a pending action."""
    if action_type == "calendar_event":
        return {
            "kind": "calendar_event",
            "title": payload["title"],
            "description": payload.get("description"),
            "start_time": payload["start_time"],
            "end_time": payload.get("end_time"),
            "all_day": bool(payload.get("all_day")),
            "recurrence_rule": payload.get("recurrence_rule"),
            "assigned_to": payload.get("assigned_to"),
            "term_time_only": bool(payload.get("term_time_only")),
        }
    if action_type == "create_task":
        return {
            "kind": "create_task",
            "title": payload["title"],
            "description": payload.get("description"),
            "due_date": payload.get("due_date"),
            "recurrence_rule": payload.get("recurrence_rule"),
            "assigned_to": payload.get("assigned_to"),
            "category": payload.get("category", "other"),
            "priority": payload.get("priority", 2),
        }
    if action_type == "shopping_item":
        return {
            "kind": "shopping_item",
            "name": payload["name"],
            "quantity": payload.get("quantity"),
            "category": payload.get("category"),
        }
    return None


def normalise_edited_action_payload(
    action_type: str,
    payload: dict,
    *,
    people: list[dict[str, str]],
) -> dict | None:
    """Rebuild an editable action through the same deterministic validators as creation."""
    timezone_name = payload.get("_timezone", "Europe/London")
    reference = request_reference(None, timezone_name)
    language = "de" if payload.get("_language") == "de" else "en"

    if action_type == "calendar_event":
        action = HermesCalendarAction(
            kind="create_calendar_event",
            title=payload.get("title"),
            description=payload.get("description"),
            start_time=payload.get("start_time"),
            end_time=payload.get("end_time"),
            all_day=bool(payload.get("all_day")),
            recurrence_rule=payload.get("recurrence_rule"),
            assigned_to=payload.get("assigned_to"),
            term_time_only=bool(payload.get("term_time_only")),
        )
        normalised = _calendar_payload(action, people=people, reference=reference)
        if not normalised:
            return None
        if action.term_time_only:
            if not normalised.get("assigned_to") or not normalised.get("recurrence_rule"):
                return None
            normalised["term_time_only"] = True
            normalised["timezone"] = payload.get("timezone", timezone_name)
    elif action_type == "create_task":
        action = HermesCreateTaskAction(
            kind="create_task",
            title=payload.get("title"),
            description=payload.get("description"),
            due_date=payload.get("due_date"),
            recurrence_rule=payload.get("recurrence_rule"),
            assigned_to=payload.get("assigned_to"),
            category=payload.get("category", "other"),
            priority=payload.get("priority", 2),
        )
        normalised = _task_payload(action, people=people, reference=reference)
        if not normalised:
            return None
    elif action_type == "shopping_item":
        name = str(payload.get("name") or "").strip()
        if not name or len(name) > 300:
            return None
        quantity = payload.get("quantity")
        category = payload.get("category")
        if quantity is not None:
            quantity = quantity.strip()
            if len(quantity) > 100:
                return None
        if category is not None:
            category = category.strip()
            if len(category) > 100:
                return None
        normalised = {
            "name": name,
            "quantity": quantity or None,
            "category": category or None,
        }
    else:
        return None

    normalised["_language"] = language
    normalised["_timezone"] = timezone_name
    return normalised


def edited_action_summary(
    action_type: str,
    payload: dict,
    people: list[dict[str, str]],
) -> str:
    language = "de" if payload.get("_language") == "de" else "en"
    timezone_name = payload.get("_timezone", "Europe/London")
    if action_type == "calendar_event":
        return _calendar_summary(payload, people, timezone_name, language)
    if action_type == "create_task":
        return _task_summary(payload, people, timezone_name, language)
    if action_type == "shopping_item":
        return _shopping_summary(payload, language)
    raise ValueError("This assistant action cannot be edited")


async def store_pending_actions(
    db,
    *,
    actions: list[HermesAssistantAction],
    people: list[dict[str, str]],
    reference: datetime,
    timezone_name: str,
    current_user: dict,
    persist: bool = True,
    request_text: str = "",
    request_message: str = "",
    response_language: str = "en",
) -> list[AssistantActionResponse]:
    response_language = "de" if response_language == "de" else "en"
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(minutes=30)
    responses: list[AssistantActionResponse] = []
    for action in actions[:3]:
        if isinstance(action, HermesCalendarAction) and _EXPLICIT_TASK_WORDS.search(
            _grounding_text(request_message)
        ):
            task_action = HermesCreateTaskAction(
                kind="create_task",
                title=action.title,
                description=action.description,
                due_date=action.start_time,
                recurrence_rule=action.recurrence_rule,
                assigned_to=action.assigned_to,
                category="other",
                priority=2,
                evidence=action.evidence,
            )
            if not _task_action_is_grounded(task_action, request_text):
                continue
            payload = _task_payload(task_action, people=people, reference=reference)
            if not payload:
                continue
            action_type = "create_task"
            summary = _task_summary(payload, people, timezone_name, response_language)
        elif isinstance(action, HermesCalendarAction):
            if not _calendar_action_is_grounded(action, request_text):
                continue
            payload = _calendar_payload(action, people=people, reference=reference)
            if not payload:
                continue
            if action.term_time_only:
                if not payload.get("assigned_to"):
                    continue
                payload["term_time_only"] = True
                payload["timezone"] = getattr(reference.tzinfo, "key", timezone_name)
            action_type = "calendar_event"
            summary = _calendar_summary(payload, people, timezone_name, response_language)
        elif isinstance(action, HermesLightsAction):
            if not _lights_action_is_grounded(action, request_message, request_text):
                continue
            payload = {"state": action.state}
            action_type = "home_lights"
            if response_language == "de":
                summary = f"Alle Lichter im Haus {'einschalten' if action.state == 'on' else 'ausschalten'}"
            else:
                summary = f"Turn {action.state} all Home Assistant lights"
        elif isinstance(action, HermesCreateTaskAction):
            if not _task_action_is_grounded(action, request_text):
                continue
            payload = _task_payload(action, people=people, reference=reference)
            if not payload:
                continue
            action_type = "create_task"
            summary = _task_summary(payload, people, timezone_name, response_language)
        elif isinstance(action, HermesCompleteTaskAction):
            cursor = await db.execute(
                """
                SELECT id, title, due_date FROM tasks
                WHERE id = ? AND family_id = ? AND completed_at IS NULL AND deleted_at IS NULL
                """,
                (action.task_id, current_user["family_id"]),
            )
            task = await cursor.fetchone()
            if not task:
                continue
            if not await _completion_action_is_unambiguous(
                db,
                task=task,
                family_id=current_user["family_id"],
                request_text=request_text,
            ):
                continue
            payload = {"task_id": task["id"]}
            action_type = "complete_task"
            if response_language == "de":
                summary = f"Aufgabe „{task['title'][:300]}“ als erledigt markieren"
            else:
                summary = f"Mark task '{task['title'][:300]}' complete"
        elif isinstance(action, HermesShoppingAction):
            if not _shopping_action_is_grounded(action, request_message):
                continue
            name = action.name.strip()
            if not name:
                continue
            payload = {
                "name": name[:300],
                "quantity": action.quantity.strip()[:100] if action.quantity else None,
                "category": action.category.strip()[:100] if action.category else None,
            }
            action_type = "shopping_item"
            summary = _shopping_summary(payload, response_language)
        else:
            continue

        payload["_language"] = response_language
        payload["_timezone"] = timezone_name
        action_id = str(uuid.uuid4())
        if persist:
            await db.execute(
                """
                INSERT INTO assistant_actions
                    (id, action_type, payload, summary, status, expires_at,
                     family_id, created_at, updated_at, created_by, client_id, client_timestamp)
                VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    action_id,
                    action_type,
                    json.dumps(payload, separators=(",", ":")),
                    summary,
                    expires_at.isoformat(),
                    current_user["family_id"],
                    now.isoformat(),
                    now.isoformat(),
                    current_user["id"],
                    "bismarck-assistant",
                    reference.isoformat(),
                ),
            )
        responses.append(
            AssistantActionResponse(
                id=action_id,
                kind=action_type,
                summary=summary,
                status="pending",
                expires_at=expires_at.isoformat(),
                editable=(
                    persist
                    and assistant_action_preview(action_type, payload) is not None
                ),
                preview=assistant_action_preview(action_type, payload),
            )
        )
    if persist:
        await db.commit()
    return responses


async def create_calendar_event_from_action(
    db,
    *,
    payload: dict,
    current_user: dict,
) -> str:
    assigned_to = payload.get("assigned_to")
    if assigned_to:
        cursor = await db.execute(
            """
            SELECT id FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            UNION ALL
            SELECT id FROM children WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                assigned_to,
                current_user["family_id"],
                assigned_to,
                current_user["family_id"],
            ),
        )
        if not await cursor.fetchone():
            raise ValueError("The selected family member no longer exists")

    async def insert_event(
        *,
        start_time: str,
        end_time: str | None,
        recurrence_rule: str | None,
    ) -> str:
        event_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """
            INSERT INTO calendar_events
                (id, title, description, start_time, end_time, all_day,
                 recurrence_rule, family_member_ids, assigned_to, event_type, exertion,
                 family_id, created_at, updated_at, created_by, client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'other', 0, ?, ?, ?, ?, ?, ?)
            """,
            (
                event_id,
                payload["title"],
                payload.get("description"),
                start_time,
                end_time,
                int(payload.get("all_day", False)),
                recurrence_rule,
                json.dumps([assigned_to]) if assigned_to else None,
                assigned_to,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
                "bismarck-assistant",
                now,
            ),
        )
        return event_id

    if not payload.get("term_time_only"):
        return await insert_event(
            start_time=payload["start_time"],
            end_time=payload.get("end_time"),
            recurrence_rule=payload.get("recurrence_rule"),
        )

    cursor = await db.execute(
        """
        SELECT start_date, end_date
        FROM term_dates
        WHERE person_id = ? AND family_id = ? AND deleted_at IS NULL
        ORDER BY start_date
        """,
        (
            assigned_to,
            current_user["family_id"],
        ),
    )
    terms = await cursor.fetchall()
    if not terms:
        raise ValueError("No term dates are configured for this family member")

    cursor = await db.execute(
        """
        SELECT date
        FROM holiday_dates
        WHERE person_id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (assigned_to, current_user["family_id"]),
    )
    holidays = {row["date"] for row in await cursor.fetchall()}

    timezone_name = payload.get("timezone", "Europe/London")
    try:
        local_zone = ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError:
        local_zone = ZoneInfo("Europe/London")
    all_day = bool(payload.get("all_day")) or len(payload["start_time"]) == 10
    if all_day:
        series_start = datetime.combine(
            date.fromisoformat(payload["start_time"]),
            datetime.min.time(),
            tzinfo=local_zone,
        )
        duration = None
    else:
        series_start = datetime.fromisoformat(payload["start_time"].replace("Z", "+00:00"))
        if series_start.tzinfo is None:
            series_start = series_start.replace(tzinfo=local_zone)
        series_start = series_start.astimezone(local_zone)
        if payload.get("end_time"):
            parsed_end = datetime.fromisoformat(payload["end_time"].replace("Z", "+00:00"))
            if parsed_end.tzinfo is None:
                parsed_end = parsed_end.replace(tzinfo=local_zone)
            duration = parsed_end.astimezone(local_zone) - series_start
        else:
            duration = None

    try:
        rule = rrulestr(payload["recurrence_rule"], dtstart=series_start)
    except (TypeError, ValueError) as exc:
        raise ValueError("The recurring calendar schedule is invalid") from exc

    occurrence_starts: dict[str, datetime] = {}
    for term in terms:
        term_start = datetime.combine(
            date.fromisoformat(term["start_date"]),
            datetime.min.time(),
            tzinfo=local_zone,
        )
        term_end = datetime.combine(
            date.fromisoformat(term["end_date"]),
            datetime.max.time(),
            tzinfo=local_zone,
        )
        for occurrence in rule.between(term_start, term_end, inc=True):
            local_occurrence = occurrence.astimezone(local_zone)
            if local_occurrence.date().isoformat() in holidays:
                continue
            occurrence_starts[local_occurrence.isoformat()] = local_occurrence

    starts = sorted(occurrence_starts.values())
    if not starts:
        raise ValueError("No matching dates remain inside the configured term dates")
    if len(starts) > _MAX_TERM_TIME_OCCURRENCES:
        raise ValueError("The term-time schedule covers too many dates to add safely")

    first_id = ""
    for occurrence in starts:
        if all_day:
            occurrence_start = occurrence.date().isoformat()
            occurrence_end = None
        else:
            occurrence_start = occurrence.isoformat()
            occurrence_end = (occurrence + duration).isoformat() if duration else None
        event_id = await insert_event(
            start_time=occurrence_start,
            end_time=occurrence_end,
            recurrence_rule=None,
        )
        first_id = first_id or event_id
    return first_id


async def create_task_from_action(db, *, payload: dict, current_user: dict) -> str:
    assigned_to = payload.get("assigned_to")
    assignee_type = None
    if assigned_to:
        cursor = await db.execute(
            """
            SELECT id, 'user' AS person_type FROM users
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            UNION ALL
            SELECT id, 'child' AS person_type FROM children
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                assigned_to,
                current_user["family_id"],
                assigned_to,
                current_user["family_id"],
            ),
        )
        person = await cursor.fetchone()
        if not person:
            raise ValueError("The selected family member no longer exists")
        assignee_type = person["person_type"]

    task_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO tasks
            (id, title, description, assigned_to, due_date, category,
             recurrence_rule, priority, family_id, created_at, updated_at,
             created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            task_id,
            payload["title"],
            payload.get("description"),
            assigned_to,
            payload.get("due_date"),
            payload.get("category", "other"),
            payload.get("recurrence_rule"),
            payload.get("priority", 2),
            current_user["family_id"],
            now,
            now,
            current_user["id"],
            "bismarck-assistant",
            now,
        ),
    )
    if assigned_to and assignee_type:
        await db.execute(
            """
            INSERT INTO task_assignments
                (id, task_id, assignee_id, assignee_type, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                task_id,
                assigned_to,
                assignee_type,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
            ),
        )
    return task_id


async def complete_task_from_action(db, *, payload: dict, current_user: dict) -> str:
    task_id = payload["task_id"]
    cursor = await db.execute(
        """
        SELECT id FROM tasks
        WHERE id = ? AND family_id = ? AND completed_at IS NULL AND deleted_at IS NULL
        """,
        (task_id, current_user["family_id"]),
    )
    if not await cursor.fetchone():
        raise ValueError("The task is no longer available")
    await save_history(
        db,
        "tasks",
        task_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE tasks SET completed_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, task_id, current_user["family_id"]),
    )
    await db.execute(
        """
        UPDATE task_assignments
        SET completed_at = ?, completed_by = ?, updated_at = ?
        WHERE task_id = ? AND deleted_at IS NULL AND completed_at IS NULL
        """,
        (now, current_user["id"], now, task_id),
    )
    return task_id


async def create_shopping_item_from_action(db, *, payload: dict, current_user: dict) -> str:
    item_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO shopping_items
            (id, name, quantity, category, checked, family_id,
             created_at, updated_at, created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
        """,
        (
            item_id,
            payload["name"],
            payload.get("quantity"),
            payload.get("category"),
            current_user["family_id"],
            now,
            now,
            current_user["id"],
            "bismarck-assistant",
            now,
        ),
    )
    return item_id


async def call_all_lights(*, family_id: str, state: str) -> None:
    await turn_all_lights_for_family(family_id, state)


def request_reference(client_now: str | None, timezone_name: str) -> datetime:
    return reference_in_timezone(client_now, timezone_name)

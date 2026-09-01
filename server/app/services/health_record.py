"""Children's health-record business logic — milestones, vaccinations, growth
centiles and a GP-ready illness summary.

This is record-keeping and reminders only, never clinical advice. Reference data
(milestones, the routine immunisation schedule) lives here as constants.
"""

import calendar
from datetime import date, datetime, timedelta, timezone

from app.services import who_growth

_DAYS_PER_MONTH = 30.4375

MILESTONE_DISCLAIMER = (
    "Developmental milestones vary widely between children. This is a record, "
    "not a medical assessment."
)
VACCINATION_DISCLAIMER = (
    "Reminder dates are computed from the NHS routine childhood immunisation "
    "schedule (reviewed July 2026), not medical advice. The exact vaccines and "
    "whether the 18-month visit applies depend on your child's date of birth — "
    "always check your child's Red Book and confirm with your GP."
)
GROWTH_DISCLAIMER = "Centiles are indicative, not a medical assessment."
SUMMARY_DISCLAIMER = (
    "A record for your reference and to share with a clinician, not medical advice."
)

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

# UK red-book style developmental milestones. Each has a rough typical age band
# (min/max months) and a category. Order here is not significant — responses
# are sorted by typical age.
MILESTONES: list[dict] = [
    {"key": "smiles", "title": "Smiles responsively", "category": "social", "min": 1, "max": 3},
    {"key": "lifts_head", "title": "Lifts head when on tummy", "category": "movement", "min": 1, "max": 4},
    {"key": "coos", "title": "Coos and makes sounds", "category": "communication", "min": 2, "max": 4},
    {"key": "reaches_for_objects", "title": "Reaches for objects", "category": "movement", "min": 3, "max": 5},
    {"key": "rolls_over", "title": "Rolls over", "category": "movement", "min": 4, "max": 6},
    {"key": "babbles", "title": "Babbles", "category": "communication", "min": 5, "max": 8},
    {"key": "sits_unsupported", "title": "Sits unsupported", "category": "movement", "min": 6, "max": 9},
    {"key": "stranger_awareness", "title": "Shows awareness of strangers", "category": "social", "min": 6, "max": 10},
    {"key": "plays_peekaboo", "title": "Enjoys peekaboo", "category": "social", "min": 6, "max": 12},
    {"key": "crawls", "title": "Crawls", "category": "movement", "min": 6, "max": 11},
    {"key": "pulls_to_stand", "title": "Pulls to stand", "category": "movement", "min": 8, "max": 12},
    {"key": "waves_bye", "title": "Waves bye-bye", "category": "social", "min": 9, "max": 14},
    {"key": "first_words", "title": "Says first words", "category": "communication", "min": 10, "max": 15},
    {"key": "walks_alone", "title": "Walks alone", "category": "movement", "min": 12, "max": 18},
    {"key": "drinks_from_cup", "title": "Drinks from a cup", "category": "self-care", "min": 12, "max": 18},
    {"key": "follows_instructions", "title": "Follows a simple instruction", "category": "communication", "min": 12, "max": 18},
    {"key": "points_to_objects", "title": "Points to objects to show interest", "category": "communication", "min": 12, "max": 18},
    {"key": "uses_spoon", "title": "Uses a spoon", "category": "self-care", "min": 15, "max": 24},
    {"key": "runs", "title": "Runs", "category": "movement", "min": 18, "max": 30},
    {"key": "kicks_ball", "title": "Kicks a ball", "category": "movement", "min": 18, "max": 30},
    {"key": "two_word_phrases", "title": "Joins two words together", "category": "communication", "min": 18, "max": 30},
    {"key": "walks_up_stairs", "title": "Walks up stairs", "category": "movement", "min": 24, "max": 36},
    {"key": "removes_clothing", "title": "Takes off own clothing", "category": "self-care", "min": 24, "max": 36},
    {"key": "names_pictures", "title": "Names pictures in a book", "category": "communication", "min": 24, "max": 36},
    {"key": "jumps", "title": "Jumps with both feet", "category": "movement", "min": 30, "max": 42},
    {"key": "toilet_trained_day", "title": "Dry during the day", "category": "self-care", "min": 30, "max": 42},
    {"key": "pedals_tricycle", "title": "Pedals a tricycle", "category": "movement", "min": 36, "max": 48},
]

# The England routine childhood immunisation schedule, 8 weeks to 3y4m. The
# transition rules are from UKHSA's 30 April and 31 October 2025 programme
# letters. Keep display and push reminders on the same cohort-filtered helper.
# https://www.gov.uk/government/publications/changes-to-the-routine-childhood-schedule-letter
_JULY_2024_COHORT = date(2024, 7, 1)
_JANUARY_2025_COHORT = date(2025, 1, 1)
_EARLY_VISIT_CHANGE = date(2025, 7, 1)

VACCINE_SCHEDULE: list[dict] = [
    {"key": "six_in_one_1", "name": "6-in-1 (1st dose)", "weeks": 8, "label": "8 weeks"},
    {"key": "menb_1", "name": "MenB (1st dose)", "weeks": 8, "label": "8 weeks"},
    {"key": "rotavirus_1", "name": "Rotavirus (1st dose)", "weeks": 8, "label": "8 weeks"},
    {"key": "six_in_one_2", "name": "6-in-1 (2nd dose)", "weeks": 12, "label": "12 weeks"},
    {"key": "menb_2", "name": "MenB (2nd dose)", "weeks": 12, "label": "12 weeks"},
    {"key": "rotavirus_2", "name": "Rotavirus (2nd dose)", "weeks": 12, "label": "12 weeks"},
    {"key": "six_in_one_3", "name": "6-in-1 (3rd dose)", "weeks": 16, "label": "16 weeks"},
    {"key": "pcv_1", "name": "Pneumococcal PCV (1st dose)", "weeks": 16, "label": "16 weeks"},
    {"key": "mmrv_1", "name": "MMR/MMRV (1st dose)", "months": 12, "label": "1 year"},
    {"key": "pcv_2", "name": "Pneumococcal PCV (2nd dose)", "months": 12, "label": "1 year"},
    {"key": "menb_3", "name": "MenB (3rd dose)", "months": 12, "label": "1 year"},
    {
        "key": "hib_menc",
        "name": "Hib/MenC",
        "months": 12,
        "label": "1 year",
        "max_dob_exclusive": _JULY_2024_COHORT,
    },
    {
        "key": "six_in_one_4",
        "name": "6-in-1 (4th dose)",
        "months": 18,
        "label": "18 months",
        "min_dob": _JULY_2024_COHORT,
    },
    {
        "key": "mmrv_18m",
        "name": "MMR/MMRV (18-month dose)",
        "months": 18,
        "label": "18 months",
        "min_dob": _JULY_2024_COHORT,
    },
    {"key": "four_in_one_booster", "name": "4-in-1 pre-school booster", "months": 40, "label": "3 years 4 months"},
    {
        "key": "mmrv_2",
        "name": "MMR/MMRV (3 years 4 months)",
        "months": 40,
        "label": "3 years 4 months",
        "max_dob_exclusive": _JANUARY_2025_COHORT,
    },
]

_MILESTONE_BY_KEY = {m["key"]: m for m in MILESTONES}
_VACCINE_BY_KEY = {v["key"]: v for v in VACCINE_SCHEDULE}


# ---------------------------------------------------------------------------
# Date helpers
# ---------------------------------------------------------------------------


def _parse_date(value: str | None) -> date | None:
    """Parse an ISO date (accepting a leading date within a full timestamp)."""
    if not value:
        return None
    try:
        return date.fromisoformat(value[:10])
    except (ValueError, TypeError):
        return None


def _add_months(start: date, months: int) -> date:
    """Add whole calendar months, clamping to the last valid day."""
    index = start.month - 1 + months
    year = start.year + index // 12
    month = index % 12 + 1
    day = min(start.day, calendar.monthrange(year, month)[1])
    return date(year, month, day)


def _due_date(dob: date, entry: dict) -> date:
    if "weeks" in entry:
        return dob + timedelta(weeks=entry["weeks"])
    return _add_months(dob, entry["months"])


def vaccination_schedule_for_dob(dob: date | None) -> list[dict]:
    """Return the default schedule that applies to one child's birth cohort.

    The MenB/PCV switch was based on whether the 12-week appointment occurred
    before 1 July 2025, rather than a simple DOB cohort. A late appointment can
    therefore differ; the UI disclaimer tells families to confirm the Red Book.
    """
    if dob is None:
        return []

    uses_new_early_visits = dob + timedelta(weeks=12) >= _EARLY_VISIT_CHANGE
    applicable: list[dict] = []
    for source in VACCINE_SCHEDULE:
        minimum = source.get("min_dob")
        maximum = source.get("max_dob_exclusive")
        if minimum is not None and dob < minimum:
            continue
        if maximum is not None and dob >= maximum:
            continue

        entry = dict(source)
        if entry["key"] == "menb_2":
            entry["weeks"] = 12 if uses_new_early_visits else 16
            entry["label"] = f"{entry['weeks']} weeks"
        elif entry["key"] == "pcv_1":
            entry["weeks"] = 16 if uses_new_early_visits else 12
            entry["label"] = f"{entry['weeks']} weeks"
        applicable.append(entry)

    return sorted(applicable, key=lambda entry: _due_date(dob, entry))


def vaccine_applies_to_dob(key: str, dob: date | None) -> bool:
    return any(entry["key"] == key for entry in vaccination_schedule_for_dob(dob))


def age_in_months(dob: date | None, on_day: date | None = None) -> float | None:
    """Approximate age in months (WHO uses ~30.4375 days per month)."""
    if dob is None:
        return None
    reference = on_day or datetime.now(timezone.utc).date()
    days = (reference - dob).days
    if days < 0:
        return None
    return round(days / _DAYS_PER_MONTH, 1)


# ---------------------------------------------------------------------------
# Child lookup — tolerant of soft-deleted children so records stay accessible.
# ---------------------------------------------------------------------------


async def get_family_child(db, family_id: str, child_id: str) -> dict | None:
    """Return the child's record within the family, or None. Includes
    soft-deleted children so their historical health record remains readable."""
    cursor = await db.execute(
        "SELECT id, name, date_of_birth, sex FROM children WHERE id = ? AND family_id = ?",
        (child_id, family_id),
    )
    row = await cursor.fetchone()
    return dict(row) if row else None


# ---------------------------------------------------------------------------
# Milestones
# ---------------------------------------------------------------------------


def _milestone_status(entry: dict, age_months: float | None, achieved: bool) -> str:
    if achieved:
        return "achieved"
    if age_months is None or age_months < entry["min"]:
        return "upcoming"
    if age_months <= entry["max"]:
        return "due"
    return "overdue"


async def list_milestones(db, family_id: str, child: dict) -> list[dict]:
    """Merge the milestone reference list with the child's achieved status."""
    cursor = await db.execute(
        """SELECT milestone_key, achieved_on, note FROM child_milestones
           WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL""",
        (child["id"], family_id),
    )
    achieved = {row["milestone_key"]: dict(row) for row in await cursor.fetchall()}
    age_months = age_in_months(_parse_date(child["date_of_birth"]))

    items = []
    for entry in sorted(MILESTONES, key=lambda m: (m["min"], m["max"])):
        record = achieved.get(entry["key"])
        is_achieved = record is not None
        items.append({
            "key": entry["key"],
            "title": entry["title"],
            "category": entry["category"],
            "typical_age_min_months": entry["min"],
            "typical_age_max_months": entry["max"],
            "achieved": is_achieved,
            "achieved_on": record["achieved_on"] if record else None,
            "note": record["note"] if record else None,
            "status": _milestone_status(entry, age_months, is_achieved),
        })
    return items


def milestone_exists(key: str) -> bool:
    return key in _MILESTONE_BY_KEY


# ---------------------------------------------------------------------------
# Vaccinations
# ---------------------------------------------------------------------------


def _vaccination_status(due: date | None, given: bool, today: date) -> str:
    if given:
        return "given"
    if due is None:
        return "upcoming"
    if due < today:
        return "overdue"
    if due <= today + timedelta(days=14):
        return "due"
    return "upcoming"


async def list_vaccinations(db, family_id: str, child: dict) -> list[dict]:
    """Scheduled doses plus any family-entered additional vaccinations."""
    cursor = await db.execute(
        """SELECT vaccine_key, vaccine_name, given_on FROM child_vaccinations
           WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL""",
        (child["id"], family_id),
    )
    rows = [dict(row) for row in await cursor.fetchall()]
    recorded = {row["vaccine_key"]: row["given_on"] for row in rows}
    dob = _parse_date(child["date_of_birth"])
    today = datetime.now(timezone.utc).date()

    items = []
    applicable_schedule = vaccination_schedule_for_dob(dob)
    applicable_keys = {entry["key"] for entry in applicable_schedule}
    for entry in applicable_schedule:
        due = _due_date(dob, entry)
        given_on = recorded.get(entry["key"])
        items.append({
            "key": entry["key"],
            "name": entry["name"],
            "due_age_label": entry["label"],
            "due_date": due.isoformat() if due else None,
            "status": _vaccination_status(due, given_on is not None, today),
            "given_on": given_on,
            "is_standard": True,
        })

    additional = [row for row in rows if row["vaccine_key"] not in applicable_keys]
    for record in sorted(additional, key=lambda item: item["given_on"], reverse=True):
        reference = _VACCINE_BY_KEY.get(record["vaccine_key"])
        items.append({
            "key": record["vaccine_key"],
            "name": record["vaccine_name"] or (
                reference["name"]
                if reference is not None
                else record["vaccine_key"].removeprefix("custom:")
            ),
            "due_age_label": (
                "Recorded outside the default schedule"
                if reference is not None
                else "Additional vaccination"
            ),
            "due_date": None,
            "status": "given",
            "given_on": record["given_on"],
            "is_standard": False,
        })
    return items


def vaccine_exists(key: str) -> bool:
    return key in _VACCINE_BY_KEY


async def due_vaccination_reminders(db, family_id: str, today: date) -> list[dict]:
    """Children with a scheduled vaccination due within 14 days and not recorded.

    Used by the reminder dispatcher to push a once-only "due soon" nudge.
    """
    cursor = await db.execute(
        "SELECT id, name, date_of_birth FROM children WHERE family_id = ? AND deleted_at IS NULL",
        (family_id,),
    )
    children = [dict(row) for row in await cursor.fetchall()]

    reminders = []
    for child in children:
        dob = _parse_date(child["date_of_birth"])
        if dob is None:
            continue
        cursor = await db.execute(
            """SELECT vaccine_key FROM child_vaccinations
               WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL""",
            (child["id"], family_id),
        )
        recorded = {row["vaccine_key"] for row in await cursor.fetchall()}
        for entry in vaccination_schedule_for_dob(dob):
            if entry["key"] in recorded:
                continue
            due = _due_date(dob, entry)
            if today <= due <= today + timedelta(days=14):
                reminders.append({
                    "child_id": child["id"],
                    "child_name": child["name"],
                    "vaccine_key": entry["key"],
                    "vaccine_name": entry["name"],
                    "due_date": due,
                })
    return reminders


# ---------------------------------------------------------------------------
# Growth centiles
# ---------------------------------------------------------------------------


async def growth_centiles(db, family_id: str, child: dict) -> dict:
    """Per-measurement centiles plus WHO reference bands for charting."""
    sex = child.get("sex")
    dob = _parse_date(child["date_of_birth"])

    cursor = await db.execute(
        """SELECT date, height_cm, weight_kg FROM growth_records
           WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL
           ORDER BY date ASC""",
        (child["id"], family_id),
    )
    measurements = []
    for row in await cursor.fetchall():
        age_months = age_in_months(dob, _parse_date(row["date"]))
        measurements.append({
            "date": row["date"],
            "age_months": age_months,
            "height_cm": row["height_cm"],
            "weight_kg": row["weight_kg"],
            "height_centile": who_growth.centile("height", sex, age_months, row["height_cm"]),
            "weight_centile": who_growth.centile("weight", sex, age_months, row["weight_kg"]),
        })

    note = None
    if sex not in ("male", "female"):
        note = (
            "Sex is not set for this child, so centiles cannot be computed. "
            "Set it to view centile bands."
        )

    return {
        "measurements": measurements,
        "weight_reference": who_growth.reference_curve("weight", sex),
        "height_reference": who_growth.reference_curve("height", sex),
        "note": note,
    }


# ---------------------------------------------------------------------------
# GP-ready illness summary
# ---------------------------------------------------------------------------


def _fmt_date(iso: str | None) -> str:
    parsed = _parse_datetime(iso)
    return parsed.strftime("%a %-d %b") if parsed else (iso or "unknown date")


def _fmt_datetime(iso: str | None) -> str:
    parsed = _parse_datetime(iso)
    return parsed.strftime("%a %-d %b, %H:%M") if parsed else (iso or "unknown time")


def _parse_datetime(iso: str | None) -> datetime | None:
    if not iso:
        return None
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def _compose_report(
    name: str,
    since: str,
    until: str,
    illnesses: list[dict],
    temps: list[dict],
    doses: list[dict],
) -> str:
    lines = [f"Health summary for {name}, {since} to {until}."]

    if illnesses:
        for illness in illnesses:
            start = _fmt_date(illness["started_at"])
            if illness["ended_at"]:
                period = f"{start} to {_fmt_date(illness['ended_at'])}"
            else:
                period = f"{start} (ongoing)"
            note = f" — {illness['notes']}" if illness.get("notes") else ""
            lines.append(f"Illness: {period}{note}.")
    else:
        lines.append("No illnesses recorded in this period.")

    if temps:
        values = [t["value_celsius"] for t in temps]
        peak = max(temps, key=lambda t: t["value_celsius"])
        fevers = [t for t in temps if t["value_celsius"] >= 38.0]
        lines.append(
            f"{len(temps)} temperature readings, "
            f"{min(values):.1f}-{max(values):.1f}°C. "
            f"Peak {peak['value_celsius']:.1f}°C on {_fmt_datetime(peak['recorded_at'])}."
        )
        if fevers:
            lines.append(
                f"Fever (38.0°C or above) on {len(fevers)} of these readings."
            )

    if doses:
        grouped: dict[str, list[dict]] = {}
        for dose in doses:
            grouped.setdefault(dose["name"], []).append(dose)
        for medicine_name, given in grouped.items():
            first = _fmt_datetime(given[0]["given_at"])
            last = _fmt_datetime(given[-1]["given_at"])
            count = len(given)
            plural = "dose" if count == 1 else "doses"
            span = first if count == 1 else f"{first} to {last}"
            lines.append(f"{medicine_name}: {count} {plural} ({span}).")

    return "\n".join(lines)


async def build_summary(db, family_id: str, child: dict, since: str, until: str) -> dict:
    """Assemble a structured, shareable timeline for the given window."""
    since_bound = f"{since}T00:00:00+00:00"
    until_bound = until

    cursor = await db.execute(
        """SELECT id, started_at, ended_at, notes FROM illnesses
           WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL
             AND datetime(started_at) <= datetime(?)
             AND (ended_at IS NULL OR datetime(ended_at) >= datetime(?))
           ORDER BY started_at ASC""",
        (child["id"], family_id, until_bound, since_bound),
    )
    illnesses = [dict(row) for row in await cursor.fetchall()]

    cursor = await db.execute(
        """SELECT recorded_at, value_celsius FROM temperature_readings
           WHERE child_id = ? AND family_id = ? AND deleted_at IS NULL
             AND datetime(recorded_at) >= datetime(?)
             AND datetime(recorded_at) <= datetime(?)
           ORDER BY recorded_at ASC""",
        (child["id"], family_id, since_bound, until_bound),
    )
    temps = [dict(row) for row in await cursor.fetchall()]

    cursor = await db.execute(
        """SELECT md.given_at,
                  COALESCE(mt.name, md.medicine_name, 'Medicine') AS name,
                  md.dose_amount
           FROM medicine_doses md
           LEFT JOIN medicine_types mt ON mt.id = md.medicine_type_id
           WHERE md.child_id = ? AND md.family_id = ? AND md.deleted_at IS NULL
             AND datetime(md.given_at) >= datetime(?)
             AND datetime(md.given_at) <= datetime(?)
           ORDER BY md.given_at ASC""",
        (child["id"], family_id, since_bound, until_bound),
    )
    doses = [dict(row) for row in await cursor.fetchall()]

    report = _compose_report(
        child["name"] or "This child", since, until[:10], illnesses, temps, doses
    )

    return {
        "illnesses": illnesses,
        "temperatures": temps,
        "medicine_doses": doses,
        "report": report,
    }

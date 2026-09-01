import json
from datetime import date as date_type, datetime, timedelta

from app.services.term_status import get_people_with_routine_or_terms, is_person_in_term


def _date_bounds(day: str) -> tuple[str, str]:
    return f"{day}T00:00:00", f"{day}T23:59:59"


async def derive_meal_context(db, family_id: str, day: str) -> dict:
    d = date_type.fromisoformat(day)
    day_start, day_end = _date_bounds(day)

    person_ids = await get_people_with_routine_or_terms(db, family_id)
    school_day = False
    for pid in person_ids:
        if await is_person_in_term(db, family_id, pid, d):
            school_day = True
            break

    cursor = await db.execute(
        """
        SELECT * FROM calendar_events
        WHERE deleted_at IS NULL
          AND family_id = ?
          AND start_time <= ?
          AND COALESCE(end_time, start_time) >= ?
        """,
        (family_id, day_end, day_start),
    )
    events = [dict(r) for r in await cursor.fetchall()]

    club_day = any(e.get("event_type") in ("club", "sport") for e in events)
    high_exertion = any(int(e.get("exertion") or 0) >= 2 for e in events)

    late_home = False
    dinner_time_bucket = "early"
    latest_end = None

    for e in events:
        end = e.get("end_time")
        if not end:
            continue
        try:
            end_dt = datetime.fromisoformat(end.replace("Z", "+00:00"))
        except ValueError:
            continue

        if latest_end is None or end_dt > latest_end:
            latest_end = end_dt

        if end_dt.hour > 17 or (end_dt.hour == 17 and end_dt.minute >= 30):
            late_home = True

    if latest_end is None or (latest_end.hour < 15 or (latest_end.hour == 15 and latest_end.minute == 0)):
        dinner_time_bucket = "early"
    elif latest_end.hour >= 18:
        dinner_time_bucket = "late"
    else:
        dinner_time_bucket = "normal"

    return {
        "school_day": school_day,
        "club_day": club_day,
        "high_exertion": high_exertion,
        "late_home": late_home,
        "holiday_mode": not school_day,
        "day_of_week": d.weekday(),
        "dinner_time_bucket": dinner_time_bucket,
    }


async def _recent_meal_ids(db, family_id: str, day: str) -> set[str]:
    d = date_type.fromisoformat(day)
    last_7 = (d - timedelta(days=7)).isoformat()
    cursor = await db.execute(
        """
        SELECT meal_id, date FROM meal_plans
        WHERE deleted_at IS NULL AND family_id = ? AND date >= ? AND date <= ?
        """,
        (family_id, last_7, day),
    )
    rows = [dict(r) for r in await cursor.fetchall()]
    return {r["meal_id"] for r in rows}


async def _recent_meal_ids_3d(db, family_id: str, day: str) -> set[str]:
    d = date_type.fromisoformat(day)
    last_3 = (d - timedelta(days=3)).isoformat()
    cursor = await db.execute(
        """
        SELECT meal_id FROM meal_plans
        WHERE deleted_at IS NULL AND family_id = ? AND date >= ? AND date <= ?
        """,
        (family_id, last_3, day),
    )
    return {r["meal_id"] for r in await cursor.fetchall()}


async def _meal_rating_rows(db, family_id: str) -> list[dict]:
    cursor = await db.execute(
        """
        SELECT mr.*, mp.meal_id, mp.date AS plan_date, m.tags
        FROM meal_ratings mr
        JOIN meal_plans mp ON mp.id = mr.meal_plan_id
        JOIN meals m ON m.id = mp.meal_id
        WHERE mr.deleted_at IS NULL
          AND mp.deleted_at IS NULL
          AND m.deleted_at IS NULL
          AND mr.family_id = ?
        """,
        (family_id,),
    )
    rows = []
    for r in await cursor.fetchall():
        d = dict(r)
        d["tags_parsed"] = json.loads(d["tags"]) if d.get("tags") else []
        rows.append(d)
    return rows


def _score_meal(
    meal: dict,
    context: dict,
    ratings: list[dict],
    recent_7: set[str],
    recent_3: set[str],
) -> tuple[float, list[str]]:
    meal_id = meal["id"]
    tags = json.loads(meal["tags"]) if meal.get("tags") else []
    prep = meal.get("prep_minutes")

    score = 0.0
    reasons: list[str] = []

    meal_ratings = [r for r in ratings if r["meal_id"] == meal_id]
    if meal_ratings:
        values = [int(r["rating"]) for r in meal_ratings]
        avg_rating = sum(values) / len(values)
        has_one = any(v == 1 for v in values)
        win = 1.0 if avg_rating >= 2.0 and not has_one else 0.0
        score += win * 40
        if win:
            reasons.append("Strong historical family win")
    else:
        score += 20
        reasons.append("Untried meal gives variety")

    # Tag preference signal from each child by overlap with rated meals.
    child_scores: list[float] = []
    for child_id in {r["child_id"] for r in ratings}:
        tagged = [
            r for r in ratings
            if r["child_id"] == child_id and set(tags) & set(r["tags_parsed"])
        ]
        if not tagged:
            continue
        avg = sum(int(r["rating"]) for r in tagged) / len(tagged)
        child_scores.append(avg)
    if child_scores:
        pref = sum(child_scores) / len(child_scores)
        score += (pref / 3.0) * 30
        if pref >= 2.5:
            reasons.append("Tags align with child preferences")
        elif pref <= 1.5:
            reasons.append("Similar meals rated poorly")

    if context["club_day"] or context["high_exertion"]:
        if set(tags) & {"fast", "pasta", "rice", "filling", "chicken"}:
            score += 10
            reasons.append("Good fit for a busy or active day")
        if set(tags) & {"spicy", "experimental"}:
            score -= 6

    if context["late_home"]:
        if "fast" in tags or (prep is not None and prep <= 20):
            score += 10
            reasons.append("Works well for a late home evening")
        if set(tags) & {"roast", "slow"}:
            score -= 8

    if context["holiday_mode"] or context["day_of_week"] >= 5:
        if (prep is not None and prep >= 30) or "slow" in tags:
            score += 4

    if meal_id in recent_3:
        score -= 10
        reasons.append("Served in last 3 days")
    elif meal_id in recent_7:
        score -= 4

    return score, reasons


async def recommend_meals(db, family_id: str, day: str, limit: int = 5) -> dict:
    context = await derive_meal_context(db, family_id, day)

    cursor = await db.execute(
        "SELECT * FROM meals WHERE deleted_at IS NULL AND family_id = ? "
        "AND COALESCE(not_for_us, 0) = 0 ORDER BY name",
        (family_id,),
    )
    meals = [dict(r) for r in await cursor.fetchall()]

    ratings = await _meal_rating_rows(db, family_id)
    recent_7 = await _recent_meal_ids(db, family_id, day)
    recent_3 = await _recent_meal_ids_3d(db, family_id, day)

    scored = []
    for meal in meals:
        score, reasons = _score_meal(meal, context, ratings, recent_7, recent_3)

        cursor = await db.execute(
            "SELECT MAX(date) AS last_served_at FROM meal_plans WHERE meal_id = ? AND family_id = ? AND deleted_at IS NULL",
            (meal["id"], family_id),
        )
        row = await cursor.fetchone()

        scored.append(
            {
                "meal_id": meal["id"],
                "meal_name": meal["name"],
                "tags": json.loads(meal["tags"]) if meal.get("tags") else [],
                "score": round(score, 2),
                "reasons": reasons[:3],
                "last_served_at": row["last_served_at"] if row else None,
            }
        )

    scored.sort(key=lambda x: x["score"], reverse=True)
    return {"context": context, "recommendations": scored[:limit], "date": day}

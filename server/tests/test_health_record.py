"""Tests for the children's health-record router (/api/health-record)."""

import json
from datetime import date, datetime, timedelta, timezone

import aiosqlite
from cryptography.fernet import Fernet

from app.config import settings
from app.services.health_record import vaccination_schedule_for_dob
from app.services.reminders import dispatch_due_reminders
from app.utils.encryption import encrypt_value


# ===========================================================================
# Developmental milestones
# ===========================================================================


async def test_milestones_list_sorted_with_age_hint(client, adult_a_headers, child3):
    """The reference list is merged with achieved status and an age hint."""
    resp = await client.get(f"/api/health-record/{child3['id']}/milestones", headers=adult_a_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["disclaimer"]
    milestones = body["milestones"]
    # Sorted by typical age — the earliest band (smiles ~6wk) comes first.
    ages = [m["typical_age_min_months"] for m in milestones]
    assert ages == sorted(ages)
    assert milestones[0]["key"] == "smiles"

    by_key = {m["key"]: m for m in milestones}
    # child3 is ~20 months old: long past smiles, mid-range for running,
    # nowhere near pedalling a tricycle.
    assert by_key["smiles"]["achieved"] is False
    assert by_key["smiles"]["status"] == "overdue"
    assert by_key["runs"]["status"] == "due"
    assert by_key["pedals_tricycle"]["status"] == "upcoming"


async def test_milestone_achieve_is_idempotent_and_unmark(client, adult_a_headers, child3):
    """POST marks achieved (upsert), DELETE unmarks."""
    achieve = await client.post(
        f"/api/health-record/{child3['id']}/milestones",
        json={"milestone_key": "smiles", "achieved_on": "2025-01-05", "note": "at grandma's"},
        headers=adult_a_headers,
    )
    assert achieve.status_code == 200
    smiles = {m["key"]: m for m in achieve.json()["milestones"]}["smiles"]
    assert smiles["achieved"] is True
    assert smiles["status"] == "achieved"
    assert smiles["achieved_on"] == "2025-01-05"
    assert smiles["note"] == "at grandma's"

    # Re-POST is idempotent (still one active row) and updates the note.
    again = await client.post(
        f"/api/health-record/{child3['id']}/milestones",
        json={"milestone_key": "smiles", "achieved_on": "2025-01-06"},
        headers=adult_a_headers,
    )
    assert again.status_code == 200
    achieved = [m for m in again.json()["milestones"] if m["key"] == "smiles" and m["achieved"]]
    assert len(achieved) == 1
    assert achieved[0]["achieved_on"] == "2025-01-06"

    removed = await client.delete(
        f"/api/health-record/{child3['id']}/milestones/smiles", headers=adult_a_headers
    )
    assert removed.status_code == 204

    after = await client.get(f"/api/health-record/{child3['id']}/milestones", headers=adult_a_headers)
    smiles = {m["key"]: m for m in after.json()["milestones"]}["smiles"]
    assert smiles["achieved"] is False
    assert smiles["status"] == "overdue"


async def test_milestone_unknown_key_rejected(client, adult_a_headers, child3):
    resp = await client.post(
        f"/api/health-record/{child3['id']}/milestones",
        json={"milestone_key": "flies_to_the_moon", "achieved_on": "2025-01-05"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 400


async def test_unmark_missing_milestone_404(client, adult_a_headers, child3):
    resp = await client.delete(
        f"/api/health-record/{child3['id']}/milestones/walks_alone", headers=adult_a_headers
    )
    assert resp.status_code == 404


# ===========================================================================
# Vaccinations
# ===========================================================================


async def test_vaccination_schedule_due_dates_and_status(client, adult_a_headers, child3):
    """Due dates are computed from DOB; unrecorded past doses read as overdue."""
    resp = await client.get(f"/api/health-record/{child3['id']}/vaccinations", headers=adult_a_headers)
    assert resp.status_code == 200
    vaccines = {v["key"]: v for v in resp.json()["vaccinations"]}
    assert len(vaccines) >= 12

    # child3 DOB 2024-11-10, first 6-in-1 due at 8 weeks = 2025-01-05.
    assert vaccines["six_in_one_1"]["due_date"] == "2025-01-05"
    assert vaccines["six_in_one_1"]["status"] == "overdue"
    # The 3y4m booster is still well in the future.
    assert vaccines["mmrv_2"]["due_date"] == "2028-03-10"
    assert vaccines["mmrv_2"]["status"] == "upcoming"
    # The 18-month visit must exist (it was missing and is harm-critical).
    assert "six_in_one_4" in vaccines
    assert vaccines["six_in_one_4"]["due_age_label"] == "18 months"
    assert vaccines["six_in_one_4"]["due_date"] == "2026-05-10"


async def test_vaccination_schedule_honours_ukhsa_birth_cohort_boundaries(
    client, adult_a_headers, adult_a_user, initialized_db
):
    cohorts = {
        "cohort-before": ("2024-06-30", {"hib_menc", "mmrv_2"}),
        "cohort-start": (
            "2024-07-01",
            {"six_in_one_4", "mmrv_18m", "mmrv_2"},
        ),
        "cohort-end": (
            "2024-12-31",
            {"six_in_one_4", "mmrv_18m", "mmrv_2"},
        ),
        "cohort-after": ("2025-01-01", {"six_in_one_4", "mmrv_18m"}),
    }
    async with aiosqlite.connect(initialized_db) as db:
        for child_id, (dob, _) in cohorts.items():
            await db.execute(
                "INSERT INTO children (id, name, date_of_birth, family_id, created_by) "
                "VALUES (?, ?, ?, ?, ?)",
                (child_id, child_id, dob, adult_a_user["family_id"], adult_a_user["id"]),
            )
        await db.commit()

    conditional = {"hib_menc", "six_in_one_4", "mmrv_18m", "mmrv_2"}
    for child_id, (_, expected) in cohorts.items():
        response = await client.get(
            f"/api/health-record/{child_id}/vaccinations", headers=adult_a_headers
        )
        assert response.status_code == 200
        keys = {item["key"] for item in response.json()["vaccinations"]}
        assert keys & conditional == expected


def test_vaccination_schedule_honours_july_2025_early_visit_transition():
    old = {
        entry["key"]: entry
        for entry in vaccination_schedule_for_dob(date(2025, 4, 7))
    }
    new = {
        entry["key"]: entry
        for entry in vaccination_schedule_for_dob(date(2025, 4, 8))
    }

    assert (old["pcv_1"]["weeks"], old["menb_2"]["weeks"]) == (12, 16)
    assert (new["pcv_1"]["weeks"], new["menb_2"]["weeks"]) == (16, 12)


async def test_inapplicable_routine_vaccine_must_be_recorded_as_additional(
    client, adult_a_headers, child1
):
    response = await client.post(
        f"/api/health-record/{child1['id']}/vaccinations",
        json={"vaccine_key": "six_in_one_4", "given_on": "2022-01-01"},
        headers=adult_a_headers,
    )

    assert response.status_code == 400
    assert "additional vaccination" in response.json()["detail"]


async def test_vaccination_record_transitions_to_given(client, adult_a_headers, child3):
    record = await client.post(
        f"/api/health-record/{child3['id']}/vaccinations",
        json={"vaccine_key": "six_in_one_1", "given_on": "2025-01-07"},
        headers=adult_a_headers,
    )
    assert record.status_code == 200
    vaccines = {v["key"]: v for v in record.json()["vaccinations"]}
    assert vaccines["six_in_one_1"]["status"] == "given"
    assert vaccines["six_in_one_1"]["given_on"] == "2025-01-07"
    # Recording one does not change the others.
    assert vaccines["menb_1"]["status"] == "overdue"

    removed = await client.delete(
        f"/api/health-record/{child3['id']}/vaccinations/six_in_one_1", headers=adult_a_headers
    )
    assert removed.status_code == 204
    after = await client.get(f"/api/health-record/{child3['id']}/vaccinations", headers=adult_a_headers)
    vaccines = {v["key"]: v for v in after.json()["vaccinations"]}
    assert vaccines["six_in_one_1"]["status"] == "overdue"
    assert vaccines["six_in_one_1"]["given_on"] is None


async def test_vaccination_unknown_key_rejected(client, adult_a_headers, child3):
    resp = await client.post(
        f"/api/health-record/{child3['id']}/vaccinations",
        json={"vaccine_key": "smallpox", "given_on": "2025-01-05"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 400


async def test_additional_vaccination_is_preserved_alongside_routine_schedule(
    client, adult_a_headers, child3
):
    """Families can record a vaccine that is not in the routine schedule."""
    resp = await client.post(
        f"/api/health-record/{child3['id']}/vaccinations",
        json={"vaccine_name": "Chickenpox", "given_on": "2026-07-16"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    items = resp.json()["vaccinations"]
    custom = next(item for item in items if item["name"] == "Chickenpox")
    assert custom["key"].startswith("custom:")
    assert custom["given_on"] == "2026-07-16"
    assert custom["status"] == "given"
    assert custom["is_standard"] is False
    assert any(item["key"] == "six_in_one_1" and item["is_standard"] for item in items)

    removed = await client.delete(
        f"/api/health-record/{child3['id']}/vaccinations/{custom['key']}",
        headers=adult_a_headers,
    )
    assert removed.status_code == 204
    after = await client.get(
        f"/api/health-record/{child3['id']}/vaccinations", headers=adult_a_headers
    )
    assert all(item["key"] != custom["key"] for item in after.json()["vaccinations"])


async def test_additional_vaccination_requires_a_nonempty_name(client, adult_a_headers, child3):
    resp = await client.post(
        f"/api/health-record/{child3['id']}/vaccinations",
        json={"vaccine_name": "   ", "given_on": "2026-07-16"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 422


async def test_vaccination_requires_exactly_one_identifier_and_date_only(
    client, adult_a_headers, child3
):
    path = f"/api/health-record/{child3['id']}/vaccinations"
    both = await client.post(
        path,
        json={
            "vaccine_key": "mmrv_1",
            "vaccine_name": "Custom MMR",
            "given_on": "2026-07-16",
        },
        headers=adult_a_headers,
    )
    assert both.status_code == 422

    timestamp = await client.post(
        path,
        json={"vaccine_name": "Chickenpox", "given_on": "2026-07-16T09:00:00Z"},
        headers=adult_a_headers,
    )
    assert timestamp.status_code == 422

    future = await client.post(
        path,
        json={"vaccine_name": "Chickenpox", "given_on": "2999-01-01"},
        headers=adult_a_headers,
    )
    assert future.status_code == 422


# ===========================================================================
# Growth centiles
# ===========================================================================


async def _seed_growth(db_path, child_id, family_id, created_by, records):
    async with aiosqlite.connect(db_path) as db:
        for i, (measure_date, height, weight) in enumerate(records):
            await db.execute(
                """INSERT INTO growth_records
                   (id, child_id, date, height_cm, weight_kg, family_id, created_by)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (f"growth-{child_id}-{i}", child_id, measure_date, height, weight, family_id, created_by),
            )
        await db.commit()


async def test_growth_centiles_null_without_sex_then_computed(
    client, adult_a_headers, adult_a_user, child3, initialized_db
):
    """Centiles are null until sex is set, then match the WHO median (~p50)."""
    # A measurement at exactly 12 months at the WHO boys median values, plus one
    # beyond the 0-60 month range.
    await _seed_growth(
        initialized_db, child3["id"], adult_a_user["family_id"], adult_a_user["id"],
        [("2025-11-10", 75.7488, 9.6479), ("2030-11-10", 110.0, 20.0)],
    )

    before = await client.get(
        f"/api/health-record/{child3['id']}/growth-centiles", headers=adult_a_headers
    )
    assert before.status_code == 200
    body = before.json()
    assert body["disclaimer"] == "Centiles are indicative, not a medical assessment."
    assert body["note"] is not None  # explains sex is unknown
    assert body["weight_reference"] == []
    assert body["measurements"][0]["weight_centile"] is None

    patched = await client.patch(
        f"/api/health-record/{child3['id']}/sex", json={"sex": "male"}, headers=adult_a_headers
    )
    assert patched.status_code == 200
    assert patched.json()["sex"] == "male"

    after = await client.get(
        f"/api/health-record/{child3['id']}/growth-centiles", headers=adult_a_headers
    )
    body = after.json()
    assert body["sex"] == "male"
    assert body["note"] is None
    # Reference bands cover 0-60 months, and p50 tracks the WHO median.
    assert len(body["weight_reference"]) == 61
    ref_12 = {p["age_months"]: p for p in body["weight_reference"]}[12]
    assert abs(ref_12["p50"] - 9.6479) < 0.05
    height_ref_12 = {p["age_months"]: p for p in body["height_reference"]}[12]
    assert abs(height_ref_12["p50"] - 75.7488) < 0.05

    measurements = body["measurements"]
    in_range = measurements[0]
    assert abs(in_range["age_months"] - 12.0) < 0.1
    assert 45 < in_range["weight_centile"] < 55  # median value -> ~50th centile
    assert 45 < in_range["height_centile"] < 55
    # The measurement beyond 60 months has no centile.
    assert measurements[1]["weight_centile"] is None


def test_centile_interpolates_smoothly_in_newborn_window():
    """A day of age must not swing the centile wildly (LMS interpolated by month)."""
    from app.services.who_growth import centile

    fifteen_days = centile("weight", "male", 0.49, 3.9)
    sixteen_days = centile("weight", "male", 0.51, 3.9)
    # Without interpolation these were ~86th vs ~15th; interpolation keeps them close.
    assert abs(fifteen_days - sixteen_days) < 5


async def test_growth_centiles_girls_median(client, adult_a_headers, adult_a_user, child3, initialized_db):
    """The girls series is used when sex is female (anchor: 8.9481 kg at 12mo)."""
    await _seed_growth(
        initialized_db, child3["id"], adult_a_user["family_id"], adult_a_user["id"],
        [("2025-11-10", 74.015, 8.9481)],
    )
    await client.patch(
        f"/api/health-record/{child3['id']}/sex", json={"sex": "female"}, headers=adult_a_headers
    )
    resp = await client.get(
        f"/api/health-record/{child3['id']}/growth-centiles", headers=adult_a_headers
    )
    body = resp.json()
    ref_12 = {p["age_months"]: p for p in body["weight_reference"]}[12]
    assert abs(ref_12["p50"] - 8.9481) < 0.05
    assert 45 < body["measurements"][0]["weight_centile"] < 55


# ===========================================================================
# GP-ready illness summary
# ===========================================================================


async def test_summary_composes_from_seeded_data(
    client, adult_a_headers, adult_a_user, child1, initialized_db
):
    now = datetime.now(timezone.utc)

    def iso(days_ago, hour):
        return (now - timedelta(days=days_ago)).replace(hour=hour, minute=0, second=0, microsecond=0).isoformat()

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO illnesses (id, child_id, started_at, notes, family_id, created_by)
               VALUES (?, ?, ?, ?, ?, ?)""",
            ("ill-1", child1["id"], iso(5, 18), "Fever and cough", adult_a_user["family_id"], adult_a_user["id"]),
        )
        for i, (days_ago, hour, temp) in enumerate(
            [(5, 20, 38.5), (4, 3, 39.2), (4, 12, 37.6)]
        ):
            await db.execute(
                """INSERT INTO temperature_readings
                   (id, child_id, value_celsius, recorded_at, family_id, created_by)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (f"temp-{i}", child1["id"], temp, iso(days_ago, hour), adult_a_user["family_id"], adult_a_user["id"]),
            )
        for i in range(6):
            await db.execute(
                """INSERT INTO medicine_doses
                   (id, child_id, given_at, given_by, medicine_name, dose_amount, family_id, created_by)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (f"dose-{i}", child1["id"], iso(4, 6 + i * 3), adult_a_user["id"], "Calpol", "5ml",
                 adult_a_user["family_id"], adult_a_user["id"]),
            )
        await db.commit()

    resp = await client.get(f"/api/health-record/{child1['id']}/summary", headers=adult_a_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["illnesses"]) == 1
    assert len(body["temperatures"]) == 3
    assert len(body["medicine_doses"]) == 6
    report = body["report"]
    assert "Fever and cough" in report
    assert "39.2°C" in report  # peak temperature
    assert "Calpol" in report
    assert "6 doses" in report
    assert body["disclaimer"]


async def test_summary_since_narrows_window(
    client, adult_a_headers, adult_a_user, child1, initialized_db
):
    now = datetime.now(timezone.utc)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO medicine_doses
               (id, child_id, given_at, given_by, medicine_name, family_id, created_by)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            ("dose-old", child1["id"], (now - timedelta(days=200)).isoformat(), adult_a_user["id"],
             "Calpol", adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO medicine_doses
               (id, child_id, given_at, given_by, medicine_name, family_id, created_by)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            ("dose-new", child1["id"], (now - timedelta(days=2)).isoformat(), adult_a_user["id"],
             "Calpol", adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    # Default 90-day window excludes the 200-day-old dose.
    default = await client.get(f"/api/health-record/{child1['id']}/summary", headers=adult_a_headers)
    assert len(default.json()["medicine_doses"]) == 1

    since = (now - timedelta(days=1)).date().isoformat()
    narrowed = await client.get(
        f"/api/health-record/{child1['id']}/summary?since={since}", headers=adult_a_headers
    )
    assert len(narrowed.json()["medicine_doses"]) == 0


async def test_summary_invalid_since_rejected(client, adult_a_headers, child1):
    resp = await client.get(
        f"/api/health-record/{child1['id']}/summary?since=not-a-date", headers=adult_a_headers
    )
    assert resp.status_code == 400


# ===========================================================================
# Family isolation
# ===========================================================================


async def test_endpoints_are_family_scoped(client, other_family_headers, child1):
    """Another family cannot see or touch this family's child records."""
    cid = child1["id"]
    reads = [
        f"/api/health-record/{cid}/milestones",
        f"/api/health-record/{cid}/vaccinations",
        f"/api/health-record/{cid}/growth-centiles",
        f"/api/health-record/{cid}/summary",
    ]
    for path in reads:
        resp = await client.get(path, headers=other_family_headers)
        assert resp.status_code == 404, path

    posts = [
        (f"/api/health-record/{cid}/milestones", {"milestone_key": "smiles", "achieved_on": "2025-01-05"}),
        (f"/api/health-record/{cid}/vaccinations", {"vaccine_key": "mmrv_1", "given_on": "2025-11-10"}),
    ]
    for path, payload in posts:
        resp = await client.post(path, json=payload, headers=other_family_headers)
        assert resp.status_code == 404, path

    patched = await client.patch(
        f"/api/health-record/{cid}/sex", json={"sex": "male"}, headers=other_family_headers
    )
    assert patched.status_code == 404


# ===========================================================================
# Vaccination reminder push
# ===========================================================================


async def test_vaccination_reminder_pushes_once(initialized_db, adult_a_user, monkeypatch):
    """A child with a vaccine due soon triggers a single once-only push."""
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    settings.web_push_vapid_private_key = "/tmp/test-vapid.pem"
    settings.web_push_vapid_public_key = "p" * 65
    now = datetime.now(timezone.utc)
    # DOB 7 weeks ago -> the 8-week 6-in-1 is due in ~7 days (within the window).
    dob = (now.date() - timedelta(days=49)).isoformat()
    encrypted = encrypt_value(
        json.dumps({"endpoint": "https://push.example/id", "keys": {"p256dh": "p" * 80, "auth": "a" * 24}})
    )
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, family_id, created_by) VALUES (?, ?, ?, ?, ?)",
            ("vax-child", "Baby Vax", dob, adult_a_user["family_id"], adult_a_user["id"]),
        )
        # The other two 8-week vaccines are already done, so only the 6-in-1 is due.
        for key in ("menb_1", "rotavirus_1"):
            await db.execute(
                """INSERT INTO child_vaccinations
                   (id, child_id, vaccine_key, given_on, family_id, created_by)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (f"done-{key}", "vax-child", key, dob, adult_a_user["family_id"], adult_a_user["id"]),
            )
        await db.execute(
            """INSERT INTO reminder_preferences
               (id, user_id, family_id, quiet_start, quiet_end, privacy_mode, created_by)
               VALUES (?, ?, ?, ?, ?, 0, ?)""",
            ("pref", adult_a_user["id"], adult_a_user["family_id"], "23:59", "00:01", adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO web_push_subscriptions
               (id, user_id, family_id, endpoint_hash, encrypted_subscription, created_by)
               VALUES (?, ?, ?, ?, ?, ?)""",
            ("subscription", adult_a_user["id"], adult_a_user["family_id"], "hash", encrypted, adult_a_user["id"]),
        )
        await db.commit()

    sent = []

    async def capture(subscription, payload):
        sent.append(payload)

    async def safe_url(value):
        return value, "push.example"

    monkeypatch.setattr("app.services.reminders._send", capture)
    monkeypatch.setattr("app.services.reminders.validate_public_https_url", safe_url)
    await dispatch_due_reminders()
    await dispatch_due_reminders()

    vaccine_pushes = [p for p in sent if p["tag"] == "hausklar-vaccination"]
    assert len(vaccine_pushes) == 1
    assert "Baby Vax" in vaccine_pushes[0]["body"]
    assert "6-in-1" in vaccine_pushes[0]["body"]
    assert vaccine_pushes[0]["url"] == "/?view=family&section=medicine"

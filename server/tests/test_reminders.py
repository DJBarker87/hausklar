import json
import asyncio
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite
from cryptography.fernet import Fernet

from app.config import settings
from app.services.apns import APNSDeliveryError, device_token_hash
from app.models.finance import FinanceCalendarItemCreate, FinanceCommitmentCreate
from app.services.finance.foundation import get_finance_settings
from app.services.finance.planning import create_commitment
from app.services.finance.projections import (
    create_calendar_item,
    set_projection_preference,
)
from app.services.reminders import (
    LOCAL,
    _payload,
    _summary_counts,
    deliver_finance_report_notification,
    dispatch_due_reminders,
    due_in_window,
    endpoint_hash,
    in_quiet_hours,
)
from app.utils.encryption import decrypt_value, encrypt_value


def test_private_reminders_say_what_needs_attention_without_exposing_names():
    cases = {
        "event": ("Upcoming event", "Starts in 30 minutes"),
        "task": ("Task due", "This task is due"),
        "renewal": ("Renewal due", "Due in 3 days"),
        "library": ("Library book due", "Due back tomorrow"),
        "document": ("Document ready to review", "A document has suggestions ready to check."),
        "insight": ("Family update", "HausKlar noticed something worth checking."),
        "vaccination": ("Vaccination reminder", "A vaccination is due soon."),
        "morning": ("Today in HausKlar", "2 events and 1 task need attention"),
        "evening": ("Tomorrow, sorted", "1 event and 2 tasks to check"),
    }
    for kind, expected in cases.items():
        payload = _payload(
            kind,
            expected[0] if kind in {"morning", "evening"} else "Private family name",
            expected[1] if kind not in {"document", "insight", "vaccination"} else "Private family detail",
            "/?view=today",
            True,
        )
        assert (payload["title"], payload["body"]) == expected
        assert "Private family" not in f"{payload['title']} {payload['body']}"

    detailed = _payload(
        "event", "School pickup", "Starts in 30 minutes", "/?view=calendar", False
    )
    assert detailed["title"] == "School pickup"
    assert detailed["body"] == "Starts in 30 minutes"


async def test_summary_counts_include_only_the_adults_visible_finance_plan(
    initialized_db, adult_a_user
):
    today_start = datetime.now(LOCAL).replace(hour=0, minute=0, second=0, microsecond=0)
    tomorrow_start = today_start + timedelta(days=1)
    day_after_start = tomorrow_start + timedelta(days=1)
    user = adult_a_user
    now = datetime.now(timezone.utc).isoformat()

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        settings_row = await get_finance_settings(db, user=user)
        await create_commitment(
            db,
            user=user,
            space_id=settings_row.household_space_id,
            body=FinanceCommitmentCreate(
                name="School fees",
                amount_mode="EXACT",
                exact_minor=320_000,
                recurrence="CUSTOM",
                reviewed_dates=[today_start.date(), tomorrow_start.date()],
                payment_handling="MANUAL",
                show_in_calendar=True,
                show_in_tasks=True,
                responsible_user_id=adult_a_user["id"],
            ),
        )
        source_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO finance_purchase_sources
                (id, space_id, external_source_id, source_kind,
                 extraction_status, raw_payload_json, issues_json, received_at,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, 'tesco_batch', 'PARSED', '{}', '[]', ?, ?, ?, ?, ?)
            """,
            (
                source_id,
                settings_row.household_space_id,
                f"summary-test-{source_id}",
                now,
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await create_calendar_item(
            db,
            user=user,
            body=FinanceCalendarItemCreate(
                reviewed=True,
                space_id=settings_row.household_space_id,
                item_kind="GROCERY_DELIVERY",
                source_id=source_id,
                starts_at=today_start.replace(hour=18).isoformat(),
            ),
        )

        # Money hidden, Deliveries shown: today's summary still includes the
        # reviewed delivery and the deliberately-created Finance task.
        await set_projection_preference(
            db,
            user=user,
            show_money=False,
            show_deliveries=True,
        )
        assert await _summary_counts(
            db,
            user=user,
            day_start=today_start,
            day_end=tomorrow_start,
            task_due_before=tomorrow_start.date().isoformat(),
        ) == (1, 1)

        # Deliveries hidden, Money shown: tomorrow's summary includes only the
        # safe commitment date; tasks remain independently controlled per item.
        await set_projection_preference(
            db,
            user=user,
            show_money=True,
            show_deliveries=False,
        )
        assert await _summary_counts(
            db,
            user=user,
            day_start=tomorrow_start,
            day_end=day_after_start,
            task_due_before=day_after_start.date().isoformat(),
        ) == (1, 2)


async def test_finance_report_push_is_private_durable_and_at_most_once(
    initialized_db, adult_a_user, monkeypatch
):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    settings.web_push_vapid_private_key = "/tmp/test-vapid.pem"
    settings.web_push_vapid_public_key = "p" * 65
    encrypted = encrypt_value(
        json.dumps(
            {
                "endpoint": "https://push.example/finance",
                "keys": {"p256dh": "p" * 80, "auth": "a" * 24},
            }
        )
    )
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO web_push_subscriptions
               (id,user_id,family_id,endpoint_hash,encrypted_subscription,created_by)
               VALUES (?,?,?,?,?,?)""",
            (
                "finance-subscription",
                adult_a_user["id"],
                adult_a_user["family_id"],
                "finance-hash",
                encrypted,
                adult_a_user["id"],
            ),
        )
        await db.commit()
    sent = []

    async def capture(subscription, payload):
        sent.append(payload)

    async def safe_url(value):
        return value, "push.example"

    monkeypatch.setattr("app.services.reminders._send", capture)
    monkeypatch.setattr("app.services.reminders.validate_public_https_url", safe_url)
    key = f"finance:daily:{adult_a_user['id']}:2026-08-01"
    assert await deliver_finance_report_notification(
        user_id=adult_a_user["id"],
        family_id=adult_a_user["family_id"],
        reminder_key=f"{key}:no-action",
    ) == 0
    assert await deliver_finance_report_notification(
        user_id=adult_a_user["id"],
        family_id=adult_a_user["family_id"],
        reminder_key=key,
        action_id="payday-action",
        action_scope="household",
    ) == 1
    assert await deliver_finance_report_notification(
        user_id=adult_a_user["id"],
        family_id=adult_a_user["family_id"],
        reminder_key=key,
        action_id="payday-action",
        action_scope="household",
    ) == 0
    assert sent == [
        {
            "title": "Money needs your attention",
            "body": "Open HausKlar to finish one private money action.",
            "url": "/?view=finance&section=coach&action=payday-action&scope=household",
            "tag": "hausklar-finance",
        }
    ]
    async with aiosqlite.connect(initialized_db) as db:
        count = await (
            await db.execute(
                "SELECT COUNT(*) FROM reminder_deliveries WHERE reminder_key = ? "
                "AND deleted_at IS NULL",
                (key,),
            )
        ).fetchone()
    assert count[0] == 1


async def test_preferences_are_personal_and_validated(client, adult_a_headers, adult_b_headers, adult_a_user, adult_b_user):
    default = await client.get("/api/reminders/preferences", headers=adult_a_headers)
    assert default.status_code == 200
    assert default.json()["event_minutes_before"] == 30
    changed = {**default.json(), "event_minutes_before": 60, "privacy_mode": False}
    saved = await client.put("/api/reminders/preferences", json=changed, headers=adult_a_headers)
    assert saved.status_code == 200
    assert saved.json()["event_minutes_before"] == 60
    kat = await client.get("/api/reminders/preferences", headers=adult_b_headers)
    assert kat.status_code == 200
    assert kat.json()["event_minutes_before"] == 30
    invalid = await client.put("/api/reminders/preferences", json={**changed, "quiet_start": "25:00"}, headers=adult_a_headers)
    assert invalid.status_code == 422
    test = await client.post("/api/reminders/test", headers=adult_a_headers)
    assert test.status_code == 409


async def test_concurrent_first_preferences_reads_are_idempotent(
    client, adult_a_headers, initialized_db, adult_a_user
):
    preferences, preview = await asyncio.gather(
        client.get("/api/reminders/preferences", headers=adult_a_headers),
        client.get("/api/reminders/preview", headers=adult_a_headers),
    )
    assert preferences.status_code == 200
    assert preview.status_code == 200
    async with aiosqlite.connect(initialized_db) as db:
        count = await (
            await db.execute(
                "SELECT COUNT(*) FROM reminder_preferences WHERE user_id=? AND deleted_at IS NULL",
                (adult_a_user["id"],),
            )
        ).fetchone()
    assert count[0] == 1


async def test_preview_is_personalised(client, adult_a_headers, adult_a_user, adult_b_user):
    start = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
    shared = await client.post("/api/calendar/", json={"title": "Family event", "start_time": start}, headers=adult_a_headers)
    assert shared.status_code == 201
    assigned = await client.post("/api/calendar/", json={"title": "Morgan only", "start_time": start, "assigned_to": adult_b_user["id"]}, headers=adult_a_headers)
    assert assigned.status_code == 201
    preview = await client.get("/api/reminders/preview", headers=adult_a_headers)
    assert preview.status_code == 200
    titles = {item["title"] for item in preview.json()}
    assert all(item["id"].startswith(("event:", "task:")) for item in preview.json())
    assert "Family event" in titles
    assert "Morgan only" not in titles


async def test_preview_skips_cancelled_recurrence_and_keeps_the_next_occurrence(
    client, adult_a_headers
):
    first_start = (datetime.now(timezone.utc) + timedelta(hours=2)).replace(
        microsecond=0
    )
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Daily family check-in",
            "start_time": first_start.isoformat(),
            "recurrence_rule": "FREQ=DAILY;COUNT=2",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    cancelled = await client.post(
        f"/api/calendar/{created.json()['id']}/occurrences/delete",
        json={
            "scope": "only_this",
            "occurrence_start": first_start.isoformat(),
        },
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 204

    preview = await client.get("/api/reminders/preview", headers=adult_a_headers)

    assert preview.status_code == 200
    matching = [
        item for item in preview.json() if item["title"] == "Daily family check-in"
    ]
    assert len(matching) == 1
    expected_local_occurrence = (first_start + timedelta(days=1)).astimezone(LOCAL)
    assert expected_local_occurrence.strftime("%a %-d %b") in matching[0]["detail"]


async def test_renewal_reminder_goes_to_its_adult_and_opens_the_exact_record(
    client,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    adult_a_user,
):
    due = (datetime.now(LOCAL).date() + timedelta(days=10)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO renewals
                (id, title, category, due_date, reminder_days_before,
                 family_id, created_by)
            VALUES (?, ?, 'document', ?, 21, ?, ?)
            """,
            ("renewal-passport", "Renew passport", due, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    adult_a_preview = await client.get("/api/reminders/preview", headers=adult_a_headers)
    assert adult_a_preview.status_code == 200
    reminder = next(item for item in adult_a_preview.json() if item["kind"] == "renewal")
    assert reminder["title"] == "Renew passport"
    assert reminder["url"] == "/?view=lists&section=renewals&renewal=renewal-passport"

    adult_b_preview = await client.get("/api/reminders/preview", headers=adult_b_headers)
    assert adult_b_preview.status_code == 200
    assert all(item["kind"] != "renewal" for item in adult_b_preview.json())


async def test_affected_adult_receives_event_reminder(
    client, adult_a_headers, adult_a_user, adult_b_user, child1
):
    start = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
    response = await client.post(
        "/api/calendar/",
        json={
            "title": "Morgan takes Child One to the doctor",
            "start_time": start,
            "family_member_ids": [adult_b_user["id"], child1["id"]],
            "affected_member_ids": [adult_a_user["id"]],
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 201

    preview = await client.get("/api/reminders/preview", headers=adult_a_headers)
    assert "Morgan takes Child One to the doctor" in {item["title"] for item in preview.json()}


async def test_push_subscription_is_encrypted_and_scoped(client, adult_a_headers, adult_a_user, initialized_db, monkeypatch):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    settings.web_push_vapid_private_key = "/tmp/test-vapid.pem"
    settings.web_push_vapid_public_key = "public-key"
    async def safe_url(value):
        return value, "push.example"
    monkeypatch.setattr("app.routers.reminders.validate_public_https_url", safe_url)
    payload = {"endpoint": "https://push.example/subscription/123456789", "p256dh": "p" * 80, "auth": "a" * 24}
    response = await client.post("/api/reminders/push/subscriptions", json=payload, headers=adult_a_headers)
    assert response.status_code == 200
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute("SELECT * FROM web_push_subscriptions")).fetchone()
    assert payload["endpoint"] not in row["encrypted_subscription"]
    decoded = json.loads(decrypt_value(row["encrypted_subscription"]))
    assert decoded["endpoint"] == payload["endpoint"]
    removed = await client.delete("/api/reminders/push/subscriptions", headers=adult_a_headers)
    assert removed.status_code == 204


async def test_apns_registration_is_encrypted_owner_scoped_and_revocable(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(settings, "ha_token_encryption_key", Fernet.generate_key().decode())
    monkeypatch.setattr(settings, "apns_team_id", "ABCDE12345")
    monkeypatch.setattr(settings, "apns_key_id", "A1B2C3D4E5")
    monkeypatch.setattr(settings, "apns_private_key_path", "/tmp/AuthKey_APNS.p8")
    monkeypatch.setattr(settings, "apns_bundle_id", "com.example.hausklar")
    token = "ab" * 32
    response = await client.post(
        "/api/reminders/apns/devices",
        json={
            "device_token": token,
            "environment": "sandbox",
            "app_version": "1.8",
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    assert response.json()["configured"] is True
    assert response.json()["registered"] is True
    digest = device_token_hash(token, "sandbox", "com.example.hausklar")
    assert response.json()["token_digest"] == digest

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute("SELECT * FROM apns_device_registrations")).fetchone()
    assert token not in row["encrypted_device_token"]
    assert decrypt_value(row["encrypted_device_token"]) == token
    assert row["user_id"] == adult_a_user["id"]

    adult_b_status = await client.get("/api/reminders/apns", headers=adult_b_headers)
    assert adult_b_status.status_code == 200
    assert adult_b_status.json()["registered"] is False
    removed = await client.delete(
        f"/api/reminders/apns/devices/{digest}", headers=adult_a_headers
    )
    assert removed.status_code == 204
    adult_a_status = await client.get("/api/reminders/apns", headers=adult_a_headers)
    assert adult_a_status.json()["registered"] is False


async def test_apns_registration_rejects_non_hex_token(client, adult_a_headers):
    response = await client.post(
        "/api/reminders/apns/devices",
        json={"device_token": "not-a-device-token" * 3, "environment": "production"},
        headers=adult_a_headers,
    )
    assert response.status_code == 422


async def test_apns_test_notification_uses_only_the_current_users_device(
    client, adult_a_headers, adult_a_user, initialized_db, monkeypatch
):
    monkeypatch.setattr(settings, "ha_token_encryption_key", Fernet.generate_key().decode())
    monkeypatch.setattr(settings, "apns_team_id", "ABCDE12345")
    monkeypatch.setattr(settings, "apns_key_id", "A1B2C3D4E5")
    monkeypatch.setattr(settings, "apns_private_key_path", "/tmp/AuthKey_APNS.p8")
    monkeypatch.setattr(settings, "apns_bundle_id", "com.example.hausklar")
    token = "cd" * 32
    registered = await client.post(
        "/api/reminders/apns/devices",
        json={"device_token": token, "environment": "production"},
        headers=adult_a_headers,
    )
    assert registered.status_code == 200
    calls = []

    async def capture(**kwargs):
        calls.append(kwargs)

    monkeypatch.setattr("app.routers.reminders.send_apns", capture)
    response = await client.post("/api/reminders/apns/test", headers=adult_a_headers)
    assert response.status_code == 200
    assert response.json() == {"delivered": 1}
    assert calls[0]["device_token"] == token
    assert calls[0]["environment"] == "production"
    assert calls[0]["payload"]["url"] == "/?view=today"


async def test_dispatch_sends_apns_event_once_and_preserves_privacy(
    initialized_db, adult_a_user, monkeypatch
):
    monkeypatch.setattr(settings, "ha_token_encryption_key", Fernet.generate_key().decode())
    monkeypatch.setattr(settings, "web_push_vapid_private_key", "")
    monkeypatch.setattr(settings, "web_push_vapid_public_key", "")
    monkeypatch.setattr(settings, "apns_team_id", "ABCDE12345")
    monkeypatch.setattr(settings, "apns_key_id", "A1B2C3D4E5")
    monkeypatch.setattr(settings, "apns_private_key_path", "/tmp/AuthKey_APNS.p8")
    monkeypatch.setattr(settings, "apns_bundle_id", "com.example.hausklar")
    now = datetime.now(timezone.utc)
    start = (now + timedelta(minutes=30)).replace(microsecond=0).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO reminder_preferences
               (id,user_id,family_id,quiet_start,quiet_end,privacy_mode,created_by)
               VALUES (?,?,?,?,?,1,?)""",
            ("apns-pref", adult_a_user["id"], adult_a_user["family_id"], "23:59", "00:01", adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO apns_device_registrations
               (id,user_id,family_id,token_hash,encrypted_device_token,environment,
                bundle_id,last_registered_at,created_by)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (
                "apns-device",
                adult_a_user["id"],
                adult_a_user["family_id"],
                "apns-hash",
                encrypt_value("ef" * 32),
                "production",
                "com.example.hausklar",
                now.isoformat(),
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO calendar_events
               (id,title,start_time,all_day,family_id,created_by)
               VALUES (?,?,?,?,?,?)""",
            ("apns-event", "Private appointment", start, 0, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()
    calls = []

    async def capture(**kwargs):
        calls.append(kwargs)

    monkeypatch.setattr("app.services.reminders.send_apns", capture)
    await dispatch_due_reminders()
    await dispatch_due_reminders()
    event_calls = [call for call in calls if call["payload"]["tag"] == "hausklar-event"]
    assert len(event_calls) == 1
    assert event_calls[0]["device_token"] == "ef" * 32
    assert event_calls[0]["payload"]["title"] == "Upcoming event"
    assert event_calls[0]["payload"]["body"] == "Starts in 30 minutes"
    assert "Private appointment" not in event_calls[0]["payload"]["body"]
    async with aiosqlite.connect(initialized_db) as db:
        deliveries = await (
            await db.execute(
                "SELECT COUNT(*) FROM reminder_deliveries "
                "WHERE subscription_id='apns-device' AND reminder_key LIKE 'event:%'"
            )
        ).fetchone()
    assert deliveries[0] == 1


async def test_dispatch_retires_an_unregistered_apns_device(
    initialized_db, adult_a_user, monkeypatch
):
    monkeypatch.setattr(settings, "ha_token_encryption_key", Fernet.generate_key().decode())
    monkeypatch.setattr(settings, "web_push_vapid_private_key", "")
    monkeypatch.setattr(settings, "web_push_vapid_public_key", "")
    monkeypatch.setattr(settings, "apns_team_id", "ABCDE12345")
    monkeypatch.setattr(settings, "apns_key_id", "A1B2C3D4E5")
    monkeypatch.setattr(settings, "apns_private_key_path", "/tmp/AuthKey_APNS.p8")
    monkeypatch.setattr(settings, "apns_bundle_id", "com.example.hausklar")
    now = datetime.now(timezone.utc)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO reminder_preferences
               (id,user_id,family_id,quiet_start,quiet_end,created_by)
               VALUES (?,?,?,?,?,?)""",
            ("dead-pref", adult_a_user["id"], adult_a_user["family_id"], "23:59", "00:01", adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO apns_device_registrations
               (id,user_id,family_id,token_hash,encrypted_device_token,environment,
                bundle_id,last_registered_at,created_by)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (
                "dead-device",
                adult_a_user["id"],
                adult_a_user["family_id"],
                "dead-hash",
                encrypt_value("12" * 32),
                "production",
                "com.example.hausklar",
                now.isoformat(),
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO family_insights
               (id,kind,message,target_date,status,family_id,created_at,created_by)
               VALUES (?,?,?,?,?,?,?,?)""",
            (
                "dead-device-insight",
                "prep",
                "Pack school kit",
                now.date().isoformat(),
                "active",
                adult_a_user["family_id"],
                now.isoformat(),
                "school-brain",
            ),
        )
        await db.commit()

    async def reject(**kwargs):
        raise APNSDeliveryError(410, "Unregistered")

    monkeypatch.setattr("app.services.reminders.send_apns", reject)
    await dispatch_due_reminders()
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT deleted_at,last_error_code FROM apns_device_registrations "
                "WHERE id='dead-device'"
            )
        ).fetchone()
    assert row[0] is not None
    assert row[1] == "Unregistered"


async def test_removing_one_push_endpoint_preserves_the_users_other_devices(
    client, adult_a_headers, adult_a_user, initialized_db, monkeypatch
):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    settings.web_push_vapid_private_key = "/tmp/test-vapid.pem"
    settings.web_push_vapid_public_key = "public-key"

    async def safe_url(value):
        return value, "push.example"

    monkeypatch.setattr("app.routers.reminders.validate_public_https_url", safe_url)
    first = {"endpoint": "https://push.example/device/mac", "p256dh": "p" * 80, "auth": "a" * 24}
    second = {"endpoint": "https://push.example/device/phone", "p256dh": "q" * 80, "auth": "b" * 24}
    assert (await client.post("/api/reminders/push/subscriptions", json=first, headers=adult_a_headers)).status_code == 200
    assert (await client.post("/api/reminders/push/subscriptions", json=second, headers=adult_a_headers)).status_code == 200

    removed = await client.delete(
        f"/api/reminders/push/subscriptions/{endpoint_hash(first['endpoint'])}",
        headers=adult_a_headers,
    )
    assert removed.status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT endpoint_hash,deleted_at FROM web_push_subscriptions WHERE user_id=?",
                (adult_a_user["id"],),
            )
        ).fetchall()
    states = {row[0]: row[1] for row in rows}
    assert states[endpoint_hash(first["endpoint"])] is not None
    assert states[endpoint_hash(second["endpoint"])] is None


def test_quiet_hours_handles_overnight_window():
    assert in_quiet_hours(datetime(2026, 7, 12, 22, 0), "21:00", "07:00")
    assert in_quiet_hours(datetime(2026, 7, 12, 6, 0), "21:00", "07:00")
    assert not in_quiet_hours(datetime(2026, 7, 12, 12, 0), "21:00", "07:00")


def test_scheduler_window_recovers_brief_downtime_without_running_all_day():
    assert due_in_window(datetime(2026, 7, 12, 9, 0), "09:00")
    assert due_in_window(datetime(2026, 7, 12, 9, 14, 59), "09:00")
    assert not due_in_window(datetime(2026, 7, 12, 8, 59, 59), "09:00")
    assert not due_in_window(datetime(2026, 7, 12, 9, 15), "09:00")


async def test_dispatch_sends_zulu_event_once(initialized_db, adult_a_user, monkeypatch):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    settings.web_push_vapid_private_key = "/tmp/test-vapid.pem"
    settings.web_push_vapid_public_key = "p" * 65
    now = datetime.now(timezone.utc)
    start = (now + timedelta(minutes=30)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    encrypted = encrypt_value(json.dumps({"endpoint": "https://push.example/id", "keys": {"p256dh": "p" * 80, "auth": "a" * 24}}))
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute("""INSERT INTO reminder_preferences
            (id,user_id,family_id,quiet_start,quiet_end,created_by) VALUES (?,?,?,?,?,?)""",
            ("pref", adult_a_user["id"], adult_a_user["family_id"], "23:59", "00:01", adult_a_user["id"]))
        await db.execute("""INSERT INTO web_push_subscriptions
            (id,user_id,family_id,endpoint_hash,encrypted_subscription,created_by) VALUES (?,?,?,?,?,?)""",
            ("subscription", adult_a_user["id"], adult_a_user["family_id"], "hash", encrypted, adult_a_user["id"]))
        await db.execute("""INSERT INTO calendar_events
            (id,title,start_time,all_day,family_id,created_by) VALUES (?,?,?,?,?,?)""",
            ("event", "School pickup", start, 0, adult_a_user["family_id"], adult_a_user["id"]))
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
    event_notifications = [item for item in sent if item["tag"] == "hausklar-event"]
    assert len(event_notifications) == 1
    assert event_notifications[0]["title"] == "Upcoming event"
    assert event_notifications[0]["body"] == "Starts in 30 minutes"
    async with aiosqlite.connect(initialized_db) as db:
        assert (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM reminder_deliveries "
                    "WHERE reminder_key LIKE 'event:%'"
                )
            ).fetchone()
        )[0] == 1


async def test_dispatch_notifies_new_document_with_pending_suggestions_once(
    initialized_db, adult_a_user, monkeypatch
):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    settings.web_push_vapid_private_key = "/tmp/test-vapid.pem"
    settings.web_push_vapid_public_key = "p" * 65
    now = datetime.now(timezone.utc)
    encrypted = encrypt_value(json.dumps({"endpoint": "https://push.example/id", "keys": {"p256dh": "p" * 80, "auth": "a" * 24}}))
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute("""INSERT INTO reminder_preferences
            (id,user_id,family_id,quiet_start,quiet_end,privacy_mode,created_by) VALUES (?,?,?,?,?,0,?)""",
            ("pref", adult_a_user["id"], adult_a_user["family_id"], "23:59", "00:01", adult_a_user["id"]))
        await db.execute("""INSERT INTO web_push_subscriptions
            (id,user_id,family_id,endpoint_hash,encrypted_subscription,created_by) VALUES (?,?,?,?,?,?)""",
            ("subscription", adult_a_user["id"], adult_a_user["family_id"], "hash", encrypted, adult_a_user["id"]))
        await db.execute("""INSERT INTO documents
            (id,title,original_filename,media_type,storage_key,file_size,sha256,source,category,status,family_id,created_at,created_by)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            ("push-doc", "School letter", "letter.pdf", "application/pdf", "key", 10, "s" * 64,
             "file", "school", "inbox", adult_a_user["family_id"], now.isoformat(), adult_a_user["id"]))
        await db.execute("""INSERT INTO capture_suggestions
            (id,document_id,kind,title,start_time,all_day,status,family_id,created_by)
            VALUES (?,?,?,?,?,?,?,?,?)""",
            ("push-suggestion", "push-doc", "event", "Sports day", "2026-07-17", 1, "pending",
             adult_a_user["family_id"], adult_a_user["id"]))
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
    document_pushes = [payload for payload in sent if payload["tag"] == "hausklar-document"]
    assert len(document_pushes) == 1
    assert "School letter" in document_pushes[0]["body"]
    assert document_pushes[0]["url"] == "/?view=documents&document=push-doc"


async def test_dispatch_notifies_new_insights_once(initialized_db, adult_a_user, monkeypatch):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    settings.web_push_vapid_private_key = "/tmp/test-vapid.pem"
    settings.web_push_vapid_public_key = "p" * 65
    now = datetime.now(timezone.utc)
    encrypted = encrypt_value(json.dumps({"endpoint": "https://push.example/id", "keys": {"p256dh": "p" * 80, "auth": "a" * 24}}))
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute("""INSERT INTO reminder_preferences
            (id,user_id,family_id,quiet_start,quiet_end,privacy_mode,created_by) VALUES (?,?,?,?,?,0,?)""",
            ("pref", adult_a_user["id"], adult_a_user["family_id"], "23:59", "00:01", adult_a_user["id"]))
        await db.execute("""INSERT INTO web_push_subscriptions
            (id,user_id,family_id,endpoint_hash,encrypted_subscription,created_by) VALUES (?,?,?,?,?,?)""",
            ("subscription", adult_a_user["id"], adult_a_user["family_id"], "hash", encrypted, adult_a_user["id"]))
        await db.execute("""INSERT INTO family_insights
            (id,kind,message,target_date,status,family_id,created_at,created_by) VALUES (?,?,?,?,?,?,?,?)""",
            ("push-insight", "prep", "Swimming tomorrow but no kit-packing task",
             (now + timedelta(days=1)).date().isoformat(), "active",
             adult_a_user["family_id"], now.isoformat(), "school-brain"))
        await db.execute("""INSERT INTO family_insights
            (id,kind,message,target_date,status,family_id,created_at,created_by) VALUES (?,?,?,?,?,?,?,?)""",
            ("old-insight", "weather", "Rain forecast for forest school",
             (now + timedelta(days=2)).date().isoformat(), "active",
             adult_a_user["family_id"], (now - timedelta(hours=48)).isoformat(), "school-brain"))
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
    insight_pushes = [payload for payload in sent if payload["tag"] == "hausklar-insight"]
    assert len(insight_pushes) == 1
    assert insight_pushes[0]["title"] == "HausKlar noticed something"
    assert insight_pushes[0]["body"] == "Swimming tomorrow but no kit-packing task"
    assert insight_pushes[0]["url"] == "/?view=today"

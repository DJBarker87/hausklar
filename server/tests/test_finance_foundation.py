import asyncio

import aiosqlite
import pytest

from app.database import init_db, standalone_db
from app.services.finance.foundation import (
    accessible_finance_spaces,
    get_finance_settings,
    require_finance_space,
)


@pytest.mark.asyncio
async def test_family_adult_can_open_finance_without_an_entitlement(client, adult_a_headers):
    response = await client.get("/api/finance/spaces", headers=adult_a_headers)

    assert response.status_code == 200
    assert [item["kind"] for item in response.json()] == ["personal", "household"]


@pytest.mark.asyncio
async def test_each_adult_sees_only_own_personal_and_household_spaces(
    client,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_response = await client.get("/api/finance/spaces", headers=adult_a_headers)
    assert adult_a_response.status_code == 200
    assert [item["kind"] for item in adult_a_response.json()] == ["personal", "household"]
    assert adult_a_response.json()[0]["name"] == "My finances"
    assert adult_a_response.json()[0]["is_default"] is True
    assert adult_a_response.json()[1]["name"] == "Household"
    assert adult_a_response.json()[1]["is_default"] is False

    adult_b_response = await client.get("/api/finance/spaces", headers=adult_b_headers)
    assert adult_b_response.status_code == 200
    adult_a_spaces = {item["kind"]: item["id"] for item in adult_a_response.json()}
    adult_b_spaces = {item["kind"]: item["id"] for item in adult_b_response.json()}
    assert adult_b_spaces["household"] == adult_a_spaces["household"]
    assert adult_b_spaces["personal"] != adult_a_spaces["personal"]
    assert adult_a_spaces["personal"] not in {item["id"] for item in adult_b_response.json()}

    repeated = await client.get("/api/finance/spaces", headers=adult_a_headers)
    assert repeated.json() == adult_a_response.json()


@pytest.mark.asyncio
async def test_established_finance_space_reads_do_not_compete_for_writer_lock(
    initialized_db,
    adult_a_user,
):
    async with standalone_db(initialized_db) as setup_db:
        initial = await accessible_finance_spaces(setup_db, user=adult_a_user)
    assert [space.kind for space in initial] == ["personal", "household"]

    async with (
        standalone_db(initialized_db) as writer_db,
        standalone_db(initialized_db) as reader_db,
    ):
        await writer_db.execute("BEGIN IMMEDIATE")
        await reader_db.execute("PRAGMA busy_timeout=50")
        repeated = await asyncio.wait_for(
            accessible_finance_spaces(reader_db, user=adult_a_user),
            timeout=0.5,
        )
        required = await asyncio.wait_for(
            require_finance_space(
                reader_db,
                user=adult_a_user,
                space_id=initial[0].id,
            ),
            timeout=0.5,
        )
        settings = await asyncio.wait_for(
            get_finance_settings(reader_db, user=adult_a_user),
            timeout=0.5,
        )

    assert [space.id for space in repeated] == [space.id for space in initial]
    assert required["id"] == initial[0].id
    assert settings.personal_space_id == initial[0].id


@pytest.mark.asyncio
async def test_finance_settings_use_household_timezone_without_exposing_partner_space(
    client,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_settings = (await client.get("/api/finance/settings", headers=adult_a_headers)).json()
    adult_b_settings = (await client.get("/api/finance/settings", headers=adult_b_headers)).json()

    assert adult_a_settings["id"] == adult_b_settings["id"]
    assert adult_a_settings["household_timezone"] == "Europe/London"
    assert adult_a_settings["default_currency"] == "GBP"
    assert adult_a_settings["household_space_id"] == adult_b_settings["household_space_id"]
    assert adult_a_settings["personal_space_id"] != adult_b_settings["personal_space_id"]


@pytest.mark.asyncio
async def test_user_profile_has_no_finance_entitlement(client, adult_a_headers):
    profile = await client.get("/api/auth/me", headers=adult_a_headers)

    assert profile.status_code == 200
    assert "finance_enabled" not in profile.json()


@pytest.mark.asyncio
async def test_manual_account_creation_saves_a_dated_current_balance(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    personal = next(item["id"] for item in spaces if item["kind"] == "personal")

    created = await client.post(
        "/api/finance/accounts",
        params={"space_id": personal},
        json={
            "label": "Manual current",
            "institution": "Local bank",
            "account_type": "CURRENT",
            "currency": "GBP",
            "current_balance_minor": 123_456,
            "balance_observed_at": "2026-08-01T09:15:00+01:00",
        },
        headers=adult_a_headers,
    )

    assert created.status_code == 201, created.text
    account = created.json()
    assert account["provider_presence_status"] == "ACTIVE"
    assert account["balance"] == {
        "booked_minor": 123_456,
        "available_minor": None,
        "credit_limit_minor": None,
        "provider_at": None,
        "observed_at": "2026-08-01T08:15:00+00:00",
    }

    undated = await client.post(
        "/api/finance/accounts",
        params={"space_id": personal},
        json={
            "label": "Undated",
            "account_type": "CASH",
            "currency": "GBP",
            "current_balance_minor": 2_000,
            "balance_observed_at": "2026-08-01T09:15:00",
        },
        headers=adult_a_headers,
    )
    assert undated.status_code == 422


@pytest.mark.asyncio
async def test_finance_schema_is_idempotent_and_has_audit_columns(initialized_db):
    # Simulate an installation created before the entitlement was removed.
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "ALTER TABLE users ADD COLUMN finance_enabled INTEGER NOT NULL DEFAULT 0"
        )
        await db.commit()

    await init_db(initialized_db)
    await init_db(initialized_db)

    expected_audit_columns = {
        "id",
        "created_at",
        "updated_at",
        "created_by",
        "client_id",
        "client_timestamp",
        "deleted_at",
    }
    async with aiosqlite.connect(initialized_db) as db:
        user_columns = {
            row[1] for row in await (await db.execute("PRAGMA table_info(users)")).fetchall()
        }
        assert "finance_enabled" not in user_columns
        for table in ("finance_spaces", "finance_settings"):
            columns = {
                row[1]
                for row in await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
            }
            assert expected_audit_columns <= columns

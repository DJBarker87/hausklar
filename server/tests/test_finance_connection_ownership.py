import aiosqlite
import pytest


@pytest.mark.asyncio
async def test_household_bank_connection_marks_only_its_owner_as_manager(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_spaces = (
        await client.get("/api/finance/spaces", headers=adult_a_headers)
    ).json()
    adult_b_spaces = (
        await client.get("/api/finance/spaces", headers=adult_b_headers)
    ).json()
    household_id = next(
        space["id"] for space in adult_a_spaces if space["kind"] == "household"
    )
    assert household_id == next(
        space["id"] for space in adult_b_spaces if space["kind"] == "household"
    )

    connection_id = "dom-household-bank"
    now = "2026-08-03T10:00:00+00:00"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO finance_connections
                (id, space_id, provider, institution_id, status,
                 granted_capabilities, last_error_code, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, 'TRUELAYER', 'GB:Family Bank', 'EXPIRED',
                    '["accounts","balances","transactions"]', 'CONSENT_EXPIRED',
                    ?, ?, ?, ?)
            """,
            (
                connection_id,
                household_id,
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.commit()

    owner_response = await client.get(
        "/api/finance/connections",
        params={"space_id": household_id},
        headers=adult_a_headers,
    )
    other_adult_response = await client.get(
        "/api/finance/connections",
        params={"space_id": household_id},
        headers=adult_b_headers,
    )

    assert owner_response.status_code == 200, owner_response.text
    assert other_adult_response.status_code == 200, other_adult_response.text
    assert owner_response.json()[0]["can_manage"] is True
    assert other_adult_response.json()[0]["can_manage"] is False
    assert "created_by" not in other_adult_response.json()[0]

    other_adult_sync = await client.post(
        f"/api/finance/connections/{connection_id}/sync",
        headers=adult_b_headers,
    )
    other_adult_disconnect = await client.delete(
        f"/api/finance/connections/{connection_id}",
        headers=adult_b_headers,
    )

    assert other_adult_sync.status_code == 404
    assert other_adult_disconnect.status_code == 404

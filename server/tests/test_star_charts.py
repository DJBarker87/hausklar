"""Tests for the star charts router (/api/star-charts)."""

import asyncio

import aiosqlite

# ===========================================================================
# Chart CRUD (5 tests)
# ===========================================================================


async def test_create_chart_with_defaults(client, adult_a_headers, child1):
    """POST /api/star-charts/ creates a chart with default values."""
    resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["child_id"] == child1["id"]
    assert data["title"] == "Star Chart"
    assert data["grid_rows"] == 5
    assert data["grid_columns"] == 5
    assert data["reward_amount_pence"] == 500
    assert data["completed_at"] is None
    assert data["stars_count"] == 0
    assert data["total_cells"] == 25
    assert data["stars"] == []


async def test_list_charts_by_child(client, adult_a_headers, child1, child2):
    """GET /api/star-charts/?child_id= filters by child."""
    await client.post("/api/star-charts/", json={"child_id": child1["id"]}, headers=adult_a_headers)
    await client.post("/api/star-charts/", json={"child_id": child2["id"]}, headers=adult_a_headers)

    resp = await client.get(f"/api/star-charts/?child_id={child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 1
    assert data[0]["child_id"] == child1["id"]


async def test_list_active_charts_only(client, adult_a_headers, child1):
    """GET /api/star-charts/?active=true returns only uncompleted charts."""
    # Create a 1x1 chart and complete it
    resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"], "grid_rows": 1, "grid_columns": 1, "reward_amount_pence": 100},
        headers=adult_a_headers,
    )
    chart_id = resp.json()["id"]
    await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)

    # Create active chart
    await client.post("/api/star-charts/", json={"child_id": child1["id"]}, headers=adult_a_headers)

    resp = await client.get(f"/api/star-charts/?child_id={child1['id']}&active=true", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 1
    assert data[0]["completed_at"] is None


async def test_update_chart_settings(client, adult_a_headers, child1):
    """PUT /api/star-charts/{id} updates title and reward."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    resp = await client.put(
        f"/api/star-charts/{chart_id}",
        json={"title": "Good Behaviour", "reward_amount_pence": 1000},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["title"] == "Good Behaviour"
    assert data["reward_amount_pence"] == 1000


async def test_soft_delete_chart(client, adult_a_headers, child1):
    """DELETE /api/star-charts/{id} soft-deletes the chart."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    resp = await client.delete(f"/api/star-charts/{chart_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    list_resp = await client.get(f"/api/star-charts/?child_id={child1['id']}", headers=adult_a_headers)
    assert len(list_resp.json()) == 0


# ===========================================================================
# Star placement (6 tests)
# ===========================================================================


async def test_place_star(client, adult_a_headers, child1):
    """POST /api/star-charts/{id}/stars places a star."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"], "grid_rows": 3, "grid_columns": 3},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    resp = await client.post(
        f"/api/star-charts/{chart_id}/stars",
        json={"row_index": 0, "col_index": 0},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["row_index"] == 0
    assert data["col_index"] == 0


async def test_duplicate_cell_409(client, adult_a_headers, child1):
    """Placing a star on an occupied cell returns 409."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)
    resp = await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)
    assert resp.status_code == 409


async def test_out_of_bounds_400(client, adult_a_headers, child1):
    """Placing a star outside grid bounds returns 400."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"], "grid_rows": 3, "grid_columns": 3},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    resp = await client.post(
        f"/api/star-charts/{chart_id}/stars",
        json={"row_index": 5, "col_index": 0},
        headers=adult_a_headers,
    )
    assert resp.status_code == 400


async def test_completed_chart_400(client, adult_a_headers, child1):
    """Placing a star on a completed chart returns 400."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"], "grid_rows": 1, "grid_columns": 1, "reward_amount_pence": 100},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    # Complete the chart
    await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)

    # Try to place another star
    resp = await client.post(
        f"/api/star-charts/{chart_id}/stars",
        json={"row_index": 0, "col_index": 0},
        headers=adult_a_headers,
    )
    assert resp.status_code == 400


async def test_remove_star(client, adult_a_headers, child1):
    """DELETE /api/star-charts/{id}/stars/{star_id} removes a star."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    star_resp = await client.post(
        f"/api/star-charts/{chart_id}/stars",
        json={"row_index": 0, "col_index": 0},
        headers=adult_a_headers,
    )
    star_id = star_resp.json()["id"]

    resp = await client.delete(f"/api/star-charts/{chart_id}/stars/{star_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    # Chart should have 0 stars
    chart_resp = await client.get(f"/api/star-charts/{chart_id}", headers=adult_a_headers)
    assert chart_resp.json()["stars_count"] == 0


async def test_remove_star_uncompletes_chart(client, adult_a_headers, child1):
    """Removing a star from a completed chart un-completes it."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"], "grid_rows": 1, "grid_columns": 2, "reward_amount_pence": 100},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    # Fill both cells
    await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)
    star_resp = await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 1}, headers=adult_a_headers)

    # Verify completed
    chart_resp = await client.get(f"/api/star-charts/{chart_id}", headers=adult_a_headers)
    assert chart_resp.json()["completed_at"] is not None

    # Remove a star
    # The last star placed might be in the completion response
    star_id = star_resp.json()["chart"]["stars"][-1]["id"]
    await client.delete(f"/api/star-charts/{chart_id}/stars/{star_id}", headers=adult_a_headers)

    # Chart should be un-completed
    chart_resp = await client.get(f"/api/star-charts/{chart_id}", headers=adult_a_headers)
    assert chart_resp.json()["completed_at"] is None


# ===========================================================================
# Completion (3 tests)
# ===========================================================================


async def test_final_star_completes_chart(client, adult_a_headers, child1):
    """Placing the final star completes the chart."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"], "grid_rows": 1, "grid_columns": 2, "reward_amount_pence": 250},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)
    resp = await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 1}, headers=adult_a_headers)

    assert resp.status_code == 201
    data = resp.json()
    assert "chart" in data
    assert data["chart"]["completed_at"] is not None
    assert data["reward_amount_pence"] == 250


async def test_completion_credits_balance(client, adult_a_headers, child1):
    """Completing a chart credits the child's balance."""
    # Check initial balance is 0
    balance_resp = await client.get(f"/api/star-charts/balance/{child1['id']}", headers=adult_a_headers)
    assert balance_resp.json()["balance_pence"] == 0

    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"], "grid_rows": 1, "grid_columns": 1, "reward_amount_pence": 500},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]

    resp = await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)
    data = resp.json()
    assert data["new_balance_pence"] == 500
    assert data["new_balance_display"] == "\u00a35.00"


async def test_completion_creates_transaction(client, adult_a_headers, child1):
    """Completing a chart creates a balance transaction."""
    create_resp = await client.post(
        "/api/star-charts/",
        json={"child_id": child1["id"], "grid_rows": 1, "grid_columns": 1, "reward_amount_pence": 300},
        headers=adult_a_headers,
    )
    chart_id = create_resp.json()["id"]
    await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)

    txn_resp = await client.get(f"/api/star-charts/balance/{child1['id']}/transactions", headers=adult_a_headers)
    assert txn_resp.status_code == 200
    txns = txn_resp.json()
    assert len(txns) >= 1
    assert txns[0]["reason"] == "chart_completed"
    assert txns[0]["amount_pence"] == 300
    assert txns[0]["chart_id"] == chart_id


async def test_concurrent_final_star_credits_reward_once(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    create = await client.post(
        "/api/star-charts/",
        json={
            "child_id": child1["id"],
            "grid_rows": 1,
            "grid_columns": 1,
            "reward_amount_pence": 500,
        },
        headers=adult_a_headers,
    )
    chart_id = create.json()["id"]

    responses = await asyncio.gather(
        *[
            client.post(
                f"/api/star-charts/{chart_id}/stars",
                json={"row_index": 0, "col_index": 0},
                headers=adult_a_headers,
            )
            for _ in range(2)
        ]
    )

    assert sum(response.status_code == 201 for response in responses) == 1
    assert all(response.status_code in {201, 400, 409} for response in responses)
    async with aiosqlite.connect(initialized_db) as db:
        stars = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM star_chart_stars "
                    "WHERE chart_id = ? AND deleted_at IS NULL",
                    (chart_id,),
                )
            ).fetchone()
        )[0]
        transactions = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM star_chart_balance_transactions "
                    "WHERE chart_id = ? AND deleted_at IS NULL",
                    (chart_id,),
                )
            ).fetchone()
        )[0]
        balance = (
            await (
                await db.execute(
                    "SELECT balance_pence FROM star_chart_balances WHERE child_id = ?",
                    (child1["id"],),
                )
            ).fetchone()
        )[0]

    assert stars == 1
    assert transactions == 1
    assert balance == 500


async def test_removing_completed_star_reverses_reward_before_recompletion(
    client,
    adult_a_headers,
    child1,
):
    create = await client.post(
        "/api/star-charts/",
        json={
            "child_id": child1["id"],
            "grid_rows": 1,
            "grid_columns": 1,
            "reward_amount_pence": 250,
        },
        headers=adult_a_headers,
    )
    chart_id = create.json()["id"]
    completed = await client.post(
        f"/api/star-charts/{chart_id}/stars",
        json={"row_index": 0, "col_index": 0},
        headers=adult_a_headers,
    )
    star_id = completed.json()["chart"]["stars"][0]["id"]

    removed = await client.delete(
        f"/api/star-charts/{chart_id}/stars/{star_id}",
        headers=adult_a_headers,
    )
    after_removal = await client.get(
        f"/api/star-charts/balance/{child1['id']}",
        headers=adult_a_headers,
    )
    history_after_removal = await client.get(
        f"/api/star-charts/balance/{child1['id']}/transactions",
        headers=adult_a_headers,
    )
    completed_again = await client.post(
        f"/api/star-charts/{chart_id}/stars",
        json={"row_index": 0, "col_index": 0},
        headers=adult_a_headers,
    )
    history_after_recompletion = await client.get(
        f"/api/star-charts/balance/{child1['id']}/transactions",
        headers=adult_a_headers,
    )

    assert removed.status_code == 204
    assert after_removal.json()["balance_pence"] == 0
    assert {
        (item["reason"], item["amount_pence"])
        for item in history_after_removal.json()
        if item["chart_id"] == chart_id
    } == {("manual_adjustment", 250), ("manual_adjustment", -250)}
    assert completed_again.status_code == 201
    assert completed_again.json()["new_balance_pence"] == 250
    matching = [
        (item["reason"], item["amount_pence"])
        for item in history_after_recompletion.json()
        if item["chart_id"] == chart_id
    ]
    assert matching.count(("chart_completed", 250)) == 1
    assert matching.count(("manual_adjustment", 250)) == 1
    assert matching.count(("manual_adjustment", -250)) == 1


# ===========================================================================
# Balance (4 tests)
# ===========================================================================


async def test_get_balance_default_zero(client, adult_a_headers, child1):
    """GET /api/star-charts/balance/{child_id} returns 0 by default."""
    resp = await client.get(f"/api/star-charts/balance/{child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["balance_pence"] == 0
    assert data["balance_display"] == "\u00a30.00"


async def test_adjust_balance_add(client, adult_a_headers, child1):
    """POST /api/star-charts/balance/{child_id}/adjust adds to balance."""
    resp = await client.post(
        f"/api/star-charts/balance/{child1['id']}/adjust",
        json={"amount_pence": 200, "reason": "manual_adjustment", "notes": "Bonus"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["balance_pence"] == 200


async def test_adjust_balance_is_idempotent_on_client_id(client, adult_a_headers, child1):
    """A retried adjustment with the same client_id must not credit twice."""
    payload = {
        "amount_pence": 300,
        "reason": "manual_adjustment",
        "client_id": "retry-token-1",
        "client_timestamp": "2026-07-12T10:00:00Z",
    }
    first = await client.post(
        f"/api/star-charts/balance/{child1['id']}/adjust", json=payload, headers=adult_a_headers
    )
    assert first.status_code == 200
    assert first.json()["balance_pence"] == 300

    # Same client_id → treated as a duplicate, balance unchanged.
    retry = await client.post(
        f"/api/star-charts/balance/{child1['id']}/adjust", json=payload, headers=adult_a_headers
    )
    assert retry.status_code == 200
    assert retry.json()["balance_pence"] == 300

    transactions = await client.get(
        f"/api/star-charts/balance/{child1['id']}/transactions", headers=adult_a_headers
    )
    assert transactions.status_code == 200
    matching = [t for t in transactions.json() if t.get("amount_pence") == 300]
    assert len(matching) == 1


async def test_adjust_balance_subtract(client, adult_a_headers, child1):
    """POST /api/star-charts/balance/{child_id}/adjust subtracts from balance."""
    # Add first
    await client.post(
        f"/api/star-charts/balance/{child1['id']}/adjust",
        json={"amount_pence": 500, "reason": "manual_adjustment"},
        headers=adult_a_headers,
    )
    # Subtract
    resp = await client.post(
        f"/api/star-charts/balance/{child1['id']}/adjust",
        json={"amount_pence": -200, "reason": "payout", "notes": "Pocket money"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["balance_pence"] == 300


async def test_concurrent_balance_adjustments_are_not_lost(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    responses = await asyncio.gather(
        client.post(
            f"/api/star-charts/balance/{child1['id']}/adjust",
            json={"amount_pence": 125, "reason": "manual_adjustment"},
            headers=adult_a_headers,
        ),
        client.post(
            f"/api/star-charts/balance/{child1['id']}/adjust",
            json={"amount_pence": 275, "reason": "manual_adjustment"},
            headers=adult_a_headers,
        ),
    )

    assert [response.status_code for response in responses] == [200, 200]
    async with aiosqlite.connect(initialized_db) as db:
        balance = (
            await (
                await db.execute(
                    "SELECT balance_pence FROM star_chart_balances WHERE child_id = ?",
                    (child1["id"],),
                )
            ).fetchone()
        )[0]
        transactions = await (
            await db.execute(
                "SELECT amount_pence FROM star_chart_balance_transactions "
                "WHERE child_id = ? AND deleted_at IS NULL ORDER BY amount_pence",
                (child1["id"],),
            )
        ).fetchall()

    assert balance == 400
    assert [row[0] for row in transactions] == [125, 275]


async def test_transaction_history(client, adult_a_headers, child1):
    """GET /api/star-charts/balance/{child_id}/transactions returns history."""
    await client.post(
        f"/api/star-charts/balance/{child1['id']}/adjust",
        json={"amount_pence": 100, "reason": "manual_adjustment"},
        headers=adult_a_headers,
    )
    await client.post(
        f"/api/star-charts/balance/{child1['id']}/adjust",
        json={"amount_pence": -50, "reason": "payout"},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/star-charts/balance/{child1['id']}/transactions", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 2


# ===========================================================================
# Multi-chart (2 tests)
# ===========================================================================


async def test_multiple_charts_per_child(client, adult_a_headers, child1):
    """A child can have multiple active charts."""
    await client.post("/api/star-charts/", json={"child_id": child1["id"], "title": "Chart A"}, headers=adult_a_headers)
    await client.post("/api/star-charts/", json={"child_id": child1["id"], "title": "Chart B"}, headers=adult_a_headers)

    resp = await client.get(f"/api/star-charts/?child_id={child1['id']}", headers=adult_a_headers)
    assert len(resp.json()) == 2


async def test_balance_accumulates(client, adult_a_headers, child1):
    """Balance accumulates across completed charts."""
    for i in range(2):
        create_resp = await client.post(
            "/api/star-charts/",
            json={"child_id": child1["id"], "grid_rows": 1, "grid_columns": 1, "reward_amount_pence": 200},
            headers=adult_a_headers,
        )
        chart_id = create_resp.json()["id"]
        await client.post(f"/api/star-charts/{chart_id}/stars", json={"row_index": 0, "col_index": 0}, headers=adult_a_headers)

    balance_resp = await client.get(f"/api/star-charts/balance/{child1['id']}", headers=adult_a_headers)
    assert balance_resp.json()["balance_pence"] == 400

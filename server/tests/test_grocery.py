"""Tests for grocery replenishment endpoints (/api/grocery)."""

import hashlib
import io
import json
import zipfile

import aiosqlite


async def test_grocery_item_crud_and_import(client, adult_a_headers):
    create_resp = await client.post(
        "/api/grocery/items",
        json={
            "name": "Chicken breast",
            "category": "meat",
            "default_unit": "pack",
            "aliases": ["chicken fillets"],
            "is_use_by_tracked": True,
            "default_quantity": 2,
        },
        headers=adult_a_headers,
    )
    assert create_resp.status_code == 201
    item = create_resp.json()
    assert item["name"] == "Chicken breast"
    assert item["is_use_by_tracked"] is True

    list_resp = await client.get("/api/grocery/items?category=meat", headers=adult_a_headers)
    assert list_resp.status_code == 200
    assert any(x["id"] == item["id"] for x in list_resp.json())

    import_resp = await client.post(
        "/api/grocery/import",
        json={"raw_text": "Tesco Chicken Fillets 650g\nUnknown thing"},
        headers=adult_a_headers,
    )
    assert import_resp.status_code == 200
    matches = import_resp.json()["matches"]
    assert matches[0]["matched_item_id"] == item["id"]
    assert matches[0]["needs_review"] is False
    assert matches[1]["needs_review"] is True


async def test_purchase_consumption_stock_expiry(client, adult_a_headers):
    item_resp = await client.post(
        "/api/grocery/items",
        json={"name": "Yoghurt", "category": "dairy", "is_use_by_tracked": True},
        headers=adult_a_headers,
    )
    item_id = item_resp.json()["id"]

    batch_resp = await client.post(
        "/api/grocery/batches",
        json={
            "purchased_at": "2026-02-10T10:00:00Z",
            "source": "tesco",
            "lines": [
                {
                    "grocery_item_id": item_id,
                    "qty": 6,
                    "unit": "each",
                    "use_by_date": "2026-02-17",
                    "storage": "fridge",
                }
            ],
        },
        headers=adult_a_headers,
    )
    assert batch_resp.status_code == 201
    line_id = batch_resp.json()["lines"][0]["id"]

    use_by_patch = await client.patch(
        f"/api/grocery/purchases/{line_id}/use-by",
        json={"use_by_date": "2026-02-18"},
        headers=adult_a_headers,
    )
    assert use_by_patch.status_code == 200
    assert use_by_patch.json()["use_by_date"] == "2026-02-18"

    consume_resp = await client.post(
        "/api/grocery/consumption",
        json={
            "grocery_item_id": item_id,
            "amount": 2,
            "unit": "each",
            "event_type": "consumed",
            "event_at": "2026-02-11T18:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert consume_resp.status_code == 201

    stock_resp = await client.get("/api/grocery/stock", headers=adult_a_headers)
    assert stock_resp.status_code == 200
    yoghurt = next(x for x in stock_resp.json() if x["grocery_item_id"] == item_id)
    assert yoghurt["remaining"] == 4


async def test_batch_and_consumption_reject_other_family_item(
    client,
    adult_a_headers,
    other_family_headers,
):
    other_item = await client.post(
        "/api/grocery/items",
        json={"name": "Private other-family item"},
        headers=other_family_headers,
    )
    item_id = other_item.json()["id"]

    batch = await client.post(
        "/api/grocery/batches",
        json={
            "purchased_at": "2026-02-10T10:00:00Z",
            "lines": [{"grocery_item_id": item_id, "qty": 1}],
        },
        headers=adult_a_headers,
    )
    consumption = await client.post(
        "/api/grocery/consumption",
        json={"grocery_item_id": item_id, "amount": 1},
        headers=adult_a_headers,
    )

    assert batch.status_code == 422
    assert consumption.status_code == 422
    assert "not available" in batch.json()["detail"]


async def test_grocery_suggestions_and_accept(client, adult_a_headers):
    item_resp = await client.post(
        "/api/grocery/items",
        json={"name": "Milk", "category": "dairy", "default_quantity": 2, "default_unit": "litre"},
        headers=adult_a_headers,
    )
    item_id = item_resp.json()["id"]

    await client.post(
        "/api/grocery/batches",
        json={
            "purchased_at": "2026-01-01T10:00:00Z",
            "source": "tesco",
            "lines": [{"grocery_item_id": item_id, "qty": 2, "unit": "litre"}],
        },
        headers=adult_a_headers,
    )

    for day in (2, 3, 4, 5, 6, 7, 8):
        await client.post(
            "/api/grocery/consumption",
            json={
                "grocery_item_id": item_id,
                "amount": 0.4,
                "unit": "litre",
                "event_type": "consumed",
                "event_at": f"2026-01-{day:02d}T19:00:00Z",
            },
            headers=adult_a_headers,
        )

    suggestions_resp = await client.get("/api/grocery/suggestions", headers=adult_a_headers)
    assert suggestions_resp.status_code == 200
    suggestions = suggestions_resp.json()["suggestions"]
    assert any(s["grocery_item_id"] == item_id for s in suggestions)

    accept_resp = await client.post(
        "/api/grocery/suggestions/accept",
        json={"grocery_item_ids": [item_id]},
        headers=adult_a_headers,
    )
    assert accept_resp.status_code == 200
    assert accept_resp.json()["created"] >= 1

    shopping = await client.get("/api/meals/shopping", headers=adult_a_headers)
    assert shopping.status_code == 200
    assert any(i["name"] == "Milk" for i in shopping.json())


async def test_grocery_suggestions_zero_usage_no_500(client, adult_a_headers):
    item_resp = await client.post(
        "/api/grocery/items",
        json={"name": "Crumpets", "category": "bakery", "default_quantity": 1, "default_unit": "pack"},
        headers=adult_a_headers,
    )
    assert item_resp.status_code == 201
    item_id = item_resp.json()["id"]

    batch_resp = await client.post(
        "/api/grocery/batches",
        json={
            "purchased_at": "2026-02-01T10:00:00Z",
            "source": "tesco",
            "lines": [{"grocery_item_id": item_id, "qty": 1, "unit": "pack"}],
        },
        headers=adult_a_headers,
    )
    assert batch_resp.status_code == 201

    suggestions_resp = await client.get("/api/grocery/suggestions", headers=adult_a_headers)
    assert suggestions_resp.status_code == 200
    suggestions = suggestions_resp.json()["suggestions"]
    assert any(s["grocery_item_id"] == item_id for s in suggestions)


async def test_freezer_add_and_list(client, adult_a_headers):
    add_resp = await client.post(
        "/api/grocery/freezer/add",
        json={"name": "Maultaschen", "qty": 5},
        headers=adult_a_headers,
    )
    assert add_resp.status_code == 201
    assert add_resp.json()["item_name"] == "Maultaschen"
    assert add_resp.json()["qty"] == 5

    add_resp2 = await client.post(
        "/api/grocery/freezer/add",
        json={"name": "Sausages", "qty": 4},
        headers=adult_a_headers,
    )
    assert add_resp2.status_code == 201

    list_resp = await client.get("/api/grocery/freezer", headers=adult_a_headers)
    assert list_resp.status_code == 200
    items = list_resp.json()
    names = [i["item_name"] for i in items]
    assert "Maultaschen" in names
    assert "Sausages" in names


async def test_critical_low_stock_alerts(client, adult_a_headers):
    item_resp = await client.post(
        "/api/grocery/items",
        json={"name": "Diet Coke", "category": "drinks", "default_unit": "each"},
        headers=adult_a_headers,
    )
    assert item_resp.status_code == 201
    coke_id = item_resp.json()["id"]

    batch_resp = await client.post(
        "/api/grocery/batches",
        json={
            "purchased_at": "2026-02-15T10:00:00Z",
            "source": "tesco",
            "lines": [{"grocery_item_id": coke_id, "qty": 4, "unit": "each"}],
        },
        headers=adult_a_headers,
    )
    assert batch_resp.status_code == 201

    consume_resp = await client.post(
        "/api/grocery/consumption",
        json={
            "grocery_item_id": coke_id,
            "amount": 1,
            "unit": "each",
            "event_type": "consumed",
            "event_at": "2026-02-15T20:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert consume_resp.status_code == 201

    alert_resp = await client.get("/api/grocery/critical-low", headers=adult_a_headers)
    assert alert_resp.status_code == 200
    alerts = alert_resp.json()
    coke_alert = next(x for x in alerts if x["grocery_item_id"] == coke_id)
    assert coke_alert["item_name"] == "Diet Coke"
    assert coke_alert["threshold"] == 4.0
    assert coke_alert["remaining"] == 3.0


def _tesco_export_bytes() -> bytes:
    return json.dumps(
        {
            "profile": {
                "email": "demo-person-25@example.invalid",
                "deliveryAddress": "Never store this address",
            },
            "transactionalRecords": [
                {
                    "orderReference": "TESCO-100",
                    "orderDate": "2026-01-03T10:30:00Z",
                    "channel": "Home delivery",
                    "orderTotal": "£4.40",
                    "items": [
                        {
                            "productId": "milk-4pt",
                            "productName": "Tesco British Whole Milk 4 Pints",
                            "quantity": 1,
                            "lineTotal": "£1.65",
                        },
                        {
                            "productName": "Tesco Bananas 5 Pack",
                            "quantity": 1,
                            "lineTotal": "£1.10",
                        },
                    ],
                },
                {
                    "transactionId": "TESCO-101",
                    "transactionDate": "2026-01-10T11:00:00Z",
                    "storeName": "Example Town",
                    "transactionTotal": 4.75,
                    "products": [
                        {
                            "productName": "Tesco British Whole Milk 4 Pints",
                            "quantity": 1,
                            "price": 1.85,
                        },
                        {
                            "productName": "Tesco Bananas 5 Pack",
                            "quantity": 1,
                            "price": 1.10,
                        },
                    ],
                },
            ],
        }
    ).encode()


async def test_tesco_history_preview_import_summary_and_idempotency(
    client,
    adult_a_headers,
    initialized_db,
    other_family_headers,
):
    data = _tesco_export_bytes()
    digest = hashlib.sha256(data).hexdigest()
    files = {"file": ("tesco-data.json", data, "application/json")}

    preview = await client.post(
        "/api/grocery/tesco-history/preview",
        files=files,
        headers=adult_a_headers,
    )
    assert preview.status_code == 200
    assert preview.json()["order_count"] == 2
    assert preview.json()["line_count"] == 4
    assert preview.json()["already_imported"] is False
    assert preview.json()["can_confirm"] is True

    imported = await client.post(
        "/api/grocery/tesco-history/import",
        files=files,
        data={"expected_sha256": digest},
        headers=adult_a_headers,
    )
    assert imported.status_code == 201
    assert imported.json()["imported"] is True
    assert imported.json()["imported_orders"] == 2
    assert imported.json()["skipped_orders"] == 0

    summary = await client.get(
        "/api/grocery/tesco-history/summary",
        headers=adult_a_headers,
    )
    assert summary.status_code == 200
    assert summary.json()["shop_count"] == 2
    assert summary.json()["line_count"] == 4
    assert summary.json()["price_rise_count"] == 1
    milk = next(item for item in summary.json()["usuals"] if "Milk" in item["name"])
    assert milk["shop_count"] == 2
    assert milk["latest_price_pence"] == 185
    assert milk["previous_price_pence"] == 165

    replay = await client.post(
        "/api/grocery/tesco-history/import",
        files=files,
        data={"expected_sha256": digest},
        headers=adult_a_headers,
    )
    assert replay.status_code == 201
    assert replay.json()["imported"] is False
    assert replay.json()["imported_orders"] == 0
    assert replay.json()["skipped_orders"] == 2

    private_summary = await client.get(
        "/api/grocery/tesco-history/summary",
        headers=other_family_headers,
    )
    assert private_summary.status_code == 200
    assert private_summary.json()["shop_count"] == 0

    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT product_name FROM tesco_history_lines ORDER BY product_name"
            )
        ).fetchall()
        assert rows
        stored_text = " ".join(value for row in rows for value in row)
        assert "demo-person-25@example.invalid" not in stored_text
        assert "Never store this address" not in stored_text


async def test_tesco_history_accepts_zip_and_rejects_changed_confirmation(
    client,
    adult_a_headers,
):
    report = _tesco_export_bytes()
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr("report/transactions.json", report)
    data = archive.getvalue()
    preview = await client.post(
        "/api/grocery/tesco-history/preview",
        files={"file": ("tesco.zip", data, "application/zip")},
        headers=adult_a_headers,
    )
    assert preview.status_code == 200
    assert preview.json()["order_count"] == 2

    changed = await client.post(
        "/api/grocery/tesco-history/import",
        files={"file": ("tesco.zip", data, "application/zip")},
        data={"expected_sha256": "0" * 64},
        headers=adult_a_headers,
    )
    assert changed.status_code == 409


async def test_tesco_history_rejects_unrecognised_json(client, adult_a_headers):
    response = await client.post(
        "/api/grocery/tesco-history/preview",
        files={
            "file": (
                "profile.json",
                json.dumps({"name": "Alex", "joined": "2020-01-01"}).encode(),
                "application/json",
            )
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 422
    assert "No Tesco shops were recognised" in response.json()["detail"]

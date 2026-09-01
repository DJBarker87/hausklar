import pytest

from app.services.finance.delivery_evidence import labelled_email_delivery_window


def test_labelled_email_delivery_window_requires_one_clear_date_and_time() -> None:
    assert labelled_email_delivery_window(
        "Expected delivery date: 15 August 2026\nDelivery window: 9:00 am–11:30 am",
        timezone_name="Europe/London",
    ) == {
        "starts_at": "2026-08-15T09:00:00+01:00",
        "ends_at": "2026-08-15T11:30:00+01:00",
        "all_day": False,
    }
    assert labelled_email_delivery_window(
        "Arrival date: 16/08/2026",
        timezone_name="Europe/London",
    ) == {
        "starts_at": "2026-08-16",
        "ends_at": None,
        "all_day": True,
    }
    assert (
        labelled_email_delivery_window(
            "Your parcel should arrive on 17 August 2026 between 9 and 11.",
            timezone_name="Europe/London",
        )
        is None
    )
    assert (
        labelled_email_delivery_window(
            "Delivery date: 17 August 2026\nDelivery time: 09:00\nArrival time: 13:00",
            timezone_name="Europe/London",
        )
        is None
    )


@pytest.mark.asyncio
async def test_structured_tesco_and_parcel_evidence_offer_editable_calendar_details(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
) -> None:
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    personal_space = next(item["id"] for item in spaces if item["kind"] == "personal")

    tesco_source = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": personal_space},
        headers=adult_a_headers,
        json={
            "external_source_id": "tesco-delivery-1",
            "adapter": "tesco_batch",
            "reviewed": True,
            "payload": {
                "id": "tesco-delivery-1",
                "purchased_at": "2026-08-01T10:00:00+01:00",
                "currency": "GBP",
                "lines": [
                    {
                        "id": "tesco-line-1",
                        "raw_name": "Family groceries",
                        "qty": 1,
                        "price_pence": 2500,
                    }
                ],
                "final_total_minor": 2500,
                "delivery_window": {
                    "starts_at": "2026-08-08T14:00:00+01:00",
                    "ends_at": "2026-08-08T15:00:00+01:00",
                    "all_day": False,
                },
            },
        },
    )
    assert tesco_source.status_code == 201, tesco_source.text
    tesco_source_id = tesco_source.json()["source"]["id"]
    tesco_prefill = await client.get(
        "/api/finance/calendar-items/prefill",
        params={"source_id": tesco_source_id},
        headers=adult_a_headers,
    )
    assert tesco_prefill.json() == {
        "item_kind": "GROCERY_DELIVERY",
        "starts_at": "2026-08-08T14:00:00+01:00",
        "ends_at": "2026-08-08T15:00:00+01:00",
        "all_day": False,
    }

    parcel_source = await client.post(
        "/api/finance/purchases/evidence",
        params={"space_id": personal_space},
        headers=adult_a_headers,
        json={
            "external_source_id": "amazon-dispatch-delivery-1",
            "adapter": "amazon_email",
            "reviewed": True,
            "payload": {
                "source_id": "amazon-dispatch-delivery-1",
                "event_type": "dispatch",
                "order_reference": "ORDER-DELIVERY-1",
                "merchant": "Amazon UK",
                "purchased_at": "2026-08-01",
                "currency": "GBP",
                "lines": [
                    {
                        "line_reference": "parcel-line-1",
                        "description": "School bag",
                        "net_minor": 3000,
                        "shipment_reference": "SHIP-DELIVERY-1",
                    }
                ],
                "final_total_minor": 3000,
                "shipments": [
                    {
                        "shipment_reference": "SHIP-DELIVERY-1",
                        "delivery_window": {
                            "starts_at": "2026-08-09",
                            "ends_at": None,
                            "all_day": True,
                        },
                    }
                ],
            },
        },
    )
    assert parcel_source.status_code == 201, parcel_source.text
    parcel_source_id = parcel_source.json()["source"]["id"]
    parcel_prefill = await client.get(
        "/api/finance/calendar-items/prefill",
        params={"source_id": parcel_source_id},
        headers=adult_a_headers,
    )
    assert parcel_prefill.json() == {
        "item_kind": "PARCEL_DELIVERY",
        "starts_at": "2026-08-09",
        "ends_at": None,
        "all_day": True,
    }

    for source_id in (tesco_source_id, parcel_source_id):
        saved = await client.get(
            "/api/finance/calendar-items",
            params={"source_id": source_id},
            headers=adult_a_headers,
        )
        assert saved.json() == []

import httpx
import pytest

from app.services.fitness.food_lookup import (
    FoodLookupNotFoundError,
    FoodLookupUnavailableError,
    lookup_barcode,
    normalise_barcode,
    search_foods,
)


@pytest.mark.asyncio
async def test_barcode_lookup_returns_reviewable_normalised_draft():
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["User-Agent"].startswith("HausKlar/")
        return httpx.Response(
            200,
            request=request,
            json={
                "product": {
                    "product_name": "Greek yoghurt",
                    "brands": "Example Dairy",
                    "product_quantity_unit": "g",
                    "serving_quantity": 150,
                    "serving_quantity_unit": "g",
                    "serving_size": "One pot",
                    "nutriments": {
                        "energy-kcal_100g": 72,
                        "proteins_100g": 9.5,
                        "carbohydrates_100g": 4.1,
                        "sugars_100g": 3.8,
                        "fat_100g": 1.8,
                        "saturated-fat_100g": 1.1,
                        "fiber_100g": 0,
                        "salt_100g": 0.12,
                        "sodium_100g": 0.048,
                    },
                }
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await lookup_barcode("5000123456789", client=client)

    assert result.name == "Greek yoghurt"
    assert result.nutrients.calories_kcal == 72
    assert result.nutrients.protein_g == 9.5
    assert result.nutrients.fibre_g == 0
    assert result.nutrients.sodium_mg == 48
    assert result.serving is not None and result.serving.amount == 150
    assert result.needs_review is True
    assert result.source == "open_food_facts"


@pytest.mark.asyncio
async def test_barcode_lookup_converts_kilojoules_and_warns_on_missing_macros():
    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            request=request,
            json={
                "product": {
                    "product_name": "Mystery drink",
                    "product_quantity_unit": "ml",
                    "nutriments": {"energy-kj_100g": 418.4},
                }
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await lookup_barcode("12345678", client=client)

    assert result.reference_unit == "ml"
    assert result.nutrients.calories_kcal == 100
    assert result.warnings == [
        "The main nutrients are missing; check the package before saving."
    ]


@pytest.mark.asyncio
async def test_barcode_lookup_has_honest_not_found_and_unavailable_states():
    async def missing(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(missing)) as client:
        with pytest.raises(FoodLookupNotFoundError):
            await lookup_barcode("12345678", client=client)

    async def broken(_: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline")

    async with httpx.AsyncClient(transport=httpx.MockTransport(broken)) as client:
        with pytest.raises(FoodLookupUnavailableError):
            await lookup_barcode("12345678", client=client)


def test_barcode_lookup_rejects_non_package_codes():
    with pytest.raises(ValueError, match="8 to 14 digit"):
        normalise_barcode("not-a-barcode")


@pytest.mark.asyncio
async def test_food_search_is_explicit_compact_and_returns_reviewable_drafts():
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/cgi/search.pl"
        assert request.url.params["search_terms"] == "greek yoghurt"
        assert request.url.params["page_size"] == "8"
        assert "nutriments" in request.url.params["fields"]
        return httpx.Response(
            200,
            request=request,
            json={
                "products": [
                    {
                        "code": "5000123456789",
                        "product_name": "Greek yoghurt",
                        "brands": "Example Dairy",
                        "product_quantity_unit": "g",
                        "nutriments": {
                            "energy-kcal_100g": 72,
                            "proteins_100g": 9.5,
                        },
                    },
                    {"code": "invalid", "product_name": "Ignored"},
                ]
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        results = await search_foods("  greek   yoghurt ", client=client)

    assert len(results) == 1
    assert results[0].name == "Greek yoghurt"
    assert results[0].barcode == "5000123456789"
    assert results[0].needs_review is True

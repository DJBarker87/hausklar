"""Optional barcode lookup which never becomes authoritative without review."""

import math
import re
from typing import Any

import httpx

from app.models.fitness_food_lookup import (
    FoodLookupDraft,
    FoodLookupNutrients,
    FoodLookupServing,
)

OPEN_FOOD_FACTS_URL = "https://world.openfoodfacts.org/api/v3/product/{barcode}"
OPEN_FOOD_FACTS_SEARCH_URL = "https://world.openfoodfacts.org/cgi/search.pl"
OPEN_FOOD_FACTS_FIELDS = ",".join(
    (
        "code",
        "product_name",
        "abbreviated_product_name",
        "generic_name",
        "brands",
        "nutriments",
        "nutrition",
        "serving_quantity",
        "serving_quantity_unit",
        "serving_size",
        "product_quantity_unit",
    )
)
BARCODE_RE = re.compile(r"^[0-9]{8,14}$")
SEARCH_RE = re.compile(r"^[^\x00-\x1f\x7f]{2,100}$")
LOOKUP_TIMEOUT = httpx.Timeout(8.0, connect=3.0, read=6.0, write=3.0, pool=3.0)
USER_AGENT = "HausKlar/1.0 (https://hausklar.example.invalid)"


class FoodLookupNotFoundError(LookupError):
    pass


class FoodLookupUnavailableError(RuntimeError):
    pass


def normalise_barcode(value: str) -> str:
    barcode = value.strip()
    if not BARCODE_RE.fullmatch(barcode):
        raise ValueError("Scan or enter an 8 to 14 digit barcode")
    return barcode


def normalise_search(value: str) -> str:
    query = " ".join(value.split()).strip()
    if not SEARCH_RE.fullmatch(query):
        raise ValueError("Enter at least 2 characters to look up a food")
    return query


def _text(value: Any, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = " ".join(value.split()).strip()
    return cleaned[:limit] or None


def _number(value: Any, *, maximum: float) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(parsed) or parsed < 0 or parsed > maximum:
        return None
    return round(parsed, 4)


def _legacy_nutrient(product: dict[str, Any], key: str, maximum: float) -> float | None:
    nutriments = product.get("nutriments")
    if not isinstance(nutriments, dict):
        return None
    return _number(nutriments.get(f"{key}_100g"), maximum=maximum)


def _v3_nutrient(product: dict[str, Any], key: str, maximum: float) -> float | None:
    nutrition = product.get("nutrition")
    if not isinstance(nutrition, dict):
        return None
    aggregate = nutrition.get("aggregated_set")
    if not isinstance(aggregate, dict) or aggregate.get("per") not in {"100g", "100ml"}:
        return None
    nutrients = aggregate.get("nutrients")
    if not isinstance(nutrients, dict) or not isinstance(nutrients.get(key), dict):
        return None
    item = nutrients[key]
    return _number(item.get("value_computed", item.get("value")), maximum=maximum)


def _nutrient(product: dict[str, Any], key: str, maximum: float) -> float | None:
    legacy = _legacy_nutrient(product, key, maximum)
    return legacy if legacy is not None else _v3_nutrient(product, key, maximum)


def _calories(product: dict[str, Any]) -> float | None:
    kcal = _nutrient(product, "energy-kcal", 2_000)
    if kcal is not None:
        return kcal
    kilojoules = _nutrient(product, "energy-kj", 8_400)
    return round(kilojoules / 4.184, 4) if kilojoules is not None else None


def _reference_unit(product: dict[str, Any]) -> str:
    nutrition = product.get("nutrition")
    if isinstance(nutrition, dict):
        aggregate = nutrition.get("aggregated_set")
        if isinstance(aggregate, dict) and aggregate.get("per") == "100ml":
            return "ml"
    product_unit = str(product.get("product_quantity_unit") or "").lower()
    return "ml" if product_unit in {"ml", "cl", "l"} else "g"


def _serving(product: dict[str, Any], reference_unit: str) -> FoodLookupServing | None:
    amount = _number(product.get("serving_quantity"), maximum=10_000)
    unit = str(product.get("serving_quantity_unit") or reference_unit).lower()
    if amount is None:
        return None
    if unit == "cl":
        amount *= 10
        unit = "ml"
    elif unit == "l":
        amount *= 1_000
        unit = "ml"
    if unit not in {"g", "ml"}:
        return None
    label = _text(product.get("serving_size"), 120) or f"One serving ({amount:g} {unit})"
    return FoodLookupServing(name=label, amount=amount, unit=unit)


def parse_open_food_facts(barcode: str, payload: Any) -> FoodLookupDraft:
    if not isinstance(payload, dict) or not isinstance(payload.get("product"), dict):
        raise FoodLookupNotFoundError("No matching packaged food was found")
    product = payload["product"]
    name = next(
        (
            text
            for text in (
                _text(product.get("product_name"), 200),
                _text(product.get("abbreviated_product_name"), 200),
                _text(product.get("generic_name"), 200),
            )
            if text
        ),
        None,
    )
    if name is None:
        raise FoodLookupNotFoundError("That barcode has no usable food name")
    nutrients = FoodLookupNutrients(
        calories_kcal=_calories(product),
        protein_g=_nutrient(product, "proteins", 100),
        carbohydrate_g=_nutrient(product, "carbohydrates", 100),
        sugars_g=_nutrient(product, "sugars", 100),
        fat_g=_nutrient(product, "fat", 100),
        saturated_fat_g=_nutrient(product, "saturated-fat", 100),
        fibre_g=_nutrient(product, "fiber", 100),
        salt_g=_nutrient(product, "salt", 100),
        sodium_mg=(
            round(sodium_g * 1_000, 4)
            if (sodium_g := _nutrient(product, "sodium", 100)) is not None
            else None
        ),
    )
    warnings: list[str] = []
    if nutrients.calories_kcal is None:
        warnings.append("Calories are missing; copy them from the package before saving.")
    if all(
        value is None
        for value in (
            nutrients.protein_g,
            nutrients.carbohydrate_g,
            nutrients.fat_g,
        )
    ):
        warnings.append("The main nutrients are missing; check the package before saving.")
    reference_unit = _reference_unit(product)
    return FoodLookupDraft(
        barcode=barcode,
        name=name,
        brand=_text(product.get("brands"), 160),
        reference_unit=reference_unit,
        nutrients=nutrients,
        serving=_serving(product, reference_unit),
        source_url=f"https://world.openfoodfacts.org/product/{barcode}",
        warnings=warnings,
    )


async def lookup_barcode(
    raw_barcode: str, *, client: httpx.AsyncClient | None = None
) -> FoodLookupDraft:
    barcode = normalise_barcode(raw_barcode)
    owns_client = client is None
    http = client or httpx.AsyncClient(
        timeout=LOOKUP_TIMEOUT,
        follow_redirects=False,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )
    try:
        response = await http.get(
            OPEN_FOOD_FACTS_URL.format(barcode=barcode),
            params={"fields": OPEN_FOOD_FACTS_FIELDS, "product_type": "food", "lc": "en"},
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        )
        if response.status_code == 404:
            raise FoodLookupNotFoundError("No matching packaged food was found")
        response.raise_for_status()
        return parse_open_food_facts(barcode, response.json())
    except FoodLookupNotFoundError:
        raise
    except (httpx.HTTPError, ValueError) as exc:
        raise FoodLookupUnavailableError(
            "Food lookup is unavailable; enter the package details manually"
        ) from exc
    finally:
        if owns_client:
            await http.aclose()


async def search_foods(
    raw_query: str, *, client: httpx.AsyncClient | None = None
) -> list[FoodLookupDraft]:
    """Run one explicit product search; callers must not use this as typeahead."""
    query = normalise_search(raw_query)
    owns_client = client is None
    http = client or httpx.AsyncClient(
        timeout=LOOKUP_TIMEOUT,
        follow_redirects=False,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )
    try:
        response = await http.get(
            OPEN_FOOD_FACTS_SEARCH_URL,
            params={
                "search_terms": query,
                "search_simple": "1",
                "action": "process",
                "json": "1",
                "page_size": "8",
                "sort_by": "popularity_key",
                "fields": OPEN_FOOD_FACTS_FIELDS,
            },
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        )
        response.raise_for_status()
        payload = response.json()
        products = payload.get("products") if isinstance(payload, dict) else None
        if not isinstance(products, list):
            raise FoodLookupUnavailableError(
                "Food lookup returned an unexpected response; try again later"
            )
        results: list[FoodLookupDraft] = []
        seen: set[str] = set()
        for product in products:
            if not isinstance(product, dict):
                continue
            barcode = str(product.get("code") or "").strip()
            if not BARCODE_RE.fullmatch(barcode) or barcode in seen:
                continue
            try:
                draft = parse_open_food_facts(barcode, {"product": product})
            except FoodLookupNotFoundError:
                continue
            seen.add(barcode)
            results.append(draft)
            if len(results) == 8:
                break
        return results
    except FoodLookupUnavailableError:
        raise
    except (httpx.HTTPError, ValueError) as exc:
        raise FoodLookupUnavailableError(
            "Food lookup is unavailable; try a barcode or add the food manually"
        ) from exc
    finally:
        if owns_client:
            await http.aclose()

"""CallMeBot WhatsApp notification service."""

import httpx

from app.config import settings


async def send_whatsapp(phone: str, apikey: str, message: str) -> dict:
    """Send a WhatsApp message via CallMeBot API.

    Returns a dict with 'success' (bool) and optionally 'error' (str).
    """
    if not phone or not apikey:
        return {"success": False, "error": "Phone or API key not configured"}

    url = "https://api.callmebot.com/whatsapp.php"
    params = {
        "phone": phone,
        "text": message,
        "apikey": apikey,
    }

    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.get(url, params=params)
            resp.raise_for_status()
            return {"success": True}
    except httpx.TimeoutException:
        return {"success": False, "error": "provider_timeout"}
    except httpx.HTTPStatusError:
        return {"success": False, "error": "provider_http_error"}
    except httpx.HTTPError:
        return {"success": False, "error": "provider_network_error"}
    except Exception:
        return {"success": False, "error": "provider_internal_error"}


async def send_briefing_to_all(message: str) -> list[dict]:
    """Send a WhatsApp message to both Alex and Morgan.

    Returns a list of result dicts, one per recipient.
    """
    results = []

    # Send to Alex
    adult_a_result = await send_whatsapp(
        phone=settings.notification_primary_adult_phone,
        apikey=settings.notification_primary_adult_apikey,
        message=message,
    )
    adult_a_result["recipient"] = "Alex"
    results.append(adult_a_result)

    # Send to Morgan
    adult_b_result = await send_whatsapp(
        phone=settings.notification_secondary_adult_phone,
        apikey=settings.notification_secondary_adult_apikey,
        message=message,
    )
    adult_b_result["recipient"] = "Morgan"
    results.append(adult_b_result)

    return results

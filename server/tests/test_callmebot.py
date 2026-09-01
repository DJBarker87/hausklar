import json

import httpx

from app.services.callmebot import send_whatsapp


async def test_callmebot_failure_never_returns_request_secrets(monkeypatch):
    phone = "+00000000002"
    api_key = "private-callmebot-key"
    message = "Private family briefing with medicine details"

    async def fail(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, request=request)

    transport = httpx.MockTransport(fail)
    real_client = httpx.AsyncClient
    monkeypatch.setattr(
        "app.services.callmebot.httpx.AsyncClient",
        lambda **kwargs: real_client(transport=transport, **kwargs),
    )

    result = await send_whatsapp(phone, api_key, message)
    encoded = json.dumps(result)

    assert result == {"success": False, "error": "provider_http_error"}
    assert phone not in encoded
    assert api_key not in encoded
    assert message not in encoded

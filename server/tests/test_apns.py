import json

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.config import settings
from app.services import apns


class _Response:
    status_code = 200

    def json(self):
        return {}


async def test_send_apns_uses_http2_fixed_topic_and_bounded_alert(tmp_path, monkeypatch):
    private_key = ec.generate_private_key(ec.SECP256R1())
    key_path = tmp_path / "AuthKey_TEST.p8"
    key_path.write_bytes(
        private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    monkeypatch.setattr(settings, "apns_team_id", "ABCDE12345")
    monkeypatch.setattr(settings, "apns_key_id", "A1B2C3D4E5")
    monkeypatch.setattr(settings, "apns_private_key_path", str(key_path))
    monkeypatch.setattr(settings, "apns_bundle_id", "com.example.hausklar")
    captured = {}

    class Client:
        def __init__(self, **kwargs):
            captured["client"] = kwargs

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def post(self, url, *, content, headers):
            captured.update(url=url, content=content, headers=headers)
            return _Response()

    monkeypatch.setattr(apns.httpx, "AsyncClient", Client)
    await apns.send_apns(
        device_token="ab" * 32,
        environment="production",
        payload={
            "title": "Family reminder",
            "body": "School pickup starts soon",
            "url": "/?view=calendar&event=one",
            "tag": "hausklar-event",
        },
        collapse_key="event:one",
    )
    assert captured["client"]["http2"] is True
    assert captured["url"].startswith("https://api.push.apple.com/3/device/")
    assert captured["headers"]["apns-topic"] == "com.example.hausklar"
    assert captured["headers"]["apns-push-type"] == "alert"
    authorization = captured["headers"]["authorization"].removeprefix("bearer ")
    claims = jwt.decode(
        authorization,
        private_key.public_key(),
        algorithms=["ES256"],
        options={"verify_aud": False},
    )
    assert claims["iss"] == "ABCDE12345"
    body = json.loads(captured["content"])
    assert body["aps"]["alert"]["title"] == "Family reminder"
    assert body["url"] == "/?view=calendar&event=one"


@pytest.mark.parametrize(
    ("status", "reason", "invalidates"),
    [(410, "Unregistered", True), (400, "BadDeviceToken", True), (429, "TooManyRequests", False)],
)
def test_apns_delivery_error_knows_when_to_retire_device(status, reason, invalidates):
    assert apns.APNSDeliveryError(status, reason).invalidates_device is invalidates

import json

import pytest

from app.config import settings
from app.middleware.request_security import _request_limit
from app.services.finance.upload_limits import (
    MAX_STATEMENT_IMPORT_BYTES,
    MULTIPART_REQUEST_OVERHEAD_BYTES,
)


async def test_rejects_declared_oversized_json_before_authentication(client):
    response = await client.post(
        "/api/tasks/",
        content=b"{}",
        headers={"Content-Length": "1048577", "Content-Type": "application/json"},
    )

    assert response.status_code == 413
    assert response.json() == {"detail": "Request body is too large"}


async def test_rejects_chunked_body_that_crosses_limit(client):
    async def chunks():
        yield b'{"message":"'
        yield b"a" * 1_048_576
        yield b'"}'

    response = await client.post(
        "/api/assistant/message",
        content=chunks(),
        headers={"Content-Type": "application/json"},
    )

    assert response.status_code == 413
    assert response.json() == {"detail": "Request body is too large"}


@pytest.mark.parametrize(
    ("path", "expected_limit"),
    [
        (
            "/api/finance/imports/preview",
            MAX_STATEMENT_IMPORT_BYTES + MULTIPART_REQUEST_OVERHEAD_BYTES,
        ),
        (
            "/api/finance/imports/confirm",
            MAX_STATEMENT_IMPORT_BYTES + MULTIPART_REQUEST_OVERHEAD_BYTES,
        ),
        (
            "/api/finance/purchases/evidence/upload",
            settings.document_max_upload_bytes + MULTIPART_REQUEST_OVERHEAD_BYTES,
        ),
    ],
)
async def test_finance_multipart_limits_allow_overhead_and_reject_larger_requests(
    client,
    path,
    expected_limit,
):
    assert _request_limit(path, "POST") == expected_limit

    below = await client.post(
        path,
        content=b"--incomplete-multipart--",
        headers={
            "Content-Type": "multipart/form-data; boundary=audit",
            "Content-Length": str(expected_limit),
        },
    )
    above = await client.post(
        path,
        content=b"--incomplete-multipart--",
        headers={
            "Content-Type": "multipart/form-data; boundary=audit",
            "Content-Length": str(expected_limit + 1),
        },
    )

    assert below.status_code != 413
    assert above.status_code == 413
    assert above.json() == {"detail": "Request body is too large"}


async def test_cookie_authenticated_mutation_requires_exact_web_origin(
    client,
    adult_a_user,
):
    login = await client.post(
        "/api/auth/web/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert login.status_code == 200

    sibling_origin = await client.post(
        "/api/documents/",
        files={"file": ("letter.txt", b"private", "text/plain")},
        data={"title": "Letter", "suggestions_json": json.dumps([])},
        headers={"Origin": "https://taken-over.example.invalid"},
    )
    missing_origin = await client.post("/api/auth/web/logout")

    assert sibling_origin.status_code == 403
    assert missing_origin.status_code == 403


async def test_exact_web_origin_and_native_bearer_requests_are_allowed(
    client,
    adult_a_user,
    adult_a_headers,
):
    login = await client.post(
        "/api/auth/web/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert login.status_code == 200

    browser_logout = await client.post(
        "/api/auth/web/logout",
        headers={"Origin": "https://test"},
    )
    native_task = await client.post(
        "/api/tasks/",
        json={"title": "Native task"},
        headers={**adult_a_headers, "Origin": "https://untrusted.example"},
    )

    assert browser_logout.status_code == 204
    assert native_task.status_code == 201

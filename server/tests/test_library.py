"""Local authority catalogue parsing, credential safety, tenancy and loan syncing."""

from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import aiosqlite
import httpx
import pytest
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

from app.config import settings
from app.services.library import (
    LibraryConnectionError,
    LibraryLoanRecord,
    LIBRARY_PROVIDER_DASHBOARD_PATH,
    LIBRARY_PROVIDER_HOME_PATH,
    LIBRARY_PROVIDER_KEY_PATH,
    LIBRARY_PROVIDER_LOGIN_PATH,
    ConfiguredLibraryClient,
    parse_library_loans,
)


LIBRARY_TODAY = datetime.now(ZoneInfo("Europe/London")).date()


LOANS_HTML = """
<html><body><table>
  <thead><tr><th>No.</th><th>Title</th><th>Author</th><th>Due</th><th>Status</th></tr></thead>
  <tbody>
    <tr><td><input type="checkbox" value="copy-101"></td>
        <td><a href="/cgi-bin/spydus.exe/FULL/OPAC/BIBENQ/101">The Wild Robot</a></td>
        <td>Peter Brown</td><td>18 August 2026</td><td>Renewable</td></tr>
    <tr><td><input type="checkbox" value="copy-202"></td>
        <td>The Gruffalo</td><td>Julia Donaldson</td><td>09/08/2026</td>
        <td>Cannot renew — reserved</td></tr>
  </tbody>
</table></body></html>
"""

LIVE_LIBRARY_LOANS_HTML = """
<html><body><table>
  <thead><tr><th>#</th><th>Details</th><th></th><th>Date due</th><th>Status</th><th>Options</th></tr></thead>
  <tbody><tr>
    <td><input type="checkbox" value="copy-live-1">Select record 1</td>
    <td><a href="#">Like The Wild Robot</a><a href="#">Dislike The Wild Robot</a></td>
    <td><a href="/cgi-bin/spydus.exe/ENQ/OPAC/BIBENQ/123?QRY=IRN(1)">The Wild Robot</a>
        Peter Brown 2016</td>
    <td>03 Sep 2026</td><td>Renewed 2 times</td>
    <td><a href="/cgi-bin/spydus.exe/PGM/OPAC/CCOPT/123/LOANRENQ">Renew loan</a></td>
  </tr></tbody>
</table></body></html>
"""


def _public_key_script() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=1024).public_key()
    pem = key.public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()
    return f"function rsaEncrypt(value) {{ setPublicKey('{pem}'); }}"


def test_parse_spydus_current_loans_table():
    loans = parse_library_loans(LOANS_HTML)
    assert [(item.title, item.author, item.due_date) for item in loans] == [
        ("The Wild Robot", "Peter Brown", date(2026, 8, 18)),
        ("The Gruffalo", "Julia Donaldson", date(2026, 8, 9)),
    ]
    assert loans[0].source_key == "value:copy-101"
    assert loans[0].renewable is True
    assert loans[1].renewable is False


def test_parse_live_local_authority_split_details_table():
    loans = parse_library_loans(LIVE_LIBRARY_LOANS_HTML)
    assert len(loans) == 1
    assert loans[0].title == "The Wild Robot"
    assert loans[0].author == "Peter Brown"
    assert loans[0].due_date == date(2026, 9, 3)
    assert loans[0].source_key == "value:copy-live-1"
    assert loans[0].renewable is True
    assert loans[0].renewal_count == 2


@pytest.mark.asyncio
async def test_local_authority_client_encrypts_pin_and_follows_only_catalogue_links():
    raw_pin = "2468"
    observed_post = b""

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal observed_post
        if request.url.path == LIBRARY_PROVIDER_HOME_PATH:
            return httpx.Response(200, text="<html>Home</html>", request=request)
        if request.url.path == LIBRARY_PROVIDER_KEY_PATH:
            return httpx.Response(200, text=_public_key_script(), request=request)
        if request.url.path == LIBRARY_PROVIDER_LOGIN_PATH and request.method == "POST":
            observed_post = request.content
            return httpx.Response(
                200,
                text=(
                    '<html><head><meta http-equiv="Refresh" content="0; '
                    f'url={LIBRARY_PROVIDER_DASHBOARD_PATH}"></head></html>'
                ),
                request=request,
            )
        if request.url.path.endswith("/CCOPT/LB/1"):
            return httpx.Response(
                200,
                text='<a href="/cgi-bin/spydus.exe/PGM/OPAC/CCOPT/LOAN/1">Current loans (2)</a>',
                request=request,
            )
        if request.url.path.endswith("/CCOPT/LOAN/1"):
            return httpx.Response(200, text=LOANS_HTML, request=request)
        raise AssertionError(str(request.url))

    async with ConfiguredLibraryClient(transport=httpx.MockTransport(handler)) as catalogue:
        loans = await catalogue.current_loans(card_number="TESTCARD123", pin=raw_pin)

    assert [item.title for item in loans] == ["The Wild Robot", "The Gruffalo"]
    assert raw_pin.encode() not in observed_post
    assert b"BRWLPWD=" in observed_post


@pytest.mark.asyncio
async def test_local_authority_client_rejects_cross_origin_meta_refresh():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            text=(
                '<html><head><meta http-equiv="refresh" '
                'content="0; url=https://attacker.example/collect"></head></html>'
            ),
            request=request,
        )

    with pytest.raises(LibraryConnectionError) as caught:
        async with ConfiguredLibraryClient(transport=httpx.MockTransport(handler)) as catalogue:
            await catalogue.current_loans(card_number="TESTCARD123", pin="2468")
    assert caught.value.code == "unsafe_catalogue_response"


@pytest.mark.asyncio
async def test_local_authority_client_rejects_cross_origin_redirect():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            302,
            headers={"location": "https://attacker.example/collect"},
            request=request,
        )

    with pytest.raises(LibraryConnectionError) as caught:
        async with ConfiguredLibraryClient(transport=httpx.MockTransport(handler)) as catalogue:
            await catalogue.current_loans(card_number="TESTCARD123", pin="2468")
    assert caught.value.code == "unsafe_catalogue_response"


class _FakeLibraryClient:
    loans = [
        LibraryLoanRecord(
            source_key="copy:one",
            title="The Wild Robot",
            author="Peter Brown",
            due_date=LIBRARY_TODAY + timedelta(days=6),
            provider_status="Renewable",
            renewable=True,
        )
    ]

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None

    async def current_loans(self, *, card_number: str, pin: str):
        assert card_number == "TESTCARD123"
        assert pin == "2468"
        return self.loans


class _RenewedLibraryClient(_FakeLibraryClient):
    loans = [
        LibraryLoanRecord(
            source_key="copy:one",
            title="The Wild Robot",
            author="Peter Brown",
            due_date=LIBRARY_TODAY + timedelta(days=20),
            provider_status="Renewed",
            renewable=True,
            renewal_count=1,
        )
    ]


class _GroupedOverdueLibraryClient(_FakeLibraryClient):
    loans = [
        LibraryLoanRecord(
            source_key="copy:one",
            title="The Wild Robot",
            author="Peter Brown",
            due_date=LIBRARY_TODAY - timedelta(days=1),
            provider_status="Overdue",
            renewable=False,
        ),
        LibraryLoanRecord(
            source_key="copy:two",
            title="The Gruffalo",
            author="Julia Donaldson",
            due_date=LIBRARY_TODAY - timedelta(days=1),
            provider_status="Overdue",
            renewable=False,
        ),
        LibraryLoanRecord(
            source_key="copy:three",
            title="Paddington",
            author="Michael Bond",
            due_date=LIBRARY_TODAY - timedelta(days=1),
            provider_status="Overdue",
            renewable=False,
        ),
    ]


class _OneOutstandingOverdueLibraryClient(_GroupedOverdueLibraryClient):
    loans = _GroupedOverdueLibraryClient.loans[:1]


@pytest.mark.asyncio
async def test_library_account_is_encrypted_family_scoped_and_deletable(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    adult_b_user,
    other_family_headers,
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(settings, "ha_token_encryption_key", Fernet.generate_key().decode())
    monkeypatch.setattr("app.routers.library.ConfiguredLibraryClient", _FakeLibraryClient)

    created = await client.post(
        "/api/library/accounts",
        headers=adult_a_headers,
        json={
            "label": "Children",
            "card_number": "TESTCARD123",
            "pin": "2468",
            "reminder_days_before": 4,
        },
    )
    assert created.status_code == 201, created.text
    overview = created.json()
    assert overview["accounts"][0]["card_last_four"] == "D123"
    assert "card_number" not in created.text
    assert "encrypted" not in created.text
    assert "pin" not in overview["accounts"][0]
    assert all(
        "2468" not in str(value)
        for key, value in overview["accounts"][0].items()
        if key != "id"
    )
    assert overview["loans"][0]["title"] == "The Wild Robot"
    assert overview["loans"][0]["account_label"] == "Children"
    assert overview["loans"][0]["status"] == "due_soon"
    assert overview["loans"][0]["renew_url"].startswith("https://library.example.invalid/")

    async with aiosqlite.connect(initialized_db) as db:
        stored = await (
            await db.execute(
                "SELECT encrypted_card_number,encrypted_pin FROM library_accounts"
            )
        ).fetchone()
    assert "TESTCARD123" not in stored[0]
    assert "2468" not in stored[1]

    family_view = await client.get("/api/library/", headers=adult_b_headers)
    assert family_view.status_code == 200
    family_overview = family_view.json()
    assert family_overview["accounts"][0]["label"] == "Children"
    assert family_overview["accounts"][0]["card_last_four"] == "D123"
    assert family_overview["loans"][0]["title"] == "The Wild Robot"
    isolated = await client.get("/api/library/", headers=other_family_headers)
    assert isolated.json() == {"accounts": [], "loans": []}

    tasks = (await client.get("/api/tasks/?limit=200", headers=adult_b_headers)).json()
    library_task = next(item for item in tasks if item["id"].startswith("library-task-"))
    assert library_task["title"] == "Renew or return The Wild Robot"
    assert library_task["assigned_to"] is None
    assert {
        (assignee["assignee_id"], assignee["assignee_name"])
        for assignee in library_task["assignees"]
    } == {(adult_a_user["id"], "Alex"), (adult_b_user["id"], "Morgan")}
    assert library_task["actionable_from"] == (
        LIBRARY_TODAY - timedelta(days=1)
    ).isoformat()
    assert library_task["managed_source"]["kind"] == "library_loan"
    assert "library=" in library_task["managed_source"]["deep_link"]
    for adult, headers in ((adult_a_user, adult_a_headers), (adult_b_user, adult_b_headers)):
        filtered_tasks = (
            await client.get(
                f"/api/tasks/?assigned_to={adult['id']}&limit=200",
                headers=headers,
            )
        ).json()
        assert library_task["id"] in {item["id"] for item in filtered_tasks}
    other_tasks = (await client.get("/api/tasks/?limit=200", headers=other_family_headers)).json()
    assert not any(item["id"].startswith("library-task-") for item in other_tasks)

    completed = await client.patch(
        f"/api/tasks/{library_task['id']}/complete", headers=adult_b_headers
    )
    assert completed.status_code == 200
    assert completed.json()["completed_at"] is not None
    reopened = await client.patch(
        f"/api/tasks/{library_task['id']}/reopen", headers=adult_a_headers
    )
    assert reopened.status_code == 200
    assert reopened.json()["completed_at"] is None

    completed_again = await client.patch(
        f"/api/tasks/{library_task['id']}/complete", headers=adult_a_headers
    )
    assert completed_again.json()["completed_at"] is not None
    monkeypatch.setattr("app.routers.library.ConfiguredLibraryClient", _RenewedLibraryClient)
    refreshed = await client.post(
        f"/api/library/accounts/{overview['accounts'][0]['id']}/sync",
        headers=adult_b_headers,
    )
    assert refreshed.status_code == 200
    assert refreshed.json()["loans"][0]["status"] == "current"
    assert refreshed.json()["loans"][0]["renew_url"] is None
    refreshed_tasks = (await client.get("/api/tasks/?limit=200", headers=adult_a_headers)).json()
    refreshed_task = next(item for item in refreshed_tasks if item["id"] == library_task["id"])
    assert refreshed_task["completed_at"] is None
    assert refreshed_task["due_date"] == (LIBRARY_TODAY + timedelta(days=20)).isoformat()

    account_id = overview["accounts"][0]["id"]
    denied = await client.delete(
        f"/api/library/accounts/{account_id}", headers=other_family_headers
    )
    assert denied.status_code == 404
    removed = await client.delete(
        f"/api/library/accounts/{account_id}", headers=adult_a_headers
    )
    assert removed.status_code == 204
    assert (await client.get("/api/library/", headers=adult_a_headers)).json() == {
        "accounts": [],
        "loans": [],
    }
    async with aiosqlite.connect(initialized_db) as db:
        soft_deleted = await (
            await db.execute(
                "SELECT deleted_at FROM library_accounts WHERE id=?", (account_id,)
            )
        ).fetchone()
    assert soft_deleted[0] is not None


@pytest.mark.asyncio
async def test_same_day_loans_are_one_shared_task_and_outstanding_book_reopens(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(settings, "ha_token_encryption_key", Fernet.generate_key().decode())
    monkeypatch.setattr(
        "app.routers.library.ConfiguredLibraryClient", _GroupedOverdueLibraryClient
    )

    created = await client.post(
        "/api/library/accounts",
        headers=adult_a_headers,
        json={
            "label": "Children",
            "card_number": "TESTCARD123",
            "pin": "2468",
        },
    )
    assert created.status_code == 201, created.text
    account_id = created.json()["accounts"][0]["id"]

    tasks = (await client.get("/api/tasks/?limit=200", headers=adult_b_headers)).json()
    library_tasks = [item for item in tasks if item["id"].startswith("library-task-")]
    assert len(library_tasks) == 1
    grouped_task = library_tasks[0]
    assert grouped_task["id"].startswith("library-task-group-")
    assert grouped_task["title"] == "Return 3 overdue library books"
    assert grouped_task["priority"] == 3
    assert grouped_task["managed_source"]["label"] == "3 library books"
    assert all(
        title in grouped_task["description"]
        for title in ("The Wild Robot", "The Gruffalo", "Paddington")
    )
    assert {item["assignee_id"] for item in grouped_task["assignees"]} == {
        adult_a_user["id"],
        adult_b_user["id"],
    }
    overview = (await client.get("/api/tasks/overview", headers=adult_b_headers)).json()
    adult_overview = {
        item["person_id"]: item
        for item in overview
        if item["person_id"] in {adult_a_user["id"], adult_b_user["id"]}
    }
    assert adult_overview.keys() == {adult_a_user["id"], adult_b_user["id"]}
    assert all(item["total_pending"] == 1 for item in adult_overview.values())
    assert all(item["overdue"] == 1 for item in adult_overview.values())

    completed = await client.patch(
        f"/api/tasks/{grouped_task['id']}/complete", headers=adult_b_headers
    )
    assert completed.status_code == 200
    assert completed.json()["completed_at"] is not None
    assert all(
        assignee["completed_by"] == adult_b_user["id"]
        for assignee in completed.json()["assignees"]
    )
    async with aiosqlite.connect(initialized_db) as db:
        completion_rows = await (
            await db.execute(
                "SELECT task_completed_at FROM library_loans WHERE deleted_at IS NULL"
            )
        ).fetchall()
    assert len(completion_rows) == 3
    assert all(row[0] is not None for row in completion_rows)

    monkeypatch.setattr(
        "app.routers.library.ConfiguredLibraryClient", _OneOutstandingOverdueLibraryClient
    )
    refreshed = await client.post(
        f"/api/library/accounts/{account_id}/sync",
        headers=adult_a_headers,
    )
    assert refreshed.status_code == 200, refreshed.text
    assert [loan["title"] for loan in refreshed.json()["loans"]] == ["The Wild Robot"]
    assert refreshed.json()["loans"][0]["status"] == "overdue"

    tasks = (await client.get("/api/tasks/?limit=200", headers=adult_a_headers)).json()
    library_tasks = [item for item in tasks if item["id"].startswith("library-task-")]
    assert len(library_tasks) == 1
    overdue_task = library_tasks[0]
    assert overdue_task["id"] != grouped_task["id"]
    assert overdue_task["title"] == "Return overdue library book: The Wild Robot"
    assert overdue_task["completed_at"] is None
    assert overdue_task["priority"] == 3
    for adult, headers in ((adult_a_user, adult_a_headers), (adult_b_user, adult_b_headers)):
        filtered_tasks = (
            await client.get(
                f"/api/tasks/?assigned_to={adult['id']}&limit=200",
                headers=headers,
            )
        ).json()
        assert overdue_task["id"] in {item["id"] for item in filtered_tasks}
    overview = (await client.get("/api/tasks/overview", headers=adult_a_headers)).json()
    adult_overview = {
        item["person_id"]: item
        for item in overview
        if item["person_id"] in {adult_a_user["id"], adult_b_user["id"]}
    }
    assert all(item["total_pending"] == 1 for item in adult_overview.values())
    assert all(item["overdue"] == 1 for item in adult_overview.values())

    async with aiosqlite.connect(initialized_db) as db:
        active = await (
            await db.execute(
                "SELECT title,task_completed_at FROM library_loans "
                "WHERE deleted_at IS NULL"
            )
        ).fetchall()
        deleted_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM library_loans WHERE deleted_at IS NOT NULL"
                )
            ).fetchone()
        )[0]
    assert active == [("The Wild Robot", None)]
    assert deleted_count == 2


@pytest.mark.asyncio
async def test_invalid_pin_is_never_echoed(client, adult_a_headers):
    invalid_pin = "13579"
    response = await client.post(
        "/api/library/accounts",
        headers=adult_a_headers,
        json={"label": "Card", "card_number": "TESTCARD123", "pin": invalid_pin},
    )
    assert response.status_code == 422
    assert invalid_pin not in response.text

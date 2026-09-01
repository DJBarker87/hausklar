"""Bounded, read-only access to Local authority's Civica Spydus catalogue."""

from __future__ import annotations

import base64
import hashlib
import logging
import re
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit
from zoneinfo import ZoneInfo

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app.database import database_lease
from app.services.record_history import save_history
from app.utils.encryption import decrypt_value

logger = logging.getLogger(__name__)

LIBRARY_PROVIDER_ORIGIN = "https://library.example.invalid"
LIBRARY_PROVIDER_HOME_PATH = "/cgi-bin/spydus.exe/MSGTRN/OPAC/HOME"
LIBRARY_PROVIDER_LOGIN_PATH = "/cgi-bin/spydus.exe/PGM/OPAC/CCOPT/LB/2"
LIBRARY_PROVIDER_DASHBOARD_PATH = "/cgi-bin/spydus.exe/PGM/OPAC/CCOPT/LB/1?ISGLB=1"
LIBRARY_PROVIDER_KEY_PATH = "/docs/OPAC/js/encrypt.js"
LIBRARY_PROVIDER_ACCOUNT_URL = f"{LIBRARY_PROVIDER_ORIGIN}{LIBRARY_PROVIDER_DASHBOARD_PATH}"

_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
_MAX_REDIRECTS = 3
_SYNC_SUCCESS_DELAY = timedelta(hours=6)
_SYNC_FAILURE_DELAY = timedelta(hours=1)


class LibraryConnectionError(RuntimeError):
    """A safe, user-displayable catalogue connection failure."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class LibraryLoanRecord:
    source_key: str
    title: str
    due_date: date
    author: str | None = None
    material_format: str | None = None
    provider_status: str | None = None
    renewable: bool | None = None
    renewal_count: int | None = None


@dataclass
class _Cell:
    text: list[str]
    links: list[str]
    link_labels: list[str]
    values: list[str]


@dataclass
class _Table:
    headers: list[str]
    rows: list[list[_Cell]]


class _CatalogueHTMLParser(HTMLParser):
    """Collect links and simple HTML tables without executing catalogue code."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[str, str, str]] = []
        self.tables: list[_Table] = []
        self._anchor_href: str | None = None
        self._anchor_title = ""
        self._anchor_text: list[str] = []
        self._table_depth = 0
        self._table: _Table | None = None
        self._row: list[_Cell] | None = None
        self._cell: _Cell | None = None
        self._cell_is_header = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {key.lower(): value or "" for key, value in attrs}
        if tag == "a":
            self._anchor_href = values.get("href")
            self._anchor_title = values.get("title", "")
            self._anchor_text = []
            if self._cell is not None and self._anchor_href:
                self._cell.links.append(self._anchor_href)
        if tag == "table":
            self._table_depth += 1
            if self._table_depth == 1:
                self._table = _Table(headers=[], rows=[])
        elif tag == "tr" and self._table_depth == 1:
            self._row = []
        elif tag in {"th", "td"} and self._table_depth == 1 and self._row is not None:
            self._cell = _Cell(text=[], links=[], link_labels=[], values=[])
            self._cell_is_header = tag == "th"
        elif tag == "input" and self._cell is not None:
            value = values.get("value", "").strip()
            if value:
                self._cell.values.append(value)

    def handle_data(self, data: str) -> None:
        if self._anchor_href is not None:
            self._anchor_text.append(data)
        if self._cell is not None:
            self._cell.text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._anchor_href is not None:
            label = _clean_text(" ".join(self._anchor_text))
            self.links.append(
                (
                    self._anchor_href,
                    label,
                    _clean_text(self._anchor_title),
                )
            )
            if self._cell is not None and label:
                self._cell.link_labels.append(label)
            self._anchor_href = None
            self._anchor_title = ""
            self._anchor_text = []
        elif tag in {"th", "td"} and self._cell is not None and self._row is not None:
            if self._cell_is_header and self._table is not None:
                self._table.headers.append(_clean_text(" ".join(self._cell.text)))
            self._row.append(self._cell)
            self._cell = None
        elif tag == "tr" and self._row is not None:
            if self._table is not None and any(_cell_text(cell) for cell in self._row):
                if not all(not cell.links and not cell.values for cell in self._row) or not self._table.headers:
                    self._table.rows.append(self._row)
            self._row = None
        elif tag == "table" and self._table_depth:
            if self._table_depth == 1 and self._table is not None:
                self.tables.append(self._table)
                self._table = None
            self._table_depth -= 1


class _MetaRefreshParser(HTMLParser):
    """Read a zero-delay HTML refresh without interpreting page scripts."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.target: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if self.target is not None or tag.casefold() != "meta":
            return
        values = {key.casefold(): value or "" for key, value in attrs}
        if values.get("http-equiv", "").strip().casefold() != "refresh":
            return
        match = re.fullmatch(
            r"\s*0(?:\.0*)?\s*;\s*url\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|(.+?))\s*",
            values.get("content", ""),
            flags=re.I,
        )
        if match:
            self.target = next(value for value in match.groups() if value is not None)


def _meta_refresh_target(html: str) -> str | None:
    parser = _MetaRefreshParser()
    parser.feed(html)
    return parser.target


def _clean_text(value: str) -> str:
    return " ".join(value.replace("\xa0", " ").split()).strip()


def _cell_text(cell: _Cell) -> str:
    return _clean_text(" ".join(cell.text))


def _normalise_header(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


def _header_index(headers: list[str], *needles: str) -> int | None:
    normalised = [_normalise_header(value) for value in headers]
    for needle in needles:
        for index, value in enumerate(normalised):
            if needle in value:
                return index
    return None


def _parse_due_date(value: str) -> date | None:
    cleaned = re.sub(r"(?<=\d)(st|nd|rd|th)\b", "", _clean_text(value), flags=re.I)
    cleaned = re.sub(r"^(due|return by)\s*[:\-]?\s*", "", cleaned, flags=re.I)
    candidates = [cleaned]
    match = re.search(
        r"\b(\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}|\d{4}-\d{2}-\d{2})\b",
        cleaned,
    )
    if match:
        candidates.insert(0, match.group(1))
    for candidate in candidates:
        for date_format in ("%d/%m/%Y", "%d-%m-%Y", "%d/%m/%y", "%d %b %Y", "%d %B %Y", "%Y-%m-%d"):
            try:
                return datetime.strptime(candidate, date_format).date()
            except ValueError:
                continue
    return None


def _optional_text(value: str) -> str | None:
    cleaned = _clean_text(value)
    return cleaned[:300] if cleaned and cleaned not in {"-", "—"} else None


def _source_key(row: list[_Cell], title: str, author: str | None) -> str:
    for cell in row:
        for value in cell.values:
            cleaned = _clean_text(value)
            if cleaned and len(cleaned) <= 200:
                return f"value:{cleaned}"
        for href in cell.links:
            if "/cgi-bin/spydus.exe/" in href and len(href) <= 2_000:
                return f"href:{href}"
    return f"title:{title.casefold()}|author:{(author or '').casefold()}"


def _live_details(row: list[_Cell], *, details_index: int, due_index: int) -> tuple[int, str] | None:
    """Find the title link in Local authority's split Details columns."""
    for index in range(details_index, min(due_index, len(row))):
        cell = row[index]
        if any("/BIBENQ/" in href for href in cell.links):
            title = next((_optional_text(label) for label in cell.link_labels if label), None)
            if title:
                return index, title
    return None


def _author_from_live_details(cell: _Cell, title: str) -> str | None:
    details = _cell_text(cell)
    if not details.casefold().startswith(title.casefold()):
        return None
    remainder = details[len(title) :].strip()
    remainder = re.sub(r"\s+(?:18|19|20)\d{2}\s*$", "", remainder).strip()
    return _optional_text(remainder)


def parse_library_loans(html: str) -> list[LibraryLoanRecord]:
    """Extract current loans from a Spydus table, tolerating minor label changes."""
    parser = _CatalogueHTMLParser()
    parser.feed(html)
    loans: list[LibraryLoanRecord] = []
    for table in parser.tables:
        title_index = _header_index(table.headers, "title", "item")
        due_index = _header_index(table.headers, "date due", "due date", "due")
        details_index = _header_index(table.headers, "details")
        if (title_index is None and details_index is None) or due_index is None:
            continue
        author_index = _header_index(table.headers, "author", "creator")
        format_index = _header_index(table.headers, "format", "material")
        status_index = _header_index(table.headers, "status")
        renewal_index = _header_index(table.headers, "renewal", "renewals")
        for row in table.rows:
            if due_index >= len(row):
                continue
            live_details = (
                _live_details(row, details_index=details_index, due_index=due_index)
                if title_index is None and details_index is not None
                else None
            )
            resolved_title_index = live_details[0] if live_details else title_index
            if resolved_title_index is None or resolved_title_index >= len(row):
                continue
            title = (
                live_details[1]
                if live_details
                else _optional_text(_cell_text(row[resolved_title_index]))
            )
            due = _parse_due_date(_cell_text(row[due_index]))
            if not title or due is None:
                continue
            author = (
                _optional_text(_cell_text(row[author_index]))
                if author_index is not None and author_index < len(row)
                else _author_from_live_details(row[resolved_title_index], title)
                if live_details
                else None
            )
            material_format = (
                _optional_text(_cell_text(row[format_index]))
                if format_index is not None and format_index < len(row)
                else None
            )
            provider_status = (
                _optional_text(_cell_text(row[status_index]))
                if status_index is not None and status_index < len(row)
                else None
            )
            renewal_count = None
            if renewal_index is not None and renewal_index < len(row):
                renewal_match = re.search(r"\d+", _cell_text(row[renewal_index]))
                renewal_count = int(renewal_match.group()) if renewal_match else None
            elif provider_status:
                renewal_match = re.search(r"renewed\s+(\d+)\s+times?", provider_status, re.I)
                renewal_count = int(renewal_match.group(1)) if renewal_match else None
            status_folded = (provider_status or "").casefold()
            renewable = None
            if status_folded:
                renewable = not any(
                    marker in status_folded
                    for marker in ("cannot renew", "not renewable", "reserved", "maximum")
                )
            loans.append(
                LibraryLoanRecord(
                    source_key=_source_key(row, title, author),
                    title=title[:500],
                    author=author,
                    material_format=material_format,
                    due_date=due,
                    provider_status=provider_status,
                    renewable=renewable,
                    renewal_count=renewal_count,
                )
            )
        if loans:
            break
    if loans:
        return loans[:100]
    visible = _clean_text(re.sub(r"<[^>]+>", " ", html)).casefold()
    if re.search(r"\b(?:0|no)\s+current loans?\b", visible):
        return []
    raise LibraryConnectionError(
        "catalogue_changed",
        "The library changed its account page. HausKlar could not read the loans safely.",
    )


def _safe_catalogue_url(value: str, *, base: str = LIBRARY_PROVIDER_ORIGIN) -> str:
    target = urljoin(base, value)
    parsed = urlsplit(target)
    if (
        parsed.scheme != "https"
        or parsed.hostname != "library.example.invalid"
        or parsed.port not in {None, 443}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
        or not (
            parsed.path.startswith("/cgi-bin/spydus.exe/")
            or parsed.path == LIBRARY_PROVIDER_KEY_PATH
        )
        or len(target) > 4_096
    ):
        raise LibraryConnectionError(
            "unsafe_catalogue_response",
            "The library returned an unexpected link, so HausKlar stopped safely.",
        )
    return target


def _public_key_from_script(script: str) -> rsa.RSAPublicKey:
    match = re.search(
        r"-----BEGIN PUBLIC KEY-----(.*?)-----END PUBLIC KEY-----",
        script,
        flags=re.S,
    )
    if not match:
        raise LibraryConnectionError(
            "catalogue_changed",
            "The library changed its login page. HausKlar did not send the PIN.",
        )
    body = re.sub(r"[^A-Za-z0-9+/=]", "", match.group(1))
    pem = f"-----BEGIN PUBLIC KEY-----\n{body}\n-----END PUBLIC KEY-----\n".encode()
    try:
        key = serialization.load_pem_public_key(pem)
    except (TypeError, ValueError) as exc:
        raise LibraryConnectionError(
            "catalogue_changed",
            "The library changed its login page. HausKlar did not send the PIN.",
        ) from exc
    if not isinstance(key, rsa.RSAPublicKey) or key.key_size < 1024:
        raise LibraryConnectionError(
            "catalogue_changed",
            "The library returned an unsupported login key.",
        )
    return key


class ConfiguredLibraryClient:
    """One short-lived authenticated catalogue session, fixed to the Local authority host."""

    def __init__(self, *, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self._client = httpx.AsyncClient(
            transport=transport,
            follow_redirects=False,
            timeout=httpx.Timeout(15.0, connect=8.0),
            headers={
                "User-Agent": "HausKlar/1.8 (read-only family library reminder)",
                "Accept": "text/html,application/javascript;q=0.9,text/javascript;q=0.9",
            },
        )

    async def __aenter__(self) -> ConfiguredLibraryClient:
        return self

    async def __aexit__(self, *_args) -> None:
        await self._client.aclose()

    async def _request(
        self,
        method: str,
        value: str,
        *,
        data: dict[str, str] | None = None,
    ) -> tuple[str, str]:
        target = _safe_catalogue_url(value)
        current_method = method.upper()
        current_data = data
        for redirect_count in range(_MAX_REDIRECTS + 1):
            try:
                async with self._client.stream(
                    current_method,
                    target,
                    data=current_data,
                ) as response:
                    if response.status_code in {301, 302, 303, 307, 308}:
                        if redirect_count >= _MAX_REDIRECTS:
                            raise LibraryConnectionError(
                                "too_many_redirects",
                                "The library redirected too many times. Try again later.",
                            )
                        location = response.headers.get("location")
                        if not location:
                            raise LibraryConnectionError(
                                "catalogue_changed",
                                "The library returned an incomplete response.",
                            )
                        target = _safe_catalogue_url(location, base=target)
                        if response.status_code == 303 or (
                            response.status_code in {301, 302} and current_method == "POST"
                        ):
                            current_method = "GET"
                            current_data = None
                        continue
                    if response.status_code >= 400:
                        raise LibraryConnectionError(
                            "catalogue_unavailable",
                            "The library is unavailable just now. Try again later.",
                        )
                    declared = response.headers.get("content-length")
                    if declared and declared.isdigit() and int(declared) > _MAX_RESPONSE_BYTES:
                        raise LibraryConnectionError(
                            "response_too_large",
                            "The library returned more data than HausKlar will accept.",
                        )
                    body = bytearray()
                    async for chunk in response.aiter_bytes():
                        body.extend(chunk)
                        if len(body) > _MAX_RESPONSE_BYTES:
                            raise LibraryConnectionError(
                                "response_too_large",
                                "The library returned more data than HausKlar will accept.",
                            )
                    decoded = body.decode(response.encoding or "utf-8", errors="replace")
                    refresh_target = _meta_refresh_target(decoded)
                    if refresh_target is not None:
                        if redirect_count >= _MAX_REDIRECTS:
                            raise LibraryConnectionError(
                                "too_many_redirects",
                                "The library redirected too many times. Try again later.",
                            )
                        target = _safe_catalogue_url(refresh_target, base=target)
                        current_method = "GET"
                        current_data = None
                        continue
                    return decoded, target
            except LibraryConnectionError:
                raise
            except (httpx.HTTPError, OSError) as exc:
                raise LibraryConnectionError(
                    "catalogue_unavailable",
                    "The library is unavailable just now. Try again later.",
                ) from exc
        raise LibraryConnectionError("catalogue_unavailable", "The library is unavailable.")

    async def current_loans(self, *, card_number: str, pin: str) -> list[LibraryLoanRecord]:
        await self._request("GET", LIBRARY_PROVIDER_HOME_PATH)
        script, _ = await self._request("GET", LIBRARY_PROVIDER_KEY_PATH)
        public_key = _public_key_from_script(script)
        encrypted_pin = base64.b64encode(
            public_key.encrypt(pin.encode(), padding.PKCS1v15())
        ).decode()
        dashboard, dashboard_url = await self._request(
            "POST",
            LIBRARY_PROVIDER_LOGIN_PATH,
            data={
                "BRWLID": card_number,
                "BRWLPWD": encrypted_pin,
                "ISGLB": "1",
                "RDT": LIBRARY_PROVIDER_DASHBOARD_PATH,
            },
        )
        if "/LOGIN" in urlsplit(dashboard_url).path.upper() or re.search(
            r"(?:incorrect|invalid).{0,60}(?:card|pin)|unable to log in",
            _clean_text(re.sub(r"<[^>]+>", " ", dashboard)),
            flags=re.I,
        ):
            raise LibraryConnectionError(
                "login_rejected",
                "The library did not accept that card number and PIN.",
            )
        parser = _CatalogueHTMLParser()
        parser.feed(dashboard)
        current_loans_url = None
        for href, text, title in parser.links:
            label = f"{text} {title}".casefold()
            if "current loan" in label:
                current_loans_url = _safe_catalogue_url(href, base=dashboard_url)
                break
        if current_loans_url is None:
            visible = _clean_text(re.sub(r"<[^>]+>", " ", dashboard)).casefold()
            if re.search(r"\b(?:0|no)\s+current loans?\b", visible):
                return []
            raise LibraryConnectionError(
                "login_rejected",
                "The library did not accept that card number and PIN.",
            )
        loans_page, _ = await self._request("GET", current_loans_url)
        return parse_library_loans(loans_page)


def external_item_hash(source_key: str) -> str:
    return hashlib.sha256(source_key.encode()).hexdigest()


async def persist_library_sync(
    db,
    *,
    account_id: str,
    family_id: str,
    actor_id: str,
    loans: list[LibraryLoanRecord],
    now: datetime | None = None,
) -> None:
    synced = now or datetime.now(timezone.utc)
    synced_at = synced.isoformat()
    synced_with_timezone = (
        synced if synced.tzinfo is not None else synced.replace(tzinfo=timezone.utc)
    )
    local_today = synced_with_timezone.astimezone(ZoneInfo("Europe/London")).date()
    seen: set[str] = set()
    for loan in loans:
        item_hash = external_item_hash(loan.source_key)
        seen.add(item_hash)
        existing = await (
            await db.execute(
                """SELECT id,due_date,task_completed_at,task_completed_by
                   FROM library_loans
                   WHERE account_id = ? AND external_item_hash = ?""",
                (account_id, item_hash),
            )
        ).fetchone()
        due_date = loan.due_date.isoformat()
        due_date_changed = bool(existing and existing["due_date"] != due_date)
        reopen_overdue = bool(
            existing
            and existing["task_completed_at"] is not None
            and loan.due_date < local_today
        )
        reset_completion = due_date_changed or reopen_overdue
        if existing and reset_completion:
            await save_history(
                db,
                "library_loans",
                existing["id"],
                actor_id,
                family_id=family_id,
            )
        values = (
            loan.title,
            loan.author,
            loan.material_format,
            due_date,
            loan.provider_status,
            None if loan.renewable is None else int(loan.renewable),
            loan.renewal_count,
            None if reset_completion else existing["task_completed_at"] if existing else None,
            None if reset_completion else existing["task_completed_by"] if existing else None,
            synced_at,
            synced_at,
        )
        if existing:
            await db.execute(
                """UPDATE library_loans
                   SET title=?,author=?,material_format=?,due_date=?,provider_status=?,
                       renewable=?,renewal_count=?,task_completed_at=?,task_completed_by=?,
                       last_seen_at=?,updated_at=?,deleted_at=NULL
                   WHERE id=? AND family_id=?""",
                (*values, existing["id"], family_id),
            )
        else:
            await db.execute(
                """INSERT INTO library_loans
                   (id,account_id,external_item_hash,title,author,material_format,due_date,
                    provider_status,renewable,renewal_count,task_completed_at,task_completed_by,
                    last_seen_at,family_id,created_at,updated_at,created_by)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    str(uuid.uuid4()),
                    account_id,
                    item_hash,
                    loan.title,
                    loan.author,
                    loan.material_format,
                    loan.due_date.isoformat(),
                    loan.provider_status,
                    None if loan.renewable is None else int(loan.renewable),
                    loan.renewal_count,
                    None,
                    None,
                    synced_at,
                    family_id,
                    synced_at,
                    synced_at,
                    actor_id,
                ),
            )
    if seen:
        placeholders = ",".join("?" for _ in seen)
        await db.execute(
            f"""UPDATE library_loans SET deleted_at=?,updated_at=?
                WHERE account_id=? AND family_id=? AND deleted_at IS NULL
                  AND external_item_hash NOT IN ({placeholders})""",
            (synced_at, synced_at, account_id, family_id, *sorted(seen)),
        )
    else:
        await db.execute(
            """UPDATE library_loans SET deleted_at=?,updated_at=?
               WHERE account_id=? AND family_id=? AND deleted_at IS NULL""",
            (synced_at, synced_at, account_id, family_id),
        )
    await db.execute(
        """UPDATE library_accounts
           SET last_sync_at=?,last_success_at=?,last_error_code=NULL,next_sync_at=?,updated_at=?
           WHERE id=? AND family_id=? AND deleted_at IS NULL""",
        (
            synced_at,
            synced_at,
            (synced + _SYNC_SUCCESS_DELAY).isoformat(),
            synced_at,
            account_id,
            family_id,
        ),
    )


async def mark_library_sync_failure(
    *,
    account_id: str,
    family_id: str,
    code: str,
    now: datetime | None = None,
) -> None:
    failed = now or datetime.now(timezone.utc)
    failed_at = failed.isoformat()
    async with database_lease() as db:
        await db.execute(
            """UPDATE library_accounts
               SET last_sync_at=?,last_error_code=?,next_sync_at=?,updated_at=?
               WHERE id=? AND family_id=? AND deleted_at IS NULL""",
            (
                failed_at,
                code[:80],
                (failed + _SYNC_FAILURE_DELAY).isoformat(),
                failed_at,
                account_id,
                family_id,
            ),
        )
        await db.commit()


async def sync_due_library_accounts() -> int:
    """Refresh due library cards without retaining credentials in task state."""
    now = datetime.now(timezone.utc)
    async with database_lease() as db:
        rows = await (
            await db.execute(
                """SELECT id,family_id,created_by,encrypted_card_number,encrypted_pin
                   FROM library_accounts
                   WHERE deleted_at IS NULL AND sync_enabled=1
                     AND (next_sync_at IS NULL OR next_sync_at<=?)
                   ORDER BY COALESCE(next_sync_at,created_at) LIMIT 20""",
                (now.isoformat(),),
            )
        ).fetchall()
    completed = 0
    for row in rows:
        try:
            card_number = decrypt_value(row["encrypted_card_number"])
            pin = decrypt_value(row["encrypted_pin"])
            async with ConfiguredLibraryClient() as client:
                loans = await client.current_loans(card_number=card_number, pin=pin)
            async with database_lease() as db:
                await persist_library_sync(
                    db,
                    account_id=row["id"],
                    family_id=row["family_id"],
                    actor_id=row["created_by"] or "library-sync",
                    loans=loans,
                )
                await db.commit()
            completed += 1
        except LibraryConnectionError as exc:
            await mark_library_sync_failure(
                account_id=row["id"], family_id=row["family_id"], code=exc.code
            )
        except Exception:
            logger.error("Library card refresh failed")
            await mark_library_sync_failure(
                account_id=row["id"], family_id=row["family_id"], code="sync_failed"
            )
    return completed

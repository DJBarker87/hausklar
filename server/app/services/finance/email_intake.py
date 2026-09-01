"""Private Finance forwarding aliases and isolated Resend receipt intake."""

import asyncio
import json
import re
import secrets
import string
import uuid
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from email.utils import parseaddr

import httpx

from app.config import settings
from app.models.finance import (
    FinanceEmailAddressResponse,
    FinanceEmailAddressesResponse,
    FinanceEmailEnrollmentCreate,
    FinanceEmailEnrollmentResponse,
    FinanceEmailSendTestResponse,
    FinanceEmailSourceHealthResponse,
    FinancePurchaseEvidenceIngest,
)
from app.services.documents import (
    DocumentStorageError,
    remove_new_upload,
    safe_filename,
    store_bytes,
)
from app.services.finance.evidence import EvidenceIssue
from app.services.finance.delivery_evidence import (
    LABELLED_EMAIL_DELIVERY_ORIGIN,
    labelled_email_delivery_window,
)
from app.services.finance.foundation import (
    accessible_finance_spaces,
    require_finance_access,
    require_finance_space,
)
from app.services.finance.purchase_evidence import ingest_purchase_evidence
from app.services.finance.resource_limits import reserve_finance_resource
from app.services.finance.retailer_email import (
    RetailerEmailFormatError,
    parse_retailer_email,
)
from app.services.idempotency import serialized_create
from app.services.record_history import save_history


_ADDRESS_ALPHABET = string.ascii_lowercase + string.digits
_FINANCE_PREFIX = "finance-"
_GMAIL_INSTRUCTIONS = (
    "In Gmail, create a forwarding rule for retailer receipts and send them to this "
    "Finance address. Forward the verification message first."
)
_OUTLOOK_INSTRUCTIONS = (
    "In Outlook, create a rule that forwards retailer receipts to this Finance "
    "address, then send one real message to verify the source."
)
_LABEL = re.compile(r"^([A-Za-z _-]+):\s*(.+?)\s*$", re.MULTILINE)
_LINE = re.compile(
    r"^(?:item|service):\s*(.+?)\s*\|\s*([£$€]?\s*[0-9]+(?:[.,][0-9]{1,2})?)\s*$",
    re.IGNORECASE | re.MULTILINE,
)


class FinanceEmailError(ValueError):
    """Base error safe to expose from Finance email settings routes."""


class FinanceEmailNotFoundError(FinanceEmailError):
    """An authorised Finance email record was not found."""


class FinanceEmailConflictError(FinanceEmailError):
    """The requested Finance email state conflicts with the current state."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _domain() -> str:
    return settings.resend_inbound_domain.strip().lower().lstrip("@")


def _normalise_address(value: object) -> str:
    raw = str(value or "")
    return (parseaddr(raw)[1] or raw).strip().lower()


def _alias_response(row: dict) -> FinanceEmailAddressResponse:
    return FinanceEmailAddressResponse(
        id=row["id"],
        space_id=row["space_id"],
        alias_kind=row["alias_kind"],
        address=row["address"],
        enabled=bool(row["enabled"]),
        last_received_at=row["last_received_at"],
        last_parsed_at=row["last_parsed_at"],
        last_test_sent_at=row["last_test_sent_at"],
        created_at=row["created_at"],
    )


def _enrollment_response(row: dict) -> FinanceEmailEnrollmentResponse:
    return FinanceEmailEnrollmentResponse(
        id=row["id"],
        alias_id=row["alias_id"],
        space_id=row["space_id"],
        expected_forwarder_address=row["expected_forwarder_address"],
        retailer_domain=row["retailer_domain"],
        transport_marker=row["transport_marker"],
        status=row["status"],
        verified_at=row["verified_at"],
        last_received_at=row["last_received_at"],
        last_success_at=row["last_success_at"],
    )


def _new_address() -> str:
    token = "".join(secrets.choice(_ADDRESS_ALPHABET) for _ in range(16))
    return f"{_FINANCE_PREFIX}{token}@{_domain()}"


async def _insert_alias(db, *, user: dict, space: dict, rotated_from_id=None) -> dict:
    now = _now()
    for _ in range(5):
        address = _new_address()
        collision = await (
            await db.execute(
                "SELECT 1 FROM finance_email_aliases WHERE LOWER(address) = ?",
                (address,),
            )
        ).fetchone()
        if collision is None:
            break
    else:  # pragma: no cover - random collision defence
        raise RuntimeError("Could not allocate a Finance email address")
    identifier = str(uuid.uuid4())
    alias_kind = "PERSONAL" if space["kind"] == "personal" else "HOUSEHOLD"
    owner_user_id = user["id"] if alias_kind == "PERSONAL" else None
    await db.execute(
        """
        INSERT INTO finance_email_aliases
            (id, space_id, alias_kind, owner_user_id, address, enabled,
             rotated_from_id, family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
        """,
        (
            identifier,
            space["id"],
            alias_kind,
            owner_user_id,
            address,
            rotated_from_id,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    row = await (
        await db.execute("SELECT * FROM finance_email_aliases WHERE id = ?", (identifier,))
    ).fetchone()
    return dict(row)


async def _authorised_alias(db, *, user: dict, alias_id: str) -> dict:
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT alias.* FROM finance_email_aliases alias
            JOIN finance_spaces space
              ON space.id = alias.space_id AND space.family_id = alias.family_id
             AND space.deleted_at IS NULL
            WHERE alias.id = ? AND alias.family_id = ? AND alias.enabled = 1
              AND alias.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            """,
            (alias_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceEmailNotFoundError("Finance email address not found")
    return dict(row)


async def list_finance_email_addresses(db, *, user: dict) -> FinanceEmailAddressesResponse:
    spaces = await accessible_finance_spaces(db, user=user)
    if not _domain():
        return FinanceEmailAddressesResponse(
            configured=False,
            gmail_instructions=_GMAIL_INSTRUCTIONS,
            outlook_instructions=_OUTLOOK_INSTRUCTIONS,
        )
    personal = next(space for space in spaces if space.kind == "personal")
    async with serialized_create(db):
        row = await (
            await db.execute(
                """
                SELECT * FROM finance_email_aliases
                WHERE space_id = ? AND family_id = ? AND enabled = 1
                  AND deleted_at IS NULL
                """,
                (personal.id, user["family_id"]),
            )
        ).fetchone()
        if row is None:
            await _insert_alias(
                db,
                user=user,
                space={"id": personal.id, "kind": personal.kind},
            )
        rows = await (
            await db.execute(
                """
                SELECT alias.* FROM finance_email_aliases alias
                JOIN finance_spaces space
                  ON space.id = alias.space_id AND space.family_id = alias.family_id
                 AND space.deleted_at IS NULL
                WHERE alias.family_id = ? AND alias.enabled = 1
                  AND alias.deleted_at IS NULL
                  AND (
                      (space.kind = 'personal' AND space.owner_user_id = ?)
                      OR (space.kind = 'household' AND space.owner_user_id IS NULL)
                  )
                ORDER BY CASE alias.alias_kind WHEN 'PERSONAL' THEN 0 ELSE 1 END,
                         alias.created_at
                """,
                (user["family_id"], user["id"]),
            )
        ).fetchall()
    return FinanceEmailAddressesResponse(
        configured=True,
        addresses=[_alias_response(dict(row)) for row in rows],
        gmail_instructions=_GMAIL_INSTRUCTIONS,
        outlook_instructions=_OUTLOOK_INSTRUCTIONS,
    )


async def create_household_finance_alias(db, *, user: dict) -> FinanceEmailAddressResponse:
    if not _domain():
        raise FinanceEmailConflictError("Inbound email is not configured")
    spaces = await accessible_finance_spaces(db, user=user)
    household = next(space for space in spaces if space.kind == "household")
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_email_aliases
                WHERE space_id = ? AND family_id = ? AND enabled = 1
                  AND deleted_at IS NULL
                """,
                (household.id, user["family_id"]),
            )
        ).fetchone()
        row = (
            dict(existing)
            if existing is not None
            else await _insert_alias(
                db,
                user=user,
                space={"id": household.id, "kind": household.kind},
            )
        )
    return _alias_response(row)


async def rotate_finance_alias(
    db,
    *,
    user: dict,
    alias_id: str,
) -> FinanceEmailAddressResponse:
    if not _domain():
        raise FinanceEmailConflictError("Inbound email is not configured")
    async with serialized_create(db):
        current = await _authorised_alias(db, user=user, alias_id=alias_id)
        space = await require_finance_space(
            db,
            user=user,
            space_id=current["space_id"],
        )
        now = _now()
        await save_history(
            db,
            "finance_email_aliases",
            alias_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_email_aliases
            SET enabled = 0, deleted_at = ?, updated_at = ?
            WHERE id = ? AND enabled = 1 AND deleted_at IS NULL
            """,
            (now, now, alias_id),
        )
        row = await _insert_alias(
            db,
            user=user,
            space=space,
            rotated_from_id=alias_id,
        )
    return _alias_response(row)


async def _send_test_email(*, destination: str, address: str) -> bool:
    if not settings.resend_api_key.strip():
        return False
    payload = {
        "from": settings.resend_from_email,
        "to": [destination],
        "subject": "Test your HausKlar Finance forwarding rule",
        "text": (
            "Forward this message to your private HausKlar Finance address to test "
            f"the rule:\n\n{address}\n\nIt will appear as test evidence, never as a task."
        ),
    }
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.post(
                "https://api.resend.com/emails",
                json=payload,
                headers={
                    "Authorization": f"Bearer {settings.resend_api_key}",
                    "Content-Type": "application/json",
                },
            )
            response.raise_for_status()
            return True
    except httpx.HTTPError:
        return False


async def send_finance_alias_test(
    db,
    *,
    user: dict,
    alias_id: str,
) -> FinanceEmailSendTestResponse:
    alias = await _authorised_alias(db, user=user, alias_id=alias_id)
    recipient = await (
        await db.execute(
            """
            SELECT email FROM users
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (user["id"], user["family_id"]),
        )
    ).fetchone()
    if recipient is None:
        raise FinanceEmailNotFoundError("Finance member not found")
    queued = await _send_test_email(destination=recipient["email"], address=alias["address"])
    if not queued:
        raise FinanceEmailConflictError("Finance test email could not be sent")
    async with serialized_create(db):
        fresh = await _authorised_alias(db, user=user, alias_id=alias_id)
        await save_history(
            db,
            "finance_email_aliases",
            alias_id,
            user["id"],
            family_id=user["family_id"],
        )
        sent_at = _now()
        await db.execute(
            "UPDATE finance_email_aliases SET last_test_sent_at = ?, updated_at = ? "
            "WHERE id = ? AND enabled = 1 AND deleted_at IS NULL",
            (sent_at, sent_at, fresh["id"]),
        )
    return FinanceEmailSendTestResponse(queued=True, destination=recipient["email"])


async def create_finance_email_enrollment(
    db,
    *,
    user: dict,
    alias_id: str,
    body: FinanceEmailEnrollmentCreate,
) -> FinanceEmailEnrollmentResponse:
    async with serialized_create(db):
        alias = await _authorised_alias(db, user=user, alias_id=alias_id)
        forwarder = await (
            await db.execute(
                """
                SELECT id FROM users
                WHERE family_id = ? AND LOWER(email) = ? AND deleted_at IS NULL
                """,
                (user["family_id"], body.expected_forwarder_address),
            )
        ).fetchone()
        if forwarder is None or (
            alias["alias_kind"] == "PERSONAL" and forwarder["id"] != user["id"]
        ):
            raise FinanceEmailNotFoundError("Forwarding mailbox not found")
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_email_enrollments
                WHERE alias_id = ? AND LOWER(expected_forwarder_address) = ?
                  AND retailer_domain = ? AND status IN ('PENDING', 'ACTIVE')
                  AND deleted_at IS NULL
                """,
                (alias_id, body.expected_forwarder_address, body.retailer_domain),
            )
        ).fetchone()
        if existing is not None:
            return _enrollment_response(dict(existing))
        identifier = str(uuid.uuid4())
        now = _now()
        await db.execute(
            """
            INSERT INTO finance_email_enrollments
                (id, space_id, alias_id, expected_forwarder_address,
                 retailer_domain, transport_marker, status, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, 'PENDING', ?, ?, ?, ?)
            """,
            (
                identifier,
                alias["space_id"],
                alias_id,
                body.expected_forwarder_address,
                body.retailer_domain,
                body.transport_marker or body.expected_forwarder_address,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        row = await (
            await db.execute(
                "SELECT * FROM finance_email_enrollments WHERE id = ?",
                (identifier,),
            )
        ).fetchone()
    return _enrollment_response(dict(row))


async def read_finance_email_health(
    db,
    *,
    user: dict,
    alias_id: str,
) -> FinanceEmailSourceHealthResponse:
    alias = await _authorised_alias(db, user=user, alias_id=alias_id)
    health = await (
        await db.execute(
            """
            SELECT source_kind, health_status, last_received_at, last_parsed_at,
                   consecutive_failures, latest_issue_code
            FROM finance_purchase_source_health
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY source_kind
            """,
            (alias["space_id"], user["family_id"]),
        )
    ).fetchall()
    enrollments = await (
        await db.execute(
            """
            SELECT * FROM finance_email_enrollments
            WHERE alias_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY created_at, id
            """,
            (alias_id, alias["space_id"], user["family_id"]),
        )
    ).fetchall()
    open_count = await (
        await db.execute(
            """
            SELECT COUNT(*) AS count FROM finance_purchase_exceptions
            WHERE space_id = ? AND family_id = ? AND status = 'OPEN'
              AND deleted_at IS NULL
            """,
            (alias["space_id"], user["family_id"]),
        )
    ).fetchone()
    return FinanceEmailSourceHealthResponse(
        alias=_alias_response(alias),
        health=[dict(row) for row in health],
        enrollments=[_enrollment_response(dict(row)) for row in enrollments],
        open_exception_count=open_count["count"],
    )


async def match_finance_recipient(db, recipients: list[str]) -> tuple[str, dict | None]:
    """Resolve every Finance alias before ordinary document routing."""
    if not recipients:
        return "none", None
    placeholders = ", ".join("?" for _ in recipients)
    rows = await (
        await db.execute(
            f"""
            SELECT alias.*, space.deleted_at AS space_deleted_at
            FROM finance_email_aliases alias
            LEFT JOIN finance_spaces space
              ON space.id = alias.space_id AND space.family_id = alias.family_id
            WHERE LOWER(alias.address) IN ({placeholders})
            """,
            recipients,
        )
    ).fetchall()
    if not rows:
        return "none", None
    active = [
        dict(row)
        for row in rows
        if row["enabled"] and row["deleted_at"] is None and row["space_deleted_at"] is None
    ]
    if not active:
        return "inactive", None
    if len(active) != 1:
        return "ambiguous", None
    return "active", active[0]


def _header_pairs(email: dict) -> list[tuple[str, str]]:
    headers = email.get("headers") or {}
    if isinstance(headers, dict):
        return [(str(name), str(value)) for name, value in headers.items()]
    if isinstance(headers, list):
        result = []
        for item in headers:
            if isinstance(item, dict):
                result.append(
                    (
                        str(item.get("name") or item.get("key") or ""),
                        str(item.get("value") or ""),
                    )
                )
        return result
    return []


def _passed_dkim_domains(value: str) -> set[str]:
    domains: set[str] = set()
    for segment in re.split(r"(?=\bdkim\s*=)", value.lower()):
        if not re.search(r"\bdkim\s*=\s*pass\b", segment):
            continue
        domain_match = re.search(r"header\.(?:d|i)\s*=\s*@?([a-z0-9.-]+)", segment)
        if domain_match:
            domains.add(domain_match.group(1).rstrip(".;"))
    return domains


def _authentication(email: dict) -> tuple[dict[str, object], str]:
    pairs = _header_pairs(email)
    blob = "\n".join(f"{name}: {value}" for name, value in pairs).lower()
    dkim_domains: set[str] = set()
    arc_domains: set[str] = set()
    receiver_results: list[str] = []
    for name, value in pairs:
        header_name = name.strip().casefold()
        if header_name == "authentication-results":
            receiver_results.append(value)
            dkim_domains.update(_passed_dkim_domains(value))
        elif header_name == "arc-authentication-results":
            arc_domains.update(_passed_dkim_domains(value))
    arc_pass = any(
        re.search(r"\barc\s*=\s*pass\b", value.lower())
        for value in receiver_results
    )
    details: dict[str, object] = {
        "dkim_pass_domains": sorted(dkim_domains),
        "arc_pass": arc_pass,
        "arc_authenticated_domains": sorted(arc_domains),
        "spf_recorded": bool(re.search(r"\bspf\s*=", blob)),
    }
    return details, blob


def _domain_matches(candidate: str, expected: str) -> bool:
    return candidate == expected or candidate.endswith(f".{expected}")


async def _trusted_origin(
    db,
    *,
    alias: dict,
    sender: str,
    email: dict,
) -> tuple[bool, dict | None, dict[str, object], str]:
    authentication, header_blob = _authentication(email)
    sender_domain = sender.rpartition("@")[2]
    dkim_domains = authentication["dkim_pass_domains"]
    arc_pass = bool(authentication["arc_pass"])
    arc_domains = authentication["arc_authenticated_domains"]
    family_sender = await (
        await db.execute(
            """
            SELECT id FROM users
            WHERE family_id = ? AND LOWER(email) = ? AND deleted_at IS NULL
            """,
            (alias["family_id"], sender),
        )
    ).fetchone()
    family_sender_authenticated = any(
        _domain_matches(domain, sender_domain) for domain in dkim_domains
    ) or (
        arc_pass
        and any(_domain_matches(domain, sender_domain) for domain in arc_domains)
    )
    if family_sender is not None and family_sender_authenticated:
        return True, None, authentication, header_blob

    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_email_enrollments
            WHERE alias_id = ? AND space_id = ? AND family_id = ?
              AND status IN ('PENDING', 'ACTIVE') AND deleted_at IS NULL
            ORDER BY CASE status WHEN 'ACTIVE' THEN 0 ELSE 1 END, created_at
            """,
            (alias["id"], alias["space_id"], alias["family_id"]),
        )
    ).fetchall()
    for row in rows:
        enrollment = dict(row)
        if not _domain_matches(sender_domain, enrollment["retailer_domain"]):
            continue
        if enrollment["transport_marker"].casefold() not in header_blob.casefold():
            continue
        original_dkim = any(
            _domain_matches(domain, enrollment["retailer_domain"])
            for domain in dkim_domains
        )
        original_arc = arc_pass and any(
            _domain_matches(domain, enrollment["retailer_domain"])
            for domain in arc_domains
        )
        if original_dkim or original_arc:
            return True, enrollment, authentication, header_blob
        return False, enrollment, authentication, header_blob
    return False, None, authentication, header_blob


def _minor(value: str) -> int:
    cleaned = value.replace("£", "").replace("$", "").replace("€", "").strip()
    cleaned = cleaned.replace(",", ".")
    try:
        decimal = Decimal(cleaned)
    except InvalidOperation as exc:
        raise ValueError("Email money value is invalid") from exc
    if not decimal.is_finite() or decimal < 0 or decimal.as_tuple().exponent < -2:
        raise ValueError("Email money value is invalid")
    return int(decimal * 100)


def _structured_email_payload(
    *,
    source_id: str,
    subject: str,
    body_text: str,
    sender: str,
) -> tuple[str, dict[str, object]] | None:
    retailer_payload = parse_retailer_email(
        source_id=source_id,
        subject=subject,
        body_text=body_text,
        sender=sender,
    )
    if retailer_payload is not None:
        return retailer_payload

    labels = {name.strip().lower(): value.strip() for name, value in _LABEL.findall(body_text)}
    line_values = [(description.strip(), _minor(amount)) for description, amount in _LINE.findall(body_text)]
    total_text = labels.get("total") or labels.get("final total")
    purchased_at = labels.get("date") or labels.get("purchased at") or labels.get("issued at")
    if not line_values or not total_text or not purchased_at:
        return None
    lower_identity = f"{subject} {sender}".lower()
    adapter = (
        "amazon_email"
        if "amazon" in lower_identity
        else "service_invoice"
        if any(value in subject.lower() for value in ("invoice", "bill"))
        else "e_receipt"
    )
    merchant = labels.get("merchant") or sender.rpartition("@")[2]
    lines = [
        {
            "line_reference": f"{source_id}:line:{index}",
            "description": description,
            "net_minor": amount,
        }
        for index, (description, amount) in enumerate(line_values)
    ]
    payload: dict[str, object] = {
        "source_id": source_id,
        "merchant": merchant,
        "currency": labels.get("currency", "GBP").upper(),
        "final_total_minor": _minor(total_text),
    }
    if adapter == "service_invoice":
        payload["issued_at"] = purchased_at
        payload["invoice_reference"] = labels.get("invoice")
        payload["services"] = lines
    else:
        payload["purchased_at"] = purchased_at
        payload["order_reference"] = labels.get("order") or labels.get("receipt")
        payload["lines"] = lines
        if adapter == "amazon_email":
            payload["event_type"] = "order"
    return adapter, payload


async def _claim_finance_message(
    db,
    *,
    alias: dict,
    actor: dict,
    provider_message_id: str,
    internet_message_id: str | None,
    sender: str,
    subject: str,
) -> tuple[str | None, dict[str, object] | None]:
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_email_messages
                WHERE provider_message_id = ? AND deleted_at IS NULL
                """,
                (provider_message_id,),
            )
        ).fetchone()
        if existing is not None and (
            existing["status"] != "FAILED" or existing["alias_id"] != alias["id"]
        ):
            return None, {
                "status": "duplicate",
                "finance_source_id": (
                    existing["source_id"]
                    if existing["alias_id"] == alias["id"]
                    else None
                ),
            }
        # Finance aliases bypass ordinary Documents intake. Count new messages
        # and genuine retries, but let harmless provider replays deduplicate
        # without using the family's evidence budget.
        await reserve_finance_resource(
            db,
            user=actor,
            kind="upload",
            manage_transaction=False,
        )
        now = _now()
        if existing is not None:
            await save_history(
                db,
                "finance_email_messages",
                existing["id"],
                actor["id"],
                family_id=alias["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_email_messages
                SET space_id = ?, alias_id = ?, internet_message_id = ?,
                    visible_sender = ?, subject = ?, status = 'PROCESSING',
                    source_id = NULL, failure_reason = NULL, received_at = ?,
                    updated_at = ?, created_by = ?
                WHERE id = ?
                """,
                (
                    alias["space_id"],
                    alias["id"],
                    internet_message_id,
                    sender,
                    subject,
                    now,
                    now,
                    actor["id"],
                    existing["id"],
                ),
            )
            return existing["id"], None
        identifier = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO finance_email_messages
                (id, space_id, alias_id, provider_message_id,
                 internet_message_id, visible_sender, subject, status,
                 received_at, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'PROCESSING', ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                alias["space_id"],
                alias["id"],
                provider_message_id,
                internet_message_id,
                sender,
                subject,
                now,
                alias["family_id"],
                now,
                now,
                actor["id"],
            ),
        )
        return identifier, None


async def _finance_actor(
    db,
    alias: dict,
    enrollment: dict | None = None,
) -> dict | None:
    if alias["alias_kind"] == "PERSONAL":
        query = (
            "SELECT * FROM users WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL"
        )
        params = (alias["owner_user_id"], alias["family_id"])
        row = await (await db.execute(query, params)).fetchone()
        return dict(row) if row is not None else None
    if enrollment is not None:
        query = (
            "SELECT * FROM users WHERE family_id = ? AND LOWER(email) = ? "
            "AND deleted_at IS NULL"
        )
        params = (alias["family_id"], enrollment["expected_forwarder_address"])
        row = await (await db.execute(query, params)).fetchone()
        if row is not None:
            return dict(row)
    # Household automatic intake is deliberately not attributed to whichever
    # family adult happens to sort first.
    return {
        "id": None,
        "family_id": alias["family_id"],
    }


async def _prepare_files(
    *,
    email_id: str,
    email: dict,
    family_id: str,
    space_id: str,
    source_id: str,
) -> tuple[list[dict[str, object]], list[str], str, bool]:
    from app.services.inbound_email import (
        _attachment_details,
        _download_attachment,
        _extract_text,
        _media_type,
    )

    files: list[dict[str, object]] = []
    storage_keys: list[str] = []
    extracted_parts: list[str] = []
    unsafe = False
    storage_family = f"finance-evidence/{family_id}/{space_id}"
    raw_email = json.dumps(email, ensure_ascii=True, default=str).encode("utf-8")
    if len(raw_email) <= settings.document_max_upload_bytes:
        storage_key, _, size, _ = await store_bytes(
            raw_email,
            filename="message.txt",
            media_type="text/plain",
            family_id=storage_family,
            document_id=source_id,
        )
        storage_keys.append(storage_key)
        files.append(
            {
                "file_role": "MESSAGE",
                "filename": "message.txt",
                "media_type": "text/plain",
                "storage_key": storage_key,
                "byte_size": size,
                "storage_status": "STORED",
            }
        )
    else:
        unsafe = True
        files.append(
            {
                "file_role": "MESSAGE",
                "filename": "message.txt",
                "media_type": "text/plain",
                "storage_key": None,
                "byte_size": len(raw_email),
                "storage_status": "REJECTED_SIZE",
            }
        )

    total_bytes = 0
    attachments = [item for item in email.get("attachments") or [] if isinstance(item, dict)]
    for index, attachment in enumerate(attachments):
        filename = safe_filename(attachment.get("filename"))
        declared_size = 0
        try:
            declared_size = max(int(attachment.get("size") or 0), 0)
        except (TypeError, ValueError):
            unsafe = True
        media_type = _media_type(filename, attachment.get("content_type"))
        if index >= 10 or declared_size > settings.document_max_upload_bytes:
            unsafe = True
            files.append(
                {
                    "file_role": "ATTACHMENT",
                    "filename": filename,
                    "media_type": str(attachment.get("content_type") or "application/octet-stream"),
                    "storage_key": None,
                    "byte_size": declared_size,
                    "storage_status": "REJECTED_SIZE",
                }
            )
            continue
        if media_type is None:
            unsafe = True
            files.append(
                {
                    "file_role": "ATTACHMENT",
                    "filename": filename,
                    "media_type": str(attachment.get("content_type") or "application/octet-stream"),
                    "storage_key": None,
                    "byte_size": declared_size,
                    "storage_status": "REJECTED_TYPE",
                }
            )
            continue
        attachment_id = str(attachment.get("id") or "").strip()
        if not attachment_id:
            unsafe = True
            files.append(
                {
                    "file_role": "ATTACHMENT",
                    "filename": filename,
                    "media_type": media_type,
                    "storage_key": None,
                    "byte_size": declared_size,
                    "storage_status": "REJECTED_UNSAFE",
                }
            )
            continue
        try:
            details = await _attachment_details(email_id, attachment_id)
            data = await _download_attachment(details["download_url"])
        except (DocumentStorageError, httpx.HTTPError, KeyError):
            unsafe = True
            files.append(
                {
                    "file_role": "ATTACHMENT",
                    "filename": filename,
                    "media_type": media_type,
                    "storage_key": None,
                    "byte_size": declared_size,
                    "storage_status": "REJECTED_UNSAFE",
                }
            )
            continue
        total_bytes += len(data)
        if total_bytes > settings.document_max_upload_bytes * 2:
            unsafe = True
            files.append(
                {
                    "file_role": "ATTACHMENT",
                    "filename": filename,
                    "media_type": media_type,
                    "storage_key": None,
                    "byte_size": len(data),
                    "storage_status": "REJECTED_SIZE",
                }
            )
            continue
        storage_key, _, size, _ = await store_bytes(
            data,
            filename=f"attachment-{index + 1}-{filename}",
            media_type=media_type,
            family_id=storage_family,
            document_id=source_id,
        )
        storage_keys.append(storage_key)
        files.append(
            {
                "file_role": "ATTACHMENT",
                "filename": filename,
                "media_type": media_type,
                "storage_key": storage_key,
                "byte_size": size,
                "storage_status": "STORED",
            }
        )
        extracted, _ = await asyncio.to_thread(_extract_text, data, media_type)
        if extracted:
            extracted_parts.append(extracted)
    return files, storage_keys, "\n\n".join(extracted_parts), unsafe


async def _finish_finance_message(
    db,
    *,
    message_id: str,
    alias: dict,
    actor: dict,
    enrollment: dict | None,
    authentication: dict[str, object],
    source_id: str,
    extraction_status: str,
    visible_sender: str,
) -> None:
    async with serialized_create(db):
        now = _now()
        await save_history(
            db,
            "finance_email_messages",
            message_id,
            actor["id"],
            family_id=alias["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_email_messages
            SET enrollment_id = ?, source_id = ?, status = ?,
                failure_reason = NULL, updated_at = ?, created_by = ?,
                visible_sender = ?
            WHERE id = ? AND status = 'PROCESSING' AND deleted_at IS NULL
            """,
            (
                enrollment["id"] if enrollment else None,
                source_id,
                extraction_status,
                now,
                actor["id"],
                visible_sender,
                message_id,
            ),
        )
        fresh_alias = await (
            await db.execute(
                "SELECT * FROM finance_email_aliases WHERE id = ?",
                (alias["id"],),
            )
        ).fetchone()
        await save_history(
            db,
            "finance_email_aliases",
            alias["id"],
            actor["id"],
            family_id=alias["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_email_aliases
            SET last_received_at = ?, last_parsed_at = ?, updated_at = ?
            WHERE id = ? AND enabled = 1 AND deleted_at IS NULL
            """,
            (
                now,
                now if extraction_status == "PARSED" else fresh_alias["last_parsed_at"],
                now,
                alias["id"],
            ),
        )
        if enrollment is not None:
            await save_history(
                db,
                "finance_email_enrollments",
                enrollment["id"],
                actor["id"],
                family_id=alias["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_email_enrollments
                SET status = 'ACTIVE', verified_at = COALESCE(verified_at, ?),
                    last_received_at = ?, last_success_at = ?,
                    last_authentication_json = ?, updated_at = ?
                WHERE id = ? AND status IN ('PENDING', 'ACTIVE')
                  AND deleted_at IS NULL
                """,
                (
                    now,
                    now,
                    now,
                    json.dumps(authentication, sort_keys=True),
                    now,
                    enrollment["id"],
                ),
            )


async def _mark_finance_message_failed(
    db,
    *,
    message_id: str,
    reason: str,
) -> None:
    # Exception text can contain sender identifiers, receipt contents, headers,
    # or attachment-derived values. Persist an operational code only.
    safe_reason = (
        reason
        if reason in {"EMAIL_PROCESSING_FAILED", "EMAIL_SOURCE_REJECTED"}
        else "EMAIL_PROCESSING_FAILED"
    )
    async with serialized_create(db):
        await db.execute(
            """
            UPDATE finance_email_messages
            SET status = 'FAILED', failure_reason = ?, updated_at = ?
            WHERE id = ? AND status = 'PROCESSING' AND deleted_at IS NULL
            """,
            (safe_reason, _now(), message_id),
        )


async def process_finance_received_email(
    payload: dict,
    *,
    alias: dict,
    db,
) -> dict[str, object]:
    """Store one exact-recipient Finance message without touching Documents."""
    email_id = str(payload.get("email_id") or "").strip()
    if not email_id:
        raise ValueError("Inbound Finance email is missing email_id")
    claim_actor = await _finance_actor(db, alias)
    if claim_actor is None:
        return {"status": "ignored", "reason": "inactive_finance_recipient"}
    sender = _normalise_address(payload.get("from"))
    subject = str(payload.get("subject") or "Finance email").strip()[:300]
    message_id, duplicate = await _claim_finance_message(
        db,
        alias=alias,
        actor=claim_actor,
        provider_message_id=email_id,
        internet_message_id=(str(payload.get("message_id")) if payload.get("message_id") else None),
        sender=sender,
        subject=subject,
    )
    if duplicate is not None:
        return duplicate
    if message_id is None:  # pragma: no cover - claim contract
        raise RuntimeError("Finance email claim returned no record")

    source_id = str(uuid.uuid4())
    stored_keys: list[str] = []
    try:
        from app.services.inbound_email import _plain_html, _retrieve_email

        email = await _retrieve_email(email_id)
        retrieved_sender = _normalise_address(email.get("from"))
        sender_mismatch = bool(retrieved_sender and retrieved_sender != sender)
        sender = retrieved_sender or sender
        trusted, enrollment, authentication, _ = await _trusted_origin(
            db,
            alias=alias,
            sender=sender,
            email=email,
        )
        authentication["webhook_sender_matches_message"] = not sender_mismatch
        trusted = trusted and not sender_mismatch
        actor = await _finance_actor(db, alias, enrollment if trusted else None)
        if actor is None:
            raise RuntimeError("Finance alias owner is no longer active")
        body_text = str(email.get("text") or "").strip() or _plain_html(email.get("html"))
        files, stored_keys, attachment_text, unsafe = await _prepare_files(
            email_id=email_id,
            email=email,
            family_id=alias["family_id"],
            space_id=alias["space_id"],
            source_id=source_id,
        )
        combined_text = "\n\n".join(
            value for value in (body_text[:150_000], attachment_text[:150_000]) if value
        )
        parse_issue = None
        recognised_adapter = None
        try:
            structured = _structured_email_payload(
                source_id=email_id,
                subject=subject,
                body_text=combined_text,
                sender=sender,
            )
        except RetailerEmailFormatError as exc:
            structured = None
            recognised_adapter = exc.adapter
            parse_issue = EvidenceIssue(
                code=exc.code,
                message=exc.safe_message,
            )
        except ValueError:
            structured = None
            parse_issue = EvidenceIssue(
                code="email_parse_failed",
                message="The receipt or invoice text contains an invalid value.",
            )
        if structured is not None:
            adapter, structured_payload = structured
        else:
            stored_media = [
                file["media_type"]
                for file in files
                if file["file_role"] == "ATTACHMENT"
                and file["storage_status"] == "STORED"
            ]
            adapter = recognised_adapter or (
                "pdf"
                if "application/pdf" in stored_media
                else "image"
                if any(str(value).startswith("image/") for value in stored_media)
                else "html"
            )
            structured_payload = {"source_id": email_id}
        if (
            trusted
            and not unsafe
            and parse_issue is None
            and "delivery_window" not in structured_payload
        ):
            timezone_row = await (
                await db.execute(
                    "SELECT household_timezone FROM finance_settings "
                    "WHERE family_id = ? AND deleted_at IS NULL",
                    (alias["family_id"],),
                )
            ).fetchone()
            if timezone_row is not None:
                delivery_window = labelled_email_delivery_window(
                    combined_text,
                    timezone_name=timezone_row["household_timezone"],
                )
                if delivery_window is not None:
                    structured_payload["delivery_window"] = delivery_window
                    structured_payload["_delivery_window_origin"] = (
                        LABELLED_EMAIL_DELIVERY_ORIGIN
                    )
        envelope = json.loads(json.dumps(email, ensure_ascii=True, default=str))
        structured_payload["_finance_email"] = {
            "provider_message_id": email_id,
            "internet_message_id": payload.get("message_id"),
            "visible_sender": sender,
            "recipient": alias["address"],
            "subject": subject,
            "headers": envelope.get("headers"),
            "attachments": envelope.get("attachments"),
            "text": str(envelope.get("text") or "")[:150_000],
            "html": str(envelope.get("html") or "")[:150_000],
            "authentication": authentication,
        }
        forced_issue = None
        if sender_mismatch:
            forced_issue = EvidenceIssue(
                code="email_sender_mismatch",
                message="The webhook sender did not match the retrieved message sender.",
            )
        elif not trusted:
            forced_issue = EvidenceIssue(
                code="email_origin_unverified",
                message=(
                    "The sender or original DKIM/ARC evidence did not match an active "
                    "family sender or enrolled forwarding source."
                ),
            )
        elif unsafe:
            forced_issue = EvidenceIssue(
                code="unsafe_email_attachment",
                message="One or more attachments failed Finance size or type checks.",
            )
        elif parse_issue is not None:
            forced_issue = parse_issue
        primary = next(
            (file for file in files if file["file_role"] == "MESSAGE"),
            None,
        )
        response = await ingest_purchase_evidence(
            db,
            user=actor,
            space_id=alias["space_id"],
            body=FinancePurchaseEvidenceIngest(
                external_source_id=email_id,
                adapter=adapter,
                reviewed=True,
                payload=structured_payload,
                received_at=datetime.now(timezone.utc),
            ),
            source_id_override=source_id,
            forced_issue=forced_issue,
            email_context={
                "storage_key": primary.get("storage_key") if primary else None,
                "media_type": primary.get("media_type") if primary else None,
                "byte_size": primary.get("byte_size") if primary else None,
                "email_alias_id": alias["id"],
                "email_enrollment_id": enrollment["id"] if enrollment else None,
                "provider_message_id": email_id,
                "internet_message_id": (
                    str(payload.get("message_id")) if payload.get("message_id") else None
                ),
                "visible_sender": sender,
                "email_subject": subject,
                "authentication_json": json.dumps(authentication, sort_keys=True),
            },
            evidence_files=files,
        )
        status = response.source.extraction_status
        # A verified household Tesco receipt can quietly extend the shared
        # grocery history. Personal Finance evidence is never copied into the
        # family Meals surface, and failure here cannot break receipt intake.
        if (
            alias["alias_kind"] == "HOUSEHOLD"
            and adapter == "tesco_batch"
            and status == "PARSED"
        ):
            try:
                from app.services.tesco_history import import_receipt_payload

                async with serialized_create(db):
                    await import_receipt_payload(
                        db,
                        family_id=alias["family_id"],
                        actor_id=actor["id"],
                        payload=structured_payload,
                    )
            except Exception:
                pass
        await _finish_finance_message(
            db,
            message_id=message_id,
            alias=alias,
            actor=actor,
            enrollment=enrollment if trusted else None,
            authentication=authentication,
            source_id=response.source.id,
            extraction_status=status,
            visible_sender=sender,
        )
        return {
            "status": status.lower(),
            "finance_source_id": response.source.id,
            "purchase_id": response.purchase.id if response.purchase else None,
            "exception_id": response.exception.id if response.exception else None,
        }
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        await asyncio.gather(
            *(remove_new_upload(key) for key in stored_keys),
            return_exceptions=True,
        )
        await _mark_finance_message_failed(
            db,
            message_id=message_id,
            reason="EMAIL_PROCESSING_FAILED",
        )
        raise

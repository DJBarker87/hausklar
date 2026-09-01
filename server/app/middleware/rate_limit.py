"""Rate limiting middleware for brute-force protection."""

import ipaddress
import math
import time
import uuid

from fastapi import HTTPException, Request, status


async def reserve_persistent_attempts(
    db,
    rules: list[tuple[str, int, int]],
    *,
    detail_prefix: str,
    manage_transaction: bool = True,
) -> None:
    """Atomically reserve durable rate-limit budget for every supplied key.

    Set ``manage_transaction`` to false only when the caller already owns an
    IMMEDIATE transaction and will commit or roll it back.
    """
    now = time.time()
    if manage_transaction:
        await db.execute("BEGIN IMMEDIATE")
    elif not db.in_transaction:
        raise RuntimeError("A caller-managed rate-limit reservation needs a transaction")
    try:
        for key, maximum, window_seconds in rules:
            cutoff = now - window_seconds
            await db.execute(
                "DELETE FROM security_rate_limit_events "
                "WHERE rate_key = ? AND created_at <= ?",
                (key, cutoff),
            )
            cursor = await db.execute(
                "SELECT COUNT(*), MIN(created_at) FROM security_rate_limit_events "
                "WHERE rate_key = ?",
                (key,),
            )
            count, oldest = await cursor.fetchone()
            if count >= maximum:
                retry_after = max(1, math.ceil((oldest + window_seconds) - now))
                retry_minutes = math.ceil(retry_after / 60)
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail=f"{detail_prefix}. Try again in {retry_minutes} minutes.",
                    headers={"Retry-After": str(retry_after)},
                )
        await db.executemany(
            "INSERT INTO security_rate_limit_events (id, rate_key, created_at) "
            "VALUES (?, ?, ?)",
            [(str(uuid.uuid4()), key, now) for key, _, _ in rules],
        )
        if manage_transaction:
            await db.commit()
    except BaseException:
        if manage_transaction and db.in_transaction:
            await db.rollback()
        raise


async def clear_persistent_attempts(db, *keys: str) -> None:
    if not keys:
        return
    placeholders = ",".join("?" for _ in keys)
    await db.execute(
        f"DELETE FROM security_rate_limit_events WHERE rate_key IN ({placeholders})",
        keys,
    )
    await db.commit()


class RateLimiter:
    """Brute-force limiter used by login flow.

    Tracks failed login attempts by key (typically client IP). Successful
    logins should clear the failure bucket.
    """

    def __init__(
        self,
        max_attempts: int = 5,
        window_seconds: int = 15 * 60,
    ) -> None:
        self.max_attempts = max_attempts
        self.window_seconds = window_seconds
        # {ip_address: [timestamp, ...]}
        self._attempts: dict[str, list[float]] = {}

    def _pruned(self, key: str) -> list[float]:
        """Return non-expired timestamps for a key."""
        now = time.time()
        cutoff = now - self.window_seconds
        timestamps = self._attempts.get(key, [])
        return [t for t in timestamps if t > cutoff]

    def ensure_allowed(
        self,
        key: str,
        *,
        detail_prefix: str = "Too many login attempts",
    ) -> None:
        """Raise HTTP 429 when the key is currently rate-limited."""
        timestamps = self._pruned(key)
        now = time.time()

        if len(timestamps) >= self.max_attempts:
            oldest = timestamps[0]
            retry_after = math.ceil((oldest + self.window_seconds) - now)
            retry_minutes = math.ceil(retry_after / 60)
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=f"{detail_prefix}. Try again in {retry_minutes} minutes.",
                headers={"Retry-After": str(retry_after)},
            )

        self._attempts[key] = timestamps

    def record_failure(self, key: str) -> None:
        """Record a failed login attempt for the key."""
        timestamps = self._pruned(key)
        timestamps.append(time.time())
        self._attempts[key] = timestamps

    def record_success(self, key: str) -> None:
        """Clear failure history for a key after successful login."""
        self._attempts.pop(key, None)

    # Keep callable form for compatibility with existing dependency usage.
    async def __call__(self, request: Request) -> None:
        ip = request.client.host if request.client else "unknown"
        self.ensure_allowed(ip)

    def reset(self) -> None:
        """Clear all tracked attempts (useful in tests)."""
        self._attempts.clear()


def extract_client_ip(request: Request) -> str:
    """Resolve best-effort client IP with trusted-proxy awareness.

    If the direct peer is loopback/private, trust Cloudflare/Caddy forwarding
    headers to recover the real internet client IP.
    """
    direct_ip = request.client.host if request.client else "unknown"
    if direct_ip == "unknown":
        return direct_ip

    try:
        parsed_direct = ipaddress.ip_address(direct_ip)
    except ValueError:
        return direct_ip

    if not (parsed_direct.is_loopback or parsed_direct.is_private):
        return direct_ip

    cf_ip = request.headers.get("CF-Connecting-IP")
    if cf_ip:
        candidate = cf_ip.strip()
        try:
            ipaddress.ip_address(candidate)
            return candidate
        except ValueError:
            pass

    xff = request.headers.get("X-Forwarded-For", "")
    if xff:
        # Left-most XFF entry is the original client per de-facto convention.
        candidate = xff.split(",")[0].strip()
        try:
            ipaddress.ip_address(candidate)
            return candidate
        except ValueError:
            pass

    return direct_ip

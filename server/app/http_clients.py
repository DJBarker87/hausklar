"""Lifecycle-scoped outbound HTTP clients, separated by provider boundary."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass

import httpx


@dataclass
class _ClientEntry:
    loop: asyncio.AbstractEventLoop
    client: httpx.AsyncClient


_clients: dict[str, _ClientEntry] = {}
_client_lock = asyncio.Lock()


async def provider_client(
    name: str,
    *,
    timeout: float | httpx.Timeout,
    follow_redirects: bool = False,
    trust_env: bool = True,
) -> httpx.AsyncClient:
    """Return one connection-pooled client for a single provider trust boundary."""
    loop = asyncio.get_running_loop()
    async with _client_lock:
        existing = _clients.get(name)
        if existing is not None and existing.loop is loop:
            return existing.client
        if existing is not None:
            await existing.client.aclose()
        client = httpx.AsyncClient(
            timeout=timeout,
            follow_redirects=follow_redirects,
            trust_env=trust_env,
            limits=httpx.Limits(
                max_connections=12,
                max_keepalive_connections=6,
                keepalive_expiry=30.0,
            ),
        )
        _clients[name] = _ClientEntry(loop=loop, client=client)
        return client


async def close_http_clients() -> None:
    """Close every provider pool during application shutdown."""
    async with _client_lock:
        entries = list(_clients.values())
        _clients.clear()
    for entry in entries:
        await entry.client.aclose()

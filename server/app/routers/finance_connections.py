"""Authenticated routes for read-only Finance bank connections."""

from collections.abc import AsyncIterator
from urllib.parse import urlencode, urlparse

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import RedirectResponse

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.middleware.rate_limit import extract_client_ip
from app.models.finance_connection import (
    FinanceBankInstitutionResponse,
    FinanceConnectionDisconnectResponse,
    FinanceConnectionResponse,
    FinanceConnectionStartRequest,
    FinanceConnectionStartResponse,
    FinanceConnectionSyncResponse,
    FinanceTrueLayerConnectionStartRequest,
)
from app.services.finance.enable_banking_connections import (
    FinanceConnectionCapabilityError,
    FinanceConnectionError,
    FinanceConnectionNotFoundError,
    FinanceConnectionProviderUnavailableError,
    FinanceConnectionStateError,
    cancel_enable_banking_callback,
    bank_connection_provider,
    complete_enable_banking_callback,
    disconnect_bank_connection,
    list_bank_connections,
    start_enable_banking_connection,
    sync_enable_banking_connection,
)
from app.services.finance.foundation import FinanceAccessDeniedError, require_finance_access
from app.services.finance.providers.base import ProviderError, ReadOnlyBankProvider
from app.services.finance.providers.enable_banking_config import (
    EnableBankingConfigurationError,
    configured_enable_banking_provider,
    enable_banking_callback_url,
)
from app.services.finance.providers.truelayer import TrueLayerAdapter
from app.services.finance.providers.truelayer_config import (
    TrueLayerConfigurationError,
    configured_truelayer_provider,
)
from app.services.finance.resource_limits import (
    finance_process_slot,
    reserve_finance_resource,
)
from app.services.finance.truelayer_connections import (
    cancel_truelayer_callback,
    claim_truelayer_callback,
    complete_truelayer_callback,
    fail_truelayer_callback_claim,
    start_truelayer_connection,
    sync_truelayer_connection,
)

router = APIRouter()


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


async def enable_banking_provider_dependency(
) -> AsyncIterator[ReadOnlyBankProvider]:
    try:
        async with configured_enable_banking_provider() as provider:
            yield provider
    except EnableBankingConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


async def truelayer_provider_dependency() -> AsyncIterator[TrueLayerAdapter]:
    try:
        async with configured_truelayer_provider() as provider:
            yield provider
    except TrueLayerConfigurationError as exc:
        raise HTTPException(status_code=503, detail="Bank connection is unavailable") from exc


def _connection_error(exc: Exception) -> HTTPException:
    if isinstance(exc, (FinanceAccessDeniedError, FinanceConnectionNotFoundError)):
        return HTTPException(status_code=404, detail="Finance connection or space not found")
    if isinstance(exc, FinanceConnectionStateError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, FinanceConnectionCapabilityError):
        return HTTPException(status_code=422, detail=str(exc))
    if isinstance(exc, FinanceConnectionProviderUnavailableError):
        return HTTPException(status_code=502, detail=str(exc))
    if isinstance(exc, (EnableBankingConfigurationError, TrueLayerConfigurationError)):
        return HTTPException(status_code=503, detail="Bank connection is unavailable")
    if isinstance(exc, ProviderError):
        return HTTPException(status_code=502, detail="Bank data request failed")
    return HTTPException(status_code=422, detail=str(exc))


def _finance_return_url(marker: str, *, client: str = "web") -> str:
    if client == "ios":
        return f"hausklar://finance-bank?{urlencode({'bank': marker})}"
    configured = settings.web_app_url.strip()
    parsed = urlparse(configured)
    try:
        explicit_port = parsed.port is not None
    except ValueError:
        explicit_port = True
    clean_origin = (
        parsed.scheme == "https"
        and bool(parsed.hostname)
        and parsed.username is None
        and parsed.password is None
        and not explicit_port
        and parsed.path in {"", "/"}
        and not parsed.params
        and not parsed.query
        and not parsed.fragment
    )
    base = configured.rstrip("/") if clean_origin else ""
    query = {"view": "finance", "section": "setup", "bank": marker}
    return f"{base}/?{urlencode(query)}"


@router.post(
    "/connections/truelayer/start",
    response_model=FinanceConnectionStartResponse,
)
async def start_truelayer_bank_connection(
    body: FinanceTrueLayerConnectionStartRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
    provider: TrueLayerAdapter = Depends(truelayer_provider_dependency),
):
    try:
        with finance_process_slot(user=current_user, kind="provider"):
            await reserve_finance_resource(db, user=current_user, kind="provider")
            redirect_url = await start_truelayer_connection(
                db,
                user=current_user,
                body=body,
                provider=provider,
            )
    except (FinanceAccessDeniedError, FinanceConnectionError, ProviderError) as exc:
        raise _connection_error(exc) from exc
    return FinanceConnectionStartResponse(redirect_url=redirect_url)


@router.get("/connections/truelayer/callback", response_class=RedirectResponse)
async def finish_truelayer_bank_connection(
    state: str | None = Query(default=None),
    code: str | None = Query(default=None),
    error: str | None = Query(default=None),
    db=Depends(get_db),
):
    if state is None or not 20 <= len(state) <= 500:
        return RedirectResponse(_finance_return_url("failed"), status_code=303)
    if error == "access_denied":
        try:
            client = await cancel_truelayer_callback(db, state=state)
        except (FinanceAccessDeniedError, FinanceConnectionError):
            return RedirectResponse(_finance_return_url("failed"), status_code=303)
        return RedirectResponse(
            _finance_return_url("cancelled", client=client),
            status_code=303,
        )
    if error is not None or code is None or not 1 <= len(code) <= 2_000:
        try:
            claim = await claim_truelayer_callback(db, state=state)
            await fail_truelayer_callback_claim(
                db,
                claim=claim,
                error_code="AUTHORISATION_PROVIDER_FAILED",
            )
        except (FinanceAccessDeniedError, FinanceConnectionError):
            return RedirectResponse(_finance_return_url("failed"), status_code=303)
        return RedirectResponse(
            _finance_return_url("failed", client=claim.client),
            status_code=303,
        )
    try:
        claim = await claim_truelayer_callback(db, state=state)
    except (FinanceAccessDeniedError, FinanceConnectionError):
        return RedirectResponse(_finance_return_url("failed"), status_code=303)
    try:
        async with configured_truelayer_provider() as provider:
            await complete_truelayer_callback(
                db,
                claim=claim,
                code=code,
                provider=provider,
            )
    except TrueLayerConfigurationError:
        await fail_truelayer_callback_claim(db, claim=claim)
        return RedirectResponse(
            _finance_return_url("failed", client=claim.client),
            status_code=303,
        )
    except (FinanceAccessDeniedError, FinanceConnectionError, ProviderError):
        return RedirectResponse(
            _finance_return_url("failed", client=claim.client),
            status_code=303,
        )
    return RedirectResponse(
        _finance_return_url("connected", client=claim.client),
        status_code=303,
    )


@router.get(
    "/connections/enable-banking/institutions",
    response_model=list[FinanceBankInstitutionResponse],
)
async def read_finance_bank_institutions(
    country: str = Query(default="GB", min_length=2, max_length=2),
    current_user: dict = Depends(_finance_user),
    provider: ReadOnlyBankProvider = Depends(enable_banking_provider_dependency),
):
    try:
        with finance_process_slot(user=current_user, kind="provider"):
            institutions = await provider.institutions(
                country=country,
                psu_type="personal",
            )
    except ProviderError as exc:
        raise _connection_error(exc) from exc
    return [
        FinanceBankInstitutionResponse(
            name=institution.name,
            country=institution.country,
            maximum_consent_validity_seconds=(
                institution.maximum_consent_validity_seconds
            ),
        )
        for institution in institutions
    ]


@router.post(
    "/connections/enable-banking/start",
    response_model=FinanceConnectionStartResponse,
)
async def start_finance_connection(
    body: FinanceConnectionStartRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
    provider: ReadOnlyBankProvider = Depends(enable_banking_provider_dependency),
):
    try:
        with finance_process_slot(user=current_user, kind="provider"):
            await reserve_finance_resource(db, user=current_user, kind="provider")
            redirect_url = await start_enable_banking_connection(
                db,
                user=current_user,
                body=body,
                provider=provider,
                callback_url=enable_banking_callback_url(),
            )
    except (FinanceAccessDeniedError, FinanceConnectionError, ProviderError) as exc:
        raise _connection_error(exc) from exc
    except EnableBankingConfigurationError as exc:
        raise _connection_error(exc) from exc
    return FinanceConnectionStartResponse(redirect_url=redirect_url)


@router.get("/connections/enable-banking/callback", response_class=RedirectResponse)
async def finish_finance_connection(
    state: str = Query(min_length=20, max_length=500),
    code: str | None = Query(default=None, min_length=1, max_length=500),
    error: str | None = Query(default=None, max_length=200),
    db=Depends(get_db),
    provider: ReadOnlyBankProvider = Depends(enable_banking_provider_dependency),
):
    if error or not code:
        try:
            await cancel_enable_banking_callback(
                db,
                state=state,
            )
        except (FinanceAccessDeniedError, FinanceConnectionError):
            return RedirectResponse(_finance_return_url("failed"), status_code=303)
        return RedirectResponse(_finance_return_url("cancelled"), status_code=303)
    try:
        await complete_enable_banking_callback(
            db,
            state=state,
            code=code,
            provider=provider,
        )
    except (
        FinanceAccessDeniedError,
        FinanceConnectionError,
        ProviderError,
    ):
        return RedirectResponse(_finance_return_url("failed"), status_code=303)
    return RedirectResponse(
        _finance_return_url("connected"),
        status_code=303,
    )


@router.get("/connections", response_model=list[FinanceConnectionResponse])
async def read_finance_connections(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_bank_connections(
            db,
            user=current_user,
            space_id=space_id,
        )
    except FinanceAccessDeniedError as exc:
        raise _connection_error(exc) from exc


@router.post(
    "/connections/{connection_id}/sync",
    response_model=FinanceConnectionSyncResponse,
)
async def sync_finance_connection(
    connection_id: str,
    request: Request,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        with finance_process_slot(user=current_user, kind="provider"):
            await reserve_finance_resource(db, user=current_user, kind="provider")
            selected_provider = await bank_connection_provider(
                db,
                user=current_user,
                connection_id=connection_id,
            )
            if selected_provider == "TRUELAYER":
                async with configured_truelayer_provider() as provider:
                    # This forwarding trust relies on HausKlar's production bind:
                    # port 8001 is exposed only on 192.0.2.129, not to the LAN, so a
                    # private direct peer is Caddy/cloudflared on the NUC. The shared
                    # resolver ignores forwarded headers from public direct peers,
                    # and the adapter omits non-public resolved addresses. If the API
                    # bind changes, this attended-request header must be disabled or
                    # replaced with an explicit trusted-proxy allowlist first.
                    provider = provider.for_end_user(extract_client_ip(request))
                    return await sync_truelayer_connection(
                        db,
                        user=current_user,
                        connection_id=connection_id,
                        provider=provider,
                    )
            async with configured_enable_banking_provider() as provider:
                return await sync_enable_banking_connection(
                    db,
                    user=current_user,
                    connection_id=connection_id,
                    provider=provider,
                )
    except (
        FinanceAccessDeniedError,
        FinanceConnectionError,
        ProviderError,
        EnableBankingConfigurationError,
        TrueLayerConfigurationError,
    ) as exc:
        raise _connection_error(exc) from exc


@router.delete(
    "/connections/{connection_id}",
    response_model=FinanceConnectionDisconnectResponse,
)
async def disconnect_finance_connection(
    connection_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await disconnect_bank_connection(
            db,
            user=current_user,
            connection_id=connection_id,
        )
    except (FinanceAccessDeniedError, FinanceConnectionError) as exc:
        raise _connection_error(exc) from exc

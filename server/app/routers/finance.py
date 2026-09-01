from datetime import date, datetime
from typing import Literal
import uuid

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Response, UploadFile, status
from fastapi.responses import FileResponse

from app.auth import get_current_user
from app.database import database_lease, get_db
from app.models.finance import (
    FinanceAccountCreate,
    FinanceAccountResponse,
    FinanceAIConsentAccept,
    FinanceAIConsentResponse,
    FinanceCoachAsk,
    FinanceCommitmentCreate,
    FinanceCommitmentResponse,
    FinanceCommitmentUpdate,
    FinanceCalendarItemCreate,
    FinanceCalendarItemPrefillResponse,
    FinanceCalendarItemResponse,
    FinanceEmailAddressResponse,
    FinanceEmailAddressesResponse,
    FinanceEmailEnrollmentCreate,
    FinanceEmailEnrollmentResponse,
    FinanceEmailSendTestResponse,
    FinanceEmailSourceHealthResponse,
    FinanceFactCreate,
    FinanceFactResponse,
    FinanceFactUpdate,
    FinanceForecastGenerate,
    FinanceForecastOverviewResponse,
    FinanceForecastResponse,
    FinanceFindingDisposition,
    FinanceFindingResponse,
    FinanceGoalCreate,
    FinanceGoalResponse,
    FinanceGoalUpdate,
    FinanceLedgerSummaryResponse,
    FinanceManualAccountCreate,
    FinanceMaterialQuestionAnswer,
    FinanceMaterialQuestionCorrection,
    FinanceMaterialQuestionResponse,
    FinanceOverviewResponse,
    FinancePatternScanResponse,
    FinancePreferenceCreate,
    FinancePreferenceResponse,
    FinancePreferenceUpdate,
    FinanceProjectionPreferenceResponse,
    FinanceProjectionPreferenceUpdate,
    FinancePurchaseDetailResponse,
    FinancePurchaseEvidenceResponse,
    FinancePurchaseEvidenceIngest,
    FinancePurchaseEvidenceIngestResponse,
    FinancePurchaseExceptionResponse,
    FinancePurchaseMatchReview,
    FinancePurchaseSummaryResponse,
    FinanceReserveCreate,
    FinanceReserveResponse,
    FinanceReserveUpdate,
    FinanceRecurringCorrection,
    FinanceRecurringSeriesResponse,
    FinanceRelationResponse,
    FinanceRelationReview,
    FinanceSettingsResponse,
    FinanceSafeToSpendRequest,
    FinanceSafeToSpendResponse,
    FinanceSpaceResponse,
    FinanceSplitReplace,
    FinanceSplitResponse,
    FinanceTransactionResponse,
)
from app.services.finance.ai import FinanceAnswer, FinanceReasoningError, run_finance_reasoning
from app.services.finance.coach import (
    FinanceAIConsentRequiredError,
    FinanceCoachConflictError,
    FinanceCoachError,
    FinanceCoachForbiddenError,
    FinanceCoachNotFoundError,
    FinanceCoachUnavailableError,
    FinanceLedgerQueryExecutor,
    accept_finance_ai_consent,
    build_finance_reasoning_adapter,
    list_finance_ai_consents,
    resolve_coach_spaces,
    revoke_finance_ai_consent,
)
from app.services.finance.foundation import (
    FinanceAccessDeniedError,
    FinanceScopeError,
    accessible_finance_spaces,
    get_finance_settings,
    require_finance_access,
)
from app.services.documents import (
    DocumentStorageError,
    promote_staged_upload,
    remove_new_upload,
    remove_staged_upload,
    resolve_storage_key,
    stage_upload,
)
from app.services.finance.evidence.types import EvidenceIssue
from app.services.finance.dates import household_zone
from app.services.finance.delivery_calendar import (
    calendar_item_prefill,
    calendar_source_for_destination,
    list_calendar_items,
)
from app.services.finance.email_intake import (
    FinanceEmailConflictError,
    FinanceEmailError,
    FinanceEmailNotFoundError,
    create_finance_email_enrollment,
    create_household_finance_alias,
    list_finance_email_addresses,
    read_finance_email_health,
    rotate_finance_alias,
    send_finance_alias_test,
)
from app.services.finance.ledger import (
    FinanceLedgerError,
    FinanceRecordNotFoundError,
    create_finance_account,
    finance_ledger_summary,
    list_finance_accounts,
    list_finance_transactions,
    record_balance_snapshot,
    replace_transaction_splits,
    review_transaction_relation,
)
from app.services.finance.monthly_overview import finance_monthly_overview
from app.services.finance.planning import (
    FinancePlanningConflictError,
    FinancePlanningError,
    FinancePlanningNotFoundError,
    create_commitment,
    create_fact,
    create_goal,
    create_preference,
    create_reserve,
    delete_commitment,
    delete_goal,
    delete_reserve,
    generate_forecast,
    generate_forecast_overview,
    list_commitments,
    list_facts,
    list_goals,
    list_preferences,
    list_reserves,
    read_forecast,
    set_fact_status,
    set_preference_status,
    update_commitment,
    update_fact,
    update_goal,
    update_preference,
    update_reserve,
)
from app.services.finance.projections import (
    FinanceProjectionConflictError,
    FinanceProjectionError,
    FinanceProjectionNotFoundError,
    cancel_calendar_item,
    create_calendar_item,
    get_projection_preference,
    set_projection_preference,
)
from app.services.finance.resource_limits import (
    finance_process_slot,
    reserve_finance_resource,
)
from app.services.finance.pattern_detection import (
    FinancePatternConflictError,
    FinancePatternError,
    FinancePatternNotFoundError,
    confirm_material_question,
    confirm_recurring_series,
    correct_material_question,
    correct_recurring_series,
    dismiss_material_question,
    dismiss_recurring_series,
    list_findings,
    list_material_questions,
    list_recurring_series,
    scan_finance_patterns,
    set_finding_disposition,
)
from app.services.finance.purchase_evidence import (
    FinancePurchaseConflictError,
    FinancePurchaseError,
    FinancePurchaseNotFoundError,
    FinancePurchaseStorageLimitError,
    ingest_purchase_evidence,
    list_purchase_inbox,
    list_purchases,
    read_purchase,
    read_purchase_by_line,
    read_purchase_by_source,
    read_purchase_by_transaction,
    read_purchase_source,
    review_purchase_match,
)
from app.services.finance.safe_to_spend_api import (
    FinanceSafeToSpendError,
    safe_to_spend_from_forecast,
)

router = APIRouter()

_COACH_UNAVAILABLE_DETAIL = (
    "Finance couldn't answer just now. Your overview and transactions are still available."
)


class _LeasedFinanceLedgerQueryExecutor:
    """Lease a pooled connection only while one deterministic query runs."""

    async def execute(self, **kwargs):
        async with database_lease() as db:
            return await FinanceLedgerQueryExecutor(db).execute(**kwargs)


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


@router.get("/spaces", response_model=list[FinanceSpaceResponse])
async def list_finance_spaces(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """List the caller's personal space and the shared household space."""
    return await accessible_finance_spaces(db, user=current_user)


@router.get("/settings", response_model=FinanceSettingsResponse)
async def read_finance_settings(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """Return household date/currency defaults for a family adult."""
    return await get_finance_settings(db, user=current_user)


@router.get(
    "/projection-preferences",
    response_model=FinanceProjectionPreferenceResponse,
)
async def read_finance_projection_preferences(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    return await get_projection_preference(db, user=current_user)


@router.patch(
    "/projection-preferences",
    response_model=FinanceProjectionPreferenceResponse,
)
async def revise_finance_projection_preferences(
    body: FinanceProjectionPreferenceUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    return await set_projection_preference(
        db,
        user=current_user,
        show_money=body.show_money,
        show_deliveries=body.show_deliveries,
    )


def _projection_error(exc: FinanceProjectionError) -> HTTPException:
    if isinstance(exc, FinanceProjectionNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinanceProjectionConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


@router.post(
    "/calendar-items",
    response_model=FinanceCalendarItemResponse,
    status_code=201,
)
async def write_finance_calendar_item(
    body: FinanceCalendarItemCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        calendar_body = await calendar_source_for_destination(
            db,
            user=current_user,
            body=body,
        )
        return await create_calendar_item(db, user=current_user, body=calendar_body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance purchase source not found") from exc
    except FinanceProjectionError as exc:
        raise _projection_error(exc) from exc


@router.get(
    "/calendar-items",
    response_model=list[FinanceCalendarItemResponse],
)
async def read_finance_calendar_items(
    space_id: str | None = Query(None, min_length=1, max_length=100),
    source_id: str | None = Query(None, min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_calendar_items(
            db,
            user=current_user,
            space_id=space_id,
            source_id=source_id,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance calendar items not found") from exc
    except FinanceProjectionError as exc:
        raise _projection_error(exc) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get(
    "/calendar-items/prefill",
    response_model=FinanceCalendarItemPrefillResponse | None,
)
async def read_finance_calendar_item_prefill(
    source_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await calendar_item_prefill(
            db,
            user=current_user,
            source_id=source_id,
        )
    except FinanceProjectionError as exc:
        raise _projection_error(exc) from exc


@router.delete("/calendar-items/{item_id}", status_code=204)
async def remove_finance_calendar_item(
    item_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        await cancel_calendar_item(db, user=current_user, item_id=item_id)
    except FinanceProjectionError as exc:
        raise _projection_error(exc) from exc
    return Response(status_code=204)


def _ledger_error(exc: FinanceLedgerError) -> HTTPException:
    if isinstance(exc, FinanceRecordNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


def _planning_error(exc: FinancePlanningError) -> HTTPException:
    if isinstance(exc, FinancePlanningNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinancePlanningConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


def _coach_error(exc: FinanceCoachError) -> HTTPException:
    if isinstance(exc, FinanceCoachForbiddenError):
        return HTTPException(status_code=403, detail=str(exc))
    if isinstance(exc, FinanceCoachNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinanceCoachConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, FinanceAIConsentRequiredError):
        return HTTPException(status_code=428, detail=str(exc))
    if isinstance(exc, FinanceCoachUnavailableError):
        return HTTPException(status_code=503, detail=_COACH_UNAVAILABLE_DETAIL)
    return HTTPException(status_code=422, detail=str(exc))


def _purchase_error(exc: FinancePurchaseError) -> HTTPException:
    if isinstance(exc, FinancePurchaseNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinancePurchaseConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, FinancePurchaseStorageLimitError):
        return HTTPException(status_code=413, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


def _email_error(exc: FinanceEmailError) -> HTTPException:
    if isinstance(exc, FinanceEmailNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinanceEmailConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


def _pattern_error(exc: FinancePatternError) -> HTTPException:
    if isinstance(exc, FinancePatternNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinancePatternConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


@router.post("/patterns/scan", response_model=FinancePatternScanResponse)
async def run_finance_pattern_scan(
    space_id: str = Query(min_length=1, max_length=100),
    as_of: date | None = None,
    currency: str = Query("GBP", min_length=3, max_length=3),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await scan_finance_patterns(
            db,
            user=current_user,
            space_id=space_id,
            as_of=as_of,
            currency=currency,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinancePatternError as exc:
        raise _pattern_error(exc) from exc
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get(
    "/recurring-series",
    response_model=list[FinanceRecurringSeriesResponse],
)
async def read_finance_recurring_series(
    space_id: str = Query(min_length=1, max_length=100),
    include_inactive: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_recurring_series(
            db,
            user=current_user,
            space_id=space_id,
            include_inactive=include_inactive,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post(
    "/recurring-series/{series_id}/confirm",
    response_model=FinanceRecurringSeriesResponse,
)
async def confirm_finance_recurring_series(
    series_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await confirm_recurring_series(db, user=current_user, series_id=series_id)
    except FinancePatternError as exc:
        raise _pattern_error(exc) from exc


@router.put(
    "/recurring-series/{series_id}",
    response_model=FinanceRecurringSeriesResponse,
)
async def revise_finance_recurring_series(
    series_id: str,
    body: FinanceRecurringCorrection,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await correct_recurring_series(
            db,
            user=current_user,
            series_id=series_id,
            body=body,
        )
    except FinancePatternError as exc:
        raise _pattern_error(exc) from exc


@router.post(
    "/recurring-series/{series_id}/dismiss",
    response_model=FinanceRecurringSeriesResponse,
)
async def dismiss_finance_recurring_series(
    series_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await dismiss_recurring_series(db, user=current_user, series_id=series_id)
    except FinancePatternError as exc:
        raise _pattern_error(exc) from exc


@router.get("/opportunities", response_model=list[FinanceFindingResponse])
async def read_finance_opportunities(
    space_id: str = Query(min_length=1, max_length=100),
    include_inactive: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_findings(
            db,
            user=current_user,
            space_id=space_id,
            include_inactive=include_inactive,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post(
    "/opportunities/{finding_id}/disposition",
    response_model=FinanceFindingResponse,
)
async def set_finance_opportunity_disposition(
    finding_id: str,
    body: FinanceFindingDisposition,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await set_finding_disposition(
            db,
            user=current_user,
            finding_id=finding_id,
            body=body,
        )
    except FinancePatternError as exc:
        raise _pattern_error(exc) from exc


@router.get(
    "/questions",
    response_model=list[FinanceMaterialQuestionResponse],
)
async def read_finance_material_questions(
    space_id: str = Query(min_length=1, max_length=100),
    include_resolved: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_material_questions(
            db,
            user=current_user,
            space_id=space_id,
            include_resolved=include_resolved,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post(
    "/questions/{question_id}/confirm",
    response_model=FinanceMaterialQuestionResponse,
)
async def confirm_finance_material_question(
    question_id: str,
    body: FinanceMaterialQuestionAnswer,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await confirm_material_question(
            db,
            user=current_user,
            question_id=question_id,
            body=body,
        )
    except FinancePatternError as exc:
        raise _pattern_error(exc) from exc


@router.put(
    "/questions/{question_id}/correct",
    response_model=FinanceMaterialQuestionResponse,
)
async def correct_finance_material_question(
    question_id: str,
    body: FinanceMaterialQuestionCorrection,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await correct_material_question(
            db,
            user=current_user,
            question_id=question_id,
            body=body,
        )
    except FinancePatternError as exc:
        raise _pattern_error(exc) from exc


@router.post(
    "/questions/{question_id}/dismiss",
    response_model=FinanceMaterialQuestionResponse,
)
async def dismiss_finance_material_question(
    question_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await dismiss_material_question(db, user=current_user, question_id=question_id)
    except FinancePatternError as exc:
        raise _pattern_error(exc) from exc


@router.get("/email-addresses", response_model=FinanceEmailAddressesResponse)
async def read_finance_email_addresses(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    return await list_finance_email_addresses(db, user=current_user)


@router.post(
    "/email-addresses/household",
    response_model=FinanceEmailAddressResponse,
    status_code=201,
)
async def write_household_finance_email_address(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_household_finance_alias(db, user=current_user)
    except FinanceEmailError as exc:
        raise _email_error(exc) from exc


@router.post(
    "/email-addresses/{alias_id}/rotate",
    response_model=FinanceEmailAddressResponse,
    status_code=201,
)
async def rotate_finance_email_address(
    alias_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await rotate_finance_alias(db, user=current_user, alias_id=alias_id)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance email address not found") from exc
    except FinanceEmailError as exc:
        raise _email_error(exc) from exc


@router.post(
    "/email-addresses/{alias_id}/send-test",
    response_model=FinanceEmailSendTestResponse,
)
async def send_finance_email_test(
    alias_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await send_finance_alias_test(db, user=current_user, alias_id=alias_id)
    except FinanceEmailError as exc:
        raise _email_error(exc) from exc


@router.post(
    "/email-addresses/{alias_id}/enrollments",
    response_model=FinanceEmailEnrollmentResponse,
    status_code=201,
)
async def write_finance_email_enrollment(
    alias_id: str,
    body: FinanceEmailEnrollmentCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_finance_email_enrollment(
            db,
            user=current_user,
            alias_id=alias_id,
            body=body,
        )
    except FinanceEmailError as exc:
        raise _email_error(exc) from exc


@router.get(
    "/email-addresses/{alias_id}/health",
    response_model=FinanceEmailSourceHealthResponse,
)
async def read_finance_email_source_health(
    alias_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await read_finance_email_health(db, user=current_user, alias_id=alias_id)
    except FinanceEmailError as exc:
        raise _email_error(exc) from exc


@router.get("/ai-consent", response_model=list[FinanceAIConsentResponse])
async def read_finance_ai_consent(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    return await list_finance_ai_consents(db, user=current_user)


@router.put("/ai-consent", response_model=FinanceAIConsentResponse)
async def grant_finance_ai_consent(
    body: FinanceAIConsentAccept,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await accept_finance_ai_consent(
            db,
            user=current_user,
            space_id=body.space_id,
            consent_version=body.consent_version,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceCoachError as exc:
        raise _coach_error(exc) from exc


@router.delete("/ai-consent", response_model=FinanceAIConsentResponse)
async def withdraw_finance_ai_consent(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await revoke_finance_ai_consent(
            db, user=current_user, space_id=space_id
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceCoachError as exc:
        raise _coach_error(exc) from exc


@router.post("/coach/ask", response_model=FinanceAnswer)
async def ask_finance_coach(
    body: FinanceCoachAsk,
    current_user: dict = Depends(_finance_user),
):
    adapter = None
    try:
        with finance_process_slot(user=current_user, kind="ai"):
            async with database_lease() as db:
                await reserve_finance_resource(db, user=current_user, kind="ai")
            adapter = build_finance_reasoning_adapter()
            async with database_lease() as db:
                space_ids = await resolve_coach_spaces(
                    db,
                    user=current_user,
                    scope=body.scope,
                    space_id=body.space_id,
                )
            return await run_finance_reasoning(
                adapter=adapter,
                executor=_LeasedFinanceLedgerQueryExecutor(),
                question=body.question,
                conversation=[turn.model_dump() for turn in body.conversation],
                principal=current_user,
                space_ids=space_ids,
            )
    except FinanceCoachError as exc:
        raise _coach_error(exc) from exc
    except FinanceReasoningError as exc:
        raise HTTPException(status_code=503, detail=_COACH_UNAVAILABLE_DETAIL) from exc
    finally:
        close_adapter = getattr(adapter, "aclose", None)
        if close_adapter is not None:
            try:
                await close_adapter()
            except Exception:
                # A transport cleanup failure must not replace a completed answer
                # or hide the original provider error from the route handler.
                pass


@router.get("/accounts", response_model=list[FinanceAccountResponse])
async def read_finance_accounts(
    space_id: str = Query(min_length=1, max_length=100),
    exclude_own_shared_copies: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_finance_accounts(
            db,
            user=current_user,
            space_id=space_id,
            exclude_own_shared_copies=exclude_own_shared_copies,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.get("/overview", response_model=FinanceOverviewResponse)
async def read_finance_overview(
    scope: Literal["mine", "household"] = Query(),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await finance_monthly_overview(
            db,
            user=current_user,
            scope=scope,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance is not available") from exc


@router.post(
    "/accounts",
    response_model=FinanceAccountResponse,
    status_code=status.HTTP_201_CREATED,
)
async def write_finance_account(
    body: FinanceManualAccountCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        account_fields = body.model_dump(
            exclude={"current_balance_minor", "balance_observed_at"}
        )
        account = await create_finance_account(
            db,
            user=current_user,
            space_id=space_id,
            body=FinanceAccountCreate(**account_fields),
        )
        await record_balance_snapshot(
            db,
            user=current_user,
            space_id=space_id,
            account_id=account.id,
            booked_minor=body.current_balance_minor,
            available_minor=None,
            credit_limit_minor=None,
            currency=body.currency,
            observed_at=body.balance_observed_at,
        )
        accounts = await list_finance_accounts(
            db,
            user=current_user,
            space_id=space_id,
        )
        return next(item for item in accounts if item.id == account.id)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceLedgerError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.get("/transactions", response_model=list[FinanceTransactionResponse])
async def read_finance_transactions(
    space_id: str = Query(min_length=1, max_length=100),
    account_id: str | None = Query(default=None, min_length=1, max_length=100),
    search: str | None = Query(default=None, max_length=200),
    include_superseded: bool = False,
    exclude_own_shared_copies: bool = False,
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_finance_transactions(
            db,
            user=current_user,
            space_id=space_id,
            account_id=account_id,
            search=search,
            include_superseded=include_superseded,
            exclude_own_shared_copies=exclude_own_shared_copies,
            offset=offset,
            limit=limit,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.get("/summary", response_model=FinanceLedgerSummaryResponse)
async def read_finance_summary(
    space_id: str = Query(min_length=1, max_length=100),
    scope: Literal["mine", "household"] | None = None,
    exclude_own_shared_copies: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await finance_ledger_summary(
            db,
            user=current_user,
            space_id=space_id,
            scope=scope,
            exclude_own_shared_copies=exclude_own_shared_copies,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceScopeError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.put(
    "/transactions/{transaction_id}/splits",
    response_model=list[FinanceSplitResponse],
)
async def write_finance_splits(
    transaction_id: str,
    body: FinanceSplitReplace,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await replace_transaction_splits(
            db,
            user=current_user,
            transaction_id=transaction_id,
            splits=body.splits,
        )
    except FinanceLedgerError as exc:
        raise _ledger_error(exc) from exc


@router.post(
    "/relations/{relation_id}/review",
    response_model=FinanceRelationResponse,
)
async def review_finance_relation(
    relation_id: str,
    body: FinanceRelationReview,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await review_transaction_relation(
            db,
            user=current_user,
            relation_id=relation_id,
            status=body.status,
        )
    except FinanceLedgerError as exc:
        raise _ledger_error(exc) from exc


@router.get("/facts", response_model=list[FinanceFactResponse])
async def read_finance_facts(
    space_id: str = Query(min_length=1, max_length=100),
    include_expired: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_facts(
            db,
            user=current_user,
            space_id=space_id,
            include_expired=include_expired,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post("/facts", response_model=FinanceFactResponse, status_code=201)
async def write_finance_fact(
    body: FinanceFactCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_fact(db, user=current_user, space_id=space_id, body=body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.put("/facts/{fact_id}", response_model=FinanceFactResponse)
async def revise_finance_fact(
    fact_id: str,
    body: FinanceFactUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await update_fact(db, user=current_user, fact_id=fact_id, body=body)
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.post("/facts/{fact_id}/confirm", response_model=FinanceFactResponse)
async def confirm_finance_fact(
    fact_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await set_fact_status(
            db, user=current_user, fact_id=fact_id, status="CONFIRMED"
        )
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.post("/facts/{fact_id}/expire", response_model=FinanceFactResponse)
async def expire_finance_fact(
    fact_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await set_fact_status(db, user=current_user, fact_id=fact_id, status="EXPIRED")
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.get("/preferences", response_model=list[FinancePreferenceResponse])
async def read_finance_preferences(
    space_id: str = Query(min_length=1, max_length=100),
    include_expired: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_preferences(
            db,
            user=current_user,
            space_id=space_id,
            include_expired=include_expired,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post("/preferences", response_model=FinancePreferenceResponse, status_code=201)
async def write_finance_preference(
    body: FinancePreferenceCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_preference(
            db, user=current_user, space_id=space_id, body=body
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.put("/preferences/{preference_id}", response_model=FinancePreferenceResponse)
async def revise_finance_preference(
    preference_id: str,
    body: FinancePreferenceUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await update_preference(
            db,
            user=current_user,
            preference_id=preference_id,
            body=body,
        )
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.post(
    "/preferences/{preference_id}/confirm",
    response_model=FinancePreferenceResponse,
)
async def confirm_finance_preference(
    preference_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await set_preference_status(
            db,
            user=current_user,
            preference_id=preference_id,
            status="CONFIRMED",
        )
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.post(
    "/preferences/{preference_id}/expire",
    response_model=FinancePreferenceResponse,
)
async def expire_finance_preference(
    preference_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await set_preference_status(
            db,
            user=current_user,
            preference_id=preference_id,
            status="EXPIRED",
        )
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.get("/commitments", response_model=list[FinanceCommitmentResponse])
async def read_finance_commitments(
    space_id: str = Query(min_length=1, max_length=100),
    as_of: date | None = None,
    exclude_own_shared_copies: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        effective_as_of = as_of
        if effective_as_of is None:
            settings = await get_finance_settings(db, user=current_user)
            effective_as_of = datetime.now(
                household_zone(settings.household_timezone)
            ).date()
        return await list_commitments(
            db,
            user=current_user,
            space_id=space_id,
            as_of=effective_as_of,
            exclude_own_shared_copies=exclude_own_shared_copies,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post("/commitments", response_model=FinanceCommitmentResponse, status_code=201)
async def write_finance_commitment(
    body: FinanceCommitmentCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_commitment(
            db, user=current_user, space_id=space_id, body=body
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.patch("/commitments/{commitment_id}", response_model=FinanceCommitmentResponse)
async def revise_finance_commitment(
    commitment_id: str,
    body: FinanceCommitmentUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await update_commitment(
            db,
            user=current_user,
            commitment_id=commitment_id,
            body=body,
        )
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.delete("/commitments/{commitment_id}", status_code=204)
async def remove_finance_commitment(
    commitment_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        await delete_commitment(db, user=current_user, commitment_id=commitment_id)
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc
    return Response(status_code=204)


@router.get("/reserves", response_model=list[FinanceReserveResponse])
async def read_finance_reserves(
    space_id: str = Query(min_length=1, max_length=100),
    exclude_own_shared_copies: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_reserves(
            db,
            user=current_user,
            space_id=space_id,
            exclude_own_shared_copies=exclude_own_shared_copies,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post("/reserves", response_model=FinanceReserveResponse, status_code=201)
async def write_finance_reserve(
    body: FinanceReserveCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_reserve(db, user=current_user, space_id=space_id, body=body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.patch("/reserves/{reserve_id}", response_model=FinanceReserveResponse)
async def revise_finance_reserve(
    reserve_id: str,
    body: FinanceReserveUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await update_reserve(
            db, user=current_user, reserve_id=reserve_id, body=body
        )
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.delete("/reserves/{reserve_id}", status_code=204)
async def remove_finance_reserve(
    reserve_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        await delete_reserve(db, user=current_user, reserve_id=reserve_id)
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc
    return Response(status_code=204)


@router.get("/goals", response_model=list[FinanceGoalResponse])
async def read_finance_goals(
    space_id: str = Query(min_length=1, max_length=100),
    as_of: date | None = None,
    exclude_own_shared_copies: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        effective_as_of = as_of
        if effective_as_of is None:
            settings = await get_finance_settings(db, user=current_user)
            effective_as_of = datetime.now(
                household_zone(settings.household_timezone)
            ).date()
        return await list_goals(
            db,
            user=current_user,
            space_id=space_id,
            as_of=effective_as_of,
            exclude_own_shared_copies=exclude_own_shared_copies,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post("/goals", response_model=FinanceGoalResponse, status_code=201)
async def write_finance_goal(
    body: FinanceGoalCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_goal(db, user=current_user, space_id=space_id, body=body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.patch("/goals/{goal_id}", response_model=FinanceGoalResponse)
async def revise_finance_goal(
    goal_id: str,
    body: FinanceGoalUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await update_goal(db, user=current_user, goal_id=goal_id, body=body)
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.delete("/goals/{goal_id}", status_code=204)
async def remove_finance_goal(
    goal_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        await delete_goal(db, user=current_user, goal_id=goal_id)
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc
    return Response(status_code=204)


@router.post("/forecasts", response_model=FinanceForecastResponse, status_code=201)
async def write_finance_forecast(
    body: FinanceForecastGenerate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await generate_forecast(
            db, user=current_user, space_id=space_id, body=body
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post(
    "/forecasts/overview",
    response_model=FinanceForecastOverviewResponse,
    status_code=201,
)
async def write_finance_forecast_overview(
    body: FinanceForecastGenerate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await generate_forecast_overview(
            db, user=current_user, space_id=space_id, body=body
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/forecasts/{forecast_id}", response_model=FinanceForecastResponse)
async def read_finance_forecast(
    forecast_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await read_forecast(db, user=current_user, forecast_id=forecast_id)
    except FinancePlanningError as exc:
        raise _planning_error(exc) from exc


@router.post("/safe-to-spend", response_model=FinanceSafeToSpendResponse)
async def read_safe_to_spend(
    body: FinanceSafeToSpendRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await safe_to_spend_from_forecast(
            db, user=current_user, body=body
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(
            status_code=404, detail="Finance forecast not found"
        ) from exc
    except FinanceSafeToSpendError as exc:
        status_code = 404 if str(exc) == "Finance forecast not found" else 422
        raise HTTPException(status_code=status_code, detail=str(exc)) from exc
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get(
    "/purchases/inbox",
    response_model=list[FinancePurchaseExceptionResponse],
)
async def read_finance_purchase_inbox(
    space_id: str = Query(min_length=1, max_length=100),
    exclude_own_shared_copies: bool = False,
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_purchase_inbox(
            db,
            user=current_user,
            space_id=space_id,
            offset=offset,
            limit=limit,
            exclude_own_shared_copies=exclude_own_shared_copies,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(
            status_code=404, detail="Finance space is not available"
        ) from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc


@router.get("/purchases", response_model=list[FinancePurchaseSummaryResponse])
async def read_finance_purchases(
    space_id: str = Query(min_length=1, max_length=100),
    exclude_own_shared_copies: bool = False,
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_purchases(
            db,
            user=current_user,
            space_id=space_id,
            offset=offset,
            limit=limit,
            exclude_own_shared_copies=exclude_own_shared_copies,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(
            status_code=404, detail="Finance space is not available"
        ) from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc


@router.get(
    "/purchases/by-source/{source_id}",
    response_model=FinancePurchaseDetailResponse,
)
async def read_finance_purchase_by_source(
    source_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """Open the purchase created from one authorised receipt or order source."""
    try:
        return await read_purchase_by_source(
            db,
            user=current_user,
            source_id=source_id,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance purchase not found") from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc


@router.get(
    "/purchases/by-transaction/{transaction_id}",
    response_model=FinancePurchaseDetailResponse,
)
async def read_finance_purchase_by_transaction(
    transaction_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """Open the purchase already matched to one authorised bank transaction."""
    try:
        return await read_purchase_by_transaction(
            db,
            user=current_user,
            transaction_id=transaction_id,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Matched Finance purchase not found") from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc


@router.get(
    "/purchases/by-line/{line_id}",
    response_model=FinancePurchaseDetailResponse,
)
async def read_finance_purchase_by_line(
    line_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """Open the purchase containing one authorised receipt line."""
    try:
        return await read_purchase_by_line(
            db,
            user=current_user,
            line_id=line_id,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance purchase line not found") from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc


@router.post(
    "/purchases/evidence",
    response_model=FinancePurchaseEvidenceIngestResponse,
    status_code=201,
)
async def write_finance_purchase_evidence(
    body: FinancePurchaseEvidenceIngest,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        with finance_process_slot(user=current_user, kind="upload"):
            await reserve_finance_resource(db, user=current_user, kind="upload")
            return await ingest_purchase_evidence(
                db,
                user=current_user,
                space_id=space_id,
                body=body,
            )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(
            status_code=404, detail="Finance space is not available"
        ) from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc


@router.post(
    "/purchases/evidence/upload",
    response_model=FinancePurchaseEvidenceIngestResponse,
    status_code=201,
)
async def upload_private_finance_evidence(
    file: UploadFile = File(...),
    title: str = Form(..., min_length=1, max_length=300),
    notes: str | None = Form(None, max_length=2_000),
    source_id: str | None = Form(None, max_length=64),
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """Store an adult-only receipt or statement in Finance, never Documents."""
    if source_id is not None:
        try:
            source_id = str(uuid.UUID(source_id))
        except (ValueError, AttributeError) as exc:
            raise HTTPException(status_code=422, detail="source_id must be a UUID") from exc
    else:
        source_id = str(uuid.uuid4())
    staged_path = None
    storage_key = None
    try:
        with finance_process_slot(user=current_user, kind="upload"):
            await reserve_finance_resource(db, user=current_user, kind="upload")
            staged_path, filename, media_type, size, _ = await stage_upload(file)
            adapter = "pdf" if media_type == "application/pdf" else "image" if media_type.startswith("image/") else "natural_language"
            storage_key = await promote_staged_upload(
                staged_path,
                family_id=f"finance-evidence/{current_user['family_id']}/{space_id}",
                document_id=source_id,
                filename=filename,
            )
            staged_path = None
            return await ingest_purchase_evidence(
                db,
                user=current_user,
                space_id=space_id,
                body=FinancePurchaseEvidenceIngest(
                    external_source_id=f"private-upload:{source_id}",
                    adapter=adapter,
                    reviewed=True,
                    payload={"title": title.strip(), "filename": filename, "notes": notes.strip() if notes else None},
                ),
                source_id_override=source_id,
                forced_issue=EvidenceIssue(
                    code="DOCUMENT_REVIEW_REQUIRED",
                    message="Open this private file and describe or match the purchase details.",
                ),
                email_context={"storage_key": storage_key, "media_type": media_type, "byte_size": size},
                evidence_files=[{
                    "file_role": "ATTACHMENT",
                    "filename": filename,
                    "media_type": media_type,
                    "storage_key": storage_key,
                    "byte_size": size,
                    "storage_status": "STORED",
                }],
            )
    except DocumentStorageError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except (FinanceAccessDeniedError, FinancePurchaseError) as exc:
        if storage_key:
            await remove_new_upload(storage_key)
        if isinstance(exc, FinanceAccessDeniedError):
            raise HTTPException(status_code=404, detail="Finance space is not available") from exc
        raise _purchase_error(exc) from exc
    except Exception:
        if storage_key:
            await remove_new_upload(storage_key)
        raise
    finally:
        await remove_staged_upload(staged_path)


@router.get(
    "/purchases/evidence/{source_id}",
    response_model=FinancePurchaseEvidenceResponse,
)
async def read_finance_purchase_evidence(
    source_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await read_purchase_source(db, user=current_user, source_id=source_id)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance purchase evidence not found") from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc


@router.get("/purchases/evidence/{source_id}/files/{file_id}")
async def open_finance_purchase_evidence_file(
    source_id: str,
    file_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """Open one authorised private Finance attachment without exposing its path."""
    try:
        source = await read_purchase_source(db, user=current_user, source_id=source_id)
    except (FinanceAccessDeniedError, FinancePurchaseError) as exc:
        raise HTTPException(status_code=404, detail="Finance evidence file not found") from exc
    if source.id != source_id:
        raise HTTPException(status_code=404, detail="Finance evidence file not found")
    row = await (
        await db.execute(
            """
            SELECT filename, media_type, storage_key FROM finance_purchase_source_files
            WHERE id = ? AND source_id = ? AND space_id = ? AND family_id = ?
              AND storage_status = 'STORED' AND deleted_at IS NULL
            """,
            (file_id, source_id, source.space_id, current_user["family_id"]),
        )
    ).fetchone()
    if row is None or row["storage_key"] is None:
        raise HTTPException(status_code=404, detail="Finance evidence file not found")
    try:
        path = resolve_storage_key(row["storage_key"])
    except DocumentStorageError as exc:
        raise HTTPException(status_code=404, detail="Finance evidence file not found") from exc
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Finance evidence file is unavailable")
    return FileResponse(
        path,
        media_type=row["media_type"],
        filename=row["filename"],
        content_disposition_type="inline",
    )


@router.post(
    "/purchases/{purchase_id}/match",
    response_model=FinancePurchaseDetailResponse,
)
async def write_finance_purchase_match(
    purchase_id: str,
    body: FinancePurchaseMatchReview,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await review_purchase_match(
            db,
            user=current_user,
            purchase_id=purchase_id,
            body=body,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance purchase not found") from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc


@router.get("/purchases/{purchase_id}", response_model=FinancePurchaseDetailResponse)
async def read_finance_purchase(
    purchase_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await read_purchase(
            db,
            user=current_user,
            purchase_id=purchase_id,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance purchase not found") from exc
    except FinancePurchaseError as exc:
        raise _purchase_error(exc) from exc

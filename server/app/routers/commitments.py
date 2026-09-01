"""Review-first incoming commitment API."""

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.commitment import (
    ChildcareGapResponse,
    CommitmentActionCompleteRequest,
    CommitmentConfirmRequest,
    CommitmentCreate,
    CommitmentDeclineRequest,
    CommitmentFromSourceRequest,
    CommitmentFromSourceResponse,
    CommitmentKind,
    CommitmentResponse,
    CommitmentStatus,
    CommitmentUpdate,
    FreeWindowQuery,
    FreeWindowQueryResponse,
)
from app.services.commitments import (
    CommitmentConflictError,
    CommitmentNotFoundError,
    CommitmentValidationError,
    childcare_gaps,
    commitment_from_source,
    complete_external_action,
    confirm_commitment,
    create_commitment,
    decline_commitment,
    delete_commitment,
    get_commitment,
    list_commitments,
    query_free_windows,
    update_commitment,
)


router = APIRouter()


def _http_error(exc: ValueError) -> HTTPException:
    if isinstance(exc, CommitmentNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, CommitmentConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=400, detail=str(exc))


@router.post(
    "/from-source",
    response_model=CommitmentFromSourceResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_from_source(
    body: CommitmentFromSourceRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Interpret reviewed source material into a draft; never execute its plan."""
    try:
        return await commitment_from_source(db, user=current_user, body=body)
    except (CommitmentNotFoundError, CommitmentConflictError, CommitmentValidationError) as exc:
        raise _http_error(exc) from exc


@router.post(
    "/free-windows/query",
    response_model=FreeWindowQueryResponse,
)
async def free_windows(
    body: FreeWindowQuery,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Find common calendar gaps and fit reviewed venue candidates inside them."""
    try:
        return await query_free_windows(db, user=current_user, body=body)
    except (CommitmentNotFoundError, CommitmentValidationError) as exc:
        raise _http_error(exc) from exc


@router.get("/childcare-gaps", response_model=list[ChildcareGapResponse])
async def get_childcare_gaps(
    child_id: str = Query(min_length=1, max_length=64),
    from_date: date = Query(alias="from"),
    to_date: date = Query(alias="to"),
    timezone_name: str = Query(
        default="Europe/London", alias="timezone", min_length=1, max_length=64
    ),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return school-holiday weekdays without explicit childcare coverage."""
    try:
        return await childcare_gaps(
            db,
            user=current_user,
            child_id=child_id,
            from_date=from_date,
            to_date=to_date,
            timezone_name=timezone_name,
        )
    except (CommitmentNotFoundError, CommitmentValidationError) as exc:
        raise _http_error(exc) from exc


@router.get("/", response_model=list[CommitmentResponse])
async def get_commitments(
    status_filter: CommitmentStatus | None = Query(default=None, alias="status"),
    kind: CommitmentKind | None = None,
    open_only: bool = False,
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if open_only and status_filter is not None:
        raise HTTPException(
            status_code=400,
            detail="Use either status or open_only, not both",
        )
    return await list_commitments(
        db,
        user=current_user,
        status=status_filter.value if status_filter else None,
        kind=kind.value if kind else None,
        open_only=open_only,
        offset=offset,
        limit=limit,
    )


@router.post(
    "/",
    response_model=CommitmentResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_commitment(
    body: CommitmentCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Store a typed, editable plan without creating downstream records."""
    try:
        result, _replayed = await create_commitment(db, user=current_user, body=body)
        return result
    except (CommitmentConflictError, CommitmentValidationError) as exc:
        raise _http_error(exc) from exc


@router.get("/{commitment_id}", response_model=CommitmentResponse)
async def get_one_commitment(
    commitment_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await get_commitment(db, user=current_user, commitment_id=commitment_id)
    except CommitmentNotFoundError as exc:
        raise _http_error(exc) from exc


@router.patch("/{commitment_id}", response_model=CommitmentResponse)
async def patch_commitment(
    commitment_id: str,
    body: CommitmentUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await update_commitment(
            db, user=current_user, commitment_id=commitment_id, body=body
        )
    except (
        CommitmentNotFoundError,
        CommitmentConflictError,
        CommitmentValidationError,
    ) as exc:
        raise _http_error(exc) from exc


@router.post("/{commitment_id}/external-action/complete", response_model=CommitmentResponse)
async def complete_action(
    commitment_id: str,
    body: CommitmentActionCompleteRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Record the user's acknowledgement; HausKlar never executes the external action."""
    try:
        return await complete_external_action(
            db, user=current_user, commitment_id=commitment_id, body=body
        )
    except (
        CommitmentNotFoundError,
        CommitmentConflictError,
        CommitmentValidationError,
    ) as exc:
        raise _http_error(exc) from exc


@router.post("/{commitment_id}/confirm", response_model=CommitmentResponse)
async def confirm(
    commitment_id: str,
    body: CommitmentConfirmRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Atomically create the reviewed calendar, task and preparation hand-offs."""
    try:
        return await confirm_commitment(
            db, user=current_user, commitment_id=commitment_id, body=body
        )
    except (
        CommitmentNotFoundError,
        CommitmentConflictError,
        CommitmentValidationError,
    ) as exc:
        raise _http_error(exc) from exc


@router.post("/{commitment_id}/decline", response_model=CommitmentResponse)
async def decline(
    commitment_id: str,
    body: CommitmentDeclineRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await decline_commitment(
            db, user=current_user, commitment_id=commitment_id, body=body
        )
    except (
        CommitmentNotFoundError,
        CommitmentConflictError,
        CommitmentValidationError,
    ) as exc:
        raise _http_error(exc) from exc


@router.delete("/{commitment_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_commitment(
    commitment_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await delete_commitment(db, user=current_user, commitment_id=commitment_id)
    except CommitmentNotFoundError as exc:
        raise _http_error(exc) from exc
    return Response(status_code=status.HTTP_204_NO_CONTENT)

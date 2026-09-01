"""Adult-only product research, price comparison, and read-only asset routes."""

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.finance_products_assets import (
    FinanceAssetSnapshotResponse,
    FinanceAssetPriceRefreshResponse,
    FinanceAssetSourceResponse,
    FinanceHLImportConfirm,
    FinanceHLImportPreviewCreate,
    FinanceHLImportPreviewResponse,
    FinanceManualAssetValueCreate,
    FinanceManualAssetValueResponse,
    FinanceNetWorthHistoryResponse,
    FinanceNetWorthResponse,
    FinanceOpportunityActionResponse,
    FinancePortfolioPositionSave,
    FinancePortfolioResponse,
    FinanceProductComparisonCreate,
    FinanceProductComparisonResponse,
    FinanceProductHistoryResponse,
    FinanceProductOpportunityAccept,
    FinanceRetailerResearchRequest,
    FinanceRetailerResearchRequestResponse,
    FinanceRetailerResearchResultCreate,
    FinanceRetailerResearchResultResponse,
    FinanceWatchAddressCreate,
    FinanceWatchSnapshotCreate,
)
from app.services.finance.assets import (
    FinanceAssetConflictError,
    FinanceAssetError,
    FinanceAssetNotFoundError,
    confirm_hl_report,
    create_watch_address,
    list_asset_sources,
    net_worth_summary,
    pause_asset_source,
    preview_hl_report,
    record_watch_snapshot,
    record_manual_asset_value,
    refresh_hl_prices,
    refresh_hl_portfolio_prices,
    refresh_securities_prices,
    refresh_watch_source,
)
from app.services.finance.portfolio import (
    create_portfolio_position,
    portfolio_summary,
    remove_portfolio_position,
    update_portfolio_position,
)
from app.services.finance.net_worth import net_worth_history
from app.services.finance.foundation import FinanceAccessDeniedError, require_finance_access
from app.services.finance.product_comparison import (
    FinanceProductConflictError,
    FinanceProductError,
    FinanceProductNotFoundError,
    accept_product_opportunity,
    create_product_comparison,
    create_retailer_research_request,
    list_retailer_research_results,
    product_price_history,
    rebuild_product_price_history,
    save_retailer_research_result,
)

router = APIRouter()


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


def _product_error(exc: FinanceProductError) -> HTTPException:
    if isinstance(exc, FinanceProductNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinanceProductConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


def _asset_error(exc: FinanceAssetError) -> HTTPException:
    if isinstance(exc, FinanceAssetNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinanceAssetConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


@router.post("/product-prices/rebuild", response_model=dict[str, int])
async def post_product_price_rebuild(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        changed = await rebuild_product_price_history(db, user=current_user, space_id=space_id)
        return {"updated_observation_count": changed}
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceProductError as exc:
        raise _product_error(exc) from exc


@router.get(
    "/items/{item_id}/product-price-history",
    response_model=FinanceProductHistoryResponse,
)
async def get_product_price_history(
    item_id: str,
    space_id: str = Query(min_length=1, max_length=100),
    limit: int = Query(200, ge=1, le=2_000),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await product_price_history(
            db,
            user=current_user,
            space_id=space_id,
            item_id=item_id,
            limit=limit,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceProductError as exc:
        raise _product_error(exc) from exc


@router.get(
    "/items/{item_id}/retailer-research-results",
    response_model=list[FinanceRetailerResearchResultResponse],
)
async def get_retailer_research_results(
    item_id: str,
    space_id: str = Query(min_length=1, max_length=100),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_retailer_research_results(
            db,
            user=current_user,
            space_id=space_id,
            item_id=item_id,
            limit=limit,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceProductError as exc:
        raise _product_error(exc) from exc


@router.post(
    "/retailer-research/requests",
    response_model=FinanceRetailerResearchRequestResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_retailer_research_request(
    body: FinanceRetailerResearchRequest,
    space_id: str = Query(min_length=1, max_length=100),
    normalized_item_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """Stage sanitised item facts for explicit manual price-evidence review."""
    try:
        return await create_retailer_research_request(
            db,
            user=current_user,
            space_id=space_id,
            normalized_item_id=normalized_item_id,
            body=body,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceProductError as exc:
        raise _product_error(exc) from exc


@router.post(
    "/retailer-research/requests/{request_id}/results",
    response_model=FinanceRetailerResearchResultResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_retailer_research_result(
    request_id: str,
    body: FinanceRetailerResearchResultCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await save_retailer_research_result(
            db, user=current_user, request_id=request_id, body=body
        )
    except FinanceProductError as exc:
        raise _product_error(exc) from exc


@router.post(
    "/product-comparisons",
    response_model=FinanceProductComparisonResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_product_comparison(
    body: FinanceProductComparisonCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_product_comparison(db, user=current_user, space_id=space_id, body=body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceProductError as exc:
        raise _product_error(exc) from exc


@router.post(
    "/product-comparisons/{comparison_id}/accept",
    response_model=FinanceOpportunityActionResponse,
)
async def post_product_opportunity_accept(
    comparison_id: str,
    body: FinanceProductOpportunityAccept,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await accept_product_opportunity(
            db, user=current_user, comparison_id=comparison_id, body=body
        )
    except FinanceProductError as exc:
        raise _product_error(exc) from exc


@router.post(
    "/assets/hl/import-preview",
    response_model=FinanceHLImportPreviewResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_hl_import_preview(
    body: FinanceHLImportPreviewCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await preview_hl_report(db, user=current_user, space_id=space_id, body=body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/hl/previews/{preview_id}/confirm",
    response_model=FinanceAssetSnapshotResponse,
)
async def post_hl_import_confirm(
    preview_id: str,
    body: FinanceHLImportConfirm,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await confirm_hl_report(db, user=current_user, preview_id=preview_id, body=body)
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/hl/sources/{source_id}/refresh-prices",
    response_model=FinanceAssetPriceRefreshResponse,
)
async def post_hl_price_refresh(
    source_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await refresh_hl_prices(db, user=current_user, source_id=source_id)
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/hl/refresh-prices",
    response_model=list[FinanceAssetPriceRefreshResponse],
)
async def post_hl_portfolio_price_refresh(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await refresh_hl_portfolio_prices(
            db,
            user=current_user,
            space_id=space_id,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.get(
    "/assets/portfolio",
    response_model=FinancePortfolioResponse,
)
async def get_securities_portfolio(
    space_id: str = Query(min_length=1, max_length=100),
    currency: str = Query("GBP", min_length=3, max_length=3),
    days: int = Query(365, ge=7, le=3_650),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await portfolio_summary(
            db,
            user=current_user,
            space_id=space_id,
            currency=currency,
            days=days,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/portfolio/positions",
    response_model=FinancePortfolioResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_securities_position(
    body: FinancePortfolioPositionSave,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_portfolio_position(
            db,
            user=current_user,
            space_id=space_id,
            body=body,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.put(
    "/assets/portfolio/positions/{position_id}",
    response_model=FinancePortfolioResponse,
)
async def put_securities_position(
    position_id: str,
    body: FinancePortfolioPositionSave,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await update_portfolio_position(
            db,
            user=current_user,
            space_id=space_id,
            position_id=position_id,
            body=body,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.delete(
    "/assets/portfolio/positions/{position_id}",
    response_model=FinancePortfolioResponse,
)
async def delete_securities_position(
    position_id: str,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await remove_portfolio_position(
            db,
            user=current_user,
            space_id=space_id,
            position_id=position_id,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/portfolio/refresh",
    response_model=FinanceAssetPriceRefreshResponse,
)
async def post_securities_portfolio_refresh(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        portfolio = await portfolio_summary(
            db,
            user=current_user,
            space_id=space_id,
            currency="GBP",
            days=7,
        )
        if portfolio.source_id is None:
            raise FinanceAssetNotFoundError("Savings portfolio not found")
        return await refresh_securities_prices(
            db,
            user=current_user,
            source_id=portfolio.source_id,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/manual-values",
    response_model=FinanceManualAssetValueResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_manual_asset_value(
    body: FinanceManualAssetValueCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await record_manual_asset_value(db, user=current_user, space_id=space_id, body=body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/watch-addresses",
    response_model=FinanceAssetSourceResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_watch_address(
    body: FinanceWatchAddressCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_watch_address(db, user=current_user, space_id=space_id, body=body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.get(
    "/assets/sources",
    response_model=list[FinanceAssetSourceResponse],
)
async def get_asset_sources(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_asset_sources(db, user=current_user, space_id=space_id)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.delete(
    "/assets/sources/{source_id}",
    response_model=FinanceAssetSourceResponse,
)
async def delete_asset_source(
    source_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await pause_asset_source(db, user=current_user, source_id=source_id)
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/sources/{source_id}/snapshots",
    response_model=FinanceAssetSnapshotResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_watch_snapshot(
    source_id: str,
    body: FinanceWatchSnapshotCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await record_watch_snapshot(db, user=current_user, source_id=source_id, body=body)
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.post(
    "/assets/sources/{source_id}/refresh",
    response_model=FinanceAssetSnapshotResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_watch_refresh(
    source_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await refresh_watch_source(db, user=current_user, source_id=source_id)
    except FinanceAssetError as exc:
        raise _asset_error(exc) from exc


@router.get("/assets/summary", response_model=FinanceNetWorthResponse)
async def get_net_worth_summary(
    space_id: str = Query(min_length=1, max_length=100),
    currency: str = Query("GBP", min_length=3, max_length=3),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await net_worth_summary(db, user=current_user, space_id=space_id, currency=currency)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except (FinanceAssetError, ValueError) as exc:
        raise _asset_error(FinanceAssetError(str(exc))) from exc


@router.get(
    "/assets/net-worth-history",
    response_model=FinanceNetWorthHistoryResponse,
)
async def get_net_worth_history(
    space_id: str = Query(min_length=1, max_length=100),
    currency: str = Query("GBP", min_length=3, max_length=3),
    days: int = Query(365, ge=7, le=3_650),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await net_worth_history(
            db,
            user=current_user,
            space_id=space_id,
            currency=currency,
            days=days,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except (FinanceAssetError, ValueError) as exc:
        raise _asset_error(FinanceAssetError(str(exc))) from exc

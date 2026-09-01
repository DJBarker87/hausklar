from typing import Annotated, Literal

from pydantic import BaseModel, Field


Identifier = Annotated[str, Field(min_length=1, max_length=100)]
Alias = Annotated[str, Field(min_length=1, max_length=200)]


class GroceryItemCreate(BaseModel):
    name: str = Field(min_length=1, max_length=300)
    category: str | None = Field(default=None, max_length=100)
    default_unit: str = Field(default="each", min_length=1, max_length=50)
    aliases: list[Alias] | None = Field(default=None, max_length=50)
    is_use_by_tracked: bool = False
    tesco_hint: str | None = Field(default=None, max_length=500)
    default_quantity: float | None = Field(default=1.0, gt=0, le=100_000, allow_inf_nan=False)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class GroceryItemUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=300)
    category: str | None = Field(default=None, max_length=100)
    default_unit: str | None = Field(default=None, min_length=1, max_length=50)
    aliases: list[Alias] | None = Field(default=None, max_length=50)
    is_use_by_tracked: bool | None = None
    tesco_hint: str | None = Field(default=None, max_length=500)
    default_quantity: float | None = Field(default=None, gt=0, le=100_000, allow_inf_nan=False)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class GroceryItemResponse(BaseModel):
    id: str
    name: str
    category: str | None = None
    default_unit: str
    aliases: list[str] | None = None
    is_use_by_tracked: bool = False
    tesco_hint: str | None = None
    default_quantity: float | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class PurchaseLineCreate(BaseModel):
    grocery_item_id: Identifier
    qty: float = Field(default=1.0, gt=0, le=100_000, allow_inf_nan=False)
    unit: str = Field(default="each", min_length=1, max_length=50)
    raw_name: str | None = Field(default=None, max_length=300)
    price_pence: int | None = Field(default=None, ge=0, le=100_000_000)
    use_by_date: str | None = Field(default=None, max_length=64)
    storage: Literal["fridge", "freezer", "pantry"] | None = "fridge"


class PurchaseLineResponse(BaseModel):
    id: str
    purchase_batch_id: str
    grocery_item_id: str
    grocery_item_name: str | None = None
    qty: float
    unit: str
    raw_name: str | None = None
    price_pence: int | None = None
    use_by_date: str | None = None
    storage: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class PurchaseBatchCreate(BaseModel):
    purchased_at: str = Field(min_length=1, max_length=64)
    source: str = Field(default="tesco", min_length=1, max_length=100)
    notes: str | None = Field(default=None, max_length=2_000)
    lines: list[PurchaseLineCreate] = Field(default_factory=list, max_length=200)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class PurchaseBatchResponse(BaseModel):
    id: str
    purchased_at: str
    source: str
    notes: str | None = None
    lines: list[PurchaseLineResponse] = Field(default_factory=list)
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class TescoImportRequest(BaseModel):
    raw_text: str = Field(min_length=1, max_length=100_000)
    purchased_at: str | None = Field(default=None, max_length=64)


class TescoImportMatch(BaseModel):
    raw_line: str
    matched_item_id: str | None = None
    matched_item_name: str | None = None
    confidence: str
    needs_review: bool


class TescoImportResponse(BaseModel):
    batch_id: str
    matches: list[TescoImportMatch]


class ConsumptionEventCreate(BaseModel):
    grocery_item_id: Identifier
    amount: float = Field(default=1.0, gt=0, le=100_000, allow_inf_nan=False)
    unit: str = Field(default="each", min_length=1, max_length=50)
    event_type: Literal["consumed", "wasted", "spilled"] = "consumed"
    source: Literal["app", "home_assistant"] = "app"
    notes: str | None = Field(default=None, max_length=2_000)
    event_at: str | None = Field(default=None, max_length=64)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class ConsumptionEventResponse(BaseModel):
    id: str
    grocery_item_id: str
    event_at: str
    amount: float
    unit: str
    event_type: str
    source: str
    notes: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class StockLevelResponse(BaseModel):
    grocery_item_id: str
    item_name: str
    category: str | None = None
    total_purchased: float
    total_consumed: float
    total_wasted: float
    remaining: float
    unit: str
    earliest_use_by: str | None = None
    days_until_expiry: int | None = None


class CriticalLowStockResponse(BaseModel):
    grocery_item_id: str
    item_name: str
    remaining: float
    unit: str
    threshold: float
    reason: str


class ExpiringItemResponse(BaseModel):
    grocery_item_id: str
    item_name: str
    use_by_date: str
    remaining_qty: float
    unit: str
    days_left: int
    alert_level: str


class SuggestionResponse(BaseModel):
    grocery_item_id: str
    item_name: str
    suggested_qty: float
    unit: str
    confidence: str
    reason: str


class ShoppingSuggestionsResponse(BaseModel):
    suggestions: list[SuggestionResponse]
    generated_at: str


class SuggestionsAcceptRequest(BaseModel):
    grocery_item_ids: list[Identifier] | None = Field(default=None, max_length=200)


class UseByPatchRequest(BaseModel):
    use_by_date: str = Field(min_length=1, max_length=64)


class FreezerAddRequest(BaseModel):
    name: str = Field(min_length=1, max_length=300)
    qty: float = Field(default=1.0, gt=0, le=100_000, allow_inf_nan=False)
    unit: str = Field(default="each", min_length=1, max_length=50)


class FreezerItemResponse(BaseModel):
    grocery_item_id: str
    item_name: str
    qty: float
    unit: str


# --- Tesco purchase history ---


class TescoHistoryPreview(BaseModel):
    filename: str
    sha256: str
    order_count: int
    line_count: int
    first_purchased_at: str | None = None
    last_purchased_at: str | None = None
    sample_items: list[str] = Field(default_factory=list)
    issues: list[str] = Field(default_factory=list)
    already_imported: bool = False
    can_confirm: bool = True


class TescoHistoryImportResult(BaseModel):
    import_id: str | None = None
    imported: bool
    imported_orders: int
    skipped_orders: int
    preview: TescoHistoryPreview


class TescoHistoryUsual(BaseModel):
    name: str
    shop_count: int
    last_bought: str
    latest_price_pence: int | None = None
    previous_price_pence: int | None = None


class TescoHistorySummary(BaseModel):
    shop_count: int = 0
    line_count: int = 0
    first_purchased_at: str | None = None
    last_purchased_at: str | None = None
    last_imported_at: str | None = None
    receipt_monitoring: bool = False
    price_rise_count: int = 0
    usuals: list[TescoHistoryUsual] = Field(default_factory=list)

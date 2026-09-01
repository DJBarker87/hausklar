from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator, model_validator


HomeControlCapability = Literal[
    "activate",
    "play_pause",
    "select_option",
    "set_temperature",
    "toggle",
    "turn_off",
    "turn_on",
    "view",
]
HomeControlKind = Literal[
    "camera",
    "climate",
    "light",
    "media",
    "mode",
    "scene",
    "sensor",
    "switch",
]


class HomeEntityResponse(BaseModel):
    entity_id: str
    name: str
    domain: str
    state: str
    device_class: str | None = None
    unit_of_measurement: str | None = None
    current_temperature: float | None = None
    temperature: float | None = None
    hvac_action: str | None = None
    brightness: int | None = None
    media_title: str | None = None
    media_artist: str | None = None
    volume_level: float | None = None
    is_volume_muted: bool | None = None
    shuffle: bool | None = None
    repeat: str | None = None
    media_album_name: str | None = None
    media_duration: float | None = None
    media_position: float | None = None
    media_position_updated_at: str | None = None
    entity_picture: str | None = None
    options: list[str] | None = None
    battery_level: int | None = None
    source: str | None = None
    operation_mode: str | None = None
    operation_list: list[str] | None = None
    group_members: list[str] | None = None
    hvac_modes: list[str] | None = None
    preset_modes: list[str] | None = None
    preset_mode: str | None = None
    min_temp: float | None = None
    max_temp: float | None = None
    last_changed: str | None = None
    last_updated: str | None = None


class HomeManifestEntity(BaseModel):
    entity_id: str
    name: str
    domain: str
    room_id: str | None = None
    room_name: str | None = None
    control_kind: HomeControlKind
    capabilities: list[HomeControlCapability] = Field(default_factory=list)
    favourite: bool = False
    advanced: bool = False


class HomeManifestRoom(BaseModel):
    id: str
    name: str
    floor: int
    entity_ids: list[str] = Field(default_factory=list)
    light_entity_ids: list[str] = Field(default_factory=list)


class HomeModeSelector(BaseModel):
    entity_id: str
    name: str
    current: str
    options: list[str]


class HomeManifestResponse(BaseModel):
    rooms: list[HomeManifestRoom] = Field(default_factory=list)
    entities: list[HomeManifestEntity] = Field(default_factory=list)
    favourite_entity_ids: list[str] = Field(default_factory=list)
    mode_selector: HomeModeSelector | None = None
    broad_action_scopes: list[Literal["favourites", "room", "all"]] = Field(
        default_factory=lambda: ["favourites", "room", "all"]
    )
    advanced_features: list[
        Literal["cameras", "diagnostics", "floor_plan_2d", "floor_plan_3d", "mesh"]
    ] = Field(default_factory=list)


class HomeExceptionResponse(BaseModel):
    id: str
    severity: Literal["attention", "urgent"]
    title: str
    detail: str
    entity_id: str | None = None
    room_id: str | None = None


class HomeSitrepResponse(BaseModel):
    tone: Literal["calm", "attention"]
    headline: str
    summary: str
    exceptions: list[HomeExceptionResponse] = Field(default_factory=list)
    updated_at: str


class HomeSnapshotResponse(BaseModel):
    configured: bool
    available: bool = False
    entities: list[HomeEntityResponse] = Field(default_factory=list)
    manifest: HomeManifestResponse | None = None
    sitrep: HomeSitrepResponse | None = None


class HomeTemperatureHistoryPoint(BaseModel):
    recorded_at: str
    temperature: float
    target_temperature: float | None = None
    heating: bool = False


class HomeTemperatureHistoryResponse(BaseModel):
    entity_id: str
    unit: str | None = None
    hours: Literal[24] = 24
    points: list[HomeTemperatureHistoryPoint] = Field(default_factory=list)


class HomeRoomBounds(BaseModel):
    x: float
    y: float
    width: float
    height: float


class HomeRoomLayout(BaseModel):
    id: str
    label: str
    bounds: HomeRoomBounds
    polygon: list[tuple[float, float]] | None = None
    light_entity_ids: list[str] = Field(default_factory=list)
    label_at: tuple[float, float]


class HomeFloorLayout(BaseModel):
    id: Literal[0, 1]
    name: str
    rooms: list[HomeRoomLayout]
    walls: list[tuple[float, float, float, float]]
    stairs: list[tuple[float, float, float, float]]


class HomeTemperatureLayout(BaseModel):
    floor: Literal[0, 1]
    entity_ids: list[str]
    at: tuple[float, float]


class HomeDoorLayout(HomeTemperatureLayout):
    label: str


class HomeLayoutResponse(BaseModel):
    width: float
    height: float
    floors: list[HomeFloorLayout]
    temperatures: list[HomeTemperatureLayout]
    doors: list[HomeDoorLayout]


class HomeActionRequest(BaseModel):
    entity_id: str = Field(min_length=3, max_length=200)
    action: Literal["turn_on", "turn_off", "toggle", "play_pause", "set_temperature"]
    value: float | None = None

    @field_validator("entity_id")
    @classmethod
    def validate_entity_id(cls, value: str) -> str:
        domain, separator, object_id = value.partition(".")
        if not separator or not domain or not object_id:
            raise ValueError("A valid Home Assistant entity ID is required")
        allowed = set("abcdefghijklmnopqrstuvwxyz0123456789_")
        if any(character not in allowed for character in domain + object_id):
            raise ValueError("A valid Home Assistant entity ID is required")
        return value


class HomeActionResponse(BaseModel):
    success: bool
    entity_id: str
    action: str


class HomeFavouritesRequest(BaseModel):
    entity_ids: list[str] = Field(max_length=12)

    @field_validator("entity_ids")
    @classmethod
    def validate_entity_ids(cls, value: list[str]) -> list[str]:
        if len(value) != len(set(value)):
            raise ValueError("Favourite Home Assistant entities must be unique")
        allowed = set("abcdefghijklmnopqrstuvwxyz0123456789_.")
        if any(
            not entity_id
            or len(entity_id) > 200
            or "." not in entity_id
            or any(character not in allowed for character in entity_id)
            for entity_id in value
        ):
            raise ValueError("A valid Home Assistant entity ID is required")
        return value


class HomeFavouritesResponse(BaseModel):
    entity_ids: list[str]


class HomeBroadActionRequest(BaseModel):
    action: Literal["lights_on", "lights_off"]
    scope: Literal["favourites", "room", "all"]
    room_id: str | None = Field(default=None, max_length=100, pattern=r"^[a-z0-9_]+$")
    confirmed: bool = False

    @model_validator(mode="after")
    def validate_scope(self):
        if self.scope == "room" and self.room_id is None:
            raise ValueError("Choose a room for this house action")
        if self.scope != "room" and self.room_id is not None:
            raise ValueError("A room can only be used with room scope")
        return self


class HomeBroadActionResponse(BaseModel):
    success: bool
    action: Literal["lights_on", "lights_off"]
    scope: Literal["favourites", "room", "all"]
    entity_ids: list[str]


class HomeServiceRequest(BaseModel):
    domain: str = Field(min_length=2, max_length=50, pattern=r"^[a-z0-9_]+$")
    service: str = Field(min_length=2, max_length=80, pattern=r"^[a-z0-9_]+$")
    data: dict[str, Any] = Field(default_factory=dict)
    return_response: bool = False

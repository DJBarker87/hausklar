from pydantic import BaseModel, Field, field_validator


class AudiobookLibrary(BaseModel):
    id: str
    name: str
    media_type: str


class AudiobookLibrariesResponse(BaseModel):
    libraries: list[AudiobookLibrary] = Field(default_factory=list, max_length=100)


class AudiobookMetadata(BaseModel):
    title: str | None = None
    author_name: str | None = None
    narrator_name: str | None = None
    description: str | None = None


class AudiobookChapter(BaseModel):
    id: int
    title: str
    start: float
    end: float


class AudiobookMediaInfo(BaseModel):
    metadata: AudiobookMetadata | None = None
    duration: float | None = None
    chapters: list[AudiobookChapter] = Field(default_factory=list, max_length=1_000)


class AudiobookLibraryItem(BaseModel):
    id: str
    media: AudiobookMediaInfo | None = None


class AudiobookLibraryItemsResponse(BaseModel):
    results: list[AudiobookLibraryItem] = Field(default_factory=list, max_length=100)


class AudiobookProgress(BaseModel):
    current_time: float | None = None
    is_finished: bool | None = None
    progress: float | None = None


class AudiobookItemDetail(AudiobookLibraryItem):
    user_media_progress: AudiobookProgress | None = None


class AudiobookProgressRequest(BaseModel):
    current_time: float = Field(ge=0, le=10_000_000)
    is_finished: bool = False


class AudiobookProgressResponse(BaseModel):
    success: bool


class AudiobookPlayRequest(BaseModel):
    entity_id: str = Field(min_length=3, max_length=200)
    start_time: float | None = Field(default=None, ge=0, le=10_000_000)

    @field_validator("entity_id")
    @classmethod
    def validate_media_player(cls, value: str) -> str:
        parts = value.split(".")
        if (
            len(parts) != 2
            or parts[0] != "media_player"
            or not all(parts)
            or any(
                character not in "abcdefghijklmnopqrstuvwxyz0123456789_"
                for character in "".join(parts)
            )
        ):
            raise ValueError("A valid media player entity is required")
        return value


class AudiobookPlayResponse(BaseModel):
    available: bool
    handoff_id: str | None = None
    reason: str | None = None

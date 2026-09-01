from enum import StrEnum

from pydantic import BaseModel, Field


class SearchResultKind(StrEnum):
    event = "event"
    task = "task"
    document = "document"
    person = "person"
    photo = "photo"
    artwork = "artwork"
    homework = "homework"
    health = "health"
    renewal = "renewal"
    birthday = "birthday"


class SearchResult(BaseModel):
    id: str
    kind: SearchResultKind
    title: str
    subtitle: str | None = None
    date: str | None = None
    image_url: str | None = None
    child_id: str | None = None
    path: str = Field(pattern=r"^\?")


class SearchResponse(BaseModel):
    query: str
    results: list[SearchResult]
    has_more: bool = False

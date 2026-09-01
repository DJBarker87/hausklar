from dataclasses import dataclass
from urllib.parse import urlencode

from fastapi import APIRouter, Depends, Query

from app.auth import get_current_user
from app.database import get_db
from app.models.search import SearchResponse, SearchResult, SearchResultKind

router = APIRouter()


@dataclass(frozen=True)
class _RankedResult:
    rank: int
    result: SearchResult


def _path(**values: str | None) -> str:
    return "?" + urlencode({key: value for key, value in values.items() if value is not None})


def _like(term: str) -> str:
    escaped = term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def _title_rank(title: str, query: str) -> int:
    normalised = title.casefold().strip()
    if normalised == query:
        return 0
    if normalised.startswith(query):
        return 1
    if any(word.startswith(query) for word in normalised.split()):
        return 2
    return 3


async def _rows(db, sql: str, params: tuple) -> list[dict]:
    return [dict(row) for row in await (await db.execute(sql, params)).fetchall()]


@router.get("", response_model=SearchResponse)
async def search_family(
    q: str = Query(min_length=2, max_length=120),
    limit: int = Query(default=30, ge=1, le=60),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Search family records without retaining the query or exposing private adult workspaces."""
    query = " ".join(q.split()).casefold()
    pattern = _like(query)
    family_id = current_user["family_id"]
    per_group = min(max(limit, 8), 30)
    found: list[_RankedResult] = []

    events = await _rows(
        db,
        """
        SELECT id, title, start_time, location
        FROM calendar_events
        WHERE family_id = ? AND deleted_at IS NULL
          AND (lower(title) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(description, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(location, '')) LIKE ? ESCAPE '\\')
        ORDER BY start_time DESC LIMIT ?
        """,
        (family_id, pattern, pattern, pattern, per_group),
    )
    for row in events:
        date = row["start_time"][:10]
        subtitle = "Calendar" + (f" · {row['location']}" if row["location"] else "")
        found.append(
            _RankedResult(
                _title_rank(row["title"], query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.event, title=row["title"],
                    subtitle=subtitle, date=date,
                    path=_path(view="calendar", event=row["id"], event_date=date),
                ),
            )
        )

    tasks = await _rows(
        db,
        """
        SELECT id, title, due_date, completed_at
        FROM tasks
        WHERE family_id = ? AND deleted_at IS NULL
          AND (lower(title) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(description, '')) LIKE ? ESCAPE '\\')
        ORDER BY COALESCE(due_date, updated_at) DESC LIMIT ?
        """,
        (family_id, pattern, pattern, per_group),
    )
    for row in tasks:
        state = "completed" if row["completed_at"] else "active"
        found.append(
            _RankedResult(
                _title_rank(row["title"], query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.task, title=row["title"],
                    subtitle="Completed task" if row["completed_at"] else "Task",
                    date=row["due_date"],
                    path=_path(view="lists", section="tasks", task=row["id"], task_status=state),
                ),
            )
        )

    documents = await _rows(
        db,
        """
        SELECT id, title, category, document_date, created_at
        FROM documents
        WHERE family_id = ? AND deleted_at IS NULL
          AND (lower(title) LIKE ? ESCAPE '\\'
               OR lower(original_filename) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(extracted_text, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(notes, '')) LIKE ? ESCAPE '\\')
        ORDER BY COALESCE(document_date, created_at) DESC LIMIT ?
        """,
        (family_id, pattern, pattern, pattern, pattern, per_group),
    )
    for row in documents:
        found.append(
            _RankedResult(
                _title_rank(row["title"], query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.document, title=row["title"],
                    subtitle=f"{row['category'].replace('_', ' ').title()} document",
                    date=row["document_date"] or row["created_at"][:10],
                    path=_path(view="family", section="documents", document=row["id"]),
                ),
            )
        )

    people = await _rows(
        db,
        """
        SELECT id, name, 'child' AS person_type, date_of_birth AS person_date, avatar_url
        FROM children
        WHERE family_id = ? AND deleted_at IS NULL AND lower(name) LIKE ? ESCAPE '\\'
        UNION ALL
        SELECT id, name, 'adult' AS person_type, NULL AS person_date, avatar_url
        FROM users
        WHERE family_id = ? AND deleted_at IS NULL AND lower(name) LIKE ? ESCAPE '\\'
        LIMIT ?
        """,
        (family_id, pattern, family_id, pattern, per_group),
    )
    for row in people:
        child_id = row["id"] if row["person_type"] == "child" else None
        found.append(
            _RankedResult(
                _title_rank(row["name"], query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.person, title=row["name"],
                    subtitle="Child" if child_id else "Adult",
                    date=row["person_date"], image_url=row["avatar_url"], child_id=child_id,
                    path=_path(view="family", child=child_id),
                ),
            )
        )

    photos = await _rows(
        db,
        """
        SELECT p.id, p.child_id, p.caption, p.taken_on, p.location, c.name AS child_name,
               p.updated_at
        FROM child_photos p
        JOIN children c ON c.id = p.child_id AND c.family_id = p.family_id
        WHERE p.family_id = ? AND p.deleted_at IS NULL AND c.deleted_at IS NULL
          AND (lower(COALESCE(p.caption, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(p.location, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(p.story, '')) LIKE ? ESCAPE '\\'
               OR lower(c.name) LIKE ? ESCAPE '\\')
        ORDER BY p.taken_on DESC LIMIT ?
        """,
        (family_id, pattern, pattern, pattern, pattern, per_group),
    )
    for row in photos:
        title = row["caption"] or f"Photo of {row['child_name']}"
        version = "".join(character for character in row["updated_at"] if character.isdigit())
        found.append(
            _RankedResult(
                _title_rank(title, query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.photo, title=title,
                    subtitle=row["child_name"] + (f" · {row['location']}" if row["location"] else ""),
                    date=row["taken_on"], child_id=row["child_id"],
                    image_url=f"/child-photos/{row['id']}/image?v={version}",
                    path=_path(view="family", section="photos", child=row["child_id"], photo=row["id"]),
                ),
            )
        )

    artworks = await _rows(
        db,
        """
        SELECT a.id, a.child_id, a.title, a.approx_date, a.medium, c.name AS child_name,
               a.updated_at
        FROM artworks a
        JOIN children c ON c.id = a.child_id AND c.family_id = a.family_id
        WHERE a.family_id = ? AND a.deleted_at IS NULL AND c.deleted_at IS NULL
          AND (lower(COALESCE(a.title, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(a.notes, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(a.story, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(a.child_quote, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(a.medium, '')) LIKE ? ESCAPE '\\'
               OR lower(c.name) LIKE ? ESCAPE '\\')
        ORDER BY a.approx_date DESC LIMIT ?
        """,
        (family_id, pattern, pattern, pattern, pattern, pattern, pattern, per_group),
    )
    for row in artworks:
        title = row["title"] or f"Artwork by {row['child_name']}"
        version = "".join(character for character in row["updated_at"] if character.isdigit())
        found.append(
            _RankedResult(
                _title_rank(title, query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.artwork, title=title,
                    subtitle=row["child_name"] + (f" · {row['medium']}" if row["medium"] else ""),
                    date=row["approx_date"], child_id=row["child_id"],
                    image_url=f"/artworks/{row['id']}/image?v={version}",
                    path=_path(view="family", section="artwork", child=row["child_id"], artwork=row["id"]),
                ),
            )
        )

    reading = await _rows(
        db,
        """
        SELECT h.id, h.child_id, h.book_title AS title, h.date AS record_date, c.name AS child_name
        FROM homework_reading h
        JOIN children c ON c.id = h.child_id AND c.family_id = h.family_id
        WHERE h.family_id = ? AND h.deleted_at IS NULL AND c.deleted_at IS NULL
          AND (lower(h.book_title) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(h.notes, '')) LIKE ? ESCAPE '\\')
        ORDER BY h.date DESC LIMIT ?
        """,
        (family_id, pattern, pattern, per_group),
    )
    for row in reading:
        found.append(
            _RankedResult(
                _title_rank(row["title"], query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.homework, title=row["title"],
                    subtitle=f"Reading · {row['child_name']}", date=row["record_date"],
                    child_id=row["child_id"],
                    path=_path(view="family", section="learning", child=row["child_id"], reading=row["id"]),
                ),
            )
        )

    health = await _rows(
        db,
        """
        SELECT v.vaccine_key AS id, v.child_id,
               COALESCE(v.vaccine_name, replace(v.vaccine_key, '_', ' ')) AS title,
               v.given_on AS record_date, c.name AS child_name
        FROM child_vaccinations v
        JOIN children c ON c.id = v.child_id AND c.family_id = v.family_id
        WHERE v.family_id = ? AND v.deleted_at IS NULL AND c.deleted_at IS NULL
          AND (lower(COALESCE(v.vaccine_name, '')) LIKE ? ESCAPE '\\'
               OR lower(v.vaccine_key) LIKE ? ESCAPE '\\'
               OR lower(c.name) LIKE ? ESCAPE '\\')
        ORDER BY v.given_on DESC LIMIT ?
        """,
        (family_id, pattern, pattern, pattern, per_group),
    )
    for row in health:
        title = row["title"].replace("custom:", "")
        found.append(
            _RankedResult(
                _title_rank(title, query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.health, title=title,
                    subtitle=f"Vaccination · {row['child_name']}", date=row["record_date"],
                    child_id=row["child_id"],
                    path=_path(view="family", section="health", child=row["child_id"], vaccination=row["id"]),
                ),
            )
        )

    renewals = await _rows(
        db,
        """
        SELECT id, title, provider, due_date
        FROM renewals
        WHERE family_id = ? AND deleted_at IS NULL
          AND (lower(title) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(provider, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(reference, '')) LIKE ? ESCAPE '\\'
               OR lower(COALESCE(notes, '')) LIKE ? ESCAPE '\\')
        ORDER BY due_date LIMIT ?
        """,
        (family_id, pattern, pattern, pattern, pattern, per_group),
    )
    for row in renewals:
        found.append(
            _RankedResult(
                _title_rank(row["title"], query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.renewal, title=row["title"],
                    subtitle=row["provider"] or "Renewal", date=row["due_date"],
                    path=_path(view="lists", section="renewals", renewal=row["id"]),
                ),
            )
        )

    birthdays = await _rows(
        db,
        """
        SELECT id, person_name, relationship, date_of_birth
        FROM birthdays
        WHERE family_id = ? AND deleted_at IS NULL
          AND lower(person_name) LIKE ? ESCAPE '\\'
        ORDER BY person_name LIMIT ?
        """,
        (family_id, pattern, per_group),
    )
    for row in birthdays:
        found.append(
            _RankedResult(
                _title_rank(row["person_name"], query),
                SearchResult(
                    id=row["id"], kind=SearchResultKind.birthday, title=row["person_name"],
                    subtitle=f"{row['relationship'].title()} birthday", date=row["date_of_birth"],
                    path=_path(view="family", section="birthdays", birthday=row["id"]),
                ),
            )
        )

    kind_order = {kind: index for index, kind in enumerate(SearchResultKind)}
    found.sort(key=lambda item: (item.rank, kind_order[item.result.kind], item.result.title.casefold()))
    return SearchResponse(
        query=" ".join(q.split()),
        results=[item.result for item in found[:limit]],
        has_more=len(found) > limit,
    )

"""Example School rugby-team discovery and HausKlar fixture presentation rules."""

from __future__ import annotations

import html
import json
import re
from datetime import date, datetime, time, timezone
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

import httpx

SCHOOL_SCHOOL_ID = "999999"
RUGBY_UNION_SPORT_ID = "24"
SCHOOL_RUGBY_TEAM_PAGE = "https://sports.example.invalid/Fixtures_Teams.asp"
SCHOOL_RUGBY_FIXTURE_FEED = "https://ical.schoolssports.com/"
SCHOOL_RUGBY_SOURCE_KIND = "school_rugby"
SCHOOL_RUGBY_HOSTNAME = "ical.schoolssports.com"
SCHOOL_RUGBY_SOURCE_COLOR = "#2563EB"
# A data colour is required so the same away warning survives on iOS and web.
SCHOOL_RUGBY_AWAY_COLOR = "#DC2626"
LOCAL_TIMEZONE = ZoneInfo("Europe/London")
_MAX_TEAM_PAGE_BYTES = 1_000_000
_TEAM_FETCH_TIMEOUT = httpx.Timeout(20.0, connect=8.0)
_CHALLENGE_COOKIE_PATTERN = re.compile(r"__jschk=([^;\"']{1,300})")


class SchoolRugbyError(ValueError):
    """A safe error that can be shown in the rugby connection UI."""


def current_school_season(today: date | None = None) -> tuple[str, str]:
    """Return the SOCS season key and human label for the current school year."""
    reference = today or datetime.now(LOCAL_TIMEZONE).date()
    start_year = reference.year if reference.month >= 7 else reference.year - 1
    return f"{start_year}{start_year + 1}", f"{start_year}/{str(start_year + 1)[-2:]}"


def rugby_fixture_feed_url(team_id: str) -> str:
    if not re.fullmatch(r"\d{1,20}", team_id):
        raise SchoolRugbyError("The selected rugby team is invalid")
    return f"{SCHOOL_RUGBY_FIXTURE_FEED}?TID={team_id}"


def rugby_source_config(*, team_id: str, team_name: str, season: str) -> str:
    return json.dumps(
        {
            "school": "Example School College",
            "sport": "Rugby Union",
            "team_id": team_id,
            "team_name": team_name,
            "season": season,
        },
        separators=(",", ":"),
        sort_keys=True,
    )


def parse_rugby_source_config(value: str | None) -> dict[str, str]:
    try:
        decoded = json.loads(value or "{}")
    except (TypeError, json.JSONDecodeError) as exc:
        raise SchoolRugbyError("The saved rugby-team setting is invalid") from exc
    if not isinstance(decoded, dict):
        raise SchoolRugbyError("The saved rugby-team setting is invalid")
    team_id = str(decoded.get("team_id") or "")
    team_name = str(decoded.get("team_name") or "").strip()
    season = str(decoded.get("season") or "").strip()
    if (
        not re.fullmatch(r"\d{1,20}", team_id)
        or not team_name
        or len(team_name) > 100
        or not re.fullmatch(r"\d{4}/\d{2}", season)
    ):
        raise SchoolRugbyError("The saved rugby-team setting is invalid")
    return {"team_id": team_id, "team_name": team_name, "season": season}


class _RugbyTeamParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._href: str | None = None
        self._title: str | None = None
        self._text: list[str] = []
        self.teams: list[dict[str, str]] = []
        self._seen: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            return
        values = {key.lower(): value or "" for key, value in attrs}
        href = html.unescape(values.get("href", ""))
        parsed = urlparse(href)
        query = {key.lower(): values for key, values in parse_qs(parsed.query).items()}
        team_ids = query.get("tid", [])
        sport_ids = query.get("sid", [])
        if (
            parsed.path.lower().endswith("fixtures_list.asp")
            and len(team_ids) == 1
            and re.fullmatch(r"\d{1,20}", team_ids[0])
            and (not sport_ids or sport_ids == [RUGBY_UNION_SPORT_ID])
        ):
            self._href = href
            self._title = html.unescape(values.get("title", ""))
            self._text = []

    def handle_data(self, data: str) -> None:
        if self._href is not None:
            self._text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() != "a" or self._href is None:
            return
        query = parse_qs(urlparse(self._href).query)
        team_id = query["TID"][0] if "TID" in query else query["tid"][0]
        visible_name = " ".join(" ".join(self._text).split())
        title_name = re.sub(
            r"\s+Fixtures\s*(?:&|and)\s*Results.*$",
            "",
            self._title or "",
            flags=re.IGNORECASE,
        ).strip()
        name = visible_name or title_name
        if name and team_id not in self._seen:
            self._seen.add(team_id)
            self.teams.append({"id": team_id, "name": name[:100]})
        self._href = None
        self._title = None
        self._text = []


def parse_rugby_teams(page_html: str) -> list[dict[str, str]]:
    parser = _RugbyTeamParser()
    parser.feed(page_html)
    parser.close()
    return parser.teams


async def _bounded_team_page(response: httpx.Response) -> str:
    response.raise_for_status()
    declared = response.headers.get("content-length")
    if declared and int(declared) > _MAX_TEAM_PAGE_BYTES:
        raise SchoolRugbyError("The Example School team list is unexpectedly large")
    body = response.content
    if len(body) > _MAX_TEAM_PAGE_BYTES:
        raise SchoolRugbyError("The Example School team list is unexpectedly large")
    return body.decode(response.encoding or "utf-8", errors="replace")


async def discover_rugby_teams(*, today: date | None = None) -> dict:
    """Fetch the bounded public Example School Rugby Union team list for the current season."""
    season_key, season_label = current_school_season(today)
    params = {"Id": SCHOOL_SCHOOL_ID, "S": season_key, "SID": RUGBY_UNION_SPORT_ID}
    try:
        async with httpx.AsyncClient(
            timeout=_TEAM_FETCH_TIMEOUT,
            follow_redirects=False,
            headers={"User-Agent": "HausKlar-SchoolRugby/1.0"},
        ) as client:
            response = await client.get(SCHOOL_RUGBY_TEAM_PAGE, params=params)
            page = await _bounded_team_page(response)
            challenge = _CHALLENGE_COOKIE_PATTERN.search(page)
            if challenge and "This site requires JavaScript" in page:
                client.cookies.set(
                    "__jschk",
                    challenge.group(1),
                    domain="sports.example.invalid",
                    path="/",
                )
                response = await client.get(SCHOOL_RUGBY_TEAM_PAGE, params=params)
                page = await _bounded_team_page(response)
    except SchoolRugbyError:
        raise
    except (httpx.HTTPError, ValueError) as exc:
        raise SchoolRugbyError("Example School's rugby teams could not be loaded") from exc

    teams = parse_rugby_teams(page)
    if not teams:
        raise SchoolRugbyError("Example School has not published rugby teams for this season yet")
    return {"season": season_label, "teams": teams}


def _utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _opponent(summary: str, team_name: str) -> str:
    expected = re.compile(
        rf"^Example School\s+College\s+Rugby\s+Union\s+{re.escape(team_name)}\s+v(?:s\.?)?\s+",
        flags=re.IGNORECASE,
    )
    candidate = expected.sub("", summary).strip()
    if candidate != summary.strip() and candidate:
        return candidate
    split = re.split(r"\s+v(?:s\.?)?\s+", summary, maxsplit=1, flags=re.IGNORECASE)
    return split[-1].strip() if len(split) == 2 and split[-1].strip() else "Opponent TBC"


def apply_rugby_venue(event: dict, venue: str) -> dict:
    """Apply the effective HOME/AWAY label and matching visual accent."""
    if venue not in {"home", "away"}:
        raise SchoolRugbyError("Rugby venue must be home or away")
    updated = dict(event)
    suffix = re.sub(r"^(?:HOME|AWAY)\s+—\s+", "", str(event["title"])).strip()
    updated["title"] = f"{venue.upper()} — {suffix}"
    updated["location"] = venue.upper()
    updated["color"] = SCHOOL_RUGBY_AWAY_COLOR if venue == "away" else None
    return updated


def transform_rugby_events(
    events: list[dict],
    *,
    config_json: str | None,
    owner_user_id: str,
    affected_user_ids: list[str],
) -> list[dict]:
    """Turn official fixture-feed rows into calm, fixed planning blocks."""
    config = parse_rugby_source_config(config_json)
    transformed: list[dict] = []
    for source_event in events:
        source_location = str(source_event.get("location") or "").strip().lower()
        if source_location not in {"home", "away"}:
            continue
        try:
            published_start = datetime.fromisoformat(
                str(source_event["start_time"]).replace("Z", "+00:00")
            ).astimezone(LOCAL_TIMEZONE)
        except (KeyError, ValueError) as exc:
            raise SchoolRugbyError("An Example School rugby fixture has an invalid date") from exc
        fixture_day = published_start.date()
        start = datetime.combine(fixture_day, time(13, 0), tzinfo=LOCAL_TIMEZONE)
        end = datetime.combine(fixture_day, time(19, 0), tzinfo=LOCAL_TIMEZONE)
        opponent = _opponent(str(source_event.get("title") or ""), config["team_name"])
        transformed_event = {
            **source_event,
            "title": f"{config['team_name']} rugby v {opponent}",
            "description": (
                f"Published kick-off: {published_start.strftime('%H:%M')}.\n\n"
                "Synced automatically from Example School College Sports."
            ),
            "start_time": _utc_text(start),
            "end_time": _utc_text(end),
            "all_day": False,
            "assigned_to": owner_user_id,
            "family_member_ids": [owner_user_id],
            "affected_member_ids": affected_user_ids or None,
            "event_type": "rugby_fixture",
            # Retain the existing silent busy-day signal without user-facing copy.
            "exertion": 3,
            "rugby_source_venue": source_location,
            "rugby_venue_override": None,
        }
        transformed.append(apply_rugby_venue(transformed_event, source_location))
    return transformed

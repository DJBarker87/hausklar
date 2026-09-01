"""Tests for the term scraper service (app.services.term_scraper)."""

import uuid
from datetime import date

import aiosqlite

from app.services import term_scraper
from app.database import init_db
from app.services.term_scraper import (
    SCHOOL_CONFIG,
    SchoolConfig,
    _apply_term_updates,
    _collect_school_terms,
    _extract_linked_term_documents,
    _parse_example_school_college,
    _parse_generic_uk_terms,
    _target_academic_year_starts,
    generate_claude_prompt,
    update_term_dates,
)

REFERENCE_DATE = date(2026, 7, 14)


# ---------------------------------------------------------------------------
# Parsing: Example School College format
# ---------------------------------------------------------------------------


async def test_parse_example_school_college_basic():
    """_parse_example_school_college extracts terms from Example School-style training/end-of-half text."""
    sample_text = """
    Lent Half 2026
    Training Days: Mon 5 Jan, Tue 6 Jan
    Boys arrive: Wed 7 Jan
    End of Half: Fri 20 Mar
    Exeat weekends: 7-8 Feb, 7-8 Mar

    Summer Half 2026
    Training Days: Tue 21 Apr
    Boys arrive: Wed 22 Apr
    End of Half: Fri 3 Jul
    Exeat weekends: 16-17 May, 13-14 Jun
    """
    terms = _parse_example_school_college(sample_text, REFERENCE_DATE)
    assert isinstance(terms, list)
    assert len(terms) >= 1

    for term in terms:
        assert "label" in term
        assert "start_date" in term
        assert "end_date" in term

    labels = [t["label"] for t in terms]
    # Should find both halves
    assert any("Lent" in label for label in labels)
    assert any("Summer" in label for label in labels)


async def test_parse_example_school_college_empty():
    """_parse_example_school_college returns empty list for unrelated text."""
    result = _parse_example_school_college(
        "This is just some random text about nothing.",
        REFERENCE_DATE,
    )
    assert result == []

    result_empty = _parse_example_school_college("", REFERENCE_DATE)
    assert result_empty == []


async def test_parse_example_school_college_live_2026_format_and_excludes_following_ay():
    sample_text = """
    ### Michaelmas 2026
    Mon 7 – Wed 9 Sep Training Days for Masters
    Thu 17 Dec End of Half
    ### Lent 2027
    Mon 11 – Tue 12 Jan Training Days for Masters
    Thu 25 Mar End of Half
    ### Summer 2027
    Mon 19 – Tue 20 Apr Training Days for Masters
    Sat 3 July End of Half
    ### Michaelmas 2027
    Mon 6 – Wed 8 Sep Training Days for Masters
    Thu 16 Dec End of Half
    """

    assert _target_academic_year_starts(REFERENCE_DATE) == {2025, 2026}
    assert _parse_example_school_college(sample_text, REFERENCE_DATE) == [
        {
            "label": "Michaelmas Half 2026",
            "start_date": "2026-09-07",
            "end_date": "2026-12-17",
        },
        {
            "label": "Lent Half 2027",
            "start_date": "2027-01-11",
            "end_date": "2027-03-25",
        },
        {
            "label": "Summer Half 2027",
            "start_date": "2027-04-19",
            "end_date": "2027-07-03",
        },
    ]


# ---------------------------------------------------------------------------
# Parsing: Generic UK terms format
# ---------------------------------------------------------------------------


async def test_parse_generic_uk_terms_basic():
    """_parse_generic_uk_terms extracts from 'Term: date – date' format."""
    sample_text = """
    Term Dates 2025-2026

    Autumn Term: 4 September – 18 December 2025
    Spring Term: 6 January – 28 March 2026
    Summer Term: 20 April – 17 July 2026
    """
    terms = _parse_generic_uk_terms(sample_text, REFERENCE_DATE)
    assert isinstance(terms, list)
    assert len(terms) >= 1

    for term in terms:
        assert "label" in term
        assert "start_date" in term
        assert "end_date" in term

    labels = [t["label"] for t in terms]
    assert any("Spring" in label for label in labels)


async def test_parse_generic_uk_terms_start_end_format():
    """_parse_generic_uk_terms handles 'Term starts: / Term ends:' format."""
    sample_text = """
    Spring Term 2026
    Term starts: Monday 6 January 2026
    Half term: 16 February – 20 February
    Term ends: Friday 28 March 2026

    Summer Term 2026
    Term starts: Monday 20 April 2026
    Half term: 25 May – 29 May
    Term ends: Friday 17 July 2026
    """
    terms = _parse_generic_uk_terms(sample_text, REFERENCE_DATE)
    assert isinstance(terms, list)
    assert len(terms) >= 1

    for term in terms:
        assert "label" in term
        assert "start_date" in term
        assert "end_date" in term


async def test_parse_generic_uk_terms_empty():
    """_parse_generic_uk_terms returns empty list for unrelated text."""
    result = _parse_generic_uk_terms(
        "No school dates mentioned here at all.",
        REFERENCE_DATE,
    )
    assert result == []

    result_empty = _parse_generic_uk_terms("", REFERENCE_DATE)
    assert result_empty == []


async def test_parse_example_secondary_pdf_format_includes_next_academic_year():
    sample_text = """
    AUTUMN TERM 2026
    Term commences Thursday 10 September 2026
    Term ends Wednesday 16 December 2026
    SPRING TERM 2027
    Term commences Wednesday 6 January 2027
    Term ends Tuesday 23 March 2027
    SUMMER TERM 2027
    Term commences Wednesday 14 April 2027
    Term ends Thursday 15 July 2027
    """

    assert _parse_generic_uk_terms(sample_text, REFERENCE_DATE) == [
        {
            "label": "Autumn Term 2026",
            "start_date": "2026-09-10",
            "end_date": "2026-12-16",
        },
        {
            "label": "Spring Term 2027",
            "start_date": "2027-01-06",
            "end_date": "2027-03-23",
        },
        {
            "label": "Summer Term 2027",
            "start_date": "2027-04-14",
            "end_date": "2027-07-15",
        },
    ]


async def test_parse_example_primary_school_ocr_keeps_all_six_teaching_blocks():
    sample_text = """
    Autumn 202 6
    Term 1 (3 9 days)
    Term starts on: Thursday 3rd Septem ber 202 6
    Term ends on: Frid ay 2 3rd October 202 6
    Term 2 (35 days)
    Term starts on: Monday 2nd November 202 6
    Term ends on: Friday 1 8th December 202 6
    Spring 202 7
    Term 3 (30 days)
    Term starts on: Monday 4th January 202 7
    Term ends on: Thursday 11th February 202 7
    Term 4 (24 days)
    Term starts on: Monday 22nd February 202 7
    Term ends on: Thursday 25th March 202 7
    Summer 202 7
    Term 5 (34 days)
    Term starts on: Monday 12 th April 202 7
    Term ends on: Friday 2 8th May 202 7
    Term 6 (33 days)
    Term starts on: Monday 7th June 202 7
    Term ends on: Friday 1 6th July 202 7
    """

    terms = _parse_generic_uk_terms(sample_text, REFERENCE_DATE)
    assert [term["label"] for term in terms] == [
        "Autumn Term 1 2026",
        "Autumn Term 2 2026",
        "Spring Term 3 2027",
        "Spring Term 4 2027",
        "Summer Term 5 2027",
        "Summer Term 6 2027",
    ]
    assert terms[0]["start_date"] == "2026-09-03"
    assert terms[-1]["end_date"] == "2027-07-16"


async def test_parse_preschool_yearless_dates_use_nearest_academic_heading():
    sample_text = """
    Term Dates 2025/2026
    Summer 2026
    Term starts Tues 14 April
    Term ends Wed 15th July
    Term Dates 2026/2027
    Autumn 2026
    Term starts Thursday 3rd September
    Term ends Thursday 17th December
    Spring 2027
    Term starts Tuesday 5th January
    Term ends Wednesday 24th March
    Summer 2027
    Term starts Tuesday 13th April
    Term ends Wednesday 14th July
    """

    terms = _parse_generic_uk_terms(sample_text, REFERENCE_DATE)
    assert [(term["start_date"], term["end_date"]) for term in terms] == [
        ("2026-04-14", "2026-07-15"),
        ("2026-09-03", "2026-12-17"),
        ("2027-01-05", "2027-03-24"),
        ("2027-04-13", "2027-07-14"),
    ]


async def test_linked_term_pdf_extraction_is_allowlisted_and_deduplicated():
    page = """
    [2026-2027 Term Dates](https://resources.finalsite.net/a/2026-2027TermDates.pdf)
    [duplicate image](https://resources.finalsite.net/image/2026-2027TermDates.pdf)
    [untrusted](https://example.org/2026-2027TermDates.pdf)
    [not terms](https://resources.finalsite.net/a/newsletter.pdf)
    """

    assert _extract_linked_term_documents(
        page,
        base_url="https://primary-school.example.invalid/term-dates",
        allowed_hosts=("resources.finalsite.net",),
    ) == ["https://resources.finalsite.net/a/2026-2027TermDates.pdf"]


async def test_collect_school_terms_follows_linked_pdf(monkeypatch):
    config = SchoolConfig(
        known_url="https://school.example/term-dates",
        person_ids=["person"],
        search_query="School term dates",
        linked_document_hosts=("school.example",),
    )
    page = "[Download term dates](https://school.example/term-dates-2026-27.pdf)"
    pdf = """
    Autumn Term 2026
    Term commences Thursday 10 September 2026
    Term ends Wednesday 16 December 2026
    """
    calls: list[tuple[str, bool]] = []

    async def fake_fetch(url: str, use_jina: bool = False) -> str:
        calls.append((url, use_jina))
        return page if url == config.known_url else pdf

    monkeypatch.setattr(term_scraper, "fetch_page", fake_fetch)
    _key, result, terms = await _collect_school_terms(
        "school",
        config,
        REFERENCE_DATE,
    )

    assert result["status"] == "partial"
    assert result["next_academic_year_complete"] is False
    assert result["linked_documents"] == 1
    assert terms[0]["start_date"] == "2026-09-10"
    assert calls == [
        (config.known_url, False),
        ("https://school.example/term-dates-2026-27.pdf", True),
    ]


# ---------------------------------------------------------------------------
# Claude prompt generation
# ---------------------------------------------------------------------------


async def test_generate_claude_prompt():
    """generate_claude_prompt returns a string with school name, raw text, and JSON mention."""
    school_name = "Example School College"
    raw_text = "Lent Half 2026\nTraining Days: Mon 5 Jan"

    prompt = generate_claude_prompt(school_name, raw_text)
    assert isinstance(prompt, str)
    assert school_name in prompt
    assert raw_text in prompt
    assert "JSON" in prompt or "json" in prompt.lower()


# ---------------------------------------------------------------------------
# DB: update_term_dates
# ---------------------------------------------------------------------------


async def test_update_term_dates_inserts(db_path):
    """update_term_dates inserts new terms with created_by='term-scraper'."""
    await init_db(db_path)
    person_id = "00000000-0000-0000-0000-000000000011"

    terms = [
        {
            "label": "Spring Term 2026",
            "start_date": "2026-01-06",
            "end_date": "2026-03-28",
        },
        {
            "label": "Summer Term 2026",
            "start_date": "2026-04-20",
            "end_date": "2026-07-17",
        },
    ]

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        count = await update_term_dates(db, "primary_school", terms)

    assert count == 2

    # Verify rows were inserted
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM term_dates WHERE person_id = ? AND deleted_at IS NULL",
            (person_id,),
        )
        rows = await cursor.fetchall()

    assert len(rows) == 2
    labels = [r["label"] for r in rows]
    assert "Spring Term 2026" in labels
    assert "Summer Term 2026" in labels

    for row in rows:
        assert row["created_by"] == "term-scraper"


async def test_update_term_dates_replaces_auto_entries(db_path):
    """update_term_dates soft-deletes old auto entries and inserts new ones."""
    await init_db(db_path)
    person_id = "00000000-0000-0000-0000-000000000011"

    old_terms = [
        {
            "label": "Old Spring 2026",
            "start_date": "2026-01-06",
            "end_date": "2026-03-28",
        },
    ]

    # Insert initial auto terms
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await update_term_dates(db, "primary_school", old_terms)

    # Capture the old row id
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT id FROM term_dates WHERE person_id = ? AND deleted_at IS NULL",
            (person_id,),
        )
        old_rows = await cursor.fetchall()
    assert len(old_rows) == 1
    old_id = old_rows[0]["id"]

    # Now update with new terms
    new_terms = [
        {
            "label": "New Autumn Term 1 2025",
            "start_date": "2025-09-04",
            "end_date": "2025-10-22",
        },
        {
            "label": "New Autumn Term 2 2025",
            "start_date": "2025-11-03",
            "end_date": "2025-12-19",
        },
        {
            "label": "New Spring Term 3 2026",
            "start_date": "2026-01-07",
            "end_date": "2026-02-12",
        },
        {
            "label": "New Spring Term 4 2026",
            "start_date": "2026-02-23",
            "end_date": "2026-03-27",
        },
        {
            "label": "New Summer Term 5 2026",
            "start_date": "2026-04-13",
            "end_date": "2026-05-22",
        },
        {
            "label": "New Summer Term 6 2026",
            "start_date": "2026-06-01",
            "end_date": "2026-07-18",
        },
    ]

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        count = await update_term_dates(db, "primary_school", new_terms)

    assert count == 6

    # Verify old entry is soft-deleted
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT * FROM term_dates WHERE id = ?", (old_id,))
        old_row = await cursor.fetchone()
    assert old_row is not None
    assert old_row["deleted_at"] is not None

    # Verify new entries exist and are active
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM term_dates WHERE person_id = ? AND deleted_at IS NULL",
            (person_id,),
        )
        active_rows = await cursor.fetchall()

    assert len(active_rows) == 6
    labels = [r["label"] for r in active_rows]
    assert "New Spring Term 3 2026" in labels
    assert "New Summer Term 6 2026" in labels


async def test_update_term_dates_preserves_manual_entries(db_path):
    """update_term_dates does not soft-delete manually created term entries."""
    await init_db(db_path)
    person_id = "00000000-0000-0000-0000-000000000011"
    now = "2026-02-09T12:00:00.000Z"

    # Insert a manual term (created_by is a user id, not 'term-scraper')
    manual_id = str(uuid.uuid4())
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO term_dates (id, person_id, label, start_date, end_date,
               created_at, updated_at, created_by)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                manual_id,
                person_id,
                "Manual Autumn Term",
                "2025-09-04",
                "2025-12-18",
                now,
                now,
                "00000000-0000-0000-0000-000000000001",  # Alex's user id
            ),
        )
        await db.commit()

    # Also insert an auto term that should be replaced
    auto_id = str(uuid.uuid4())
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO term_dates (id, person_id, label, start_date, end_date,
               created_at, updated_at, created_by)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                auto_id,
                person_id,
                "Auto Spring Term",
                "2026-01-06",
                "2026-03-28",
                now,
                now,
                "term-scraper",
            ),
        )
        await db.commit()

    # Run update_term_dates with new terms
    new_terms = [
        {
            "label": "Scraped Autumn Term 1 2025",
            "start_date": "2025-09-04",
            "end_date": "2025-10-22",
        },
        {
            "label": "Scraped Autumn Term 2 2025",
            "start_date": "2025-11-03",
            "end_date": "2025-12-19",
        },
        {
            "label": "Scraped Spring Term 3 2026",
            "start_date": "2026-01-07",
            "end_date": "2026-02-12",
        },
        {
            "label": "Scraped Spring Term 4 2026",
            "start_date": "2026-02-23",
            "end_date": "2026-03-27",
        },
        {
            "label": "Scraped Summer Term 5 2026",
            "start_date": "2026-04-13",
            "end_date": "2026-05-22",
        },
        {
            "label": "Scraped Summer Term 6 2026",
            "start_date": "2026-06-01",
            "end_date": "2026-07-17",
        },
    ]

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await update_term_dates(db, "primary_school", new_terms)

    # Verify manual entry is still active
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT * FROM term_dates WHERE id = ?", (manual_id,))
        manual_row = await cursor.fetchone()
    assert manual_row is not None
    assert manual_row["deleted_at"] is None
    assert manual_row["label"] == "Manual Autumn Term"

    # Verify old auto entry is soft-deleted
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT * FROM term_dates WHERE id = ?", (auto_id,))
        auto_row = await cursor.fetchone()
    assert auto_row is not None
    assert auto_row["deleted_at"] is not None

    # Verify new scraped entry exists
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            """SELECT * FROM term_dates
               WHERE person_id = ? AND deleted_at IS NULL AND created_by = 'term-scraper'""",
            (person_id,),
        )
        scraped_rows = await cursor.fetchall()
    assert len(scraped_rows) == 4
    assert {row["label"] for row in scraped_rows} == {
        "Scraped Spring Term 3 2026",
        "Scraped Spring Term 4 2026",
        "Scraped Summer Term 5 2026",
        "Scraped Summer Term 6 2026",
    }


async def test_update_term_dates_ignores_configured_people_outside_family(
    initialized_db,
    child1,
    second_family,
):
    terms = [
        {
            "label": "Summer Term 2099",
            "start_date": "2099-04-20",
            "end_date": "2099-07-17",
        }
    ]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        count = await update_term_dates(
            db,
            "primary_school",
            terms,
            family_id=second_family["id"],
        )

    assert count == 0
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT COUNT(*) FROM term_dates WHERE person_id = ?",
                (child1["id"],),
            )
        ).fetchone()
    assert row[0] == 0


async def test_aggregated_refresh_applies_ottilies_school_transition(
    initialized_db,
    child1,
    child2,
    child3,
):
    family_id = "00000000-0000-0000-0000-000000000100"
    max_id = "00000000-0000-0000-0000-000000000011"
    ottilie_id = "00000000-0000-0000-0000-000000000012"
    cassius_id = "00000000-0000-0000-0000-000000000013"
    porny_terms = [
        {
            "label": "Summer Term 6 2026",
            "start_date": "2026-06-01",
            "end_date": "2026-07-17",
        },
        {
            "label": "Autumn Term 1 2026",
            "start_date": "2026-09-03",
            "end_date": "2026-10-23",
        },
    ]
    preschool_terms = [
        {
            "label": "Summer Term 2026",
            "start_date": "2026-04-14",
            "end_date": "2026-07-15",
        },
        {
            "label": "Autumn Term 2026",
            "start_date": "2026-09-03",
            "end_date": "2026-12-17",
        },
        {
            "label": "Spring Term 2027",
            "start_date": "2027-01-05",
            "end_date": "2027-03-24",
        },
    ]
    collected = [
        ("primary_school", {"status": "ok"}, porny_terms),
        ("school_preschool", {"status": "ok"}, preschool_terms),
    ]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await _apply_term_updates(
            db,
            collected,
            family_id=family_id,
            reference_date=REFERENCE_DATE,
        )

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                """
                SELECT person_id, label, start_date FROM term_dates
                WHERE person_id IN (?, ?, ?) AND deleted_at IS NULL
                  AND created_by = 'term-scraper'
                ORDER BY person_id, start_date
                """,
                (max_id, ottilie_id, cassius_id),
            )
        ).fetchall()

    labels_by_person: dict[str, list[str]] = {}
    for row in rows:
        labels_by_person.setdefault(row["person_id"], []).append(row["label"])
    assert labels_by_person[max_id] == ["Summer Term 6 2026", "Autumn Term 1 2026"]
    assert labels_by_person[ottilie_id] == ["Summer Term 2026", "Autumn Term 1 2026"]
    assert labels_by_person[cassius_id] == ["Spring Term 2027"]
    ottilie_autumn = next(
        row
        for row in rows
        if row["person_id"] == ottilie_id
        and row["label"] == "Autumn Term 1 2026"
    )
    assert ottilie_autumn["start_date"] == "2026-09-09"


async def test_aggregated_refresh_preserves_person_if_transition_source_fails(
    initialized_db,
    child2,
):
    family_id = "00000000-0000-0000-0000-000000000100"
    ottilie_id = "00000000-0000-0000-0000-000000000012"
    now = "2026-07-14T12:00:00+00:00"
    existing_id = str(uuid.uuid4())
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO term_dates
                (id, person_id, label, start_date, end_date, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'term-scraper')
            """,
            (
                existing_id,
                ottilie_id,
                "Existing protected term",
                "2026-09-01",
                "2026-12-01",
                family_id,
                now,
                now,
            ),
        )
        await db.commit()

    collected = [
        (
            "primary_school",
            {"status": "ok"},
            [
                {
                    "label": "Autumn Term 1 2026",
                    "start_date": "2026-09-03",
                    "end_date": "2026-10-23",
                }
            ],
        ),
        ("school_preschool", {"status": "fetch_failed"}, []),
    ]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        summary = await _apply_term_updates(
            db,
            collected,
            family_id=family_id,
            reference_date=REFERENCE_DATE,
        )

    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT deleted_at FROM term_dates WHERE id = ?",
                (existing_id,),
            )
        ).fetchone()
    assert row[0] is None
    assert ottilie_id in summary["primary_school"]["write_skipped_people"]


async def test_scraped_terms_do_not_overlap_active_manual_terms(
    initialized_db,
    child1,
):
    family_id = "00000000-0000-0000-0000-000000000100"
    max_id = "00000000-0000-0000-0000-000000000011"
    now = "2026-07-14T12:00:00+00:00"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO term_dates
                (id, person_id, label, start_date, end_date, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                max_id,
                "Manual current term",
                "2026-04-01",
                "2026-07-20",
                family_id,
                now,
                now,
                "00000000-0000-0000-0000-000000000001",
            ),
        )
        await db.commit()
        await update_term_dates(
            db,
            "primary_school",
            [
                {
                    "label": "Overlapping scraped term",
                    "start_date": "2026-06-01",
                    "end_date": "2026-07-17",
                },
                {
                    "label": "Future scraped term",
                    "start_date": "2026-09-03",
                    "end_date": "2026-10-23",
                },
            ],
            family_id=family_id,
        )

    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                """
                SELECT label FROM term_dates
                WHERE person_id = ? AND deleted_at IS NULL
                ORDER BY start_date
                """,
                (max_id,),
            )
        ).fetchall()
    assert [row[0] for row in rows] == ["Manual current term", "Future scraped term"]


async def test_identical_scraper_refresh_preserves_term_and_boundary_event_ids(
    initialized_db,
    child1,
):
    family_id = "00000000-0000-0000-0000-000000000100"
    terms = [
        {
            "label": "Autumn Term 1 2026",
            "start_date": "2026-09-03",
            "end_date": "2026-10-23",
        }
    ]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await update_term_dates(
            db,
            "primary_school",
            terms,
            family_id=family_id,
        )
        term_before = await (
            await db.execute(
                """
                SELECT id, updated_at FROM term_dates
                WHERE person_id = ? AND created_by = 'term-scraper'
                  AND deleted_at IS NULL
                """,
                (child1["id"],),
            )
        ).fetchone()
        events_before = await (
            await db.execute(
                """
                SELECT id, updated_at FROM calendar_events
                WHERE source_term_date_id = ? AND deleted_at IS NULL
                ORDER BY term_boundary
                """,
                (term_before["id"],),
            )
        ).fetchall()
        history_before = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id = ?",
                    (term_before["id"],),
                )
            ).fetchone()
        )[0]

        await update_term_dates(
            db,
            "primary_school",
            terms,
            family_id=family_id,
        )
        term_after = await (
            await db.execute(
                """
                SELECT id, updated_at FROM term_dates
                WHERE person_id = ? AND created_by = 'term-scraper'
                  AND deleted_at IS NULL
                """,
                (child1["id"],),
            )
        ).fetchone()
        events_after = await (
            await db.execute(
                """
                SELECT id, updated_at FROM calendar_events
                WHERE source_term_date_id = ? AND deleted_at IS NULL
                ORDER BY term_boundary
                """,
                (term_after["id"],),
            )
        ).fetchall()
        history_after = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id = ?",
                    (term_after["id"],),
                )
            ).fetchone()
        )[0]

    assert tuple(term_after) == tuple(term_before)
    assert [tuple(row) for row in events_after] == [tuple(row) for row in events_before]
    assert history_after == history_before


async def test_partial_academic_year_parse_preserves_unmentioned_scraped_terms(
    initialized_db,
    child1,
):
    family_id = "00000000-0000-0000-0000-000000000100"
    now = "2026-07-14T12:00:00+00:00"
    existing = [
        (str(uuid.uuid4()), "Autumn Term 2026", "2026-09-03", "2026-12-18"),
        (str(uuid.uuid4()), "Spring Term 2027", "2027-01-04", "2027-03-25"),
        (str(uuid.uuid4()), "Summer Term 2027", "2027-04-12", "2027-07-16"),
    ]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await db.executemany(
            """
            INSERT INTO term_dates
                (id, person_id, label, start_date, end_date, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'term-scraper')
            """,
            [
                (
                    term_id,
                    child1["id"],
                    label,
                    start,
                    end,
                    family_id,
                    now,
                    now,
                )
                for term_id, label, start, end in existing
            ],
        )
        await db.commit()
        await update_term_dates(
            db,
            "primary_school",
            [
                {
                    "label": "Autumn Term 2026 (confirmed)",
                    "start_date": "2026-09-03",
                    "end_date": "2026-12-18",
                }
            ],
            family_id=family_id,
        )
        rows = await (
            await db.execute(
                """
                SELECT id, label FROM term_dates
                WHERE person_id = ? AND created_by = 'term-scraper'
                  AND deleted_at IS NULL
                ORDER BY start_date
                """,
                (child1["id"],),
            )
        ).fetchall()

    assert [row["id"] for row in rows] == [term[0] for term in existing]
    assert [row["label"] for row in rows] == [
        "Autumn Term 2026 (confirmed)",
        "Spring Term 2027",
        "Summer Term 2027",
    ]


async def test_changed_partial_academic_year_does_not_create_overlapping_duplicate(
    initialized_db,
    child1,
):
    family_id = "00000000-0000-0000-0000-000000000100"
    now = "2026-07-14T12:00:00+00:00"
    existing = [
        (str(uuid.uuid4()), "Autumn Term 2026", "2026-09-03", "2026-12-18"),
        (str(uuid.uuid4()), "Spring Term 2027", "2027-01-04", "2027-03-25"),
        (str(uuid.uuid4()), "Summer Term 2027", "2027-04-12", "2027-07-16"),
    ]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await db.executemany(
            """
            INSERT INTO term_dates
                (id, person_id, label, start_date, end_date, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'term-scraper')
            """,
            [
                (
                    term_id,
                    child1["id"],
                    label,
                    start,
                    end,
                    family_id,
                    now,
                    now,
                )
                for term_id, label, start, end in existing
            ],
        )
        await db.commit()
        count = await update_term_dates(
            db,
            "primary_school",
            [
                {
                    "label": "Autumn Term 2026 changed partial",
                    "start_date": "2026-09-04",
                    "end_date": "2026-12-19",
                }
            ],
            family_id=family_id,
        )
        rows = await (
            await db.execute(
                """
                SELECT id, start_date, end_date FROM term_dates
                WHERE person_id = ? AND created_by = 'term-scraper'
                  AND deleted_at IS NULL
                ORDER BY start_date
                """,
                (child1["id"],),
            )
        ).fetchall()

    assert count == 0
    assert [row["id"] for row in rows] == [term[0] for term in existing]
    assert [(row["start_date"], row["end_date"]) for row in rows] == [
        (term[2], term[3]) for term in existing
    ]


# ---------------------------------------------------------------------------
# SCHOOL_CONFIG
# ---------------------------------------------------------------------------


async def test_school_config_has_required_schools():
    """SCHOOL_CONFIG contains entries for all required schools."""
    assert isinstance(SCHOOL_CONFIG, dict)
    required_keys = ["school_college", "example_secondary", "primary_school", "school_preschool"]
    for key in required_keys:
        assert key in SCHOOL_CONFIG, f"Missing school config key: {key}"

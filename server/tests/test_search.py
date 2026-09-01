import aiosqlite

EXAMPLE_FAMILY_ID = "00000000-0000-0000-0000-000000000100"
SECOND_FAMILY_ID = "00000000-0000-0000-0000-000000000200"


async def test_search_requires_authentication_and_a_useful_query(client, adult_a_headers):
    assert (await client.get("/api/search", params={"q": "calendar"})).status_code == 401
    too_short = await client.get("/api/search", params={"q": "a"}, headers=adult_a_headers)
    assert too_short.status_code == 422


async def test_search_finds_core_family_work_and_opens_the_exact_record(
    client,
    initialized_db,
    adult_a_headers,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, description, start_time, location, family_id)
               VALUES (?, ?, ?, ?, ?, ?)""",
            ("event-sports", "Sports day", "Bring trainers", "2026-08-12T09:00:00Z", "School field", EXAMPLE_FAMILY_ID),
        )
        await db.execute(
            """INSERT INTO tasks (id, title, description, due_date, family_id)
               VALUES (?, ?, ?, ?, ?)""",
            ("task-sports", "Pack sports kit", "White socks", "2026-08-11", EXAMPLE_FAMILY_ID),
        )
        await db.execute(
            """INSERT INTO documents
               (id, title, original_filename, media_type, storage_key, file_size, sha256,
                category, status, extracted_text, family_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                "document-sports", "Summer term letter", "letter.pdf", "application/pdf",
                "test/letter.pdf", 123, "abc", "school", "filed",
                "Private sports day arrangements and packed lunch details", EXAMPLE_FAMILY_ID,
            ),
        )
        await db.execute(
            """INSERT INTO calendar_events (id, title, start_time, family_id)
               VALUES (?, ?, ?, ?)""",
            ("other-event", "Secret sports plan", "2026-08-12T09:00:00Z", SECOND_FAMILY_ID),
        )
        await db.commit()

    response = await client.get("/api/search", params={"q": "sports"}, headers=adult_a_headers)
    assert response.status_code == 200, response.text
    results = response.json()["results"]
    by_kind = {result["kind"]: result for result in results}

    assert by_kind["event"]["path"] == "?view=calendar&event=event-sports&event_date=2026-08-12"
    assert by_kind["task"]["path"] == "?view=lists&section=tasks&task=task-sports&task_status=active"
    assert by_kind["document"]["path"] == "?view=family&section=documents&document=document-sports"
    assert by_kind["document"]["subtitle"] == "School document"
    # Matching OCR makes the document discoverable but private contents are not echoed in results.
    assert "packed lunch" not in str(results).lower()
    assert "other-event" not in {result["id"] for result in results}


async def test_search_covers_people_memories_health_and_household_records(
    client,
    initialized_db,
    adult_a_headers,
    child1,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO child_photos
               (id, child_id, caption, taken_on, media_type, storage_key, file_size, sha256,
                location, family_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                "photo-beach", child1["id"], "Sandcastle champion", "2026-06-01",
                "image/jpeg", "photo.jpg", 100, "photo-sha", "Brighton beach", EXAMPLE_FAMILY_ID,
            ),
        )
        await db.execute(
            """INSERT INTO artworks
               (id, child_id, title, medium, approx_date, media_type, storage_key, file_size, sha256,
                family_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                "art-sandcastle", child1["id"], "The great sandcastle", "Paint",
                "2026-06", "image/jpeg", "art.jpg", 100, "art-sha", EXAMPLE_FAMILY_ID,
            ),
        )
        await db.execute(
            """INSERT INTO child_vaccinations
               (id, child_id, vaccine_key, vaccine_name, given_on, family_id)
               VALUES (?, ?, ?, ?, ?, ?)""",
            ("vaccination-flu", child1["id"], "custom:flu", "Flu vaccine", "2026-01-10", EXAMPLE_FAMILY_ID),
        )
        await db.execute(
            """INSERT INTO renewals
               (id, title, category, due_date, provider, family_id)
               VALUES (?, ?, ?, ?, ?, ?)""",
            ("renewal-beach", "Beach hut membership", "membership", "2027-05-01", "Seafront Club", EXAMPLE_FAMILY_ID),
        )
        await db.commit()

    child_results = (await client.get("/api/search", params={"q": "Child 1"}, headers=adult_a_headers)).json()["results"]
    assert any(result["kind"] == "person" and result["child_id"] == child1["id"] for result in child_results)

    beach_results = (await client.get("/api/search", params={"q": "beach"}, headers=adult_a_headers)).json()["results"]
    assert {result["kind"] for result in beach_results} >= {"photo", "renewal"}
    photo = next(result for result in beach_results if result["kind"] == "photo")
    assert photo["path"].endswith(f"child={child1['id']}&photo=photo-beach")
    assert photo["image_url"].startswith("/child-photos/photo-beach/image")

    vaccine_results = (await client.get("/api/search", params={"q": "flu"}, headers=adult_a_headers)).json()["results"]
    vaccination = next(result for result in vaccine_results if result["kind"] == "health")
    assert vaccination["id"] == "custom:flu"
    assert vaccination["path"].endswith(
        f"child={child1['id']}&vaccination=custom%3Aflu"
    )
    assert vaccination["child_id"] == child1["id"]


async def test_search_limit_is_bounded_and_reports_more(client, initialized_db, adult_a_headers):
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            "INSERT INTO tasks (id, title, family_id) VALUES (?, ?, ?)",
            [(f"matching-{index}", f"Matching job {index}", EXAMPLE_FAMILY_ID) for index in range(6)],
        )
        await db.commit()

    response = await client.get("/api/search", params={"q": "matching", "limit": 3}, headers=adult_a_headers)
    assert response.status_code == 200
    assert len(response.json()["results"]) == 3
    assert response.json()["has_more"] is True

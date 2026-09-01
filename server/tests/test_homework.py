"""Tests for the homework router (/api/homework — reading & spellings)."""

from datetime import date, timedelta


# ===========================================================================
# Reading logs
# ===========================================================================


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


async def test_create_reading_log(client, adult_a_headers, child1):
    """POST /api/homework/reading with valid data returns 201."""
    resp = await client.post(
        "/api/homework/reading",
        json={
            "child_id": child1["id"],
            "book_title": "The Gruffalo",
            "minutes": 15,
            "date": "2026-02-07",
            "notes": "Read aloud together",
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["book_title"] == "The Gruffalo"
    assert data["minutes"] == 15
    assert data["child_id"] == child1["id"]
    assert data["date"] == "2026-02-07"
    assert data["notes"] == "Read aloud together"
    assert data["id"] is not None
    assert data["created_at"] is not None
    assert data["created_by"] is not None


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------


async def test_list_reading_logs(client, adult_a_headers, child1):
    """GET /api/homework/reading returns all non-deleted reading logs."""
    await client.post(
        "/api/homework/reading",
        json={
            "child_id": child1["id"],
            "book_title": "Book A",
            "minutes": 10,
            "date": "2026-02-06",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/homework/reading",
        json={
            "child_id": child1["id"],
            "book_title": "Book B",
            "minutes": 20,
            "date": "2026-02-07",
        },
        headers=adult_a_headers,
    )

    resp = await client.get("/api/homework/reading", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 2
    titles = [r["book_title"] for r in data]
    assert "Book A" in titles
    assert "Book B" in titles


# ---------------------------------------------------------------------------
# Filter by child
# ---------------------------------------------------------------------------


async def test_filter_reading_by_child(client, adult_a_headers, child1, child2):
    """GET /api/homework/reading?child_id=... filters by child."""
    await client.post(
        "/api/homework/reading",
        json={
            "child_id": child1["id"],
            "book_title": "Child 1 Book",
            "minutes": 10,
            "date": "2026-02-06",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/homework/reading",
        json={
            "child_id": child2["id"],
            "book_title": "Child 2 Book",
            "minutes": 15,
            "date": "2026-02-06",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        f"/api/homework/reading?child_id={child1['id']}", headers=adult_a_headers
    )
    assert resp.status_code == 200
    data = resp.json()
    assert all(r["child_id"] == child1["id"] for r in data)
    assert any(r["book_title"] == "Child 1 Book" for r in data)


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------


async def test_update_reading_log(client, adult_a_headers, child1):
    """PUT /api/homework/reading/{id} updates fields and returns updated log."""
    create_resp = await client.post(
        "/api/homework/reading",
        json={
            "child_id": child1["id"],
            "book_title": "Original Title",
            "minutes": 10,
            "date": "2026-02-06",
        },
        headers=adult_a_headers,
    )
    log_id = create_resp.json()["id"]

    resp = await client.put(
        f"/api/homework/reading/{log_id}",
        json={"book_title": "Updated Title", "minutes": 25},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["book_title"] == "Updated Title"
    assert data["minutes"] == 25


# ---------------------------------------------------------------------------
# Delete (soft)
# ---------------------------------------------------------------------------


async def test_delete_reading_log(client, adult_a_headers, child1):
    """DELETE /api/homework/reading/{id} soft-deletes and returns 204."""
    create_resp = await client.post(
        "/api/homework/reading",
        json={
            "child_id": child1["id"],
            "book_title": "Temporary Book",
            "minutes": 5,
            "date": "2026-02-06",
        },
        headers=adult_a_headers,
    )
    log_id = create_resp.json()["id"]

    resp = await client.delete(f"/api/homework/reading/{log_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    # Should no longer appear in the list
    list_resp = await client.get("/api/homework/reading", headers=adult_a_headers)
    ids = [r["id"] for r in list_resp.json()]
    assert log_id not in ids


# ===========================================================================
# Spellings
# ===========================================================================


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


async def test_create_spellings(client, adult_a_headers, child1):
    """POST /api/homework/spellings with valid data returns 201."""
    resp = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["apple", "banana", "cherry"],
            "test_date": "2026-02-14",
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["word_list"] == ["apple", "banana", "cherry"]
    assert data["test_date"] == "2026-02-14"
    assert data["child_id"] == child1["id"]
    assert data["score"] is None
    assert data["practice_count"] == 0
    assert data["id"] is not None
    assert data["created_at"] is not None
    assert data["created_by"] is not None


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------


async def test_list_spellings(client, adult_a_headers, child1):
    """GET /api/homework/spellings returns all non-deleted spellings."""
    await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["dog", "cat"],
            "test_date": "2026-02-10",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["house", "tree"],
            "test_date": "2026-02-17",
        },
        headers=adult_a_headers,
    )

    resp = await client.get("/api/homework/spellings", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 2


# ---------------------------------------------------------------------------
# Update score
# ---------------------------------------------------------------------------


async def test_update_spellings_score(client, adult_a_headers, child1):
    """PUT /api/homework/spellings/{id} can set a score after a test."""
    create_resp = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["elephant", "giraffe", "zebra"],
            "test_date": "2026-02-14",
        },
        headers=adult_a_headers,
    )
    spellings_id = create_resp.json()["id"]
    assert create_resp.json()["score"] is None

    resp = await client.put(
        f"/api/homework/spellings/{spellings_id}",
        json={"score": 3},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["score"] == 3


# ---------------------------------------------------------------------------
# Update practice_count (increment)
# ---------------------------------------------------------------------------


async def test_update_spellings_practice(client, adult_a_headers, child1):
    """PUT /api/homework/spellings/{id} increments practice_count."""
    create_resp = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["Monday", "Tuesday"],
            "test_date": "2026-02-14",
        },
        headers=adult_a_headers,
    )
    spellings_id = create_resp.json()["id"]
    assert create_resp.json()["practice_count"] == 0

    # First practice session
    resp = await client.put(
        f"/api/homework/spellings/{spellings_id}",
        json={"practice_count": 1},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["practice_count"] == 1

    # Second practice session
    resp = await client.put(
        f"/api/homework/spellings/{spellings_id}",
        json={"practice_count": 1},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["practice_count"] == 2


# ---------------------------------------------------------------------------
# Delete (soft)
# ---------------------------------------------------------------------------


async def test_delete_spellings(client, adult_a_headers, child1):
    """DELETE /api/homework/spellings/{id} soft-deletes and returns 204."""
    create_resp = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["temp"],
            "test_date": "2026-02-14",
        },
        headers=adult_a_headers,
    )
    spellings_id = create_resp.json()["id"]

    resp = await client.delete(
        f"/api/homework/spellings/{spellings_id}", headers=adult_a_headers
    )
    assert resp.status_code == 204

    # Should no longer appear in the list
    list_resp = await client.get("/api/homework/spellings", headers=adult_a_headers)
    ids = [s["id"] for s in list_resp.json()]
    assert spellings_id not in ids


# ---------------------------------------------------------------------------
# Filter by child
# ---------------------------------------------------------------------------


async def test_filter_spellings_by_child(client, adult_a_headers, child1, child2):
    """GET /api/homework/spellings?child_id=... filters by child."""
    await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["red", "blue"],
            "test_date": "2026-02-14",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child2["id"],
            "word_list": ["green", "yellow"],
            "test_date": "2026-02-14",
        },
        headers=adult_a_headers,
    )

    resp = await client.get(
        f"/api/homework/spellings?child_id={child1['id']}", headers=adult_a_headers
    )
    assert resp.status_code == 200
    data = resp.json()
    assert all(s["child_id"] == child1["id"] for s in data)
    assert any(s["word_list"] == ["red", "blue"] for s in data)


async def test_score_is_validated_against_this_list(client, adult_a_headers, child1):
    created = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["one", "two"],
            "test_date": "2026-08-14",
        },
        headers=adult_a_headers,
    )
    spellings_id = created.json()["id"]

    response = await client.post(
        f"/api/homework/spellings/{spellings_id}/complete",
        json={"score": 3},
        headers=adult_a_headers,
    )
    assert response.status_code == 422
    assert "number of words" in response.json()["detail"]

    unchanged = await client.get(
        f"/api/homework/spellings/{spellings_id}", headers=adult_a_headers
    )
    assert unchanged.json()["score"] is None
    assert unchanged.json()["completed_at"] is None


async def test_real_practice_tracks_per_word_mastery_and_allows_correction(
    client, adult_a_headers, child1
):
    created = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["because", "different"],
            "test_date": "2026-08-14",
        },
        headers=adult_a_headers,
    )
    spellings_id = created.json()["id"]
    attempts = [
        {"word": "because", "correct": True},
        {"word": "different", "correct": False},
    ]
    first = await client.post(
        f"/api/homework/spellings/{spellings_id}/practice",
        json={"attempts": attempts},
        headers=adult_a_headers,
    )
    assert first.status_code == 200
    assert first.json()["practice_count"] == 1
    assert first.json()["practice_sessions"][0]["correct_count"] == 1

    second = await client.post(
        f"/api/homework/spellings/{spellings_id}/practice",
        json={
            "attempts": [
                {"word": "because", "correct": True},
                {"word": "different", "correct": True},
            ]
        },
        headers=adult_a_headers,
    )
    assert second.status_code == 200
    mastery = {item["word"]: item for item in second.json()["mastery"]}
    assert mastery["because"]["mastered"] is True
    assert mastery["different"]["needs_practice"] is True

    session_id = second.json()["practice_sessions"][0]["id"]
    corrected = await client.put(
        f"/api/homework/spellings/{spellings_id}/practice/{session_id}",
        json={
            "attempts": [
                {"word": "because", "correct": False},
                {"word": "different", "correct": True},
            ]
        },
        headers=adult_a_headers,
    )
    assert corrected.status_code == 200
    corrected_mastery = {item["word"]: item for item in corrected.json()["mastery"]}
    assert corrected_mastery["because"]["mastered"] is False

    removed = await client.delete(
        f"/api/homework/spellings/{spellings_id}/practice/{session_id}",
        headers=adult_a_headers,
    )
    assert removed.status_code == 204
    detail = await client.get(
        f"/api/homework/spellings/{spellings_id}", headers=adult_a_headers
    )
    assert detail.json()["practice_count"] == 1
    assert len(detail.json()["practice_sessions"]) == 1


async def test_spelling_completion_reopen_and_detail_correction(client, adult_a_headers, child1):
    created = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["quiet", "quite"],
            "test_date": "2026-08-14",
            "notes": "Practise the vowel order",
            "link_url": "https://school.example/spellings",
        },
        headers=adult_a_headers,
    )
    spellings_id = created.json()["id"]
    assert created.json()["status"] in {"upcoming", "due", "overdue"}

    corrected = await client.put(
        f"/api/homework/spellings/{spellings_id}",
        json={"test_date": "2026-08-15", "notes": "Teacher moved the test"},
        headers=adult_a_headers,
    )
    assert corrected.status_code == 200
    assert corrected.json()["test_date"] == "2026-08-15"
    assert corrected.json()["notes"] == "Teacher moved the test"

    completed = await client.post(
        f"/api/homework/spellings/{spellings_id}/complete",
        json={"score": 2},
        headers=adult_a_headers,
    )
    assert completed.status_code == 200
    assert completed.json()["status"] == "completed"
    assert completed.json()["score"] == 2

    reopened = await client.post(
        f"/api/homework/spellings/{spellings_id}/reopen",
        headers=adult_a_headers,
    )
    assert reopened.status_code == 200
    assert reopened.json()["completed_at"] is None
    assert reopened.json()["score"] is None


async def test_reading_and_spelling_deletions_can_be_undone(client, adult_a_headers, child1):
    reading = await client.post(
        "/api/homework/reading",
        json={
            "child_id": child1["id"],
            "book_title": "The Wild Robot",
            "minutes": 15,
            "date": "2026-08-09",
        },
        headers=adult_a_headers,
    )
    reading_id = reading.json()["id"]
    assert (await client.delete(f"/api/homework/reading/{reading_id}", headers=adult_a_headers)).status_code == 204
    restored_reading = await client.post(
        f"/api/homework/reading/{reading_id}/restore", headers=adult_a_headers
    )
    assert restored_reading.status_code == 200
    assert restored_reading.json()["book_title"] == "The Wild Robot"

    spelling = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["robot"],
            "test_date": "2026-08-14",
        },
        headers=adult_a_headers,
    )
    spelling_id = spelling.json()["id"]
    assert (await client.delete(f"/api/homework/spellings/{spelling_id}", headers=adult_a_headers)).status_code == 204
    restored_spelling = await client.post(
        f"/api/homework/spellings/{spelling_id}/restore", headers=adult_a_headers
    )
    assert restored_spelling.status_code == 200
    assert restored_spelling.json()["word_list"] == ["robot"]


async def test_homework_detail_is_family_scoped(
    client, adult_a_headers, other_family_headers, child1
):
    created = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["private"],
            "test_date": "2026-08-14",
        },
        headers=adult_a_headers,
    )
    spellings_id = created.json()["id"]
    response = await client.get(
        f"/api/homework/spellings/{spellings_id}", headers=other_family_headers
    )
    assert response.status_code == 404


async def test_upcoming_spelling_work_is_available_to_today(client, adult_a_headers, child1):
    test_date = (date.today() + timedelta(days=3)).isoformat()
    created = await client.post(
        "/api/homework/spellings",
        json={
            "child_id": child1["id"],
            "word_list": ["calendar", "practice"],
            "test_date": test_date,
        },
        headers=adult_a_headers,
    )
    spellings_id = created.json()["id"]

    dashboard = await client.get(
        "/api/briefing/dashboard?timezone=Europe/London", headers=adult_a_headers
    )
    assert dashboard.status_code == 200
    homework = dashboard.json()["homework"]
    assert any(
        item["id"] == spellings_id
        and item["child_id"] == child1["id"]
        and item["test_date"] == test_date
        for item in homework
    )

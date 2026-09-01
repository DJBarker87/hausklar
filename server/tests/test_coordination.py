from datetime import datetime
from zoneinfo import ZoneInfo

import aiosqlite
from cryptography.fernet import Fernet

from app.config import settings
from app.services.coordination import next_load_prompt, tomorrow_card


async def test_tomorrow_card_collects_plan_and_one_unowned_prompt(
    client, adult_a_headers, adult_a_user, adult_b_user, initialized_db
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO calendar_events
               (id,title,start_time,all_day,event_type,family_id,created_by)
               VALUES (?,?,?,?,?,?,?)""",
            (
                "event-tomorrow",
                "Nursery",
                "2026-07-13T08:30:00+01:00",
                0,
                "school_milestone",
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO tasks
               (id,title,due_date,priority,family_id,created_by)
               VALUES (?,?,?,?,?,?)""",
            (
                "task-unowned",
                "Buy party present",
                "2026-07-14",
                3,
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()
        db.row_factory = aiosqlite.Row
        card = await tomorrow_card(
            db,
            adult_a_user,
            now=datetime(2026, 7, 12, 18, 0, tzinfo=ZoneInfo("Europe/London")),
        )
    assert card["visible"] is True
    assert card["events"][0]["title"] == "Nursery"
    assert card["events"][0]["event_type"] == "school_milestone"
    assert card["load_prompt"]["title"] == "Buy party present"


async def test_acknowledgement_and_later_are_personal(
    client, adult_a_headers, adult_b_headers, adult_a_user, adult_b_user, initialized_db
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO tasks (id,title,due_date,priority,family_id,created_by) VALUES (?,?,?,?,?,?)",
            (
                "task-unowned",
                "Buy party present",
                "2026-07-20",
                3,
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()
    ack = await client.post(
        "/api/coordination/tomorrow/ack",
        json={"target_date": "2026-07-13"},
        headers=adult_a_headers,
    )
    later = await client.post("/api/coordination/load/task-unowned/later", headers=adult_a_headers)
    assert ack.status_code == 204
    assert later.status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT user_id,action_kind FROM coordination_actions ORDER BY action_kind"
            )
        ).fetchall()
    assert rows == [(adult_a_user["id"], "load_later"), (adult_a_user["id"], "tomorrow_ack")]


async def test_assigning_bin_load_assigns_every_open_bin_and_removes_prompt(
    client,
    adult_a_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """INSERT INTO tasks
               (id,title,due_date,category,family_id,created_by)
               VALUES (?, 'Bins', ?, 'bins', ?, ?)""",
            [
                ("bins-one", "2026-07-14", adult_a_user["family_id"], "bin-scraper"),
                ("bins-two", "2026-07-21", adult_a_user["family_id"], "bin-scraper"),
            ],
        )
        await db.commit()

    response = await client.post(
        "/api/coordination/load/bins-one/assign",
        json={"assignee_id": adult_b_user["id"]},
        headers=adult_a_headers,
    )
    assert response.status_code == 204, response.text

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        assignments = await (
            await db.execute(
                """SELECT ta.task_id,ta.assignee_id,ta.assignee_type,t.assigned_to
                   FROM task_assignments ta JOIN tasks t ON t.id=ta.task_id
                   WHERE ta.deleted_at IS NULL ORDER BY ta.task_id"""
            )
        ).fetchall()
        prompt = await next_load_prompt(
            db,
            adult_a_user,
            local_today=datetime(2026, 7, 13).date(),
        )
    assert [tuple(row) for row in assignments] == [
        ("bins-one", adult_b_user["id"], "user", adult_b_user["id"]),
        ("bins-two", adult_b_user["id"], "user", adult_b_user["id"]),
    ]
    assert prompt is None


async def test_assigning_manual_bin_does_not_take_over_scraper_responsibility(
    client,
    adult_a_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    """A user-created bins chore is independent from council collection ownership."""
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """
            INSERT INTO tasks
                (id,title,due_date,category,family_id,created_by)
            VALUES (?, ?, ?, 'bins', ?, ?)
            """,
            [
                (
                    "managed-bin",
                    "Bins",
                    "2026-07-14",
                    adult_a_user["family_id"],
                    "bin-scraper",
                ),
                (
                    "manual-bin",
                    "Clean the kitchen bin",
                    "2026-07-15",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            ],
        )
        await db.commit()

    response = await client.post(
        "/api/coordination/load/manual-bin/assign",
        json={"assignee_id": adult_b_user["id"]},
        headers=adult_a_headers,
    )

    assert response.status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        assignments = await (
            await db.execute(
                """
                SELECT task_id,assignee_id FROM task_assignments
                WHERE deleted_at IS NULL ORDER BY task_id
                """
            )
        ).fetchall()
        tasks = await (await db.execute("SELECT id,assigned_to FROM tasks ORDER BY id")).fetchall()
    assert assignments == [("manual-bin", adult_b_user["id"])]
    assert tasks == [("managed-bin", None), ("manual-bin", adult_b_user["id"])]


async def test_assigning_normal_load_only_changes_requested_task(
    client,
    adult_a_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """INSERT INTO tasks
               (id,title,due_date,category,family_id,created_by)
               VALUES (?, ?, '2026-07-14', 'household', ?, ?)""",
            [
                ("normal-one", "Book dentist", adult_a_user["family_id"], adult_a_user["id"]),
                ("normal-two", "Buy present", adult_a_user["family_id"], adult_a_user["id"]),
            ],
        )
        await db.commit()

    response = await client.post(
        "/api/coordination/load/normal-one/assign",
        json={"assignee_id": adult_b_user["id"]},
        headers=adult_a_headers,
    )
    assert response.status_code == 204, response.text
    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                """SELECT task_id,assignee_id FROM task_assignments
                   WHERE deleted_at IS NULL ORDER BY task_id"""
            )
        ).fetchall()
    assert rows == [("normal-one", adult_b_user["id"])]


async def test_assigning_load_rejects_invalid_and_cross_family_users(
    client,
    adult_a_headers,
    adult_a_user,
    other_family_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO tasks
               (id,title,due_date,category,family_id,created_by)
               VALUES ('load-task','Bins','2026-07-14','bins',?,?)""",
            (adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    for assignee_id in ("missing-user", other_family_user["id"]):
        response = await client.post(
            "/api/coordination/load/load-task/assign",
            json={"assignee_id": assignee_id},
            headers=adult_a_headers,
        )
        assert response.status_code == 400

    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute("SELECT COUNT(*) FROM task_assignments WHERE deleted_at IS NULL")
            ).fetchone()
        )[0]
    assert count == 0


async def test_shared_text_is_encrypted_scoped_and_single_use(
    client, adult_a_headers, adult_b_headers, adult_a_user, adult_b_user, initialized_db
):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    created = await client.post(
        "/api/coordination/shares",
        json={"title": "School", "text": "Sports day Friday", "url": "https://school.example/item"},
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    identifier = created.json()["id"]
    async with aiosqlite.connect(initialized_db) as db:
        encrypted = (
            await (
                await db.execute(
                    "SELECT encrypted_text FROM share_capture_drafts WHERE id=?", (identifier,)
                )
            ).fetchone()
        )[0]
    assert "Sports day" not in encrypted
    assert (
        await client.get(f"/api/coordination/shares/{identifier}", headers=adult_b_headers)
    ).status_code == 404
    claimed = await client.get(f"/api/coordination/shares/{identifier}", headers=adult_a_headers)
    assert claimed.status_code == 200
    assert claimed.json()["text"] == "School\nSports day Friday\nhttps://school.example/item"
    assert (
        await client.get(f"/api/coordination/shares/{identifier}", headers=adult_a_headers)
    ).status_code == 404


async def test_share_target_redirects_with_opaque_id(client, adult_a_user, adult_a_token, initialized_db):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    client.cookies.set("hausklar_access", adult_a_token)
    response = await client.post(
        "/api/share-target",
        data={"title": "School", "text": "Secret message", "url": ""},
        headers={"Origin": "https://test"},
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert response.headers["location"].startswith("/?view=today&share=")
    assert "Secret" not in response.headers["location"]

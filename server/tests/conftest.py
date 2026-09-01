"""Shared test fixtures for the HausKlar test suite."""

import os

import pytest
import aiosqlite
import httpx

# Ensure production security checks pass in tests before importing the app.
os.environ.setdefault("JWT_SECRET_KEY", "test-jwt-secret-key-+000000000051234567890123")  # gitleaks:allow
os.environ.setdefault("HEALTH_WEBHOOK_SECRET", "test-health-webhook-secret-0123456789")
os.environ.setdefault("ALLOW_PUBLIC_REGISTRATION", "true")
os.environ.setdefault("WEB_APP_URL", "https://test")

from app.main import app
from app.database import close_db_pool, init_db, set_db_path
from app.auth import create_access_token, hash_password
from app.routers.auth import rate_limiter, sensitive_action_limiter
from app.routers.assistant import assistant_rate_limiter
from app.routers.fitness_coach import coach_rate_limiter
from app.routers.library import library_rate_limiter
from app.services.ai_consent import AI_CONSENT_VERSION
from app.services.fitness.resource_limits import reset_fitness_upload_slots


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

EXAMPLE_FAMILY_ID = "00000000-0000-0000-0000-000000000100"
SECOND_FAMILY_ID = "00000000-0000-0000-0000-000000000200"


# ---------------------------------------------------------------------------
# Rate limiter reset (autouse — runs before every test)
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_rate_limiter():
    """Clear the login rate limiter between tests so limits don't leak."""
    rate_limiter.reset()
    sensitive_action_limiter.reset()
    assistant_rate_limiter.reset()
    coach_rate_limiter.reset()
    library_rate_limiter.reset()
    reset_fitness_upload_slots()


# ---------------------------------------------------------------------------
# Database fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def db_path(tmp_path) -> str:
    """Return a path to a temporary SQLite database file."""
    return str(tmp_path / "test.db")


@pytest.fixture
async def initialized_db(db_path: str) -> str:
    """Create the schema in the temp database and point the app at it."""
    await init_db(db_path)
    set_db_path(db_path)

    # Insert default family so all fixtures can reference it
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT OR IGNORE INTO families (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
            (EXAMPLE_FAMILY_ID, "Test Family", "2025-01-01T00:00:00Z", "2025-01-01T00:00:00Z"),
        )
        await db.commit()

    try:
        yield db_path
    finally:
        await close_db_pool()


# ---------------------------------------------------------------------------
# HTTP client fixture
# ---------------------------------------------------------------------------


@pytest.fixture
async def client(initialized_db: str):
    """Async HTTP client wired to the FastAPI app via ASGI transport."""
    transport = httpx.ASGITransport(app=app)
    # HTTPS keeps Secure browser-cookie behavior hermetic regardless of local APP_ENV.
    async with httpx.AsyncClient(transport=transport, base_url="https://test") as c:
        yield c


# ---------------------------------------------------------------------------
# User fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def adult_a_user(initialized_db: str) -> dict:
    """Insert Alex (admin) into the users table and return his details."""
    user = {
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "Alex",
        "email": "demo-person-51@example.invalid",
        "role": "admin",
        "priority": 5,
        "family_id": EXAMPLE_FAMILY_ID,
    }
    password_hash = hash_password("password123")
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO users (id, name, email, password_hash, role, priority, family_id, "
            "ai_consent_version, ai_consent_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                user["id"],
                user["name"],
                user["email"],
                password_hash,
                user["role"],
                user["priority"],
                user["family_id"],
                AI_CONSENT_VERSION,
                "2026-07-13T00:00:00Z",
            ),
        )
        await db.commit()
    return user


@pytest.fixture
async def adult_b_user(initialized_db: str) -> dict:
    """Insert Morgan (user) into the users table and return her details."""
    user = {
        "id": "00000000-0000-0000-0000-000000000002",
        "name": "Morgan",
        "email": "demo-person-52@example.invalid",
        "role": "user",
        "priority": 10,
        "family_id": EXAMPLE_FAMILY_ID,
    }
    password_hash = hash_password("password123")
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO users (id, name, email, password_hash, role, priority, family_id, "
            "ai_consent_version, ai_consent_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                user["id"],
                user["name"],
                user["email"],
                password_hash,
                user["role"],
                user["priority"],
                user["family_id"],
                AI_CONSENT_VERSION,
                "2026-07-13T00:00:00Z",
            ),
        )
        await db.commit()
    return user


# ---------------------------------------------------------------------------
# Token / header fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def adult_a_token(adult_a_user: dict) -> str:
    """Return a valid JWT access token for Alex."""
    return create_access_token(adult_a_user["id"], adult_a_user["family_id"])


@pytest.fixture
def adult_b_token(adult_b_user: dict) -> str:
    """Return a valid JWT access token for Morgan."""
    return create_access_token(adult_b_user["id"], adult_b_user["family_id"])


@pytest.fixture
def adult_a_headers(adult_a_token: str) -> dict:
    """Return Authorization headers for Alex."""
    return {"Authorization": f"Bearer {adult_a_token}"}


@pytest.fixture
def adult_b_headers(adult_b_token: str) -> dict:
    """Return Authorization headers for Morgan."""
    return {"Authorization": f"Bearer {adult_b_token}"}


# ---------------------------------------------------------------------------
# Child fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def child1(initialized_db: str) -> dict:
    """Insert Child 1 into the children table."""
    child = {
        "id": "00000000-0000-0000-0000-000000000011",
        "name": "Child 1",
        "date_of_birth": "2020-02-20",
    }
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, family_id) VALUES (?, ?, ?, ?)",
            (child["id"], child["name"], child["date_of_birth"], EXAMPLE_FAMILY_ID),
        )
        await db.commit()
    return child


@pytest.fixture
async def child2(initialized_db: str) -> dict:
    """Insert Child 2 into the children table."""
    child = {
        "id": "00000000-0000-0000-0000-000000000012",
        "name": "Child 2",
        "date_of_birth": "2021-02-06",
    }
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, family_id) VALUES (?, ?, ?, ?)",
            (child["id"], child["name"], child["date_of_birth"], EXAMPLE_FAMILY_ID),
        )
        await db.commit()
    return child


@pytest.fixture
async def child3(initialized_db: str) -> dict:
    """Insert Child 3 into the children table."""
    child = {
        "id": "00000000-0000-0000-0000-000000000013",
        "name": "Child 3",
        "date_of_birth": "2024-11-10",
    }
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, family_id) VALUES (?, ?, ?, ?)",
            (child["id"], child["name"], child["date_of_birth"], EXAMPLE_FAMILY_ID),
        )
        await db.commit()
    return child


# ---------------------------------------------------------------------------
# Second family fixtures (for multi-tenancy isolation tests)
# ---------------------------------------------------------------------------


@pytest.fixture
async def second_family(initialized_db: str) -> dict:
    """Insert a second family for isolation tests."""
    family = {
        "id": SECOND_FAMILY_ID,
        "name": "Other Family",
    }
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT OR IGNORE INTO families (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
            (family["id"], family["name"], "2025-01-01T00:00:00Z", "2025-01-01T00:00:00Z"),
        )
        await db.commit()
    return family


@pytest.fixture
async def other_family_user(initialized_db: str, second_family: dict) -> dict:
    """Insert a user in the second family and return their details."""
    user = {
        "id": "00000000-0000-0000-0000-000000000099",
        "name": "Other User",
        "email": "demo-person-47@example.invalid",
        "role": "admin",
        "priority": 10,
        "family_id": SECOND_FAMILY_ID,
    }
    password_hash = hash_password("password123")
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO users (id, name, email, password_hash, role, priority, family_id, "
            "ai_consent_version, ai_consent_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                user["id"],
                user["name"],
                user["email"],
                password_hash,
                user["role"],
                user["priority"],
                user["family_id"],
                AI_CONSENT_VERSION,
                "2026-07-13T00:00:00Z",
            ),
        )
        await db.commit()
    return user


@pytest.fixture
def other_family_token(other_family_user: dict) -> str:
    """Return a valid JWT access token for the other-family user."""
    return create_access_token(other_family_user["id"], other_family_user["family_id"])


@pytest.fixture
def other_family_headers(other_family_token: str) -> dict:
    """Return Authorization headers for the other-family user."""
    return {"Authorization": f"Bearer {other_family_token}"}

"""Safely initialise one self-hosted family without default credentials."""

import argparse
import asyncio
import getpass
import os
import re
import uuid

import aiosqlite

from app.auth import hash_password
from app.database import get_db_path, init_db

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
COMMON_PASSWORDS = {"password", "password123", "changeme", "hausklar"}


def validate_password(password: str, identity_parts: list[str]) -> None:
    lowered = password.casefold()
    if len(password) < 12 or lowered in COMMON_PASSWORDS:
        raise ValueError("Password must be at least 12 characters and not commonly used")
    if any(part and part.casefold() in lowered for part in identity_parts):
        raise ValueError("Password must not contain household identity fields")


async def bootstrap(family_name: str, admin_name: str, admin_email: str, password: str) -> tuple[str, str]:
    email = admin_email.strip().casefold()
    if not family_name.strip() or not admin_name.strip() or not EMAIL_RE.fullmatch(email):
        raise ValueError("Family name, admin name, and a valid email are required")
    validate_password(password, [family_name, admin_name, email.split("@", 1)[0]])
    db_path = get_db_path()
    await init_db(db_path)
    family_id, user_id = str(uuid.uuid4()), str(uuid.uuid4())
    db = await aiosqlite.connect(db_path)
    try:
        existing = await (await db.execute("SELECT COUNT(*) FROM families WHERE deleted_at IS NULL")).fetchone()
        if existing and existing[0]:
            raise RuntimeError("Refusing to modify a database that already contains a family")
        await db.execute("BEGIN")
        await db.execute("INSERT INTO families (id, name) VALUES (?, ?)", (family_id, family_name.strip()))
        await db.execute(
            "INSERT INTO users (id, name, email, password_hash, role, priority, family_id) VALUES (?, ?, ?, ?, 'admin', 10, ?)",
            (user_id, admin_name.strip(), email, hash_password(password), family_id),
        )
        await db.commit()
        return family_id, user_id
    except Exception:
        await db.rollback()
        raise
    finally:
        await db.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family-name", required=True)
    parser.add_argument("--admin-name", required=True)
    parser.add_argument("--admin-email", required=True)
    parser.add_argument("--password-env", help="environment variable containing the password")
    args = parser.parse_args()
    password = os.environ.get(args.password_env, "") if args.password_env else getpass.getpass()
    family_id, user_id = asyncio.run(bootstrap(args.family_name, args.admin_name, args.admin_email, password))
    print(f"Created family {family_id} and administrator {user_id} for {args.admin_email.strip().casefold()}")


if __name__ == "__main__":
    main()

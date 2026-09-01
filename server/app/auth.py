import hashlib
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
import jwt
from pwdlib import PasswordHash
from pwdlib.hashers.argon2 import Argon2Hasher
from pwdlib.hashers.bcrypt import BcryptHasher

from app.config import settings
from app.database import database_lease

password_hash = PasswordHash((Argon2Hasher(), BcryptHasher()))
security = HTTPBearer(auto_error=False)
WEB_ACCESS_COOKIE = "hausklar_access"


def hash_password(password: str) -> str:
    return password_hash.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return password_hash.verify(plain_password, hashed_password)


def verify_and_upgrade_password(
    plain_password: str,
    hashed_password: str,
) -> tuple[bool, str | None]:
    """Verify any supported hash and return an Argon2id upgrade when needed."""
    return password_hash.verify_and_update(plain_password, hashed_password)


def create_access_token(
    user_id: str,
    family_id: str | None = None,
    auth_version: int = 0,
) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.access_token_expire_minutes)
    payload = {
        "sub": user_id,
        "exp": expire,
        "type": "access",
        "ver": auth_version,
    }
    if family_id:
        payload["fam"] = family_id
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def create_refresh_token() -> str:
    return str(uuid.uuid4())


def hash_refresh_token(token: str) -> str:
    """Return a stable hash of a refresh token for database storage."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def password_reset_fingerprint(password_hash: str) -> str:
    return hashlib.sha256(password_hash.encode("utf-8")).hexdigest()


def create_password_reset_token(user_id: str, password_hash: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(hours=1)
    payload = {
        "sub": user_id,
        "exp": expire,
        "type": "reset",
        "pwd": password_reset_fingerprint(password_hash),
    }
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def decode_token(token: str) -> dict:
    try:
        payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
        return payload
    except jwt.PyJWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
        )


async def get_authenticated_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
) -> dict:
    token = credentials.credentials if credentials else request.cookies.get(WEB_ACCESS_COOKIE)
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
        )
    payload = decode_token(token)
    if payload.get("type") != "access":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token type",
        )
    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token",
        )

    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT id, name, email, role, priority, avatar_url, family_id, "
            "must_change_password, auth_version, ai_consent_version, "
            "ai_consent_at, ai_consent_revoked_at FROM users "
            "WHERE id = ? AND deleted_at IS NULL",
            (user_id,),
        )
        user = await cursor.fetchone()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
        )
    user_dict = dict(user)
    token_version = payload.get("ver", 0)
    if type(token_version) is not int or token_version != user_dict["auth_version"]:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Session has expired",
        )
    # If JWT has fam claim, validate it matches DB; if missing (old token), use DB value
    jwt_family = payload.get("fam")
    if jwt_family and jwt_family != user_dict.get("family_id"):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Family mismatch",
        )
    return user_dict


async def get_current_user(
    request: Request,
    current_user: dict = Depends(get_authenticated_user),
) -> dict:
    """Return users who have completed the mandatory password-change gate."""
    if bool(current_user.get("must_change_password")):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Password change required",
        )
    request.state.current_user = current_user
    return current_user

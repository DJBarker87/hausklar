import asyncio
import hashlib
import json
import secrets
import string
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status

from app.auth import (
    create_access_token,
    create_password_reset_token,
    create_refresh_token,
    decode_token,
    get_authenticated_user,
    get_current_user,
    hash_refresh_token,
    hash_password,
    password_reset_fingerprint,
    verify_and_upgrade_password,
    verify_password,
    WEB_ACCESS_COOKIE,
)
from app.config import settings
from app.database import database_lease, get_db
from app.middleware.rate_limit import (
    RateLimiter,
    clear_persistent_attempts,
    extract_client_ip,
    reserve_persistent_attempts,
)
from app.models.user import (
    AIConsentRequest,
    AIConsentResponse,
    ChangePasswordRequest,
    ForgotPasswordResponse,
    ForgotPasswordRequest,
    JoinFamilyRequest,
    LoginRequest,
    LoginResponse,
    OnboardingStatus,
    OnboardingUpdate,
    RefreshRequest,
    RegisterFamilyRequest,
    ResetPasswordRequest,
    TokenResponse,
    UserResponse,
    UserProfileUpdate,
)
from app.services.account_deletion import delete_account_data
from app.services.ai_consent import (
    AI_CONSENT_VERSION,
    AI_DISCLOSURE,
    AI_PROVIDER,
    has_current_ai_consent,
)
from app.services.email import send_password_reset_email
from app.services.documents import remove_stored_document
from app.services.fitness.activity_import import remove_fitness_storage_key
from app.services.media import (
    remove_family_avatar_files,
    remove_family_media_cache,
    remove_member_avatar_files,
)
from app.services.record_history import save_history

router = APIRouter()
WEB_REFRESH_COOKIE = "hausklar_refresh"
rate_limiter = RateLimiter()
sensitive_action_limiter = RateLimiter(max_attempts=10, window_seconds=15 * 60)
# Used to keep login timing closer between unknown-user and wrong-password cases.
DUMMY_PASSWORD_HASH = hash_password(secrets.token_urlsafe(32))


async def _store_refresh_token(
    db,
    user_id: str,
    token: str,
    *,
    token_id: str | None = None,
    rotation_family_id: str | None = None,
    parent_token_id: str | None = None,
    commit: bool = True,
) -> tuple[str, str]:
    """Insert a hashed refresh token and return its row and rotation-family IDs."""
    token_hash = hash_refresh_token(token)
    token_id = token_id or str(uuid.uuid4())
    rotation_family_id = rotation_family_id or token_id
    expires_at = (
        datetime.now(timezone.utc) + timedelta(days=settings.refresh_token_expire_days)
    ).isoformat()
    await db.execute(
        """
        INSERT INTO refresh_tokens (
            id, user_id, token, expires_at, rotation_family_id,
            parent_token_id, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            token_id,
            user_id,
            token_hash,
            expires_at,
            rotation_family_id,
            parent_token_id,
            datetime.now(timezone.utc).isoformat(),
        ),
    )
    if commit:
        await db.commit()
    return token_id, rotation_family_id


async def _revoke_refresh_token(db, stored_token: str) -> None:
    """Mark a refresh token as revoked."""
    await db.execute(
        "UPDATE refresh_tokens SET revoked_at = ? WHERE token = ? AND revoked_at IS NULL",
        (datetime.now(timezone.utc).isoformat(), stored_token),
    )
    await db.commit()


async def _find_refresh_token_row(db, presented_token: str):
    """Look up a refresh token by the hash of the presented secret."""
    token_hash = hash_refresh_token(presented_token)
    cursor = await db.execute(
        "SELECT id, user_id, token, expires_at, revoked_at, rotation_family_id, "
        "parent_token_id, replaced_by_id FROM refresh_tokens WHERE token = ?",
        (token_hash,),
    )
    return await cursor.fetchone()


def _rate_limit_keys(ip: str, email: str) -> tuple[str, str]:
    normalized_email = email.strip().lower()
    account_hash = hashlib.sha256(normalized_email.encode()).hexdigest()
    return ip, f"account:{account_hash}"


async def _revoke_all_refresh_tokens_for_user(
    db,
    user_id: str,
    *,
    commit: bool = True,
) -> None:
    """Revoke all active refresh tokens for a user."""
    await db.execute(
        "UPDATE refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL",
        (datetime.now(timezone.utc).isoformat(), user_id),
    )
    if commit:
        await db.commit()


async def _rotate_refresh_token(db, presented_token: str) -> TokenResponse:
    """Rotate once, fencing replay to the compromised device session family."""
    now_value = datetime.now(timezone.utc)
    now = now_value.isoformat()
    replacement_token = create_refresh_token()
    replacement_id = str(uuid.uuid4())

    await db.execute("BEGIN IMMEDIATE")
    try:
        row = await _find_refresh_token_row(db, presented_token)
        if not row:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid refresh token",
            )

        if row["revoked_at"] is not None:
            if row["replaced_by_id"] and row["rotation_family_id"]:
                await db.execute(
                    "UPDATE refresh_tokens SET revoked_at = ? "
                    "WHERE rotation_family_id = ? AND revoked_at IS NULL",
                    (now, row["rotation_family_id"]),
                )
                await db.commit()
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Refresh token reuse detected",
            )

        expires_at = datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        if expires_at < now_value:
            await db.execute(
                "UPDATE refresh_tokens SET revoked_at = ? WHERE id = ?",
                (now, row["id"]),
            )
            await db.commit()
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Refresh token has expired",
            )

        cursor = await db.execute(
            "SELECT id, family_id, auth_version FROM users WHERE id = ? AND deleted_at IS NULL",
            (row["user_id"],),
        )
        user = await cursor.fetchone()
        if not user:
            await db.execute(
                "UPDATE refresh_tokens SET revoked_at = ? "
                "WHERE rotation_family_id = ? AND revoked_at IS NULL",
                (now, row["rotation_family_id"]),
            )
            await db.commit()
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="User not found",
            )

        cursor = await db.execute(
            "UPDATE refresh_tokens SET revoked_at = ?, replaced_by_id = ? "
            "WHERE id = ? AND revoked_at IS NULL",
            (now, replacement_id, row["id"]),
        )
        if cursor.rowcount != 1:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Refresh token has already been used",
            )
        await _store_refresh_token(
            db,
            row["user_id"],
            replacement_token,
            token_id=replacement_id,
            rotation_family_id=row["rotation_family_id"],
            parent_token_id=row["id"],
            commit=False,
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    return TokenResponse(
        access_token=create_access_token(
            user["id"],
            user["family_id"],
            user["auth_version"],
        ),
        refresh_token=replacement_token,
    )


def _set_web_cookies(response: Response, access_token: str, refresh_token: str) -> None:
    secure = settings.app_env.strip().lower() == "production"
    response.set_cookie(
        WEB_ACCESS_COOKIE,
        access_token,
        max_age=settings.access_token_expire_minutes * 60,
        httponly=True,
        secure=secure,
        samesite="strict",
        path="/api",
    )
    response.set_cookie(
        WEB_REFRESH_COOKIE,
        refresh_token,
        max_age=settings.refresh_token_expire_days * 86_400,
        httponly=True,
        secure=secure,
        samesite="strict",
        path="/api/auth/web",
    )


def _clear_web_cookies(response: Response) -> None:
    secure = settings.app_env.strip().lower() == "production"
    response.delete_cookie(
        WEB_ACCESS_COOKIE,
        path="/api",
        httponly=True,
        secure=secure,
        samesite="strict",
    )
    response.delete_cookie(
        WEB_REFRESH_COOKIE,
        path="/api/auth/web",
        httponly=True,
        secure=secure,
        samesite="strict",
    )


@router.post("/login", response_model=LoginResponse)
async def login(body: LoginRequest, request: Request, db=Depends(get_db)):
    """Authenticate with email and password, receive access + refresh tokens + user profile."""
    ip = extract_client_ip(request)
    ip_key, account_key = _rate_limit_keys(ip, body.email)
    await reserve_persistent_attempts(
        db,
        [(f"login:{account_key}", rate_limiter.max_attempts, rate_limiter.window_seconds)],
        detail_prefix="Too many login attempts",
    )
    rate_limiter.ensure_allowed(ip_key)
    rate_limiter.ensure_allowed(account_key)
    rate_limiter.record_failure(ip_key)
    rate_limiter.record_failure(account_key)

    cursor = await db.execute(
        "SELECT id, name, email, password_hash, role, priority, avatar_url, "
        "family_id, must_change_password, auth_version FROM users "
        "WHERE email = ? AND deleted_at IS NULL",
        (body.email,),
    )
    user = await cursor.fetchone()

    password_hash = user["password_hash"] if user else DUMMY_PASSWORD_HASH
    password_valid, upgraded_hash = await asyncio.to_thread(
        verify_and_upgrade_password,
        body.password,
        password_hash,
    )

    if not user or not password_valid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
        )

    user_id = user["id"]
    family_id = user["family_id"]
    refresh_token = create_refresh_token()
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT password_hash, auth_version FROM users WHERE id = ? AND deleted_at IS NULL",
            (user_id,),
        )
        current_credentials = await cursor.fetchone()
        if (
            not current_credentials
            or current_credentials["password_hash"] != user["password_hash"]
            or current_credentials["auth_version"] != user["auth_version"]
        ):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid email or password",
            )
        if upgraded_hash:
            await db.execute(
                "UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?",
                (upgraded_hash, datetime.now(timezone.utc).isoformat(), user_id),
            )
        await _store_refresh_token(
            db,
            user_id,
            refresh_token,
            commit=False,
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    access_token = create_access_token(user_id, family_id, user["auth_version"])
    rate_limiter.record_success(ip_key)
    rate_limiter.record_success(account_key)
    await clear_persistent_attempts(db, f"login:{account_key}")

    return LoginResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        user=UserResponse(
            id=user["id"],
            name=user["name"],
            email=user["email"],
            role=user["role"],
            priority=user["priority"],
            avatar_url=user["avatar_url"],
            family_id=family_id,
            must_change_password=bool(user["must_change_password"]),
        ),
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    body: RefreshRequest,
    current_user: dict = Depends(get_authenticated_user),
    db=Depends(get_db),
):
    """Revoke a refresh token. Requires authentication."""
    row = await _find_refresh_token_row(db, body.refresh_token)

    if not row or row["user_id"] != current_user["id"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid refresh token",
        )

    if row["revoked_at"] is not None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Refresh token already revoked",
        )

    await _revoke_refresh_token(db, row["token"])


@router.post("/refresh", response_model=TokenResponse)
async def refresh(body: RefreshRequest, db=Depends(get_db)):
    """Exchange a valid refresh token for new access + refresh tokens (rotation)."""
    return await _rotate_refresh_token(db, body.refresh_token)


@router.post("/web/login", response_model=UserResponse)
async def web_login(
    body: LoginRequest,
    request: Request,
    response: Response,
    db=Depends(get_db),
):
    """Create a same-origin browser session without exposing tokens to JavaScript."""
    result = await login(body=body, request=request, db=db)
    _set_web_cookies(response, result.access_token, result.refresh_token)
    return result.user


@router.post("/web/register-family", response_model=UserResponse)
async def web_register_family(
    body: RegisterFamilyRequest,
    request: Request,
    response: Response,
    db=Depends(get_db),
):
    """Create a household browser session without exposing credentials to JavaScript."""
    result = await register_family(body=body, request=request, db=db)
    _set_web_cookies(response, result.access_token, result.refresh_token)
    return result.user


@router.post("/web/join-family", response_model=UserResponse)
async def web_join_family(
    body: JoinFamilyRequest,
    request: Request,
    response: Response,
    db=Depends(get_db),
):
    """Join a household and create a token-hidden browser session."""
    result = await join_family(body=body, request=request, db=db)
    _set_web_cookies(response, result.access_token, result.refresh_token)
    return result.user


@router.get("/web/session", response_model=UserResponse)
async def web_session(current_user: dict = Depends(get_authenticated_user)):
    """Return the active browser user when the HttpOnly access cookie is valid."""
    return UserResponse(**current_user)


@router.post("/web/refresh", status_code=status.HTTP_204_NO_CONTENT)
async def web_refresh(request: Request, response: Response, db=Depends(get_db)):
    """Rotate the browser refresh token and replace both HttpOnly cookies."""
    refresh_token = request.cookies.get(WEB_REFRESH_COOKIE)
    if not refresh_token:
        raise HTTPException(status_code=401, detail="Browser session has expired")
    result = await refresh(body=RefreshRequest(refresh_token=refresh_token), db=db)
    _set_web_cookies(response, result.access_token, result.refresh_token)


@router.post("/web/logout", status_code=status.HTTP_204_NO_CONTENT)
async def web_logout(
    request: Request,
    response: Response,
    db=Depends(get_db),
):
    """Revoke the presented browser session and always clear both cookies."""
    refresh_token = request.cookies.get(WEB_REFRESH_COOKIE)
    if refresh_token:
        row = await _find_refresh_token_row(db, refresh_token)
        if row and row["revoked_at"] is None:
            await _revoke_refresh_token(db, row["token"])
    _clear_web_cookies(response)


@router.post("/forgot-password", response_model=ForgotPasswordResponse)
async def forgot_password(
    body: ForgotPasswordRequest,
    request: Request,
):
    """Generate a password reset token.

    The token is never returned in API responses.
    """
    ip = extract_client_ip(request)
    _, account_key = _rate_limit_keys(ip, body.email)
    async with database_lease() as db:
        await reserve_persistent_attempts(
            db,
            [
                (
                    f"forgot:{ip}",
                    sensitive_action_limiter.max_attempts,
                    sensitive_action_limiter.window_seconds,
                ),
                (
                    f"forgot:{account_key}",
                    sensitive_action_limiter.max_attempts,
                    sensitive_action_limiter.window_seconds,
                ),
            ],
            detail_prefix="Too many password reset requests",
        )
        cursor = await db.execute(
            "SELECT id, password_hash FROM users WHERE email = ? AND deleted_at IS NULL",
            (body.email,),
        )
        user = await cursor.fetchone()
        reset_details = (user["id"], user["password_hash"]) if user else None

    if not reset_details:
        # Return a generic message to avoid leaking whether the email exists
        return ForgotPasswordResponse(
            message="If that email is registered, reset instructions have been sent."
        )

    reset_token = create_password_reset_token(*reset_details)
    send_result = await send_password_reset_email(body.email, reset_token)
    if not send_result["success"]:
        # Keep response generic to avoid account enumeration.
        print(f"[auth] Password reset email send failed: {send_result['error']}")

    return ForgotPasswordResponse(
        message="If that email is registered, reset instructions have been sent."
    )


@router.post("/reset-password")
async def reset_password(
    body: ResetPasswordRequest,
    request: Request,
    response: Response,
    db=Depends(get_db),
):
    """Reset a user's password using a valid reset token."""
    ip = extract_client_ip(request)
    await reserve_persistent_attempts(
        db,
        [
            (
                f"reset:{ip}",
                sensitive_action_limiter.max_attempts,
                sensitive_action_limiter.window_seconds,
            )
        ],
        detail_prefix="Too many password reset attempts",
    )
    payload = decode_token(body.token)

    if payload.get("type") != "reset":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid token type",
        )

    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid reset token",
        )

    cursor = await db.execute(
        "SELECT id, password_hash, auth_version FROM users WHERE id = ? AND deleted_at IS NULL",
        (user_id,),
    )
    user = await cursor.fetchone()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )
    token_fingerprint = payload.get("pwd")
    if not token_fingerprint or not secrets.compare_digest(
        token_fingerprint,
        password_reset_fingerprint(user["password_hash"]),
    ):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="This password reset link has already been used",
        )

    new_hash = await asyncio.to_thread(hash_password, body.new_password)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "UPDATE users SET password_hash = ?, must_change_password = 0, "
            "auth_version = auth_version + 1, updated_at = ? "
            "WHERE id = ? AND password_hash = ? AND auth_version = ? "
            "AND deleted_at IS NULL",
            (new_hash, now, user_id, user["password_hash"], user["auth_version"]),
        )
        if cursor.rowcount != 1:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="This password reset link has already been used",
            )
        await _revoke_all_refresh_tokens_for_user(db, user_id, commit=False)
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    _clear_web_cookies(response)

    return {"message": "Password has been reset successfully."}


async def _change_password_and_rotate(
    body: ChangePasswordRequest,
    current_user: dict,
    db,
) -> LoginResponse:
    """Change a password, revoke existing refresh sessions, and issue a replacement."""
    cursor = await db.execute(
        "SELECT password_hash, auth_version FROM users WHERE id = ? AND deleted_at IS NULL",
        (current_user["id"],),
    )
    row = await cursor.fetchone()
    password_valid = row and await asyncio.to_thread(
        verify_password,
        body.current_password,
        row["password_hash"],
    )
    if not password_valid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Current password is incorrect",
        )
    if row["auth_version"] != current_user["auth_version"]:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Session has expired",
        )
    if body.new_password == body.current_password:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="New password must be different from the current password",
        )

    new_hash = await asyncio.to_thread(hash_password, body.new_password)
    now = datetime.now(timezone.utc).isoformat()
    refresh_token = create_refresh_token()
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "UPDATE users SET password_hash = ?, must_change_password = 0, "
            "auth_version = auth_version + 1, updated_at = ? "
            "WHERE id = ? AND password_hash = ? AND auth_version = ? "
            "AND deleted_at IS NULL",
            (
                new_hash,
                now,
                current_user["id"],
                row["password_hash"],
                row["auth_version"],
            ),
        )
        if cursor.rowcount != 1:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Session has expired",
            )
        await _revoke_all_refresh_tokens_for_user(
            db,
            current_user["id"],
            commit=False,
        )
        await _store_refresh_token(
            db,
            current_user["id"],
            refresh_token,
            commit=False,
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    new_auth_version = row["auth_version"] + 1
    current_user["must_change_password"] = 0
    current_user["auth_version"] = new_auth_version
    access_token = create_access_token(
        current_user["id"],
        current_user.get("family_id"),
        new_auth_version,
    )
    return LoginResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        user=UserResponse(**current_user),
    )


@router.post("/change-password", response_model=LoginResponse)
async def change_password(
    body: ChangePasswordRequest,
    current_user: dict = Depends(get_authenticated_user),
    db=Depends(get_db),
):
    """Change a native-client password and return a fresh credential pair."""
    return await _change_password_and_rotate(body, current_user, db)


@router.post("/web/change-password", response_model=UserResponse)
async def web_change_password(
    body: ChangePasswordRequest,
    response: Response,
    current_user: dict = Depends(get_authenticated_user),
    db=Depends(get_db),
):
    """Change a browser password and rotate both HttpOnly session cookies."""
    result = await _change_password_and_rotate(body, current_user, db)
    _set_web_cookies(response, result.access_token, result.refresh_token)
    return result.user


@router.get("/me", response_model=UserResponse)
async def me(current_user: dict = Depends(get_authenticated_user)):
    """Return the currently authenticated user's profile."""
    return UserResponse(**current_user)


@router.patch("/me", response_model=UserResponse)
async def update_me(
    body: UserProfileUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update a harmless display field without changing login identity or permissions."""
    if body.name == current_user["name"]:
        return UserResponse(**current_user)
    await save_history(
        db,
        "users",
        current_user["id"],
        current_user["id"],
        family_id=current_user["family_id"],
        excluded_fields={"password_hash"},
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE users SET name = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (body.name, now, current_user["id"], current_user["family_id"]),
    )
    await db.commit()
    current_user["name"] = body.name
    return UserResponse(**current_user)


async def _onboarding_status(db, current_user: dict) -> OnboardingStatus:
    family_id = current_user["family_id"]
    family = await (
        await db.execute(
            "SELECT name FROM families WHERE id = ? AND deleted_at IS NULL",
            (family_id,),
        )
    ).fetchone()
    adults = await (
        await db.execute(
            "SELECT COUNT(*) AS count FROM users "
            "WHERE family_id = ? AND deleted_at IS NULL",
            (family_id,),
        )
    ).fetchone()
    children = await (
        await db.execute(
            "SELECT COUNT(*) AS count FROM children "
            "WHERE family_id = ? AND deleted_at IS NULL",
            (family_id,),
        )
    ).fetchone()
    commitments = await (
        await db.execute(
            "SELECT COUNT(*) AS count FROM calendar_events "
            "WHERE family_id = ? AND deleted_at IS NULL",
            (family_id,),
        )
    ).fetchone()
    reminder = await (
        await db.execute(
            "SELECT 1 FROM reminder_preferences WHERE user_id = ? AND family_id = ? "
            "AND deleted_at IS NULL AND updated_at != created_at LIMIT 1",
            (current_user["id"], family_id),
        )
    ).fetchone()
    setting_key = f"onboarding:{current_user['id']}"
    stored = await (
        await db.execute(
            "SELECT setting_value FROM family_settings "
            "WHERE family_id = ? AND setting_key = ?",
            (family_id, setting_key),
        )
    ).fetchone()
    try:
        preferences = json.loads(stored["setting_value"]) if stored else {}
    except (json.JSONDecodeError, TypeError):
        preferences = {}
    adult_count = int(adults["count"])
    child_count = int(children["count"])
    commitment_count = int(commitments["count"])
    dismissed = bool(preferences.get("dismissed", False))
    completed = bool(preferences.get("completed", False))
    selected_modules = preferences.get("selected_modules", [])
    # Pydantic validates any legacy/corrupt module values out of the response.
    valid_modules = {
        "children", "medicine_sleep", "dog", "home", "fitness", "finance"
    }
    selected_modules = [item for item in selected_modules if item in valid_modules]
    needs_core_setup = adult_count < 2 or commitment_count < 1
    return OnboardingStatus(
        family_name=family["name"] if family else "Your household",
        people_count=adult_count + child_count,
        adult_count=adult_count,
        child_count=child_count,
        calendar_commitment_count=commitment_count,
        reminders_configured=bool(reminder),
        selected_modules=selected_modules,
        dismissed=dismissed,
        completed=completed,
        should_show=not dismissed and not completed and needs_core_setup,
        first_success=commitment_count > 0,
    )


@router.get("/onboarding", response_model=OnboardingStatus)
async def get_onboarding(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return a small, derived setup state without loading optional integrations."""
    return await _onboarding_status(db, current_user)


@router.patch("/onboarding", response_model=OnboardingStatus)
async def update_onboarding(
    body: OnboardingUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    key = f"onboarding:{current_user['id']}"
    existing = await (
        await db.execute(
            "SELECT setting_value FROM family_settings "
            "WHERE family_id = ? AND setting_key = ?",
            (current_user["family_id"], key),
        )
    ).fetchone()
    try:
        values = json.loads(existing["setting_value"]) if existing else {}
    except (json.JSONDecodeError, TypeError):
        values = {}
    for field, value in body.model_dump(exclude_none=True).items():
        values[field] = value
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "INSERT OR REPLACE INTO family_settings "
        "(family_id, setting_key, setting_value, updated_at, updated_by) "
        "VALUES (?, ?, ?, ?, ?)",
        (
            current_user["family_id"], key,
            json.dumps(values, separators=(",", ":")), now, current_user["id"],
        ),
    )
    await db.commit()
    return await _onboarding_status(db, current_user)


@router.get("/capabilities")
async def auth_capabilities():
    """Expose non-sensitive sign-up capabilities so clients do not advertise disabled flows."""
    return {"public_registration": settings.allow_public_registration}


def _ai_consent_response(current_user: dict) -> AIConsentResponse:
    return AIConsentResponse(
        consented=has_current_ai_consent(current_user),
        version=AI_CONSENT_VERSION,
        consented_at=(
            current_user.get("ai_consent_at") if has_current_ai_consent(current_user) else None
        ),
        provider=AI_PROVIDER,
        disclosure=AI_DISCLOSURE,
        background_processing=False,
    )


@router.get("/ai-consent", response_model=AIConsentResponse)
async def get_ai_consent(current_user: dict = Depends(get_current_user)):
    """Return the current user's versioned external-AI permission."""
    return _ai_consent_response(current_user)


@router.put("/ai-consent", response_model=AIConsentResponse)
async def grant_ai_consent(
    body: AIConsentRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Record an explicit acceptance of the exact disclosure currently shown."""
    if body.version != AI_CONSENT_VERSION:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="The AI privacy notice has changed. Review the latest notice before continuing.",
        )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE users SET ai_consent_version = ?, ai_consent_at = ?, "
        "ai_consent_revoked_at = NULL, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
        (AI_CONSENT_VERSION, now, now, current_user["id"]),
    )
    await db.commit()
    current_user.update(
        ai_consent_version=AI_CONSENT_VERSION,
        ai_consent_at=now,
        ai_consent_revoked_at=None,
    )
    return _ai_consent_response(current_user)


@router.delete("/ai-consent", response_model=AIConsentResponse)
async def revoke_ai_consent(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Withdraw permission immediately; all external-AI routes enforce this server-side."""
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE users SET ai_consent_revoked_at = ?, updated_at = ? "
        "WHERE id = ? AND deleted_at IS NULL",
        (now, now, current_user["id"]),
    )
    await db.commit()
    current_user["ai_consent_revoked_at"] = now
    return _ai_consent_response(current_user)


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
async def delete_me(
    response: Response,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Delete an account and associated data, preserving shared family data for active members."""
    user_id = current_user["id"]
    family_id = current_user.get("family_id")
    result = await delete_account_data(db, user_id=user_id, family_id=family_id)
    for storage_key in result.storage_keys:
        await remove_stored_document(storage_key)
    for deletion_id, storage_key, storage_class in result.fitness_deletion_queue:
        try:
            await remove_fitness_storage_key(storage_key, storage_class)
        except (OSError, ValueError):
            # The durable queue survives the committed account deletion and a
            # scheduler retry removes the private file without resurrecting data.
            continue
        await db.execute(
            "DELETE FROM health_deferred_file_deletions WHERE id = ?",
            (deletion_id,),
        )
    await db.commit()
    if family_id and result.final_family:
        await remove_family_avatar_files(family_id)
        await remove_family_media_cache(family_id)
    elif family_id:
        await remove_member_avatar_files(family_id, user_id)
    _clear_web_cookies(response)


@router.post("/register-family", response_model=LoginResponse)
async def register_family(
    body: RegisterFamilyRequest,
    request: Request,
    db=Depends(get_db),
):
    """Create a new family and admin user. Returns tokens + user profile."""
    if not settings.allow_public_registration:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Public family registration is disabled",
        )
    ip = extract_client_ip(request)
    sensitive_action_limiter.ensure_allowed(
        f"register:{ip}",
        detail_prefix="Too many registration attempts",
    )
    sensitive_action_limiter.record_failure(f"register:{ip}")
    # Check email uniqueness
    cursor = await db.execute(
        "SELECT id FROM users WHERE email = ? AND deleted_at IS NULL",
        (body.email,),
    )
    if await cursor.fetchone():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email already registered",
        )

    now = datetime.now(timezone.utc).isoformat()
    family_id = str(uuid.uuid4())
    user_id = str(uuid.uuid4())

    # Create family
    await db.execute(
        "INSERT INTO families (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
        (family_id, body.family_name, now, now),
    )

    # Create admin user
    password_hash = await asyncio.to_thread(hash_password, body.password)
    await db.execute(
        """
        INSERT INTO users (id, name, email, password_hash, role, priority, family_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (user_id, body.user_name, body.email, password_hash, "admin", 10, family_id, now, now),
    )
    await db.commit()

    access_token = create_access_token(user_id, family_id, 0)
    refresh_token = create_refresh_token()
    await _store_refresh_token(db, user_id, refresh_token)

    return LoginResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        user=UserResponse(
            id=user_id,
            name=body.user_name,
            email=body.email,
            role="admin",
            priority=10,
            family_id=family_id,
        ),
    )


@router.post("/join-family", response_model=LoginResponse)
async def join_family(
    body: JoinFamilyRequest,
    request: Request,
    db=Depends(get_db),
):
    """Join an existing family via invite code. Returns tokens + user profile."""
    ip = extract_client_ip(request)
    invite_key = hashlib.sha256(body.invite_code.encode("utf-8")).hexdigest()
    await reserve_persistent_attempts(
        db,
        [
            (
                f"join:{ip}",
                sensitive_action_limiter.max_attempts,
                sensitive_action_limiter.window_seconds,
            ),
            (
                f"join-code:{invite_key}",
                sensitive_action_limiter.max_attempts,
                sensitive_action_limiter.window_seconds,
            ),
        ],
        detail_prefix="Too many family join attempts",
    )
    preflight_now = datetime.now(timezone.utc).isoformat()
    # This read avoids expensive password hashing for obviously invalid codes;
    # the authoritative consume happens under an IMMEDIATE transaction below.
    cursor = await db.execute(
        "SELECT id, name FROM families WHERE invite_code = ? "
        "AND invite_expires_at > ? AND deleted_at IS NULL",
        (body.invite_code, preflight_now),
    )
    family = await cursor.fetchone()
    if not family:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Invalid invite code",
        )

    # Check email uniqueness
    cursor = await db.execute(
        "SELECT id FROM users WHERE email = ? AND deleted_at IS NULL",
        (body.email,),
    )
    if await cursor.fetchone():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email already registered",
        )

    family_id = family["id"]
    user_id = str(uuid.uuid4())
    password_hash = await asyncio.to_thread(hash_password, body.password)
    refresh_token = create_refresh_token()
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "UPDATE families SET invite_code = NULL, invite_expires_at = NULL, "
            "updated_at = ? WHERE id = ? AND invite_code = ? "
            "AND invite_expires_at > ? AND deleted_at IS NULL",
            (now, family_id, body.invite_code, now),
        )
        if cursor.rowcount != 1:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Invalid invite code",
            )
        cursor = await db.execute(
            "SELECT id FROM users WHERE email = ? AND deleted_at IS NULL",
            (body.email,),
        )
        if await cursor.fetchone():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Email already registered",
            )
        await db.execute(
            """
            INSERT INTO users (
                id, name, email, password_hash, role, priority,
                family_id, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                user_id,
                body.user_name,
                body.email,
                password_hash,
                "user",
                5,
                family_id,
                now,
                now,
            ),
        )
        await _store_refresh_token(
            db,
            user_id,
            refresh_token,
            commit=False,
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    access_token = create_access_token(user_id, family_id, 0)

    return LoginResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        user=UserResponse(
            id=user_id,
            name=body.user_name,
            email=body.email,
            role="user",
            priority=5,
            family_id=family_id,
        ),
    )


@router.post("/invite")
async def create_invite(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Generate an 8-character invite code for the current user's family. Admin only."""
    if current_user.get("role") != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only admins can create invite codes",
        )

    family_id = current_user["family_id"]
    if not family_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="User has no family",
        )

    # Generate random 8-char alphanumeric code
    alphabet = string.ascii_uppercase + string.digits
    invite_code = "".join(secrets.choice(alphabet) for _ in range(8))

    now_value = datetime.now(timezone.utc)
    now = now_value.isoformat()
    expires_at = (now_value + timedelta(hours=24)).isoformat()
    await db.execute(
        "UPDATE families SET invite_code = ?, invite_expires_at = ?, updated_at = ? WHERE id = ?",
        (invite_code, expires_at, now, family_id),
    )
    await db.commit()

    join_url = f"{settings.web_app_url.rstrip('/')}/#join={quote(invite_code)}"
    return {
        "invite_code": invite_code,
        "expires_at": expires_at,
        "join_url": join_url,
    }

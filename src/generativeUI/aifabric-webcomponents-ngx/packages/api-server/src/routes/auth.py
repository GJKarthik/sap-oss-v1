"""
Authentication routes for SAP AI Fabric Console.
JWT-based login with bcrypt user validation, token refresh, and server-side logout
via persistent JTI revocation storage.
"""

from collections import deque
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional

import bcrypt as _bcrypt
from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import JWTError, jwt
from pydantic import BaseModel
from prometheus_client import Counter
import structlog

from ..config import settings
from ..redis_client import is_token_revoked, revoke_token
from ..store import StoreBackend, get_store

router = APIRouter()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login", auto_error=False)
logger = structlog.get_logger()
audit_logger = structlog.get_logger("audit")

AUTH_EVENTS_TOTAL = Counter(
    "sap_aifabric_auth_events_total",
    "Authentication lifecycle events by operation and result.",
    ["operation", "result"],
)
ADMIN_ACTIONS_TOTAL = Counter(
    "sap_aifabric_admin_actions_total",
    "Admin mutation actions recorded by resource, action, and result.",
    ["resource", "action", "result"],
)
_AUTH_FAILURE_TIMESTAMPS: deque[float] = deque(maxlen=2048)


def _verify_password(plain: str, hashed: str) -> bool:
    return _bcrypt.checkpw(plain.encode(), hashed.encode())


# ---------------------------------------------------------------------------
# Pydantic Models
# ---------------------------------------------------------------------------

class TokenResponse(BaseModel):
    access_token: str
    refresh_token: Optional[str] = None
    token_type: str = "bearer"
    expires_in: int


class TokenRefreshRequest(BaseModel):
    refresh_token: Optional[str] = None


class LogoutRequest(BaseModel):
    refresh_token: Optional[str] = None


class UserInfo(BaseModel):
    username: str
    role: str = "viewer"
    email: Optional[str] = None


# ---------------------------------------------------------------------------
# Token Helpers
# ---------------------------------------------------------------------------

def _make_jti() -> str:
    return str(uuid.uuid4())


def _counter_value(counter: Counter, *label_values: str) -> float:
    return float(counter.labels(*label_values)._value.get())


def _record_auth_event(operation: str, result: str) -> None:
    AUTH_EVENTS_TOTAL.labels(operation, result).inc()
    if result != "success":
        _AUTH_FAILURE_TIMESTAMPS.append(time.time())


def recent_auth_failures(window_seconds: int) -> int:
    cutoff = time.time() - max(window_seconds, 1)
    while _AUTH_FAILURE_TIMESTAMPS and _AUTH_FAILURE_TIMESTAMPS[0] < cutoff:
        _AUTH_FAILURE_TIMESTAMPS.popleft()
    return len(_AUTH_FAILURE_TIMESTAMPS)


def auth_metrics_snapshot(window_seconds: int) -> dict:
    operations = ("login", "refresh", "logout")
    successes_total = sum(_counter_value(AUTH_EVENTS_TOTAL, operation, "success") for operation in operations)
    failures_total = sum(_counter_value(AUTH_EVENTS_TOTAL, operation, "failure") for operation in operations)
    return {
        "successes_total": successes_total,
        "failures_total": failures_total,
        "recent_failures": recent_auth_failures(window_seconds),
    }


def admin_action_metrics_snapshot() -> dict:
    total = 0.0
    failures = 0.0
    for resource in ("models", "deployments", "datasources", "governance_rules", "vector_stores", "lineage"):
        for action in ("create", "delete", "update_status", "toggle", "test_connection", "index", "add_documents"):
            total += _counter_value(ADMIN_ACTIONS_TOTAL, resource, action, "success")
            total += _counter_value(ADMIN_ACTIONS_TOTAL, resource, action, "failure")
            failures += _counter_value(ADMIN_ACTIONS_TOTAL, resource, action, "failure")
    return {
        "total_actions": total,
        "failed_actions": failures,
    }


def log_admin_action(
    *,
    actor: UserInfo,
    resource: str,
    action: str,
    result: str,
    target: Optional[str] = None,
    reason: Optional[str] = None,
    **fields: object,
) -> None:
    ADMIN_ACTIONS_TOTAL.labels(resource, action, result).inc()
    audit_logger.info(
        "admin_action",
        actor_username=actor.username,
        actor_role=actor.role,
        resource=resource,
        action=action,
        result=result,
        target=target,
        reason=reason,
        **fields,
    )


def _build_token_data(user: dict, fallback_username: Optional[str] = None) -> dict:
    username = user.get("username") or fallback_username
    return {
        "sub": username,
        "role": user.get("role", "viewer"),
        "email": user.get("email"),
    }


def _build_user_info(user: dict, fallback_username: Optional[str] = None) -> UserInfo:
    return UserInfo(
        username=user.get("username") or fallback_username or "",
        role=user.get("role", "viewer"),
        email=user.get("email"),
    )


def _get_active_user(
    store: StoreBackend,
    username: Optional[str],
    credentials_exception: HTTPException,
) -> dict:
    if username is None:
        raise credentials_exception

    user = store.get_record("users", username)
    if user is None or not user.get("is_active", True):
        raise credentials_exception

    return user


async def _revoke_encoded_token(token: Optional[str], expected_type: str) -> None:
    if not token:
        return

    try:
        payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
    except JWTError:
        return

    if payload.get("type") != expected_type:
        return

    jti: Optional[str] = payload.get("jti")
    exp: Optional[int] = payload.get("exp")
    if not jti or not exp:
        return

    ttl = max(int(exp - datetime.now(timezone.utc).timestamp()), 1)
    await revoke_token(jti, ttl)


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (
        expires_delta or timedelta(minutes=settings.jwt_access_token_expire_minutes)
    )
    to_encode.update({"exp": expire, "type": "access", "jti": _make_jti()})
    return jwt.encode(to_encode, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def create_refresh_token(data: dict) -> str:
    expire = datetime.now(timezone.utc) + timedelta(days=settings.jwt_refresh_token_expire_days)
    to_encode = {**data, "exp": expire, "type": "refresh", "jti": _make_jti()}
    return jwt.encode(to_encode, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def _refresh_cookie_max_age_seconds() -> int:
    return settings.jwt_refresh_token_expire_days * 86400


def _set_refresh_cookie(response: Response, refresh_token: str) -> None:
    response.set_cookie(
        key=settings.auth_refresh_cookie_name,
        value=refresh_token,
        max_age=_refresh_cookie_max_age_seconds(),
        httponly=True,
        secure=bool(settings.auth_refresh_cookie_secure),
        samesite=settings.auth_refresh_cookie_samesite,
        path=settings.auth_refresh_cookie_path,
    )


def _clear_refresh_cookie(response: Response) -> None:
    response.delete_cookie(
        key=settings.auth_refresh_cookie_name,
        path=settings.auth_refresh_cookie_path,
        secure=bool(settings.auth_refresh_cookie_secure),
        httponly=True,
        samesite=settings.auth_refresh_cookie_samesite,
    )


def _resolve_refresh_token(request: Request, token_from_body: Optional[str]) -> Optional[str]:
    if token_from_body:
        return token_from_body
    return request.cookies.get(settings.auth_refresh_cookie_name)


async def get_current_user(
    token: Optional[str] = Depends(oauth2_scheme),
    store: StoreBackend = Depends(get_store),
) -> UserInfo:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    if token is None:
        raise credentials_exception

    try:
        payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
        username: Optional[str] = payload.get("sub")
        jti: Optional[str] = payload.get("jti")
        if username is None or payload.get("type") != "access":
            raise credentials_exception
        if jti and await is_token_revoked(jti):
            raise credentials_exception
        user = _get_active_user(store, username, credentials_exception)
        return _build_user_info(user, username)
    except JWTError:
        raise credentials_exception


def require_roles(*roles: str) -> Callable[..., UserInfo]:
    """Return a dependency that restricts access to a set of roles."""
    allowed_roles = set(roles)

    async def dependency(current_user: UserInfo = Depends(get_current_user)) -> UserInfo:
        if current_user.role not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Requires one of the following roles: {', '.join(sorted(allowed_roles))}",
            )
        return current_user

    return dependency


require_admin = require_roles("admin")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.post("/login", response_model=TokenResponse)
async def login(
    response: Response,
    form_data: OAuth2PasswordRequestForm = Depends(),
    store: StoreBackend = Depends(get_store),
):
    """Authenticate against the persistent user store and return signed JWT tokens."""
    invalid_exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid username or password",
    )

    if not form_data.username or not form_data.password:
        _record_auth_event("login", "failure")
        raise invalid_exc

    user = store.get_record("users", form_data.username)
    if user is None or not user.get("is_active", True):
        _record_auth_event("login", "failure")
        logger.warning("Authentication failed", username=form_data.username, reason="user_missing_or_inactive")
        raise invalid_exc
    if not _verify_password(form_data.password, user["hashed_password"]):
        _record_auth_event("login", "failure")
        logger.warning("Authentication failed", username=form_data.username, reason="invalid_password")
        raise invalid_exc

    token_data = _build_token_data(user, form_data.username)
    access_token = create_access_token(token_data)
    refresh_token = create_refresh_token(token_data)
    _set_refresh_cookie(response, refresh_token)
    _record_auth_event("login", "success")

    return TokenResponse(
        access_token=access_token,
        expires_in=settings.jwt_access_token_expire_minutes * 60,
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh_token(
    request: Request,
    response: Response,
    body: Optional[TokenRefreshRequest] = None,
    store: StoreBackend = Depends(get_store),
):
    """Refresh an expired access token. Rotates the refresh token."""
    invalid_exc = HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")
    encoded_refresh_token = _resolve_refresh_token(request, body.refresh_token if body else None)
    if not encoded_refresh_token:
        _record_auth_event("refresh", "failure")
        raise invalid_exc

    try:
        payload = jwt.decode(
            encoded_refresh_token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm]
        )
        if payload.get("type") != "refresh":
            _record_auth_event("refresh", "failure")
            raise invalid_exc

        username: Optional[str] = payload.get("sub")
        jti: Optional[str] = payload.get("jti")
        if jti and await is_token_revoked(jti):
            _record_auth_event("refresh", "failure")
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token has been revoked")

        user = _get_active_user(store, username, invalid_exc)

        # Revoke the old refresh token immediately (rotation)
        if jti:
            exp: Optional[int] = payload.get("exp")
            ttl = (
                max(int(exp - datetime.now(timezone.utc).timestamp()), 1)
                if exp
                else settings.jwt_refresh_token_expire_days * 86400
            )
            await revoke_token(jti, ttl)

        token_data = _build_token_data(user, username)
        rotated_refresh_token = create_refresh_token(token_data)
        _set_refresh_cookie(response, rotated_refresh_token)
        _record_auth_event("refresh", "success")
        return TokenResponse(
            access_token=create_access_token(token_data),
            expires_in=settings.jwt_access_token_expire_minutes * 60,
        )
    except JWTError:
        _record_auth_event("refresh", "failure")
        raise invalid_exc


@router.post("/logout")
async def logout(
    request: Request,
    response: Response,
    body: Optional[LogoutRequest] = None,
    token: Optional[str] = Depends(oauth2_scheme),
):
    """Revoke the current access token and optional refresh token server-side."""
    await _revoke_encoded_token(token, "access")
    await _revoke_encoded_token(_resolve_refresh_token(request, body.refresh_token if body else None), "refresh")
    _clear_refresh_cookie(response)
    _record_auth_event("logout", "success")
    return {"status": "logged_out"}


@router.get("/me", response_model=UserInfo)
async def get_me(current_user: UserInfo = Depends(get_current_user)):
    """Return current user information."""
    return current_user

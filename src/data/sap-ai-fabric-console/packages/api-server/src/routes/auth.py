"""
Authentication routes for SAP AI Fabric Console.
JWT-based login with bcrypt user validation, token refresh, and server-side logout
via persistent JTI revocation storage.
"""

import uuid
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional

import bcrypt as _bcrypt
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import JWTError, jwt
from pydantic import BaseModel

from ..config import settings
from ..redis_client import is_token_revoked, revoke_token
from ..store import StoreBackend, get_store

router = APIRouter()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login", auto_error=False)


def _verify_password(plain: str, hashed: str) -> bool:
    return _bcrypt.checkpw(plain.encode(), hashed.encode())


# ---------------------------------------------------------------------------
# Pydantic Models
# ---------------------------------------------------------------------------

class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class TokenRefreshRequest(BaseModel):
    refresh_token: str


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
    form_data: OAuth2PasswordRequestForm = Depends(),
    store: StoreBackend = Depends(get_store),
):
    """Authenticate against the persistent user store and return signed JWT tokens."""
    invalid_exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid username or password",
    )

    if not form_data.username or not form_data.password:
        raise invalid_exc

    user = store.get_record("users", form_data.username)
    if user is None or not user.get("is_active", True):
        raise invalid_exc
    if not _verify_password(form_data.password, user["hashed_password"]):
        raise invalid_exc

    token_data = _build_token_data(user, form_data.username)
    access_token = create_access_token(token_data)
    refresh_token = create_refresh_token(token_data)

    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=settings.jwt_access_token_expire_minutes * 60,
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh_token(
    body: TokenRefreshRequest,
    store: StoreBackend = Depends(get_store),
):
    """Refresh an expired access token. Rotates the refresh token."""
    invalid_exc = HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")
    try:
        payload = jwt.decode(
            body.refresh_token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm]
        )
        if payload.get("type") != "refresh":
            raise invalid_exc

        username: Optional[str] = payload.get("sub")
        jti: Optional[str] = payload.get("jti")
        if jti and await is_token_revoked(jti):
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
        return TokenResponse(
            access_token=create_access_token(token_data),
            refresh_token=create_refresh_token(token_data),
            expires_in=settings.jwt_access_token_expire_minutes * 60,
        )
    except JWTError:
        raise invalid_exc


@router.post("/logout")
async def logout(
    body: Optional[LogoutRequest] = None,
    token: Optional[str] = Depends(oauth2_scheme),
):
    """Revoke the current access token and optional refresh token server-side."""
    await _revoke_encoded_token(token, "access")
    await _revoke_encoded_token(body.refresh_token if body else None, "refresh")
    return {"status": "logged_out"}


@router.get("/me", response_model=UserInfo)
async def get_me(current_user: UserInfo = Depends(get_current_user)):
    """Return current user information."""
    return current_user

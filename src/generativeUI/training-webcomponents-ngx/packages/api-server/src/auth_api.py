"""
Local user authentication — registration, login, and token-based identity.

Passwords are hashed with SHA-256 + per-user salt (no external bcrypt dep).
JWTs are signed with HS256 using a securely configured ``AUTH_JWT_SECRET``.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import time
import re
from typing import Any

from fastapi import APIRouter, HTTPException, Request, status
from pydantic import BaseModel, Field, field_validator

from .auth_tokens import decode_local_jwt, encode_local_jwt, get_local_jwt_secret
from .identity import resolve_request_identity
from .store import get_store

router = APIRouter()

TOKEN_EXPIRY_SECONDS: int = int(os.getenv("AUTH_TOKEN_EXPIRY", "86400"))
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


# ---------------------------------------------------------------------------
# Local auth helpers
# ---------------------------------------------------------------------------

def _hash_password(password: str, salt: str | None = None) -> tuple[str, str]:
    salt = salt or secrets.token_hex(16)
    digest = hashlib.sha256(f"{salt}:{password}".encode()).hexdigest()
    return digest, salt


def _normalize_email(value: str) -> str:
    email = value.strip().lower()
    if not _EMAIL_RE.match(email):
        raise ValueError("Invalid email address")
    return email


def _ensure_local_auth_available() -> None:
    if get_local_jwt_secret():
        return
    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="Local authentication is disabled until AUTH_JWT_SECRET is securely configured.",
    )


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------


class RegisterBody(BaseModel):
    email: str
    password: str = Field(min_length=8)
    display_name: str = Field(min_length=1, max_length=256)
    team_name: str = ""

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str) -> str:
        return _normalize_email(value)


class LoginBody(BaseModel):
    email: str
    password: str

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str) -> str:
        return _normalize_email(value)


class AuthTokenResponse(BaseModel):
    token: str
    user: dict[str, Any]


class UserProfile(BaseModel):
    id: str
    email: str
    display_name: str
    initials: str
    team_name: str
    avatar_url: str | None
    role: str
    auth_source: str


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/register", response_model=AuthTokenResponse, status_code=201)
async def register(body: RegisterBody):
    _ensure_local_auth_available()
    store = get_store()
    existing = store.get_user_by_email(body.email)
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")

    digest, salt = _hash_password(body.password)
    user = store.create_user({
        "email": body.email,
        "display_name": body.display_name,
        "team_name": body.team_name,
        "password_hash": f"{salt}:{digest}",
        "auth_source": "local",
    })
    token = _issue_token(user)
    return AuthTokenResponse(token=token, user=_safe_user(user))


@router.post("/login", response_model=AuthTokenResponse)
async def login(body: LoginBody):
    _ensure_local_auth_available()
    store = get_store()
    user = store.get_user_by_email(body.email, include_hash=True)
    if not user:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")

    stored_hash = user.get("_password_hash", "")
    if ":" not in stored_hash:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")
    salt, expected_digest = stored_hash.split(":", 1)
    actual_digest, _ = _hash_password(body.password, salt)
    if not hmac.compare_digest(expected_digest, actual_digest):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")

    store.update_user_login(user["id"])
    token = _issue_token(user)
    return AuthTokenResponse(token=token, user=_safe_user(user))


@router.get("/me", response_model=UserProfile)
async def get_me(request: Request):
    user = _resolve_authenticated_user(request)
    return UserProfile(**{k: v for k, v in user.items() if k in UserProfile.model_fields})


@router.get("/users")
async def list_users():
    store = get_store()
    return [_safe_user(u) for u in store.list_users()]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _issue_token(user: dict[str, Any]) -> str:
    return encode_local_jwt({
        "sub": user["id"],
        "email": user["email"],
        "display_name": user["display_name"],
        "initials": user.get("initials", ""),
        "role": user.get("role", "user"),
        "iat": int(time.time()),
        "exp": int(time.time()) + TOKEN_EXPIRY_SECONDS,
    })


def _safe_user(user: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in user.items() if not k.startswith("_") and k != "password_hash"}


def _resolve_authenticated_user(request: Request) -> dict[str, Any]:
    auth_header = (request.headers.get("authorization") or "").strip()
    if not auth_header.lower().startswith("bearer "):
        identity = resolve_request_identity(request)
        if identity.authenticated:
            store = get_store()
            user = store.get_user_by_email(identity.email)
            if user:
                return user
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing or invalid token")

    token = auth_header.split(" ", 1)[1]
    claims = decode_local_jwt(token)
    if not claims:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token")
    if claims.get("exp", 0) < time.time():
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token")

    store = get_store()
    user = store.get_user_by_id(claims["sub"])
    if not user:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "User not found")
    return user

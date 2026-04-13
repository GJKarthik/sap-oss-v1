"""
Local user authentication — registration, login, and token-based identity.

Passwords are hashed with SHA-256 + per-user salt (no external bcrypt dep).
JWTs are signed with HS256 using ``AUTH_JWT_SECRET``.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import time
from base64 import urlsafe_b64decode, urlsafe_b64encode
from typing import Any

from fastapi import APIRouter, HTTPException, Request, status
from pydantic import BaseModel, EmailStr, Field

from .identity import resolve_request_identity
from .store import get_store

router = APIRouter()

AUTH_JWT_SECRET: str = os.getenv("AUTH_JWT_SECRET", "dev-secret-change-me")
TOKEN_EXPIRY_SECONDS: int = int(os.getenv("AUTH_TOKEN_EXPIRY", "86400"))


# ---------------------------------------------------------------------------
# Lightweight JWT helpers (no PyJWT dependency)
# ---------------------------------------------------------------------------

def _b64url(data: bytes) -> str:
    return urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(s: str) -> bytes:
    s += "=" * (-len(s) % 4)
    return urlsafe_b64decode(s)


def _jwt_encode(payload: dict[str, Any]) -> str:
    header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = _b64url(json.dumps(payload).encode())
    sig_input = f"{header}.{body}".encode()
    sig = _b64url(hmac.new(AUTH_JWT_SECRET.encode(), sig_input, hashlib.sha256).digest())
    return f"{header}.{body}.{sig}"


def _jwt_decode(token: str) -> dict[str, Any] | None:
    parts = token.split(".")
    if len(parts) != 3:
        return None
    sig_input = f"{parts[0]}.{parts[1]}".encode()
    expected_sig = _b64url(hmac.new(AUTH_JWT_SECRET.encode(), sig_input, hashlib.sha256).digest())
    if not hmac.compare_digest(expected_sig, parts[2]):
        return None
    try:
        payload = json.loads(_b64url_decode(parts[1]))
    except Exception:
        return None
    if payload.get("exp", 0) < time.time():
        return None
    return payload


def _hash_password(password: str, salt: str | None = None) -> tuple[str, str]:
    salt = salt or secrets.token_hex(16)
    digest = hashlib.sha256(f"{salt}:{password}".encode()).hexdigest()
    return digest, salt


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------


class RegisterBody(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8)
    display_name: str = Field(min_length=1, max_length=256)
    team_name: str = ""


class LoginBody(BaseModel):
    email: EmailStr
    password: str


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
    store = get_store()
    existing = store.get_user_by_email(body.email.lower())
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")

    digest, salt = _hash_password(body.password)
    user = store.create_user({
        "email": body.email.lower(),
        "display_name": body.display_name,
        "team_name": body.team_name,
        "password_hash": f"{salt}:{digest}",
        "auth_source": "local",
    })
    token = _issue_token(user)
    return AuthTokenResponse(token=token, user=_safe_user(user))


@router.post("/login", response_model=AuthTokenResponse)
async def login(body: LoginBody):
    store = get_store()
    user = store.get_user_by_email(body.email.lower(), include_hash=True)
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
    return _jwt_encode({
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
    claims = _jwt_decode(token)
    if not claims:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token")

    store = get_store()
    user = store.get_user_by_id(claims["sub"])
    if not user:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "User not found")
    return user

"""
Shared helpers for locally issued HS256 JWTs.

The local auth subsystem is disabled unless ``AUTH_JWT_SECRET`` is configured
with a non-placeholder value.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
from base64 import urlsafe_b64decode, urlsafe_b64encode
from typing import Any

from fastapi import HTTPException, status

_INSECURE_SECRETS = frozenset({"", "dev-secret-change-me", "change-me-in-production"})


def _b64url(data: bytes) -> str:
    return urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(s: str) -> bytes:
    s += "=" * (-len(s) % 4)
    return urlsafe_b64decode(s)


def get_local_jwt_secret() -> str | None:
    secret = os.getenv("AUTH_JWT_SECRET", "").strip()
    if secret in _INSECURE_SECRETS:
        return None
    return secret


def require_local_jwt_secret() -> str:
    secret = get_local_jwt_secret()
    if secret:
        return secret
    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="Local JWT authentication is disabled until AUTH_JWT_SECRET is securely configured.",
    )


def encode_local_jwt(payload: dict[str, Any]) -> str:
    secret = require_local_jwt_secret()
    header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = _b64url(json.dumps(payload).encode())
    sig_input = f"{header}.{body}".encode()
    sig = _b64url(hmac.new(secret.encode(), sig_input, hashlib.sha256).digest())
    return f"{header}.{body}.{sig}"


def decode_local_jwt(token: str) -> dict[str, Any] | None:
    secret = get_local_jwt_secret()
    if not secret:
        return None

    parts = token.split(".")
    if len(parts) != 3:
        return None

    sig_input = f"{parts[0]}.{parts[1]}".encode()
    expected_sig = _b64url(hmac.new(secret.encode(), sig_input, hashlib.sha256).digest())
    if not hmac.compare_digest(expected_sig, parts[2]):
        return None

    try:
        payload = json.loads(_b64url_decode(parts[1]))
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None

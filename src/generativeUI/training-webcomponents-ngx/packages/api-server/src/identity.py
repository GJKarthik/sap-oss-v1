from __future__ import annotations

import base64
import json
import re
from dataclasses import asdict, dataclass
from typing import Any, Optional

from fastapi import HTTPException, Request, status


@dataclass(frozen=True)
class RequestIdentity:
    user_id: str
    display_name: str
    email: str
    team_name: str
    auth_source: str
    authenticated: bool

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _clean(value: Optional[str]) -> str:
    return (value or "").strip()


def _normalize_user_id(value: Optional[str]) -> str:
    cleaned = _clean(value)
    if not cleaned:
        return ""
    if "@" in cleaned:
        return cleaned.lower()
    return re.sub(r"\s+", "-", cleaned)


def _display_name_from_email(email: str) -> str:
    local_part = email.split("@", 1)[0]
    pieces = [piece for piece in re.split(r"[._-]+", local_part) if piece]
    if not pieces:
        return email
    return " ".join(piece.capitalize() for piece in pieces)


def _first_present(mapping: Any, *keys: str) -> str:
    for key in keys:
        value = _clean(mapping.get(key))
        if value:
            return value
    return ""


def _decode_token_claims(token: str) -> dict[str, Any]:
    parts = token.split(".")
    if len(parts) < 2:
        return {}
    payload = parts[1]
    padding = "=" * (-len(payload) % 4)
    try:
        decoded = base64.urlsafe_b64decode(payload + padding)
        data = json.loads(decoded.decode("utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _identity_from_edge_headers(request: Request) -> Optional[RequestIdentity]:
    headers = request.headers
    email = _first_present(headers, "x-auth-request-email", "x-forwarded-email")
    preferred_username = _first_present(
        headers,
        "x-auth-request-preferred-username",
        "x-forwarded-preferred-username",
    )
    user = _first_present(headers, "x-auth-request-user", "x-forwarded-user")
    name = _first_present(headers, "x-auth-request-name", "x-forwarded-name")
    team_name = _first_present(headers, "x-workspace-team-name")

    user_id = _normalize_user_id(preferred_username or user or email)
    if not user_id:
        return None

    display_name = name or preferred_username or user or _display_name_from_email(email) or user_id
    return RequestIdentity(
        user_id=user_id,
        display_name=display_name,
        email=email.lower(),
        team_name=team_name,
        auth_source="edge_header",
        authenticated=True,
    )


def _identity_from_bearer_token(request: Request) -> Optional[RequestIdentity]:
    authorization = _clean(request.headers.get("authorization"))
    if not authorization.lower().startswith("bearer "):
        return None

    claims = _decode_token_claims(authorization.split(" ", 1)[1])
    email = _clean(str(claims.get("email", ""))).lower()
    preferred_username = _clean(str(claims.get("preferred_username", "")))
    user_id = _normalize_user_id(
        claims.get("sub") or claims.get("user_id") or preferred_username or email
    )
    if not user_id:
        return None

    display_name = _clean(str(claims.get("name", "")))
    if not display_name:
        given_name = _clean(str(claims.get("given_name", "")))
        family_name = _clean(str(claims.get("family_name", "")))
        display_name = " ".join(part for part in [given_name, family_name] if part).strip()
    display_name = display_name or preferred_username or _display_name_from_email(email) or user_id

    return RequestIdentity(
        user_id=user_id,
        display_name=display_name,
        email=email,
        team_name="",
        auth_source="bearer_token",
        authenticated=True,
    )


def _identity_from_workspace_hint(request: Request) -> Optional[RequestIdentity]:
    headers = request.headers
    workspace_user = _first_present(headers, "x-workspace-user")
    workspace_display_name = _first_present(headers, "x-workspace-display-name")
    workspace_team_name = _first_present(headers, "x-workspace-team-name")
    workspace_query = _clean(request.query_params.get("workspace"))

    user_id = _normalize_user_id(workspace_user or workspace_query)
    if not user_id:
        return None

    return RequestIdentity(
        user_id=user_id,
        display_name=workspace_display_name or user_id,
        email="",
        team_name=workspace_team_name,
        auth_source="workspace_hint",
        authenticated=False,
    )


def resolve_request_identity(request: Request) -> RequestIdentity:
    cached = getattr(request.state, "resolved_identity", None)
    if isinstance(cached, RequestIdentity):
        return cached

    identity = (
        _identity_from_edge_headers(request)
        or _identity_from_bearer_token(request)
        or _identity_from_workspace_hint(request)
        or RequestIdentity(
            user_id="personal-user",
            display_name="Local Preview User",
            email="",
            team_name="",
            auth_source="preview_fallback",
            authenticated=False,
        )
    )
    request.state.resolved_identity = identity
    return identity


def resolve_effective_owner(request: Request, requested_owner_id: Optional[str] = None) -> str:
    identity = resolve_request_identity(request)
    requested = _normalize_user_id(requested_owner_id)

    if identity.authenticated:
        if requested and requested != identity.user_id:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Authenticated ownership does not match the resolved user.",
            )
        return identity.user_id

    return requested or identity.user_id or "personal-user"

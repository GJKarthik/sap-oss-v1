from __future__ import annotations

import os
import re
from dataclasses import asdict, dataclass
from typing import Any, Optional

from fastapi import HTTPException, Request, status

from .auth_tokens import decode_local_jwt


def _env_flag(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in {"1", "true", "yes", "on"}


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

    claims = decode_local_jwt(authorization.split(" ", 1)[1]) or {}
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
    if not _env_flag("ALLOW_UNAUTHENTICATED_WORKSPACE_HINTS"):
        return None

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

    if requested and requested != identity.user_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Unauthenticated owner overrides are disabled.",
        )

    return identity.user_id or "personal-user"

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
from typing import Any, Dict

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field

from .database import SessionLocal
from .identity import RequestIdentity, resolve_effective_owner, resolve_request_identity
from .store import WorkspaceSettingsRecord

router = APIRouter()

DEFAULT_NAV_ROUTES = [
    "/dashboard",
    "/data-cleaning",
    "/schema-browser",
    "/data-products",
    "/data-quality",
    "/lineage",
    "/vocab-search",
    "/chat",
    "/rag-studio",
    "/semantic-search",
    "/document-ocr",
    "/pal-workbench",
    "/sparql-explorer",
    "/analytical-dashboard",
    "/streaming",
    "/pipeline",
    "/deployments",
    "/model-optimizer",
    "/registry",
    "/hana-explorer",
    "/compare",
    "/governance",
    "/analytics",
    "/glossary-manager",
    "/document-linguist",
    "/prompts",
    "/workspace",
]


def _default_backend_settings() -> dict[str, Any]:
    return {
        # Training shell settings
        "apiBaseUrl": "/api",
        "collabWsUrl": "/collab",
        # UI5 workspace settings
        "openAiBaseUrl": "/api/v1/ui5/openai",
        "mcpBaseUrl": "/api/v1/ui5/mcp/mcp",
        "agUiEndpoint": "/ag-ui/run",
        "ocrInternalToken": "",
    }


def _normalize_nav_items(items: list[Any]) -> list[dict[str, Any]]:
    normalized_items: list[dict[str, Any]] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            continue

        route = str(item.get("route") or item.get("path") or "").strip()
        path = str(item.get("path") or item.get("route") or "").strip()
        canonical_path = path or route
        canonical_route = route or path
        if not canonical_path or not canonical_route:
            continue

        try:
            order = int(item.get("order", index))
        except (TypeError, ValueError):
            order = index

        normalized_items.append(
            {
                "route": canonical_route,
                "path": canonical_path,
                "visible": bool(item.get("visible", True)),
                "order": order,
            }
        )

    return normalized_items


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _default_settings(identity: RequestIdentity) -> dict[str, Any]:
    return {
        "version": 1,
        "identity": {
            "userId": identity.user_id,
            "displayName": identity.display_name,
            "teamName": identity.team_name,
        },
        "backend": _default_backend_settings(),
        "nav": {
            "defaultLandingPath": "/",
            "items": [
                {"route": route, "path": route, "visible": True, "order": index}
                for index, route in enumerate(DEFAULT_NAV_ROUTES)
            ],
        },
        "model": {
            "defaultModel": "",
            "temperature": 0.7,
            "systemPrompt": "",
        },
        "theme": "sap_horizon",
        "language": "en",
        "updatedAt": _now_iso(),
    }


class WorkspaceBootstrapResponse(BaseModel):
    identity: Dict[str, str]
    settings: Dict[str, Any] = Field(default_factory=dict)
    auth_source: str
    authenticated: bool
    has_saved_settings: bool = False


def _normalize_settings(
    payload: dict[str, Any] | None,
    identity: RequestIdentity,
) -> dict[str, Any]:
    settings = deepcopy(payload or {})
    normalized = _default_settings(identity)
    normalized.update(
        {
            key: value
            for key, value in settings.items()
            if key in {"version", "theme", "language", "updatedAt"}
        }
    )

    backend = settings.get("backend")
    if isinstance(backend, dict):
        normalized["backend"].update(backend)

    nav = settings.get("nav")
    if isinstance(nav, dict):
        default_landing_path = str(nav.get("defaultLandingPath") or "").strip()
        if default_landing_path:
            normalized["nav"]["defaultLandingPath"] = default_landing_path
        if isinstance(nav.get("items"), list):
            normalized["nav"]["items"] = _normalize_nav_items(nav["items"])

    model = settings.get("model")
    if isinstance(model, dict):
        normalized["model"].update(model)

    stored_identity = settings.get("identity")
    team_name = identity.team_name
    if isinstance(stored_identity, dict):
        team_name = str(stored_identity.get("teamName") or team_name or "").strip()

    normalized["identity"] = {
        "userId": identity.user_id,
        "displayName": identity.display_name,
        "teamName": team_name,
    }
    normalized["updatedAt"] = _now_iso()
    return normalized


def _bootstrap_response(
    identity: RequestIdentity,
    settings: dict[str, Any],
    has_saved_settings: bool,
) -> WorkspaceBootstrapResponse:
    return WorkspaceBootstrapResponse(
        identity={
            "userId": identity.user_id,
            "displayName": identity.display_name,
            "teamName": str(settings.get("identity", {}).get("teamName", "")),
            "email": identity.email,
        },
        settings=settings,
        auth_source=identity.auth_source,
        authenticated=identity.authenticated,
        has_saved_settings=has_saved_settings,
    )


@router.get("", response_model=WorkspaceBootstrapResponse)
async def get_workspace(request: Request) -> WorkspaceBootstrapResponse:
    identity = resolve_request_identity(request)
    owner_id = resolve_effective_owner(request)
    db = SessionLocal()
    try:
        record = db.query(WorkspaceSettingsRecord).filter(WorkspaceSettingsRecord.owner_id == owner_id).first()
        settings = _normalize_settings(record.settings if record else None, identity)
        return _bootstrap_response(identity, settings, has_saved_settings=record is not None)
    finally:
        db.close()


@router.put("", response_model=WorkspaceBootstrapResponse)
async def save_workspace(request: Request, body: dict[str, Any]) -> WorkspaceBootstrapResponse:
    requested_owner = None
    identity_payload = body.get("identity")
    if isinstance(identity_payload, dict):
        requested_owner = str(identity_payload.get("userId") or "").strip()

    identity = resolve_request_identity(request)
    owner_id = resolve_effective_owner(request, requested_owner)
    settings = _normalize_settings(body, identity)

    db = SessionLocal()
    try:
        record = db.query(WorkspaceSettingsRecord).filter(WorkspaceSettingsRecord.owner_id == owner_id).first()
        if not record:
            record = WorkspaceSettingsRecord(owner_id=owner_id)
            db.add(record)

        record.settings = settings
        record.identity_email = identity.email
        record.identity_display_name = identity.display_name
        record.auth_source = identity.auth_source
        db.commit()
        db.refresh(record)
        return _bootstrap_response(identity, settings, has_saved_settings=True)
    finally:
        db.close()

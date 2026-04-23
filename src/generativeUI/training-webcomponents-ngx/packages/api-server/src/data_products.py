"""
Data Products API — serves and updates YAML-based data product definitions.

Provides endpoints to:
- List all registered data products with metadata
- Get a single product's full definition
- Update product fields (team access, country views, schema)
- Preview the effective LLM prompt for a team × product combination
"""

import os
import re
import json
import copy
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

import structlog
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, Field, field_validator

from .identity import resolve_request_identity
from .store import get_store

logger = structlog.get_logger("training-webcomponents-ngx.data_products")

router = APIRouter()

# ---------------------------------------------------------------------------
# Security: Product ID validation
# ---------------------------------------------------------------------------

_PRODUCT_ID_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")


def _validate_product_id(product_id: str) -> str:
    """Sanitize product_id to prevent path traversal and injection."""
    if not _PRODUCT_ID_RE.match(product_id):
        raise HTTPException(400, "Invalid product ID format")
    if ".." in product_id or "/" in product_id or "\\" in product_id:
        raise HTTPException(400, "Invalid product ID format")
    return product_id


# ---------------------------------------------------------------------------
# Security: RBAC write guard
# ---------------------------------------------------------------------------

_WRITE_ROLES = frozenset({"admin", "editor", "write"})


def _env_flag(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in {"1", "true", "yes", "on"}


def _normalize_role(value: Any) -> str:
    return str(value or "").strip().lower()


def _parse_team_context(header: str) -> Dict[str, str]:
    parsed: Dict[str, str] = {}
    cleaned = header.strip()
    if not cleaned:
        return parsed

    if cleaned.startswith("{"):
        try:
            ctx = json.loads(cleaned)
        except (json.JSONDecodeError, TypeError):
            raise HTTPException(400, "Malformed X-Team-Context header")
        if not isinstance(ctx, dict):
            raise HTTPException(400, "Malformed X-Team-Context header")
        for key in ("country", "domain", "teamId", "role"):
            value = ctx.get(key)
            if value is not None:
                parsed[key] = str(value).strip()
        return parsed

    parts = [part.strip() for part in cleaned.split(":")]
    if len(parts) > 0 and parts[0]:
        parsed["country"] = parts[0]
    if len(parts) > 1 and parts[1]:
        parsed["domain"] = parts[1]
    if len(parts) > 2 and parts[2]:
        parsed["teamId"] = parts[2]
    if len(parts) > 3 and parts[3]:
        parsed["role"] = parts[3]
    return parsed


def _roles_from_request(request: Request) -> Set[str]:
    identity = resolve_request_identity(request)
    if not identity.authenticated:
        return set()

    roles: set[str] = set()
    store = get_store()

    user = None
    if identity.email:
        user = store.get_user_by_email(identity.email)
    if user is None:
        user = store.get_user_by_id(identity.user_id)
    if user:
        role = _normalize_role(user.get("role"))
        if role:
            roles.add(role)

    if _env_flag("TRUST_AUTH_ROLE_HEADERS"):
        for header_name in ("x-auth-request-role", "x-forwarded-role", "x-user-role"):
            role = _normalize_role(request.headers.get(header_name))
            if role:
                roles.add(role)

    return roles


async def _require_write_access(
    request: Request,
    x_team_context: Optional[str] = Header(None),
) -> str:
    """Dependency that enforces write permission via authenticated server roles.

    Accepts either:
      - JSON: {"country":"AE","domain":"treasury"}
      - Colon-delimited: "AE:treasury:team-1"

    The header is treated as request context only. Authorization comes from the
    authenticated server-side user role or, when explicitly enabled, trusted
    upstream role headers.
    """
    if not x_team_context:
        raise HTTPException(403, "Write access requires X-Team-Context header")

    context = _parse_team_context(x_team_context)
    identity = resolve_request_identity(request)
    if not identity.authenticated:
        logger.warning("write_denied_unauthenticated", path=str(request.url))
        raise HTTPException(403, "Authenticated write access is required")

    roles = _roles_from_request(request)
    if not roles.intersection(_WRITE_ROLES):
        logger.warning(
            "write_denied",
            user_id=identity.user_id,
            roles=sorted(roles),
            context=context,
            path=str(request.url),
        )
        raise HTTPException(403, "Authenticated admin/editor role is required for writes")

    return x_team_context

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Resolve the data_products directory — works both in dev and production.
# Docker images only copy /app/src, so parent-depth assumptions from the repo
# layout are not safe there.
_THIS_DIR = Path(__file__).resolve().parent


def _resolve_default_data_products_dir(start_dir: Optional[Path] = None) -> Path:
    configured = os.getenv("DATA_PRODUCTS_DIR", "").strip()
    if configured:
        return Path(configured).expanduser()

    start = (start_dir or _THIS_DIR).resolve()
    seen: set[Path] = set()

    for base in (start, *start.parents):
        for candidate in (
            base / "src" / "training" / "data_products",
            base / "training" / "data_products",
            base / "data_products",
        ):
            if candidate in seen:
                continue
            seen.add(candidate)
            if candidate.exists():
                return candidate

    return start / "data_products"


DATA_PRODUCTS_DIR = _resolve_default_data_products_dir()


def _try_load_yaml():
    """Lazy import yaml to avoid hard dependency at module level."""
    try:
        import yaml
        return yaml
    except ImportError:
        return None


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class ProductSummary(BaseModel):
    id: str
    name: str
    version: str = ""
    description: str = ""
    domain: str = ""
    dataSecurityClass: str = ""
    owner: Dict[str, str] = Field(default_factory=dict)
    teamAccess: Dict[str, Any] = Field(default_factory=dict)
    hasCountryViews: bool = False
    countryViewCount: int = 0
    fieldCount: int = 0
    enrichmentAvailable: bool = False


class ProductDetail(BaseModel):
    id: str
    raw: Dict[str, Any] = Field(default_factory=dict)
    enrichment: Optional[Dict[str, Any]] = None


class TeamAccessUpdate(BaseModel):
    defaultAccess: str = "read"
    domainRestrictions: List[str] = Field(default_factory=list, max_length=50)
    countryRestrictions: List[str] = Field(default_factory=list, max_length=50)

    @field_validator("defaultAccess")
    @classmethod
    def validate_default_access(cls, v: str) -> str:
        allowed = {"read", "write", "admin", "none"}
        if v.lower() not in allowed:
            raise ValueError(f"defaultAccess must be one of {allowed}")
        return v.lower()

    @field_validator("domainRestrictions", "countryRestrictions")
    @classmethod
    def validate_restriction_items(cls, v: List[str]) -> List[str]:
        cleaned: List[str] = []
        for item in v:
            item = item.strip()
            if not item:
                continue
            if not re.match(r"^[a-zA-Z0-9_-]{1,64}$", item):
                raise ValueError(f"Invalid restriction value: '{item}'")
            cleaned.append(item)
        return cleaned


class ProductUpdateRequest(BaseModel):
    teamAccess: Optional[TeamAccessUpdate] = None
    countryViews: Optional[Dict[str, Any]] = None


class PromptPreviewRequest(BaseModel):
    productId: str
    country: str = ""
    domain: str = ""
    basePrompt: str = "You are a financial data analyst."


class PromptPreviewResponse(BaseModel):
    effectivePrompt: str
    glossaryTerms: List[Dict[str, str]] = Field(default_factory=list)
    filters: Dict[str, str] = Field(default_factory=dict)
    scopeLabel: str = "global"


# ---------------------------------------------------------------------------
# YAML helpers
# ---------------------------------------------------------------------------

def _load_registry() -> Dict[str, Any]:
    yaml = _try_load_yaml()
    if not yaml:
        return {"products": [], "catalog": {}}
    registry_path = DATA_PRODUCTS_DIR / "registry.yaml"
    if not registry_path.exists():
        return {"products": [], "catalog": {}}
    with open(registry_path) as f:
        return yaml.safe_load(f) or {}


def _load_product_yaml(filename: str) -> Dict[str, Any]:
    yaml = _try_load_yaml()
    if not yaml:
        return {}
    path = DATA_PRODUCTS_DIR / filename
    if not path.exists():
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}


def _load_enrichment(product_id: str) -> Optional[Dict[str, Any]]:
    yaml = _try_load_yaml()
    if not yaml:
        return None
    enriched_dir = DATA_PRODUCTS_DIR / "enriched"
    if not enriched_dir.exists():
        return None
    # Match by product_id prefix in enrichment filenames
    for f in enriched_dir.glob("*.yaml"):
        if product_id.replace("-v1", "") in f.stem:
            with open(f) as fh:
                return yaml.safe_load(fh)
    return None


def _save_product_yaml(filename: str, data: Dict[str, Any]) -> None:
    yaml = _try_load_yaml()
    if not yaml:
        raise HTTPException(500, "PyYAML not installed")
    path = DATA_PRODUCTS_DIR / filename
    with open(path, "w") as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)


def _find_product_file(product_id: str) -> Optional[str]:
    """Find the YAML filename for a given product ID."""
    registry = _load_registry()
    for ref_entry in registry.get("products", []):
        ref = ref_entry.get("ref", "")
        product_data = _load_product_yaml(ref)
        dp = product_data.get("dataProduct", {})
        if dp.get("id") == product_id:
            return ref
    return None


def _count_fields(product_data: Dict[str, Any]) -> int:
    """Count schema fields in a data product."""
    dp = product_data.get("dataProduct", {})
    count = 0
    for key in ["inputPorts", "outputPorts", "schemaFields", "schema"]:
        section = dp.get(key)
        if isinstance(section, list):
            for port in section:
                if isinstance(port, dict):
                    fields = port.get("fields", port.get("columns", []))
                    if isinstance(fields, list):
                        count += len(fields)
        elif isinstance(section, dict):
            for port_name, port_val in section.items():
                if isinstance(port_val, dict):
                    fields = port_val.get("fields", port_val.get("columns", []))
                    if isinstance(fields, list):
                        count += len(fields)
    return count


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get(
    "/products",
    response_model=List[ProductSummary],
    summary="List data products",
    description="Returns all registered data products with summary metadata including field counts, team access, country views, and enrichment status.",
    tags=["Data Products"],
)
async def list_products():
    """List all registered data products with summary metadata."""
    registry = _load_registry()
    summaries: List[ProductSummary] = []

    for ref_entry in registry.get("products", []):
        ref = ref_entry.get("ref", "")
        product_data = _load_product_yaml(ref)
        dp = product_data.get("dataProduct", {})
        if not dp:
            continue

        team_access = dp.get("x-team-access", {})
        country_views = dp.get("x-country-views", {})
        enrichment = _load_enrichment(dp.get("id", ""))

        summaries.append(ProductSummary(
            id=dp.get("id", ""),
            name=dp.get("name", ""),
            version=dp.get("version", ""),
            description=dp.get("description", "").strip(),
            domain=dp.get("domain", ""),
            dataSecurityClass=dp.get("dataSecurityClass", ""),
            owner=dp.get("owner", {}),
            teamAccess=team_access,
            hasCountryViews=bool(country_views),
            countryViewCount=len(country_views) if isinstance(country_views, dict) else 0,
            fieldCount=_count_fields(product_data),
            enrichmentAvailable=enrichment is not None,
        ))

    return summaries


@router.get(
    "/products/{product_id}",
    response_model=ProductDetail,
    summary="Get data product detail",
    description="Returns the full YAML definition of a data product, including schema, access, country views, and enrichment data. Product ID is validated against path traversal.",
    tags=["Data Products"],
    responses={400: {"description": "Invalid product ID format"}, 404: {"description": "Product not found"}},
)
async def get_product(product_id: str):
    """Get full data product definition including enrichment data."""
    _validate_product_id(product_id)
    filename = _find_product_file(product_id)
    if not filename:
        raise HTTPException(404, f"Product '{product_id}' not found")

    product_data = _load_product_yaml(filename)
    enrichment = _load_enrichment(product_id)

    return ProductDetail(
        id=product_id,
        raw=product_data,
        enrichment=enrichment,
    )


@router.patch(
    "/products/{product_id}",
    summary="Update data product",
    description="Updates team access or country views for a data product. Requires authenticated admin/editor privileges plus an X-Team-Context header for request scoping. Input is validated: defaultAccess must be read/write/admin/none, restrictions must be alphanumeric.",
    tags=["Data Products"],
    responses={
        400: {"description": "Invalid product ID or malformed body"},
        403: {"description": "Insufficient permissions (missing header, unauthenticated request, or non-writer role)"},
        404: {"description": "Product not found"},
    },
)
async def update_product(
    product_id: str,
    body: ProductUpdateRequest,
    _ctx: str = Depends(_require_write_access),
):
    """Update team access or country views for a data product.

    Requires an authenticated admin/editor identity plus X-Team-Context.
    """
    _validate_product_id(product_id)
    filename = _find_product_file(product_id)
    if not filename:
        raise HTTPException(404, f"Product '{product_id}' not found")

    product_data = _load_product_yaml(filename)
    dp = product_data.get("dataProduct", {})

    if body.teamAccess is not None:
        dp["x-team-access"] = body.teamAccess.model_dump()
    if body.countryViews is not None:
        dp["x-country-views"] = body.countryViews

    product_data["dataProduct"] = dp
    _save_product_yaml(filename, product_data)
    logger.info("product_updated", product_id=product_id)

    return {"status": "updated", "product_id": product_id}


@router.get(
    "/registry",
    summary="Get product registry",
    description="Returns the full YAML registry configuration including catalog metadata, product references, global policies, and LLM backend config.",
    tags=["Data Products"],
)
async def get_registry():
    """Get the full registry configuration."""
    return _load_registry()


@router.post(
    "/prompt-preview",
    response_model=PromptPreviewResponse,
    summary="Preview effective prompt",
    description="Composes the effective LLM system prompt for a given product, country, and domain combination. Merges base prompt, product prompting policy, and country-specific overrides (glossary, filters, prompt append).",
    tags=["Data Products"],
    responses={404: {"description": "Product not found"}},
)
async def prompt_preview(body: PromptPreviewRequest):
    """Preview the effective LLM prompt for a team × product combination."""
    filename = _find_product_file(body.productId)
    if not filename:
        raise HTTPException(404, f"Product '{body.productId}' not found")

    product_data = _load_product_yaml(filename)
    dp = product_data.get("dataProduct", {})

    prompt_parts = [body.basePrompt]
    glossary_terms: List[Dict[str, str]] = []
    filters: Dict[str, str] = {}
    scope_label = "global"

    # Apply prompting policy
    prompting = dp.get("x-prompting-policy", {})
    if prompting.get("systemPrompt"):
        prompt_parts.append(prompting["systemPrompt"])

    # Apply country-specific overrides
    country_views = dp.get("x-country-views", {})
    if body.country and body.country.upper() in country_views:
        view = country_views[body.country.upper()]
        scope_label = body.country.upper()

        if view.get("promptAppend"):
            prompt_parts.append(view["promptAppend"].strip())
        if view.get("defaultFilters"):
            filters.update(view["defaultFilters"])
        if view.get("additionalGlossary"):
            for term in view["additionalGlossary"]:
                glossary_terms.append({
                    "source": term.get("source", ""),
                    "target": term.get("target", ""),
                    "lang": term.get("lang", ""),
                })

    if body.country and body.domain:
        scope_label = f"{body.country.upper()}:{body.domain.lower()}"
    elif body.domain:
        scope_label = body.domain.lower()

    return PromptPreviewResponse(
        effectivePrompt="\n\n".join(prompt_parts),
        glossaryTerms=glossary_terms,
        filters=filters,
        scopeLabel=scope_label,
    )

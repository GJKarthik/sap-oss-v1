"""
Governance rules management routes for SAP AI Fabric Console.
State persisted via the configured shared store backend.
"""

from dataclasses import asdict
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from ..models import GovernanceRule as GovernanceRuleDC
from ..routes.auth import UserInfo, get_current_user, require_admin
from ..store import StoreBackend, get_store

router = APIRouter()


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class GovernanceRuleOut(BaseModel):
    id: str
    name: str
    rule_type: str
    active: bool
    description: Optional[str]
    updated_at: Optional[str]


class GovernanceRuleCreateRequest(BaseModel):
    name: str
    rule_type: str
    active: bool = True
    description: Optional[str] = None


class GovernanceRuleListResponse(BaseModel):
    rules: List[GovernanceRuleOut]
    total: int


def _dict_to_out(d: dict) -> GovernanceRuleOut:
    updated_at = d.get("updated_at")
    if isinstance(updated_at, datetime):
        updated_at = updated_at.isoformat()
    elif updated_at is not None:
        updated_at = str(updated_at)
    return GovernanceRuleOut(
        id=d["id"],
        name=d["name"],
        rule_type=d["rule_type"],
        active=d.get("active", True),
        description=d.get("description"),
        updated_at=updated_at,
    )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/", response_model=GovernanceRuleListResponse)
async def list_rules(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """List all governance rules."""
    rows = sorted(store.list_records("governance_rules"), key=lambda r: r["name"])
    return GovernanceRuleListResponse(rules=[_dict_to_out(r) for r in rows], total=len(rows))


@router.post("/", response_model=GovernanceRuleOut, status_code=status.HTTP_201_CREATED)
async def create_rule(
    body: GovernanceRuleCreateRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Create a new governance rule."""
    rule = GovernanceRuleDC(
        name=body.name,
        rule_type=body.rule_type,
        active=body.active,
        description=body.description,
    )
    created = store.set_record("governance_rules", rule.id, asdict(rule))
    return _dict_to_out(created)


@router.get("/{rule_id}", response_model=GovernanceRuleOut)
async def get_rule(
    rule_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Get a specific governance rule."""
    row = store.get_record("governance_rules", rule_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Rule '{rule_id}' not found")
    return _dict_to_out(row)


@router.patch("/{rule_id}/toggle")
async def toggle_rule(
    rule_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Toggle a governance rule active/inactive."""
    row = store.mutate_record(
        "governance_rules",
        rule_id,
        lambda record: {
            **record,
            "active": not record.get("active", True),
            "updated_at": datetime.now(timezone.utc),
        },
    )
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Rule '{rule_id}' not found")
    return {"id": row["id"], "active": row["active"]}


@router.delete("/{rule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_rule(
    rule_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Delete a governance rule."""
    if not store.delete_record("governance_rules", rule_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Rule '{rule_id}' not found")

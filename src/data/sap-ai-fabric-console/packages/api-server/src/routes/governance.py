"""
Governance rules management routes for SAP AI Fabric Console.
"""

from typing import List, Optional

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel

router = APIRouter()


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class GovernanceRule(BaseModel):
    id: str
    name: str
    rule_type: str  # "content-filter", "access-control", "compliance"
    active: bool = True
    description: Optional[str] = None


class GovernanceRuleCreateRequest(BaseModel):
    name: str
    rule_type: str
    active: bool = True
    description: Optional[str] = None


class GovernanceRuleListResponse(BaseModel):
    rules: List[GovernanceRule]
    total: int


# ---------------------------------------------------------------------------
# In-memory store
# ---------------------------------------------------------------------------

_rules: List[GovernanceRule] = [
    GovernanceRule(id="rule-001", name="PII Detection", rule_type="content-filter", active=True, description="Detect and redact PII in prompts and responses"),
    GovernanceRule(id="rule-002", name="Rate Limiting", rule_type="access-control", active=True, description="Enforce per-user rate limits"),
    GovernanceRule(id="rule-003", name="Audit Logging", rule_type="compliance", active=True, description="Log all AI interactions for compliance"),
]
_counter = 3


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/", response_model=GovernanceRuleListResponse)
async def list_rules():
    """List all governance rules."""
    return GovernanceRuleListResponse(rules=_rules, total=len(_rules))


@router.post("/", response_model=GovernanceRule, status_code=status.HTTP_201_CREATED)
async def create_rule(body: GovernanceRuleCreateRequest):
    """Create a new governance rule."""
    global _counter
    _counter += 1
    rule = GovernanceRule(
        id=f"rule-{_counter:03d}",
        name=body.name,
        rule_type=body.rule_type,
        active=body.active,
        description=body.description,
    )
    _rules.append(rule)
    return rule


@router.get("/{rule_id}", response_model=GovernanceRule)
async def get_rule(rule_id: str):
    """Get a specific governance rule."""
    for rule in _rules:
        if rule.id == rule_id:
            return rule
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Rule '{rule_id}' not found")


@router.patch("/{rule_id}/toggle")
async def toggle_rule(rule_id: str):
    """Toggle a governance rule active/inactive."""
    for rule in _rules:
        if rule.id == rule_id:
            rule.active = not rule.active
            return {"id": rule.id, "active": rule.active}
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Rule '{rule_id}' not found")


@router.delete("/{rule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_rule(rule_id: str):
    """Delete a governance rule."""
    global _rules
    before = len(_rules)
    _rules = [r for r in _rules if r.id != rule_id]
    if len(_rules) == before:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Rule '{rule_id}' not found")

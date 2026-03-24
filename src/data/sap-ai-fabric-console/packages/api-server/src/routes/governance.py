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
from ..routes.auth import UserInfo, get_current_user, log_admin_action, require_admin
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

@router.get("", response_model=GovernanceRuleListResponse)
async def list_rules(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """List all governance rules."""
    rows = sorted(store.list_records("governance_rules"), key=lambda r: r["name"])
    return GovernanceRuleListResponse(rules=[_dict_to_out(r) for r in rows], total=len(rows))


@router.post("", response_model=GovernanceRuleOut, status_code=status.HTTP_201_CREATED)
async def create_rule(
    body: GovernanceRuleCreateRequest,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(require_admin),
):
    """Create a new governance rule."""
    rule = GovernanceRuleDC(
        name=body.name,
        rule_type=body.rule_type,
        active=body.active,
        description=body.description,
    )
    created = store.set_record("governance_rules", rule.id, asdict(rule))
    log_admin_action(
        actor=current_user,
        resource="governance_rules",
        action="create",
        result="success",
        target=rule.id,
        rule_type=body.rule_type,
    )
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
    current_user: UserInfo = Depends(require_admin),
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
        log_admin_action(
            actor=current_user,
            resource="governance_rules",
            action="toggle",
            result="failure",
            target=rule_id,
            reason="not_found",
        )
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Rule '{rule_id}' not found")
    log_admin_action(actor=current_user, resource="governance_rules", action="toggle", result="success", target=rule_id)
    return {"id": row["id"], "active": row["active"]}


@router.delete("/{rule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_rule(
    rule_id: str,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(require_admin),
):
    """Delete a governance rule."""
    if not store.delete_record("governance_rules", rule_id):
        log_admin_action(
            actor=current_user,
            resource="governance_rules",
            action="delete",
            result="failure",
            target=rule_id,
            reason="not_found",
        )
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Rule '{rule_id}' not found")
    log_admin_action(actor=current_user, resource="governance_rules", action="delete", result="success", target=rule_id)


# ---------------------------------------------------------------------------
# Data Cleaning Approval Workflow
# ---------------------------------------------------------------------------

class DataCleaningApprovalOut(BaseModel):
    """Output schema for data cleaning approval requests."""
    id: str
    tool: str
    query: str
    table_name: str
    estimated_rows: int
    created_at: str
    requested_by: str
    status: str
    reviewed_by: Optional[str] = None
    reviewed_at: Optional[str] = None


class DataCleaningApprovalListResponse(BaseModel):
    """Response for listing pending approvals."""
    approvals: List[DataCleaningApprovalOut]
    total: int


class ApprovalDecisionRequest(BaseModel):
    """Request body for approval decisions."""
    reason: Optional[str] = None


def _approval_to_out(d: dict) -> DataCleaningApprovalOut:
    """Convert approval dict to output schema."""
    created_at = d.get("created_at")
    reviewed_at = d.get("reviewed_at")
    if isinstance(created_at, datetime):
        created_at = created_at.isoformat()
    if isinstance(reviewed_at, datetime):
        reviewed_at = reviewed_at.isoformat()
    return DataCleaningApprovalOut(
        id=d["id"],
        tool=d.get("tool", "generate_cleaning_query"),
        query=d.get("query", ""),
        table_name=d.get("table_name", ""),
        estimated_rows=d.get("estimated_rows", 0),
        created_at=str(created_at) if created_at else "",
        requested_by=d.get("requested_by", ""),
        status=d.get("status", "pending"),
        reviewed_by=d.get("reviewed_by"),
        reviewed_at=str(reviewed_at) if reviewed_at else None,
    )


@router.get("/data-cleaning/pending", response_model=DataCleaningApprovalListResponse)
async def list_pending_approvals(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """
    List pending data cleaning approval requests.
    
    Returns all approval requests for data-modifying queries generated
    by the data-cleaning-copilot that require human review.
    """
    rows = store.list_records("data_cleaning_approvals")
    pending = [r for r in rows if r.get("status") == "pending"]
    pending.sort(key=lambda r: r.get("created_at", ""), reverse=True)
    return DataCleaningApprovalListResponse(
        approvals=[_approval_to_out(r) for r in pending],
        total=len(pending),
    )


@router.get("/data-cleaning/{approval_id}", response_model=DataCleaningApprovalOut)
async def get_approval(
    approval_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Get details of a specific approval request."""
    row = store.get_record("data_cleaning_approvals", approval_id)
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Approval '{approval_id}' not found",
        )
    return _approval_to_out(row)


@router.post("/data-cleaning/{approval_id}/approve", response_model=DataCleaningApprovalOut)
async def approve_query(
    approval_id: str,
    body: ApprovalDecisionRequest = ApprovalDecisionRequest(),
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(require_admin),
):
    """
    Approve a data cleaning query for execution.
    
    Only admins can approve queries. The approval is logged for audit
    and the query becomes available for execution.
    """
    row = store.mutate_record(
        "data_cleaning_approvals",
        approval_id,
        lambda record: {
            **record,
            "status": "approved",
            "reviewed_by": current_user.username,
            "reviewed_at": datetime.now(timezone.utc),
            "review_reason": body.reason,
        },
    )
    if row is None:
        log_admin_action(
            actor=current_user,
            resource="data_cleaning_approvals",
            action="approve",
            result="failure",
            target=approval_id,
            reason="not_found",
        )
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Approval '{approval_id}' not found",
        )
    log_admin_action(
        actor=current_user,
        resource="data_cleaning_approvals",
        action="approve",
        result="success",
        target=approval_id,
        table_name=row.get("table_name"),
        estimated_rows=row.get("estimated_rows"),
    )
    return _approval_to_out(row)


@router.post("/data-cleaning/{approval_id}/reject", response_model=DataCleaningApprovalOut)
async def reject_query(
    approval_id: str,
    body: ApprovalDecisionRequest = ApprovalDecisionRequest(),
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(require_admin),
):
    """
    Reject a data cleaning query.
    
    Only admins can reject queries. The rejection is logged and the
    query will not be executed.
    """
    row = store.mutate_record(
        "data_cleaning_approvals",
        approval_id,
        lambda record: {
            **record,
            "status": "rejected",
            "reviewed_by": current_user.username,
            "reviewed_at": datetime.now(timezone.utc),
            "review_reason": body.reason,
        },
    )
    if row is None:
        log_admin_action(
            actor=current_user,
            resource="data_cleaning_approvals",
            action="reject",
            result="failure",
            target=approval_id,
            reason="not_found",
        )
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Approval '{approval_id}' not found",
        )
    log_admin_action(
        actor=current_user,
        resource="data_cleaning_approvals",
        action="reject",
        result="success",
        target=approval_id,
        reason=body.reason,
    )
    return _approval_to_out(row)


@router.get("/data-cleaning/history", response_model=DataCleaningApprovalListResponse)
async def list_approval_history(
    limit: int = 50,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """
    List historical approval decisions.
    
    Returns approved and rejected queries for audit purposes.
    """
    rows = store.list_records("data_cleaning_approvals")
    reviewed = [r for r in rows if r.get("status") in ("approved", "rejected")]
    reviewed.sort(key=lambda r: r.get("reviewed_at", ""), reverse=True)
    return DataCleaningApprovalListResponse(
        approvals=[_approval_to_out(r) for r in reviewed[:limit]],
        total=len(reviewed),
    )

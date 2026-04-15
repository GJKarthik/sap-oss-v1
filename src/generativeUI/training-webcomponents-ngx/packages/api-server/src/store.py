"""
Unified persistence store — all tables live on whatever engine ``database.py``
resolved (HANA Cloud or SQLite).

The raw ``hdbcli`` TM fallback has been removed; translation-memory now uses
the same SQLAlchemy engine as every other table.
"""

from __future__ import annotations

import logging
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Literal, Optional

log = logging.getLogger(__name__)

from sqlalchemy import Boolean, Column, DateTime, Float, Integer, JSON, String, Text

from .database import Base, SessionLocal, db_backend_label

StoreCollection = Literal["jobs", "vector_stores", "translation_memory"]


def _utc_now_naive() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)

# ---------------------------------------------------------------------------
# ORM Models  (HANA-compatible: NVARCHAR PKs ≤256, TEXT for large values)
# ---------------------------------------------------------------------------


class JobRecord(Base):
    __tablename__ = "jobs"
    id = Column(String(256), primary_key=True, index=True)
    status = Column(String(64), default="pending")
    progress = Column(Float, default=0.0)
    config = Column(JSON, default={})
    error = Column(Text, nullable=True)
    history = Column(JSON, default=list)
    evaluation = Column(JSON, nullable=True)
    deployed = Column(Boolean, default=False)
    created_at = Column(DateTime, default=_utc_now_naive)


class VectorStoreRecord(Base):
    __tablename__ = "vector_stores"
    table_name = Column(String(256), primary_key=True, index=True)
    embedding_model = Column(String(256), default="default")
    documents_added = Column(Float, default=0)
    created_at = Column(DateTime, default=_utc_now_naive)


class TranslationMemoryRecord(Base):
    __tablename__ = "translation_memory"
    id = Column(String(256), primary_key=True, index=True)
    source_text = Column(Text, index=True)
    target_text = Column(Text)
    source_lang = Column(String(5))
    target_lang = Column(String(5))
    category = Column(String(128), default="general")
    is_approved = Column(Boolean, default=False)
    created_at = Column(DateTime, default=_utc_now_naive)
    updated_at = Column(DateTime, default=_utc_now_naive)


class WorkspaceSettingsRecord(Base):
    __tablename__ = "workspace_settings"
    owner_id = Column(String(256), primary_key=True, index=True)
    settings = Column(JSON, default=dict)
    identity_email = Column(String(320), nullable=True)
    identity_display_name = Column(String(256), nullable=True)
    auth_source = Column(String(64), nullable=True)
    created_at = Column(DateTime, default=_utc_now_naive)
    updated_at = Column(DateTime, default=_utc_now_naive, onupdate=_utc_now_naive)


class NotificationRecord(Base):
    __tablename__ = "notifications"
    id = Column(String(256), primary_key=True, index=True)
    user_id = Column(String(256), index=True, nullable=False)
    icon = Column(String(128), default="message-information")
    title = Column(String(512), nullable=False)
    description = Column(Text, default="")
    severity = Column(String(32), default="info")
    read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=_utc_now_naive)


class UserRecord(Base):
    __tablename__ = "users"
    id = Column(String(256), primary_key=True, index=True)
    email = Column(String(320), unique=True, index=True, nullable=False)
    display_name = Column(String(256), nullable=False)
    initials = Column(String(4), default="")
    team_name = Column(String(256), default="")
    avatar_url = Column(Text, nullable=True)
    role = Column(String(64), default="user")
    password_hash = Column(String(256), nullable=False)
    auth_source = Column(String(64), default="local")
    last_login_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=_utc_now_naive)
    updated_at = Column(DateTime, default=_utc_now_naive, onupdate=_utc_now_naive)


class AuditLogRecord(Base):
    """Durable sink for GenUI governance batches (POST /audit/batch)."""

    __tablename__ = "audit_log"
    id = Column(String(256), primary_key=True, index=True)
    user_id = Column(String(256), index=True, nullable=True)
    created_at = Column(DateTime, default=_utc_now_naive)
    record = Column(JSON, nullable=False)


class TrainingRunRecord(Base):
    __tablename__ = "training_runs"
    id = Column(String(256), primary_key=True, index=True)
    workflow_type = Column(String(64), index=True, nullable=False)
    use_case_family = Column(String(128), default="training")
    team = Column(String(256), default="")
    requested_by = Column(String(256), index=True, default="system")
    run_name = Column(String(512), default="")
    model_name = Column(String(512), nullable=True)
    dataset_ref = Column(String(512), nullable=True)
    job_id = Column(String(256), nullable=True, index=True)
    config_json = Column(JSON, default=dict)
    risk_tier = Column(String(32), default="medium")
    risk_score = Column(Float, default=50.0)
    approval_status = Column(String(32), default="not_required")
    gate_status = Column(String(32), default="draft")
    status = Column(String(32), default="draft")
    tag = Column(String(128), nullable=True)
    blocking_checks = Column(JSON, default=list)
    created_at = Column(DateTime, default=_utc_now_naive)
    updated_at = Column(DateTime, default=_utc_now_naive, onupdate=_utc_now_naive)
    submitted_at = Column(DateTime, nullable=True)
    launched_at = Column(DateTime, nullable=True)
    completed_at = Column(DateTime, nullable=True)


class TrainingPolicyRecord(Base):
    __tablename__ = "training_policies"
    id = Column(String(256), primary_key=True, index=True)
    name = Column(String(256), nullable=False)
    description = Column(Text, default="")
    workflow_type = Column(String(64), nullable=True)
    rule_type = Column(String(64), nullable=False)
    enabled = Column(Boolean, default=True)
    severity = Column(String(32), default="medium")
    condition_json = Column(JSON, default=dict)
    created_at = Column(DateTime, default=_utc_now_naive)
    updated_at = Column(DateTime, default=_utc_now_naive, onupdate=_utc_now_naive)


class TrainingApprovalRecord(Base):
    __tablename__ = "training_approvals"
    id = Column(String(256), primary_key=True, index=True)
    run_id = Column(String(256), index=True, nullable=False)
    workflow_type = Column(String(64), index=True, nullable=False)
    title = Column(String(512), nullable=False)
    description = Column(Text, default="")
    risk_level = Column(String(32), default="medium")
    requested_by = Column(String(256), default="system")
    approvers = Column(JSON, default=list)
    status = Column(String(32), default="pending")
    created_at = Column(DateTime, default=_utc_now_naive)
    updated_at = Column(DateTime, default=_utc_now_naive, onupdate=_utc_now_naive)


class TrainingApprovalDecisionRecord(Base):
    __tablename__ = "training_approval_decisions"
    id = Column(String(256), primary_key=True, index=True)
    approval_id = Column(String(256), index=True, nullable=False)
    approver = Column(String(256), nullable=False)
    action = Column(String(32), nullable=False)
    comment = Column(Text, default="")
    decided_at = Column(DateTime, default=_utc_now_naive)


class TrainingGateCheckRecord(Base):
    __tablename__ = "training_gate_checks"
    id = Column(String(256), primary_key=True, index=True)
    run_id = Column(String(256), index=True, nullable=False)
    gate_key = Column(String(128), nullable=False)
    category = Column(String(64), nullable=False)
    status = Column(String(32), nullable=False)
    detail = Column(Text, default="")
    blocking = Column(Boolean, default=True)
    current_value = Column(Float, nullable=True)
    threshold_min = Column(Float, nullable=True)
    threshold_max = Column(Float, nullable=True)
    metadata_json = Column(JSON, default=dict)
    created_at = Column(DateTime, default=_utc_now_naive)
    updated_at = Column(DateTime, default=_utc_now_naive, onupdate=_utc_now_naive)


class TrainingMetricSnapshotRecord(Base):
    __tablename__ = "training_metric_snapshots"
    id = Column(String(256), primary_key=True, index=True)
    run_id = Column(String(256), index=True, nullable=False)
    workflow_type = Column(String(64), index=True, nullable=False)
    team = Column(String(256), default="")
    metric_key = Column(String(128), index=True, nullable=False)
    stage = Column(String(64), default="runtime")
    value = Column(Float, nullable=False)
    unit = Column(String(64), default="ratio")
    numerator = Column(Float, nullable=True)
    denominator = Column(Float, nullable=True)
    threshold_min = Column(Float, nullable=True)
    threshold_max = Column(Float, nullable=True)
    passed = Column(Boolean, default=False)
    metadata_json = Column(JSON, default=dict)
    created_at = Column(DateTime, default=_utc_now_naive)


class TrainingArtifactRecord(Base):
    __tablename__ = "training_artifacts"
    id = Column(String(256), primary_key=True, index=True)
    run_id = Column(String(256), index=True, nullable=False)
    artifact_type = Column(String(128), nullable=False)
    artifact_ref = Column(Text, nullable=False)
    metadata_json = Column(JSON, default=dict)
    created_at = Column(DateTime, default=_utc_now_naive)


# ---------------------------------------------------------------------------
# Store — high-level data-access façade
# ---------------------------------------------------------------------------


class Store:
    def __init__(self):
        self.SessionLocal = SessionLocal

    def db_backend(self) -> str:
        return db_backend_label()

    # ---- Health ------------------------------------------------------------

    def health_snapshot(self) -> Dict[str, Any]:
        return {
            "status": "healthy",
            "db_backend": self.db_backend(),
            "db_active": True,
            "jobs_count": self._count(JobRecord),
            "vector_stores_count": self._count(VectorStoreRecord),
            "tm_count": self._count(TranslationMemoryRecord),
            "users_count": self._count(UserRecord),
            "notifications_count": self._count(NotificationRecord),
            "audit_log_count": self._count(AuditLogRecord),
        }

    def _count(self, model) -> int:
        db = self.SessionLocal()
        try:
            return db.query(model).count()
        finally:
            db.close()

    # ---- Collection helpers ------------------------------------------------

    def list_collection(self, collection: StoreCollection) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            if collection == "jobs":
                return [self._job_to_dict(j) for j in db.query(JobRecord).all()]
            if collection == "vector_stores":
                return [self._store_to_dict(s) for s in db.query(VectorStoreRecord).all()]
            if collection == "translation_memory":
                return [self._tm_to_dict(t) for t in db.query(TranslationMemoryRecord).all()]
            return []
        finally:
            db.close()

    def clear_collection(self, collection: StoreCollection):
        db = self.SessionLocal()
        try:
            if collection == "jobs":
                db.query(JobRecord).delete()
            elif collection == "vector_stores":
                db.query(VectorStoreRecord).delete()
            elif collection == "translation_memory":
                db.query(TranslationMemoryRecord).delete()
            db.commit()
        finally:
            db.close()

    def restore_item(self, collection: StoreCollection, item: Dict[str, Any]):
        db = self.SessionLocal()
        try:
            if collection == "jobs":
                job = JobRecord(**item)
                if isinstance(job.created_at, str):
                    job.created_at = datetime.fromisoformat(job.created_at.replace("Z", ""))
                db.merge(job)
            db.commit()
        finally:
            db.close()

    # ---- Vector stores -----------------------------------------------------

    def get_vector_store(self, table_name: str) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            s = db.query(VectorStoreRecord).filter(VectorStoreRecord.table_name == table_name).first()
            return self._store_to_dict(s) if s else None
        finally:
            db.close()

    def create_vector_store(self, table_name: str, embedding_model: str) -> Dict[str, Any]:
        db = self.SessionLocal()
        try:
            s = VectorStoreRecord(table_name=table_name, embedding_model=embedding_model)
            db.add(s)
            db.commit()
            db.refresh(s)
            return self._store_to_dict(s)
        finally:
            db.close()

    def increment_docs(self, table_name: str, count: int):
        db = self.SessionLocal()
        try:
            s = db.query(VectorStoreRecord).filter(VectorStoreRecord.table_name == table_name).first()
            if s:
                s.documents_added += count
                db.commit()
        finally:
            db.close()

    # ---- Translation memory ------------------------------------------------

    def save_tm_entry(self, entry_data: Dict[str, Any]) -> Dict[str, Any]:
        db = self.SessionLocal()
        try:
            tm_id = entry_data.get("id") or str(uuid.uuid4())
            tm = db.query(TranslationMemoryRecord).filter(TranslationMemoryRecord.id == tm_id).first()
            if not tm:
                tm = TranslationMemoryRecord(id=tm_id)
                db.add(tm)

            tm.source_text = entry_data["source_text"]
            tm.target_text = entry_data["target_text"]
            tm.source_lang = entry_data["source_lang"]
            tm.target_lang = entry_data["target_lang"]
            tm.category = entry_data.get("category", "general")
            tm.is_approved = entry_data.get("is_approved", False)
            tm.updated_at = _utc_now_naive()

            db.commit()
            db.refresh(tm)
            return self._tm_to_dict(tm)
        finally:
            db.close()

    def delete_tm_entry(self, entry_id: str) -> None:
        db = self.SessionLocal()
        try:
            entry = db.query(TranslationMemoryRecord).filter(TranslationMemoryRecord.id == entry_id).first()
            if entry:
                db.delete(entry)
                db.commit()
        finally:
            db.close()

    # ---- Notifications -----------------------------------------------------

    def list_notifications(self, user_id: str, *, limit: int = 50) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            q = (
                db.query(NotificationRecord)
                .filter(NotificationRecord.user_id == user_id)
                .order_by(NotificationRecord.created_at.desc())
                .limit(limit)
            )
            return [self._notification_to_dict(n) for n in q.all()]
        finally:
            db.close()

    def unread_count(self, user_id: str) -> int:
        db = self.SessionLocal()
        try:
            return (
                db.query(NotificationRecord)
                .filter(NotificationRecord.user_id == user_id, NotificationRecord.read == False)  # noqa: E712
                .count()
            )
        finally:
            db.close()

    def create_notification(self, data: Dict[str, Any]) -> Dict[str, Any]:
        db = self.SessionLocal()
        try:
            record = NotificationRecord(
                id=data.get("id") or str(uuid.uuid4()),
                user_id=data["user_id"],
                icon=data.get("icon", "message-information"),
                title=data["title"],
                description=data.get("description", ""),
                severity=data.get("severity", "info"),
            )
            db.add(record)
            db.commit()
            db.refresh(record)
            return self._notification_to_dict(record)
        finally:
            db.close()

    def mark_notification_read(self, notification_id: str, user_id: str) -> bool:
        db = self.SessionLocal()
        try:
            n = (
                db.query(NotificationRecord)
                .filter(NotificationRecord.id == notification_id, NotificationRecord.user_id == user_id)
                .first()
            )
            if not n:
                return False
            n.read = True
            db.commit()
            return True
        finally:
            db.close()

    def mark_all_read(self, user_id: str) -> int:
        db = self.SessionLocal()
        try:
            count = (
                db.query(NotificationRecord)
                .filter(NotificationRecord.user_id == user_id, NotificationRecord.read == False)  # noqa: E712
                .update({"read": True})
            )
            db.commit()
            return count
        finally:
            db.close()

    # ---- Users -------------------------------------------------------------

    def get_user_by_email(self, email: str, *, include_hash: bool = False) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            u = db.query(UserRecord).filter(UserRecord.email == email).first()
            if not u:
                return None
            d = self._user_to_dict(u)
            if include_hash:
                d["_password_hash"] = u.password_hash
            return d
        finally:
            db.close()

    def get_user_by_id(self, user_id: str) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            u = db.query(UserRecord).filter(UserRecord.id == user_id).first()
            return self._user_to_dict(u) if u else None
        finally:
            db.close()

    def create_user(self, data: Dict[str, Any]) -> Dict[str, Any]:
        db = self.SessionLocal()
        try:
            user = UserRecord(
                id=data.get("id") or str(uuid.uuid4()),
                email=data["email"],
                display_name=data["display_name"],
                initials=data.get("initials", _derive_initials(data["display_name"])),
                team_name=data.get("team_name", ""),
                avatar_url=data.get("avatar_url"),
                role=data.get("role", "user"),
                password_hash=data["password_hash"],
                auth_source=data.get("auth_source", "local"),
            )
            db.add(user)
            db.commit()
            db.refresh(user)
            return self._user_to_dict(user)
        finally:
            db.close()

    def update_user_login(self, user_id: str) -> None:
        db = self.SessionLocal()
        try:
            u = db.query(UserRecord).filter(UserRecord.id == user_id).first()
            if u:
                u.last_login_at = _utc_now_naive()
                db.commit()
        finally:
            db.close()

    def list_users(self, *, limit: int = 100) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            return [self._user_to_dict(u) for u in db.query(UserRecord).limit(limit).all()]
        finally:
            db.close()

    def insert_audit_batch(self, records: List[Dict[str, Any]]) -> int:
        """Persist GenUI governance audit rows (each dict is one PersistedAuditEntry-shaped object)."""
        db = self.SessionLocal()
        try:
            for rec in records:
                uid = str(rec.get("userId") or "").strip() or None
                row = AuditLogRecord(
                    id=str(uuid.uuid4()),
                    user_id=uid,
                    record=rec,
                )
                db.add(row)
            db.commit()
            return len(records)
        finally:
            db.close()

    def list_audit_entries(self, *, run_id: Optional[str] = None, limit: int = 500) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            rows = (
                db.query(AuditLogRecord)
                .order_by(AuditLogRecord.created_at.desc())
                .limit(limit)
                .all()
            )
            entries: List[Dict[str, Any]] = []
            for row in rows:
                record = row.record or {}
                if run_id and record.get("run_id") != run_id:
                    continue
                entries.append(
                    {
                        "id": row.id,
                        "user_id": row.user_id,
                        "created_at": row.created_at.isoformat() + "Z" if row.created_at else None,
                        "record": record,
                    }
                )
            return entries
        finally:
            db.close()

    # ---- Training governance ----------------------------------------------

    def ensure_training_governance_defaults(self, policies: List[Dict[str, Any]]) -> None:
        db = self.SessionLocal()
        try:
            for policy in policies:
                row = db.query(TrainingPolicyRecord).filter(TrainingPolicyRecord.id == policy["id"]).first()
                if not row:
                    row = TrainingPolicyRecord(id=policy["id"])
                    db.add(row)
                row.name = policy["name"]
                row.description = policy.get("description", "")
                row.workflow_type = policy.get("workflow_type")
                row.rule_type = policy.get("rule_type", "approval")
                row.enabled = policy.get("enabled", True)
                row.severity = policy.get("severity", "medium")
                row.condition_json = policy.get("condition_json", {})
                row.updated_at = _utc_now_naive()
            db.commit()
        finally:
            db.close()

    def create_training_run(self, data: Dict[str, Any]) -> Dict[str, Any]:
        db = self.SessionLocal()
        try:
            row = TrainingRunRecord(
                id=data.get("id") or str(uuid.uuid4()),
                workflow_type=data["workflow_type"],
                use_case_family=data.get("use_case_family", "training"),
                team=data.get("team", ""),
                requested_by=data.get("requested_by", "system"),
                run_name=data.get("run_name", ""),
                model_name=data.get("model_name"),
                dataset_ref=data.get("dataset_ref"),
                job_id=data.get("job_id"),
                config_json=data.get("config_json", {}),
                risk_tier=data.get("risk_tier", "medium"),
                risk_score=float(data.get("risk_score", 50.0)),
                approval_status=data.get("approval_status", "not_required"),
                gate_status=data.get("gate_status", "draft"),
                status=data.get("status", "draft"),
                tag=data.get("tag"),
                blocking_checks=data.get("blocking_checks", []),
                submitted_at=data.get("submitted_at"),
                launched_at=data.get("launched_at"),
                completed_at=data.get("completed_at"),
            )
            db.add(row)
            db.commit()
            db.refresh(row)
            return self._training_run_to_dict(row)
        finally:
            db.close()

    def get_training_run(self, run_id: str) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            row = db.query(TrainingRunRecord).filter(TrainingRunRecord.id == run_id).first()
            return self._training_run_to_dict(row) if row else None
        finally:
            db.close()

    def get_training_run_for_job(self, job_id: str) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            row = (
                db.query(TrainingRunRecord)
                .filter(TrainingRunRecord.job_id == job_id)
                .order_by(TrainingRunRecord.created_at.desc())
                .first()
            )
            return self._training_run_to_dict(row) if row else None
        finally:
            db.close()

    def list_training_runs(
        self,
        *,
        workflow_type: Optional[str] = None,
        status: Optional[str] = None,
        risk_tier: Optional[str] = None,
        team: Optional[str] = None,
        requested_by: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            query = db.query(TrainingRunRecord)
            if workflow_type:
                query = query.filter(TrainingRunRecord.workflow_type == workflow_type)
            if status:
                query = query.filter(TrainingRunRecord.status == status)
            if risk_tier:
                query = query.filter(TrainingRunRecord.risk_tier == risk_tier)
            if team:
                query = query.filter(TrainingRunRecord.team == team)
            if requested_by:
                query = query.filter(TrainingRunRecord.requested_by == requested_by)
            rows = query.order_by(TrainingRunRecord.created_at.desc()).all()
            return [self._training_run_to_dict(row) for row in rows]
        finally:
            db.close()

    def update_training_run(self, run_id: str, updates: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            row = db.query(TrainingRunRecord).filter(TrainingRunRecord.id == run_id).first()
            if not row:
                return None
            for key, value in updates.items():
                if key == "config_json":
                    row.config_json = value or {}
                elif key == "blocking_checks":
                    row.blocking_checks = value or []
                elif hasattr(row, key):
                    setattr(row, key, value)
            row.updated_at = _utc_now_naive()
            db.commit()
            db.refresh(row)
            return self._training_run_to_dict(row)
        finally:
            db.close()

    def list_training_policies(self, *, workflow_type: Optional[str] = None) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            query = db.query(TrainingPolicyRecord)
            if workflow_type:
                query = query.filter(
                    (TrainingPolicyRecord.workflow_type == workflow_type)
                    | (TrainingPolicyRecord.workflow_type.is_(None))
                )
            rows = query.order_by(TrainingPolicyRecord.name.asc()).all()
            return [self._training_policy_to_dict(row) for row in rows]
        finally:
            db.close()

    def update_training_policy(self, policy_id: str, updates: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            row = db.query(TrainingPolicyRecord).filter(TrainingPolicyRecord.id == policy_id).first()
            if not row:
                return None
            for key, value in updates.items():
                if key == "condition_json":
                    row.condition_json = value or {}
                elif hasattr(row, key):
                    setattr(row, key, value)
            row.updated_at = _utc_now_naive()
            db.commit()
            db.refresh(row)
            return self._training_policy_to_dict(row)
        finally:
            db.close()

    def create_training_approval(self, data: Dict[str, Any]) -> Dict[str, Any]:
        db = self.SessionLocal()
        try:
            row = TrainingApprovalRecord(
                id=data.get("id") or str(uuid.uuid4()),
                run_id=data["run_id"],
                workflow_type=data["workflow_type"],
                title=data["title"],
                description=data.get("description", ""),
                risk_level=data.get("risk_level", "medium"),
                requested_by=data.get("requested_by", "system"),
                approvers=data.get("approvers", []),
                status=data.get("status", "pending"),
            )
            db.add(row)
            db.commit()
            db.refresh(row)
            return self._training_approval_to_dict(row, [])
        finally:
            db.close()

    def get_training_approval(self, approval_id: str) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            row = db.query(TrainingApprovalRecord).filter(TrainingApprovalRecord.id == approval_id).first()
            if not row:
                return None
            decisions = (
                db.query(TrainingApprovalDecisionRecord)
                .filter(TrainingApprovalDecisionRecord.approval_id == approval_id)
                .order_by(TrainingApprovalDecisionRecord.decided_at.asc())
                .all()
            )
            return self._training_approval_to_dict(row, decisions)
        finally:
            db.close()

    def get_training_approval_for_run(self, run_id: str) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            row = (
                db.query(TrainingApprovalRecord)
                .filter(TrainingApprovalRecord.run_id == run_id)
                .order_by(TrainingApprovalRecord.created_at.desc())
                .first()
            )
            if not row:
                return None
            decisions = (
                db.query(TrainingApprovalDecisionRecord)
                .filter(TrainingApprovalDecisionRecord.approval_id == row.id)
                .order_by(TrainingApprovalDecisionRecord.decided_at.asc())
                .all()
            )
            return self._training_approval_to_dict(row, decisions)
        finally:
            db.close()

    def list_training_approvals(
        self,
        *,
        status: Optional[str] = None,
        risk_level: Optional[str] = None,
        workflow_type: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            query = db.query(TrainingApprovalRecord)
            if status:
                query = query.filter(TrainingApprovalRecord.status == status)
            if risk_level:
                query = query.filter(TrainingApprovalRecord.risk_level == risk_level)
            if workflow_type:
                query = query.filter(TrainingApprovalRecord.workflow_type == workflow_type)
            rows = query.order_by(TrainingApprovalRecord.created_at.desc()).all()
            decisions = db.query(TrainingApprovalDecisionRecord).all()
            by_approval: Dict[str, List[TrainingApprovalDecisionRecord]] = {}
            for decision in decisions:
                by_approval.setdefault(decision.approval_id, []).append(decision)
            return [self._training_approval_to_dict(row, by_approval.get(row.id, [])) for row in rows]
        finally:
            db.close()

    def add_training_approval_decision(
        self,
        approval_id: str,
        *,
        approver: str,
        action: str,
        comment: str = "",
    ) -> Optional[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            row = db.query(TrainingApprovalRecord).filter(TrainingApprovalRecord.id == approval_id).first()
            if not row:
                return None
            decision = TrainingApprovalDecisionRecord(
                id=str(uuid.uuid4()),
                approval_id=approval_id,
                approver=approver,
                action=action,
                comment=comment,
            )
            db.add(decision)
            db.flush()

            decisions = (
                db.query(TrainingApprovalDecisionRecord)
                .filter(TrainingApprovalDecisionRecord.approval_id == approval_id)
                .order_by(TrainingApprovalDecisionRecord.decided_at.asc())
                .all()
            )
            decided_by = {entry.approver for entry in decisions}
            required = set(row.approvers or [])
            if any(entry.action == "reject" for entry in decisions):
                row.status = "rejected"
            elif required and required.issubset(decided_by):
                row.status = "approved"
            else:
                row.status = "pending"
            row.updated_at = _utc_now_naive()
            db.commit()
            return self._training_approval_to_dict(row, decisions)
        finally:
            db.close()

    def replace_training_gate_checks(self, run_id: str, checks: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            db.query(TrainingGateCheckRecord).filter(TrainingGateCheckRecord.run_id == run_id).delete()
            for check in checks:
                row = TrainingGateCheckRecord(
                    id=str(uuid.uuid4()),
                    run_id=run_id,
                    gate_key=check["gate_key"],
                    category=check.get("category", "control"),
                    status=check.get("status", "pending"),
                    detail=check.get("detail", ""),
                    blocking=bool(check.get("blocking", True)),
                    current_value=check.get("current_value"),
                    threshold_min=check.get("threshold_min"),
                    threshold_max=check.get("threshold_max"),
                    metadata_json=check.get("metadata_json", {}),
                )
                db.add(row)
            db.commit()
            rows = (
                db.query(TrainingGateCheckRecord)
                .filter(TrainingGateCheckRecord.run_id == run_id)
                .order_by(TrainingGateCheckRecord.category.asc(), TrainingGateCheckRecord.gate_key.asc())
                .all()
            )
            return [self._training_gate_check_to_dict(row) for row in rows]
        finally:
            db.close()

    def list_training_gate_checks(self, run_id: str) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            rows = (
                db.query(TrainingGateCheckRecord)
                .filter(TrainingGateCheckRecord.run_id == run_id)
                .order_by(TrainingGateCheckRecord.category.asc(), TrainingGateCheckRecord.gate_key.asc())
                .all()
            )
            return [self._training_gate_check_to_dict(row) for row in rows]
        finally:
            db.close()

    def replace_training_metric_snapshots(self, run_id: str, metrics: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            db.query(TrainingMetricSnapshotRecord).filter(TrainingMetricSnapshotRecord.run_id == run_id).delete()
            for metric in metrics:
                row = TrainingMetricSnapshotRecord(
                    id=str(uuid.uuid4()),
                    run_id=run_id,
                    workflow_type=metric.get("workflow_type", "training"),
                    team=metric.get("team", ""),
                    metric_key=metric["metric_key"],
                    stage=metric.get("stage", "runtime"),
                    value=float(metric.get("value", 0.0)),
                    unit=metric.get("unit", "ratio"),
                    numerator=metric.get("numerator"),
                    denominator=metric.get("denominator"),
                    threshold_min=metric.get("threshold_min"),
                    threshold_max=metric.get("threshold_max"),
                    passed=bool(metric.get("passed", False)),
                    metadata_json=metric.get("metadata_json", {}),
                )
                db.add(row)
            db.commit()
            rows = (
                db.query(TrainingMetricSnapshotRecord)
                .filter(TrainingMetricSnapshotRecord.run_id == run_id)
                .order_by(TrainingMetricSnapshotRecord.metric_key.asc())
                .all()
            )
            return [self._training_metric_snapshot_to_dict(row) for row in rows]
        finally:
            db.close()

    def list_training_metric_snapshots(
        self,
        *,
        run_id: Optional[str] = None,
        workflow_type: Optional[str] = None,
        team: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            query = db.query(TrainingMetricSnapshotRecord)
            if run_id:
                query = query.filter(TrainingMetricSnapshotRecord.run_id == run_id)
            if workflow_type:
                query = query.filter(TrainingMetricSnapshotRecord.workflow_type == workflow_type)
            if team:
                query = query.filter(TrainingMetricSnapshotRecord.team == team)
            rows = query.order_by(TrainingMetricSnapshotRecord.created_at.desc()).all()
            return [self._training_metric_snapshot_to_dict(row) for row in rows]
        finally:
            db.close()

    def replace_training_artifacts(self, run_id: str, artifacts: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            db.query(TrainingArtifactRecord).filter(TrainingArtifactRecord.run_id == run_id).delete()
            for artifact in artifacts:
                row = TrainingArtifactRecord(
                    id=str(uuid.uuid4()),
                    run_id=run_id,
                    artifact_type=artifact["artifact_type"],
                    artifact_ref=artifact["artifact_ref"],
                    metadata_json=artifact.get("metadata_json", {}),
                )
                db.add(row)
            db.commit()
            rows = (
                db.query(TrainingArtifactRecord)
                .filter(TrainingArtifactRecord.run_id == run_id)
                .order_by(TrainingArtifactRecord.created_at.asc())
                .all()
            )
            return [self._training_artifact_to_dict(row) for row in rows]
        finally:
            db.close()

    def list_training_artifacts(self, run_id: str) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            rows = (
                db.query(TrainingArtifactRecord)
                .filter(TrainingArtifactRecord.run_id == run_id)
                .order_by(TrainingArtifactRecord.created_at.asc())
                .all()
            )
            return [self._training_artifact_to_dict(row) for row in rows]
        finally:
            db.close()

    def get_governance_summary_for_job(self, job_id: str) -> Optional[Dict[str, Any]]:
        run = self.get_training_run_for_job(job_id)
        if not run:
            return None
        checks = self.list_training_gate_checks(run["id"])
        blocking = [check for check in checks if check["blocking"] and check["status"] != "passed"]
        return {
            "run_id": run["id"],
            "workflow_type": run["workflow_type"],
            "tag": run.get("tag"),
            "risk_tier": run["risk_tier"],
            "approval_status": run["approval_status"],
            "gate_status": run["gate_status"],
            "blocking_checks": [
                {
                    "gate_key": check["gate_key"],
                    "category": check["category"],
                    "detail": check["detail"],
                    "status": check["status"],
                }
                for check in blocking
            ],
        }

    # ---- Serializers -------------------------------------------------------

    @staticmethod
    def _job_to_dict(job: JobRecord) -> Dict[str, Any]:
        return {
            "id": job.id,
            "status": job.status,
            "progress": job.progress,
            "config": job.config,
            "error": job.error,
            "history": job.history,
            "evaluation": job.evaluation,
            "deployed": job.deployed,
            "created_at": job.created_at.isoformat() + "Z" if job.created_at else None,
        }

    @staticmethod
    def _store_to_dict(s: VectorStoreRecord) -> Dict[str, Any]:
        return {
            "table_name": s.table_name,
            "embedding_model": s.embedding_model,
            "documents_added": int(s.documents_added),
            "created_at": s.created_at.isoformat() + "Z" if s.created_at else None,
        }

    @staticmethod
    def _tm_to_dict(t: TranslationMemoryRecord) -> Dict[str, Any]:
        return {
            "id": t.id,
            "source_text": t.source_text,
            "target_text": t.target_text,
            "source_lang": t.source_lang,
            "target_lang": t.target_lang,
            "category": t.category,
            "is_approved": t.is_approved,
            "created_at": t.created_at.isoformat() + "Z" if t.created_at else None,
            "updated_at": t.updated_at.isoformat() + "Z" if t.updated_at else None,
        }

    @staticmethod
    def _notification_to_dict(n: NotificationRecord) -> Dict[str, Any]:
        return {
            "id": n.id,
            "user_id": n.user_id,
            "icon": n.icon,
            "title": n.title,
            "description": n.description,
            "severity": n.severity,
            "read": n.read,
            "created_at": n.created_at.isoformat() + "Z" if n.created_at else None,
        }

    @staticmethod
    def _user_to_dict(u: UserRecord) -> Dict[str, Any]:
        return {
            "id": u.id,
            "email": u.email,
            "display_name": u.display_name,
            "initials": u.initials,
            "team_name": u.team_name,
            "avatar_url": u.avatar_url,
            "role": u.role,
            "auth_source": u.auth_source,
            "last_login_at": u.last_login_at.isoformat() + "Z" if u.last_login_at else None,
            "created_at": u.created_at.isoformat() + "Z" if u.created_at else None,
        }

    @staticmethod
    def _training_run_to_dict(row: TrainingRunRecord) -> Dict[str, Any]:
        return {
            "id": row.id,
            "workflow_type": row.workflow_type,
            "use_case_family": row.use_case_family,
            "team": row.team,
            "requested_by": row.requested_by,
            "run_name": row.run_name,
            "model_name": row.model_name,
            "dataset_ref": row.dataset_ref,
            "job_id": row.job_id,
            "config_json": row.config_json or {},
            "risk_tier": row.risk_tier,
            "risk_score": row.risk_score,
            "approval_status": row.approval_status,
            "gate_status": row.gate_status,
            "status": row.status,
            "tag": row.tag,
            "blocking_checks": row.blocking_checks or [],
            "created_at": row.created_at.isoformat() + "Z" if row.created_at else None,
            "updated_at": row.updated_at.isoformat() + "Z" if row.updated_at else None,
            "submitted_at": row.submitted_at.isoformat() + "Z" if row.submitted_at else None,
            "launched_at": row.launched_at.isoformat() + "Z" if row.launched_at else None,
            "completed_at": row.completed_at.isoformat() + "Z" if row.completed_at else None,
        }

    @staticmethod
    def _training_policy_to_dict(row: TrainingPolicyRecord) -> Dict[str, Any]:
        return {
            "id": row.id,
            "name": row.name,
            "description": row.description,
            "workflow_type": row.workflow_type,
            "rule_type": row.rule_type,
            "enabled": row.enabled,
            "severity": row.severity,
            "condition_json": row.condition_json or {},
            "created_at": row.created_at.isoformat() + "Z" if row.created_at else None,
            "updated_at": row.updated_at.isoformat() + "Z" if row.updated_at else None,
        }

    @staticmethod
    def _training_approval_decision_to_dict(row: TrainingApprovalDecisionRecord) -> Dict[str, Any]:
        return {
            "id": row.id,
            "approval_id": row.approval_id,
            "approver": row.approver,
            "action": row.action,
            "comment": row.comment,
            "decided_at": row.decided_at.isoformat() + "Z" if row.decided_at else None,
        }

    @staticmethod
    def _training_approval_to_dict(
        row: TrainingApprovalRecord,
        decisions: List[TrainingApprovalDecisionRecord],
    ) -> Dict[str, Any]:
        return {
            "id": row.id,
            "run_id": row.run_id,
            "workflow_type": row.workflow_type,
            "title": row.title,
            "description": row.description,
            "risk_level": row.risk_level,
            "requested_by": row.requested_by,
            "approvers": row.approvers or [],
            "status": row.status,
            "decisions": [Store._training_approval_decision_to_dict(decision) for decision in decisions],
            "created_at": row.created_at.isoformat() + "Z" if row.created_at else None,
            "updated_at": row.updated_at.isoformat() + "Z" if row.updated_at else None,
        }

    @staticmethod
    def _training_gate_check_to_dict(row: TrainingGateCheckRecord) -> Dict[str, Any]:
        return {
            "id": row.id,
            "run_id": row.run_id,
            "gate_key": row.gate_key,
            "category": row.category,
            "status": row.status,
            "detail": row.detail,
            "blocking": row.blocking,
            "current_value": row.current_value,
            "threshold_min": row.threshold_min,
            "threshold_max": row.threshold_max,
            "metadata_json": row.metadata_json or {},
            "created_at": row.created_at.isoformat() + "Z" if row.created_at else None,
            "updated_at": row.updated_at.isoformat() + "Z" if row.updated_at else None,
        }

    @staticmethod
    def _training_metric_snapshot_to_dict(row: TrainingMetricSnapshotRecord) -> Dict[str, Any]:
        return {
            "id": row.id,
            "run_id": row.run_id,
            "workflow_type": row.workflow_type,
            "team": row.team,
            "metric_key": row.metric_key,
            "stage": row.stage,
            "value": row.value,
            "unit": row.unit,
            "numerator": row.numerator,
            "denominator": row.denominator,
            "threshold_min": row.threshold_min,
            "threshold_max": row.threshold_max,
            "passed": row.passed,
            "metadata_json": row.metadata_json or {},
            "created_at": row.created_at.isoformat() + "Z" if row.created_at else None,
        }

    @staticmethod
    def _training_artifact_to_dict(row: TrainingArtifactRecord) -> Dict[str, Any]:
        return {
            "id": row.id,
            "run_id": row.run_id,
            "artifact_type": row.artifact_type,
            "artifact_ref": row.artifact_ref,
            "metadata_json": row.metadata_json or {},
            "created_at": row.created_at.isoformat() + "Z" if row.created_at else None,
        }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _derive_initials(display_name: str) -> str:
    parts = display_name.strip().split()
    if len(parts) >= 2:
        return (parts[0][0] + parts[-1][0]).upper()
    if parts:
        return parts[0][:2].upper()
    return "??"


_store: Optional[Store] = None

# Idempotent reference rows (same content as first entries in scripts/seed_demo_data.py TM_ENTRIES).
# Fixed IDs so ``save_tm_entry`` updates in place on repeated startup.
_REFERENCE_TM_SEED: tuple[Dict[str, Any], ...] = (
    {
        "id": "seed-tm-1",
        "source_text": "The consolidated balance sheet shows total assets of SAR 1.2 billion.",
        "target_text": "تظهر الميزانية العمومية الموحدة إجمالي أصول بقيمة 1.2 مليار ريال سعودي.",
        "source_lang": "en",
        "target_lang": "ar",
        "category": "treasury",
        "is_approved": True,
    },
    {
        "id": "seed-tm-2",
        "source_text": "Scope 1 and Scope 2 greenhouse gas emissions decreased by 12% year-over-year.",
        "target_text": "انخفضت انبعاثات الغازات الدفيئة للنطاق 1 والنطاق 2 بنسبة 12% على أساس سنوي.",
        "source_lang": "en",
        "target_lang": "ar",
        "category": "esg",
        "is_approved": True,
    },
    {
        "id": "seed-tm-3",
        "source_text": "The hedging effectiveness test resulted in a ratio within the 80-125% corridor.",
        "target_text": "أسفر اختبار فعالية التحوط عن نسبة ضمن نطاق 80-125%.",
        "source_lang": "en",
        "target_lang": "ar",
        "category": "treasury",
        "is_approved": True,
    },
    {
        "id": "seed-tm-4",
        "source_text": "Operating expenses for Q3 exceeded budget by 4.2%, primarily driven by FX losses.",
        "target_text": "تجاوزت المصاريف التشغيلية للربع الثالث الميزانية بنسبة 4.2%، مدفوعة بشكل رئيسي بخسائر صرف العملات.",
        "source_lang": "en",
        "target_lang": "ar",
        "category": "performance",
        "is_approved": True,
    },
    {
        "id": "seed-tm-5",
        "source_text": "Water intensity per unit of revenue improved to 3.8 m³/SAR million.",
        "target_text": "تحسنت كثافة استهلاك المياه لكل وحدة إيرادات إلى 3.8 متر مكعب/مليون ريال سعودي.",
        "source_lang": "en",
        "target_lang": "ar",
        "category": "esg",
        "is_approved": True,
    },
)


def _env_flag(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in ("1", "true", "yes", "on")


def get_store() -> Store:
    global _store
    if _store is None:
        _store = Store()
    return _store


def seed_store(*, force: bool = False) -> None:
    """Load optional, idempotent reference data after :func:`database.init_database`.

    Schema creation and empty tables are handled by ``init_database()`` only; this
    hook adds a small translation-memory baseline when explicitly requested.

    * **Default (API startup):** no rows unless ``SEED_DEMO_DATA`` is truthy
      (``1``, ``true``, ``yes``, ``on``).
    * **Admin CLI:** ``python scripts/store_admin.py migrate --seed`` passes
      ``force=True`` so seeding runs without the env var.
    * **Full demos** (vectorize batch, all TM rows, data-product checks): run
      ``scripts/seed_demo_data.py`` against a running API.

    Safe to call on every process start: rows use stable IDs and ``Store.save_tm_entry``
    merges updates.
    """
    if not force and not _env_flag("SEED_DEMO_DATA"):
        log.debug(
            "seed_store: skipped (set SEED_DEMO_DATA=1 for startup seed, or run "
            "'python scripts/store_admin.py migrate --seed', or use scripts/seed_demo_data.py)"
        )
        return

    store = get_store()
    for row in _REFERENCE_TM_SEED:
        store.save_tm_entry(dict(row))
    log.info("seed_store: ensured %d reference translation-memory row(s)", len(_REFERENCE_TM_SEED))

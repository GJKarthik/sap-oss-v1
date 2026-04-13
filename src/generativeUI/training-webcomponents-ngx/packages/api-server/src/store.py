"""
Unified persistence store — all tables live on whatever engine ``database.py``
resolved (HANA Cloud or SQLite).

The raw ``hdbcli`` TM fallback has been removed; translation-memory now uses
the same SQLAlchemy engine as every other table.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Dict, List, Literal, Optional

from sqlalchemy import Boolean, Column, DateTime, Float, Integer, JSON, String, Text

from .database import Base, SessionLocal, db_backend_label

StoreCollection = Literal["jobs", "vector_stores", "translation_memory"]

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
    created_at = Column(DateTime, default=datetime.utcnow)


class VectorStoreRecord(Base):
    __tablename__ = "vector_stores"
    table_name = Column(String(256), primary_key=True, index=True)
    embedding_model = Column(String(256), default="default")
    documents_added = Column(Float, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)


class TranslationMemoryRecord(Base):
    __tablename__ = "translation_memory"
    id = Column(String(256), primary_key=True, index=True)
    source_text = Column(Text, index=True)
    target_text = Column(Text)
    source_lang = Column(String(5))
    target_lang = Column(String(5))
    category = Column(String(128), default="general")
    is_approved = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow)


class WorkspaceSettingsRecord(Base):
    __tablename__ = "workspace_settings"
    owner_id = Column(String(256), primary_key=True, index=True)
    settings = Column(JSON, default=dict)
    identity_email = Column(String(320), nullable=True)
    identity_display_name = Column(String(256), nullable=True)
    auth_source = Column(String(64), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class NotificationRecord(Base):
    __tablename__ = "notifications"
    id = Column(String(256), primary_key=True, index=True)
    user_id = Column(String(256), index=True, nullable=False)
    icon = Column(String(128), default="message-information")
    title = Column(String(512), nullable=False)
    description = Column(Text, default="")
    severity = Column(String(32), default="info")
    read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)


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
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class AuditLogRecord(Base):
    """Durable sink for GenUI governance batches (POST /audit/batch)."""

    __tablename__ = "audit_log"
    id = Column(String(256), primary_key=True, index=True)
    user_id = Column(String(256), index=True, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    record = Column(JSON, nullable=False)


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
            tm.updated_at = datetime.utcnow()

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
                u.last_login_at = datetime.utcnow()
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


def get_store() -> Store:
    global _store
    if _store is None:
        _store = Store()
    return _store


def seed_store():
    pass

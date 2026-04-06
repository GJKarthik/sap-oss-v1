import os
import uuid
from datetime import datetime
from typing import Any, Dict, List, Literal, Optional

from sqlalchemy import Boolean, Column, DateTime, Float, JSON, String

from .database import Base, SessionLocal

StoreCollection = Literal["jobs", "vector_stores", "translation_memory"]
TranslationMemoryBackend = Literal["sqlite", "hana"]

HANA_HOST = os.getenv("HANA_HOST", "localhost")
HANA_PORT = int(os.getenv("HANA_PORT", "443"))
HANA_USER = os.getenv("HANA_USER", "")
HANA_PASSWORD = os.getenv("HANA_PASSWORD", "")
HANA_ENCRYPT = os.getenv("HANA_ENCRYPT", "true").lower() == "true"
HANA_TM_TABLE = "TRANSLATION_MEMORY"


class JobRecord(Base):
    __tablename__ = "jobs"
    id = Column(String, primary_key=True, index=True)
    status = Column(String, default="pending")
    progress = Column(Float, default=0.0)
    config = Column(JSON, default={})
    error = Column(String, nullable=True)
    history = Column(JSON, default=list)
    evaluation = Column(JSON, nullable=True)
    deployed = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class VectorStoreRecord(Base):
    __tablename__ = "vector_stores"
    table_name = Column(String, primary_key=True, index=True)
    embedding_model = Column(String, default="default")
    documents_added = Column(Float, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)


class TranslationMemoryRecord(Base):
    __tablename__ = "translation_memory"
    id = Column(String, primary_key=True, index=True)
    source_text = Column(String, index=True)
    target_text = Column(String)
    source_lang = Column(String(5))
    target_lang = Column(String(5))
    category = Column(String, default="general")
    is_approved = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow)


class Store:
    def __init__(self):
        self.SessionLocal = SessionLocal

    def translation_memory_backend(self) -> TranslationMemoryBackend:
        if not HANA_USER:
            return "sqlite"
        try:
            import hdbcli.dbapi  # type: ignore  # noqa: F401
        except ImportError:
            return "sqlite"
        return "hana"

    def health_snapshot(self) -> Dict[str, Any]:
        return {
            "status": "healthy",
            "db_active": True,
            "jobs_count": self._count_jobs(),
            "vector_stores_count": self._count_vector_stores(),
            "tm_count": self._count_tm(),
            "translation_memory_backend": self.translation_memory_backend(),
        }

    def _count_jobs(self) -> int:
        db = self.SessionLocal()
        try:
            return db.query(JobRecord).count()
        finally:
            db.close()

    def _count_vector_stores(self) -> int:
        db = self.SessionLocal()
        try:
            return db.query(VectorStoreRecord).count()
        finally:
            db.close()

    def _count_tm(self) -> int:
        if self.translation_memory_backend() == "hana":
            return self._count_tm_hana()

        db = self.SessionLocal()
        try:
            return db.query(TranslationMemoryRecord).count()
        finally:
            db.close()

    def _hana_connection(self):
        import hdbcli.dbapi as hdbcli  # type: ignore

        return hdbcli.connect(
            address=HANA_HOST,
            port=HANA_PORT,
            user=HANA_USER,
            password=HANA_PASSWORD,
            encrypt=HANA_ENCRYPT,
        )

    def _ensure_hana_tm_table(self, cursor) -> None:
        cursor.execute(
            "SELECT COUNT(*) FROM SYS.TABLES WHERE SCHEMA_NAME = CURRENT_SCHEMA AND TABLE_NAME = ?",
            (HANA_TM_TABLE,),
        )
        row = cursor.fetchone()
        if row and int(row[0]) > 0:
            return

        cursor.execute(
            f'''
            CREATE TABLE "{HANA_TM_TABLE}" (
                "ID" NVARCHAR(100) PRIMARY KEY,
                "SOURCE_TEXT" NCLOB,
                "TARGET_TEXT" NCLOB,
                "SOURCE_LANG" NVARCHAR(5),
                "TARGET_LANG" NVARCHAR(5),
                "CATEGORY" NVARCHAR(100),
                "IS_APPROVED" BOOLEAN,
                "CREATED_AT" TIMESTAMP,
                "UPDATED_AT" TIMESTAMP
            )
            '''
        )

    def _tm_row_to_dict(self, row) -> Dict[str, Any]:
        created_at = row[7]
        updated_at = row[8]
        return {
            "id": row[0],
            "source_text": row[1],
            "target_text": row[2],
            "source_lang": row[3],
            "target_lang": row[4],
            "category": row[5],
            "is_approved": bool(row[6]),
            "created_at": created_at.isoformat() + "Z" if created_at else None,
            "updated_at": updated_at.isoformat() + "Z" if updated_at else None,
        }

    def _count_tm_hana(self) -> int:
        conn = self._hana_connection()
        try:
            cursor = conn.cursor()
            self._ensure_hana_tm_table(cursor)
            cursor.execute(f'SELECT COUNT(*) FROM "{HANA_TM_TABLE}"')
            row = cursor.fetchone()
            return int(row[0]) if row else 0
        finally:
            conn.close()

    def _list_tm_hana(self) -> List[Dict[str, Any]]:
        conn = self._hana_connection()
        try:
            cursor = conn.cursor()
            self._ensure_hana_tm_table(cursor)
            cursor.execute(
                f'''
                SELECT
                    "ID",
                    "SOURCE_TEXT",
                    "TARGET_TEXT",
                    "SOURCE_LANG",
                    "TARGET_LANG",
                    "CATEGORY",
                    "IS_APPROVED",
                    "CREATED_AT",
                    "UPDATED_AT"
                FROM "{HANA_TM_TABLE}"
                ORDER BY "UPDATED_AT" DESC, "CREATED_AT" DESC
                '''
            )
            return [self._tm_row_to_dict(row) for row in cursor.fetchall()]
        finally:
            conn.close()

    def _save_tm_entry_hana(self, entry_data: Dict[str, Any]) -> Dict[str, Any]:
        conn = self._hana_connection()
        try:
            cursor = conn.cursor()
            self._ensure_hana_tm_table(cursor)
            now = datetime.utcnow()
            tm_id = entry_data.get("id") or str(uuid.uuid4())

            cursor.execute(
                f'SELECT "CREATED_AT" FROM "{HANA_TM_TABLE}" WHERE "ID" = ?',
                (tm_id,),
            )
            existing = cursor.fetchone()
            created_at = existing[0] if existing else now

            if existing:
                cursor.execute(
                    f'''
                    UPDATE "{HANA_TM_TABLE}"
                    SET
                        "SOURCE_TEXT" = ?,
                        "TARGET_TEXT" = ?,
                        "SOURCE_LANG" = ?,
                        "TARGET_LANG" = ?,
                        "CATEGORY" = ?,
                        "IS_APPROVED" = ?,
                        "UPDATED_AT" = ?
                    WHERE "ID" = ?
                    ''',
                    (
                        entry_data["source_text"],
                        entry_data["target_text"],
                        entry_data["source_lang"],
                        entry_data["target_lang"],
                        entry_data.get("category", "general"),
                        bool(entry_data.get("is_approved", False)),
                        now,
                        tm_id,
                    ),
                )
            else:
                cursor.execute(
                    f'''
                    INSERT INTO "{HANA_TM_TABLE}" (
                        "ID",
                        "SOURCE_TEXT",
                        "TARGET_TEXT",
                        "SOURCE_LANG",
                        "TARGET_LANG",
                        "CATEGORY",
                        "IS_APPROVED",
                        "CREATED_AT",
                        "UPDATED_AT"
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ''',
                    (
                        tm_id,
                        entry_data["source_text"],
                        entry_data["target_text"],
                        entry_data["source_lang"],
                        entry_data["target_lang"],
                        entry_data.get("category", "general"),
                        bool(entry_data.get("is_approved", False)),
                        created_at,
                        now,
                    ),
                )

            conn.commit()
            cursor.execute(
                f'''
                SELECT
                    "ID",
                    "SOURCE_TEXT",
                    "TARGET_TEXT",
                    "SOURCE_LANG",
                    "TARGET_LANG",
                    "CATEGORY",
                    "IS_APPROVED",
                    "CREATED_AT",
                    "UPDATED_AT"
                FROM "{HANA_TM_TABLE}"
                WHERE "ID" = ?
                ''',
                (tm_id,),
            )
            return self._tm_row_to_dict(cursor.fetchone())
        finally:
            conn.close()

    def list_collection(self, collection: StoreCollection) -> List[Dict[str, Any]]:
        if collection == "translation_memory" and self.translation_memory_backend() == "hana":
            return self._list_tm_hana()

        db = self.SessionLocal()
        try:
            if collection == "jobs":
                jobs = db.query(JobRecord).all()
                return [self._to_dict(j) for j in jobs]
            if collection == "vector_stores":
                stores = db.query(VectorStoreRecord).all()
                return [self._store_to_dict(s) for s in stores]
            if collection == "translation_memory":
                tm = db.query(TranslationMemoryRecord).all()
                return [self._tm_to_dict(t) for t in tm]
            return []
        finally:
            db.close()

    def _to_dict(self, job: JobRecord) -> Dict[str, Any]:
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

    def _store_to_dict(self, s: VectorStoreRecord) -> Dict[str, Any]:
        return {
            "table_name": s.table_name,
            "embedding_model": s.embedding_model,
            "documents_added": int(s.documents_added),
            "created_at": s.created_at.isoformat() + "Z" if s.created_at else None,
        }

    def _tm_to_dict(self, t: TranslationMemoryRecord) -> Dict[str, Any]:
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

    def save_tm_entry(self, entry_data: Dict[str, Any]) -> Dict[str, Any]:
        if self.translation_memory_backend() == "hana":
            return self._save_tm_entry_hana(entry_data)

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
        if self.translation_memory_backend() == "hana":
            conn = self._hana_connection()
            try:
                cursor = conn.cursor()
                self._ensure_hana_tm_table(cursor)
                cursor.execute(f'DELETE FROM "{HANA_TM_TABLE}" WHERE "ID" = ?', (entry_id,))
                conn.commit()
            finally:
                conn.close()
            return

        db = self.SessionLocal()
        try:
            entry = db.query(TranslationMemoryRecord).filter(TranslationMemoryRecord.id == entry_id).first()
            if entry:
                db.delete(entry)
                db.commit()
        finally:
            db.close()

    def clear_collection(self, collection: StoreCollection):
        if collection == "translation_memory" and self.translation_memory_backend() == "hana":
            conn = self._hana_connection()
            try:
                cursor = conn.cursor()
                self._ensure_hana_tm_table(cursor)
                cursor.execute(f'DELETE FROM "{HANA_TM_TABLE}"')
                conn.commit()
            finally:
                conn.close()
            return

        db = self.SessionLocal()
        try:
            if collection == "jobs":
                db.query(JobRecord).delete()
            if collection == "vector_stores":
                db.query(VectorStoreRecord).delete()
            if collection == "translation_memory":
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


_store: Optional[Store] = None


def get_store() -> Store:
    global _store
    if _store is None:
        _store = Store()
    return _store


def seed_store():
    # Placeholder for reference data seeding if needed
    pass

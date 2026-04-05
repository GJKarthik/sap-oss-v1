from datetime import datetime
from typing import Optional, List, Dict, Any, Literal
from sqlalchemy import Column, String, Float, JSON, Boolean, DateTime
from .database import Base, SessionLocal

StoreCollection = Literal["jobs", "vector_stores"]

class JobRecord(Base):
    __tablename__ = 'jobs'
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
    __tablename__ = 'vector_stores'
    table_name = Column(String, primary_key=True, index=True)
    embedding_model = Column(String, default="default")
    documents_added = Column(Float, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)

class Store:
    def __init__(self):
        self.SessionLocal = SessionLocal

    def health_snapshot(self) -> Dict[str, Any]:
        return {
            "status": "healthy",
            "db_active": True,
            "jobs_count": self._count_jobs(),
            "vector_stores_count": self._count_vector_stores()
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

    def list_collection(self, collection: StoreCollection) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            if collection == "jobs":
                jobs = db.query(JobRecord).all()
                return [self._to_dict(j) for j in jobs]
            if collection == "vector_stores":
                stores = db.query(VectorStoreRecord).all()
                return [self._store_to_dict(s) for s in stores]
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
            "created_at": job.created_at.isoformat() + "Z" if job.created_at else None
        }

    def _store_to_dict(self, s: VectorStoreRecord) -> Dict[str, Any]:
        return {
            "table_name": s.table_name,
            "embedding_model": s.embedding_model,
            "documents_added": int(s.documents_added),
            "created_at": s.created_at.isoformat() + "Z" if s.created_at else None
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

    def clear_collection(self, collection: StoreCollection):
        db = self.SessionLocal()
        try:
            if collection == "jobs":
                db.query(JobRecord).delete()
            if collection == "vector_stores":
                db.query(VectorStoreRecord).delete()
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
    store = get_store()
    if not store.get_vector_store("ARABIC_FINANCIAL_REPORTS"):
        store.create_vector_store("ARABIC_FINANCIAL_REPORTS", "google-bert/bert-base-multilingual-uncased")

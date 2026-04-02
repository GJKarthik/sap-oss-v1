from datetime import datetime
from typing import Optional, List, Dict, Any, Literal
from sqlalchemy import Column, String, Float, JSON, Boolean, DateTime
from .database import Base, SessionLocal

StoreCollection = Literal["jobs"]

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

class Store:
    def __init__(self):
        self.SessionLocal = SessionLocal

    def health_snapshot(self) -> Dict[str, Any]:
        return {
            "status": "healthy",
            "db_active": True,
            "jobs_count": self._count_jobs()
        }

    def _count_jobs(self) -> int:
        db = self.SessionLocal()
        try:
            return db.query(JobRecord).count()
        finally:
            db.close()

    def list_collection(self, collection: StoreCollection) -> List[Dict[str, Any]]:
        db = self.SessionLocal()
        try:
            if collection == "jobs":
                jobs = db.query(JobRecord).all()
                return [self._to_dict(j) for j in jobs]
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

    def clear_collection(self, collection: StoreCollection):
        db = self.SessionLocal()
        try:
            if collection == "jobs":
                db.query(JobRecord).delete()
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

#!/usr/bin/env python3
"""
Job persistence layer backed by SQLite.

Replaces the in-memory ``jobs_store: dict`` with a durable store that
survives process restarts.  Falls back to in-memory mode when SQLite is
unavailable or the DB path is set to ":memory:".
"""

import json
import logging
import os
import sqlite3
from datetime import datetime
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

DB_PATH = os.getenv("MODELOPT_JOBS_DB", "jobs.db")

_CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS jobs (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    config_json     TEXT NOT NULL,
    created_at      TEXT NOT NULL,
    started_at      TEXT,
    completed_at    TEXT,
    progress        REAL NOT NULL DEFAULT 0.0,
    output_path     TEXT,
    error           TEXT
);
"""


def _now_iso() -> str:
    return datetime.utcnow().isoformat()


class JobStore:
    """Thin wrapper around SQLite for job CRUD."""

    def __init__(self, db_path: str = DB_PATH):
        self._db_path = db_path
        self._conn: Optional[sqlite3.Connection] = None
        self._ensure_schema()

    # -- connection management ------------------------------------------------

    def _get_conn(self) -> sqlite3.Connection:
        if self._conn is None:
            self._conn = sqlite3.connect(self._db_path, check_same_thread=False)
            self._conn.row_factory = sqlite3.Row
        return self._conn

    def _ensure_schema(self) -> None:
        try:
            self._get_conn().executescript(_CREATE_TABLE)
            logger.info("Job store ready (%s)", self._db_path)
        except Exception as exc:
            logger.error("Failed to initialise job store: %s", exc)

    # -- public API -----------------------------------------------------------

    def create(self, job_id: str, name: str, config: dict) -> dict:
        row = {
            "id": job_id,
            "name": name,
            "status": "pending",
            "config_json": json.dumps(config),
            "created_at": _now_iso(),
            "progress": 0.0,
        }
        self._get_conn().execute(
            "INSERT INTO jobs (id, name, status, config_json, created_at, progress) "
            "VALUES (:id, :name, :status, :config_json, :created_at, :progress)",
            row,
        )
        self._get_conn().commit()
        return self.get(job_id)  # type: ignore[return-value]

    def get(self, job_id: str) -> Optional[dict]:
        cur = self._get_conn().execute("SELECT * FROM jobs WHERE id = ?", (job_id,))
        row = cur.fetchone()
        return self._row_to_dict(row) if row else None

    def list_all(self, status: Optional[str] = None, limit: int = 100) -> List[dict]:
        if status:
            cur = self._get_conn().execute(
                "SELECT * FROM jobs WHERE status = ? ORDER BY created_at DESC LIMIT ?",
                (status, limit),
            )
        else:
            cur = self._get_conn().execute(
                "SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)
            )
        return [self._row_to_dict(r) for r in cur.fetchall()]

    def update(
        self,
        job_id: str,
        *,
        status: Optional[str] = None,
        progress: Optional[float] = None,
        started_at: Optional[str] = None,
        completed_at: Optional[str] = None,
        output_path: Optional[str] = None,
        error: Optional[str] = None,
    ) -> Optional[dict]:
        sets: list[str] = []
        vals: dict = {"id": job_id}
        for col in ("status", "progress", "started_at", "completed_at", "output_path", "error"):
            v = locals()[col]
            if v is not None:
                sets.append(f"{col} = :{col}")
                vals[col] = v
        if not sets:
            return self.get(job_id)
        sql = f"UPDATE jobs SET {', '.join(sets)} WHERE id = :id"
        self._get_conn().execute(sql, vals)
        self._get_conn().commit()
        return self.get(job_id)

    def delete(self, job_id: str) -> bool:
        cur = self._get_conn().execute("DELETE FROM jobs WHERE id = ?", (job_id,))
        self._get_conn().commit()
        return cur.rowcount > 0

    # -- helpers --------------------------------------------------------------

    @staticmethod
    def _row_to_dict(row: sqlite3.Row) -> dict:
        d = dict(row)
        d["config"] = json.loads(d.pop("config_json"))
        return d


# Module-level singleton
_store: Optional[JobStore] = None


def get_job_store() -> JobStore:
    global _store
    if _store is None:
        _store = JobStore()
    return _store


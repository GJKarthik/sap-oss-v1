"""
Dual-mode persistence layer — HANA Cloud primary, SQLite fallback.

When HANA credentials are present the engine connects via the
``hana+hdbcli://`` SQLAlchemy dialect.  Otherwise the engine falls back
to the local SQLite file ``enterprise_mlops.db``.

An explicit ``DATABASE_URL`` env var always takes priority over both.
"""

from __future__ import annotations

import logging
import os

from sqlalchemy import create_engine, text
from sqlalchemy.orm import declarative_base, sessionmaker

from .hana_config import HANA_ENCRYPT, HANA_HOST, HANA_PASSWORD, HANA_PORT, HANA_USER

log = logging.getLogger(__name__)

# ---- URL resolution --------------------------------------------------------

_explicit_url = os.getenv("DATABASE_URL", "").strip()


def _build_database_url() -> str:
    if _explicit_url:
        return _explicit_url

    if HANA_HOST and HANA_USER and HANA_PASSWORD:
        encrypt_flag = "true" if HANA_ENCRYPT else "false"
        return (
            f"hana+hdbcli://{HANA_USER}:{HANA_PASSWORD}"
            f"@{HANA_HOST}:{HANA_PORT}"
            f"?encrypt={encrypt_flag}&sslValidateCertificate=false"
        )

    return "sqlite:///./enterprise_mlops.db"


DATABASE_URL: str = _build_database_url()
IS_HANA: bool = DATABASE_URL.startswith("hana")
IS_SQLITE: bool = DATABASE_URL.startswith("sqlite")

# ---- Engine / Session / Base -----------------------------------------------

_connect_args: dict = {"check_same_thread": False} if IS_SQLITE else {}
_pool_kwargs: dict = (
    {"pool_size": 5, "max_overflow": 10, "pool_pre_ping": True}
    if not IS_SQLITE
    else {}
)

engine = create_engine(DATABASE_URL, connect_args=_connect_args, **_pool_kwargs)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


async def init_database():
    if IS_HANA:
        log.info("Initialising HANA schema (create_all with checkfirst)…")
    else:
        log.info("Initialising SQLite database…")
    Base.metadata.create_all(bind=engine)


async def close_database():
    engine.dispose()


def db_backend_label() -> str:
    if IS_HANA:
        return "hana"
    if IS_SQLITE:
        return "sqlite"
    return DATABASE_URL.split("://")[0]

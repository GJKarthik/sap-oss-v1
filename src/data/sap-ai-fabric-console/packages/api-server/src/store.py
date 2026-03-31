"""
Persistent state store abstractions for SAP AI Fabric Console API.
Supports SQLite for local/test usage and SAP HANA Cloud for shared production state.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sqlite3
import threading
from typing import Any, Callable, Dict, Literal

from .config import settings

StoreCollection = Literal[
    "users",
    "models",
    "deployments",
    "datasources",
    "vector_stores",
    "governance_rules",
    "data_cleaning_approvals",
    "genui_sessions",
]

RateLimitResult = Dict[str, int | bool]


class BaseStore(ABC):
    """Shared store contract used by the API routes and lifecycle hooks."""

    backend_name: str = "base"

    @property
    @abstractmethod
    def connection_target(self) -> str:
        """Human-readable connection target for health checks and logs."""

    @property
    def database_path(self) -> Path | None:
        """SQLite stores expose a path; other backends return None."""
        return None

    @abstractmethod
    def initialise(self) -> None:
        """Prepare the backend storage structures if needed."""

    @abstractmethod
    def close(self) -> None:
        """Release backend resources."""

    @abstractmethod
    def snapshot(self, name: StoreCollection) -> Dict[str, Dict[str, Any]]:
        """Return a keyed snapshot of a collection."""

    @abstractmethod
    def list_records(self, name: StoreCollection) -> list[Dict[str, Any]]:
        """Return all records for a collection."""

    @abstractmethod
    def get_record(self, name: StoreCollection, key: str) -> Dict[str, Any] | None:
        """Return a record by key."""

    @abstractmethod
    def has_record(self, name: StoreCollection, key: str) -> bool:
        """Return True when the record exists."""

    @abstractmethod
    def set_record(self, name: StoreCollection, key: str, value: Dict[str, Any]) -> Dict[str, Any]:
        """Insert or replace a record."""

    @abstractmethod
    def delete_record(self, name: StoreCollection, key: str) -> bool:
        """Delete a record and report whether it existed."""

    @abstractmethod
    def mutate_record(
        self,
        name: StoreCollection,
        key: str,
        mutator: Callable[[Dict[str, Any]], Dict[str, Any] | None],
    ) -> Dict[str, Any] | None:
        """Load, mutate, and store a record atomically."""

    @abstractmethod
    def count(self, name: StoreCollection) -> int:
        """Return collection size."""

    @abstractmethod
    def clear(self) -> None:
        """Remove all persisted state."""

    @abstractmethod
    def revoke_jti(self, jti: str, expire_seconds: int) -> None:
        """Persist a revoked token JTI with TTL."""

    @abstractmethod
    def is_jti_revoked(self, jti: str) -> bool:
        """Return True if a token JTI is currently revoked."""

    @abstractmethod
    def consume_rate_limit(self, bucket_key: str, limit: int, window_seconds: int) -> RateLimitResult:
        """Consume a rate-limit token for the given bucket."""

    @abstractmethod
    def health_snapshot(self) -> Dict[str, Any]:
        """Return a backend-specific connectivity snapshot for health probes."""

    @property
    @abstractmethod
    def revoked_jtis(self) -> set[str]:
        """Return the currently non-expired revoked JTIs."""

    def _serialise(self, value: Dict[str, Any]) -> str:
        return json.dumps(value, default=self._json_default)

    def _deserialise(self, payload: str) -> Dict[str, Any]:
        return json.loads(payload)

    @staticmethod
    def _json_default(value: Any) -> str:
        if isinstance(value, datetime):
            return value.isoformat()
        raise TypeError(f"Unsupported type for store serialisation: {type(value)!r}")

    @property
    def users(self) -> Dict[str, Dict[str, Any]]:
        return self.snapshot("users")

    @property
    def models(self) -> Dict[str, Dict[str, Any]]:
        return self.snapshot("models")

    @property
    def deployments(self) -> Dict[str, Dict[str, Any]]:
        return self.snapshot("deployments")

    @property
    def datasources(self) -> Dict[str, Dict[str, Any]]:
        return self.snapshot("datasources")

    @property
    def vector_stores(self) -> Dict[str, Dict[str, Any]]:
        return self.snapshot("vector_stores")

    @property
    def governance_rules(self) -> Dict[str, Dict[str, Any]]:
        return self.snapshot("governance_rules")


class AppStore(BaseStore):
    """Thread-safe wrapper around the persistent SQLite-backed store."""

    backend_name = "sqlite"

    def __init__(self, database_path: str | None = None) -> None:
        self._lock = threading.RLock()
        self._database_path = Path(database_path or settings.store_database_path)
        self._initialised = False

    @property
    def connection_target(self) -> str:
        return str(self._database_path)

    @property
    def database_path(self) -> Path:
        return self._database_path

    def initialise(self) -> None:
        with self._lock:
            if self._initialised:
                return

            self._database_path.parent.mkdir(parents=True, exist_ok=True)
            connection = self._open_connection()
            try:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute("PRAGMA synchronous=NORMAL")
                connection.execute("PRAGMA busy_timeout=5000")
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS app_records (
                        collection TEXT NOT NULL,
                        record_key TEXT NOT NULL,
                        payload TEXT NOT NULL,
                        PRIMARY KEY (collection, record_key)
                    )
                    """
                )
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS revoked_tokens (
                        jti TEXT PRIMARY KEY,
                        expires_at INTEGER NOT NULL
                    )
                    """
                )
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS rate_limit_buckets (
                        bucket_key TEXT PRIMARY KEY,
                        request_count INTEGER NOT NULL,
                        reset_at INTEGER NOT NULL
                    )
                    """
                )
                connection.commit()
                self._initialised = True
            finally:
                connection.close()

    def close(self) -> None:
        with self._lock:
            self._initialised = False

    def _open_connection(self) -> sqlite3.Connection:
        return sqlite3.connect(
            self._database_path,
            timeout=30,
        )

    def _ensure_initialised(self) -> None:
        if not self._initialised:
            self.initialise()

    @contextmanager
    def _connection(self) -> sqlite3.Connection:
        self._ensure_initialised()
        connection = self._open_connection()
        try:
            connection.execute("PRAGMA busy_timeout=5000")
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def snapshot(self, name: StoreCollection) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            with self._connection() as connection:
                rows = connection.execute(
                    "SELECT record_key, payload FROM app_records WHERE collection = ?",
                    (name,),
                ).fetchall()
            return {
                key: deepcopy(self._deserialise(payload))
                for key, payload in rows
            }

    def list_records(self, name: StoreCollection) -> list[Dict[str, Any]]:
        with self._lock:
            with self._connection() as connection:
                rows = connection.execute(
                    "SELECT payload FROM app_records WHERE collection = ?",
                    (name,),
                ).fetchall()
            return [deepcopy(self._deserialise(payload)) for (payload,) in rows]

    def get_record(self, name: StoreCollection, key: str) -> Dict[str, Any] | None:
        with self._lock:
            with self._connection() as connection:
                row = connection.execute(
                    "SELECT payload FROM app_records WHERE collection = ? AND record_key = ?",
                    (name, key),
                ).fetchone()
            return deepcopy(self._deserialise(row[0])) if row is not None else None

    def has_record(self, name: StoreCollection, key: str) -> bool:
        with self._lock:
            with self._connection() as connection:
                row = connection.execute(
                    "SELECT 1 FROM app_records WHERE collection = ? AND record_key = ?",
                    (name, key),
                ).fetchone()
            return row is not None

    def set_record(self, name: StoreCollection, key: str, value: Dict[str, Any]) -> Dict[str, Any]:
        with self._lock:
            record = deepcopy(value)
            with self._connection() as connection:
                connection.execute(
                    """
                    INSERT INTO app_records (collection, record_key, payload)
                    VALUES (?, ?, ?)
                    ON CONFLICT(collection, record_key)
                    DO UPDATE SET payload = excluded.payload
                    """,
                    (name, key, self._serialise(record)),
                )
            return deepcopy(record)

    def delete_record(self, name: StoreCollection, key: str) -> bool:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.execute(
                    "DELETE FROM app_records WHERE collection = ? AND record_key = ?",
                    (name, key),
                )
            return cursor.rowcount > 0

    def mutate_record(
        self,
        name: StoreCollection,
        key: str,
        mutator: Callable[[Dict[str, Any]], Dict[str, Any] | None],
    ) -> Dict[str, Any] | None:
        with self._lock:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                row = connection.execute(
                    "SELECT payload FROM app_records WHERE collection = ? AND record_key = ?",
                    (name, key),
                ).fetchone()
                if row is None:
                    return None

                current = self._deserialise(row[0])
                working_copy = deepcopy(current)
                replacement = mutator(working_copy)
                updated = working_copy if replacement is None else replacement
                connection.execute(
                    """
                    INSERT INTO app_records (collection, record_key, payload)
                    VALUES (?, ?, ?)
                    ON CONFLICT(collection, record_key)
                    DO UPDATE SET payload = excluded.payload
                    """,
                    (name, key, self._serialise(deepcopy(updated))),
                )
            return deepcopy(updated)

    def count(self, name: StoreCollection) -> int:
        with self._lock:
            with self._connection() as connection:
                row = connection.execute(
                    "SELECT COUNT(*) FROM app_records WHERE collection = ?",
                    (name,),
                ).fetchone()
            return int(row[0]) if row is not None else 0

    def clear(self) -> None:
        with self._lock:
            with self._connection() as connection:
                connection.execute("DELETE FROM app_records")
                connection.execute("DELETE FROM revoked_tokens")
                connection.execute("DELETE FROM rate_limit_buckets")

    def revoke_jti(self, jti: str, expire_seconds: int) -> None:
        with self._lock:
            now_ts = int(datetime.now(timezone.utc).timestamp())
            expires_at = now_ts + max(expire_seconds, 1)
            with self._connection() as connection:
                self._cleanup_revoked_tokens(connection, now_ts)
                connection.execute(
                    """
                    INSERT INTO revoked_tokens (jti, expires_at)
                    VALUES (?, ?)
                    ON CONFLICT(jti)
                    DO UPDATE SET expires_at = excluded.expires_at
                    """,
                    (jti, expires_at),
                )

    def is_jti_revoked(self, jti: str) -> bool:
        with self._lock:
            now_ts = int(datetime.now(timezone.utc).timestamp())
            with self._connection() as connection:
                self._cleanup_revoked_tokens(connection, now_ts)
                row = connection.execute(
                    "SELECT 1 FROM revoked_tokens WHERE jti = ?",
                    (jti,),
                ).fetchone()
            return row is not None

    def _cleanup_revoked_tokens(self, connection: sqlite3.Connection, now_ts: int | None = None) -> None:
        reference = now_ts or int(datetime.now(timezone.utc).timestamp())
        connection.execute(
            "DELETE FROM revoked_tokens WHERE expires_at <= ?",
            (reference,),
        )

    def consume_rate_limit(self, bucket_key: str, limit: int, window_seconds: int) -> RateLimitResult:
        if limit <= 0:
            return {
                "allowed": True,
                "limit": 0,
                "remaining": 0,
                "retry_after": 0,
            }

        with self._lock:
            now_ts = int(datetime.now(timezone.utc).timestamp())
            reset_at = now_ts + max(window_seconds, 1)
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                self._cleanup_rate_limits(connection, now_ts)
                row = connection.execute(
                    "SELECT request_count, reset_at FROM rate_limit_buckets WHERE bucket_key = ?",
                    (bucket_key,),
                ).fetchone()

                if row is not None and int(row[1]) > now_ts:
                    request_count = int(row[0])
                    reset_at = int(row[1])
                else:
                    request_count = 0

                if request_count >= limit:
                    return {
                        "allowed": False,
                        "limit": limit,
                        "remaining": 0,
                        "retry_after": max(reset_at - now_ts, 1),
                    }

                request_count += 1
                connection.execute(
                    """
                    INSERT INTO rate_limit_buckets (bucket_key, request_count, reset_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(bucket_key)
                    DO UPDATE SET
                        request_count = excluded.request_count,
                        reset_at = excluded.reset_at
                    """,
                    (bucket_key, request_count, reset_at),
                )
                return {
                    "allowed": True,
                    "limit": limit,
                    "remaining": max(limit - request_count, 0),
                    "retry_after": max(reset_at - now_ts, 1),
                }

    def _cleanup_rate_limits(self, connection: sqlite3.Connection, now_ts: int | None = None) -> None:
        reference = now_ts or int(datetime.now(timezone.utc).timestamp())
        connection.execute(
            "DELETE FROM rate_limit_buckets WHERE reset_at <= ?",
            (reference,),
        )

    def health_snapshot(self) -> Dict[str, Any]:
        with self._lock:
            with self._connection() as connection:
                row = connection.execute("SELECT 1").fetchone()
            return {
                "store": "ok",
                "store_backend": self.backend_name,
                "connection_target": self.connection_target,
                "database_path": str(self._database_path),
                "probe": int(row[0]) if row is not None else None,
            }

    @property
    def revoked_jtis(self) -> set[str]:
        with self._lock:
            now_ts = int(datetime.now(timezone.utc).timestamp())
            with self._connection() as connection:
                self._cleanup_revoked_tokens(connection, now_ts)
                rows = connection.execute("SELECT jti FROM revoked_tokens").fetchall()
            return {jti for (jti,) in rows}


class HanaAppStore(BaseStore):
    """Thread-safe HANA-backed store for shared application state."""

    backend_name = "hana"
    _RECORDS_TABLE_SUFFIX = "APP_RECORDS"
    _REVOKED_TOKENS_TABLE_SUFFIX = "REVOKED_TOKENS"
    _RATE_LIMITS_TABLE_SUFFIX = "RATE_LIMIT_BUCKETS"

    def __init__(
        self,
        *,
        host: str | None = None,
        port: int | None = None,
        user: str | None = None,
        password: str | None = None,
        encrypt: bool | None = None,
        schema: str | None = None,
        table_prefix: str | None = None,
        connection_factory: Callable[[], Any] | None = None,
    ) -> None:
        self._lock = threading.RLock()
        self._host = host or settings.hana_host
        self._port = int(port or settings.hana_port)
        self._user = user or settings.hana_user
        self._password = password or settings.hana_password
        self._encrypt = settings.hana_encrypt if encrypt is None else encrypt
        self._schema = (schema if schema is not None else settings.hana_store_schema).strip().upper()
        prefix = table_prefix if table_prefix is not None else settings.hana_store_table_prefix
        self._table_prefix = self._normalise_table_prefix(prefix)
        self._connection_factory = connection_factory or self._default_connection_factory
        self._initialised = False

    @property
    def connection_target(self) -> str:
        schema_part = self._schema or "<current-schema>"
        return f"hana://{self._host}:{self._port}/{schema_part}#{self._table_prefix}"

    def initialise(self) -> None:
        with self._lock:
            if self._initialised:
                return

            self._validate_configuration()
            connection = self._open_connection()
            try:
                self._configure_connection(connection)
                existing_tables = self._existing_tables(connection)
                cursor = connection.cursor()
                for table_name, ddl in self._table_definitions().items():
                    if table_name in existing_tables:
                        continue
                    cursor.execute(ddl)
                connection.commit()
                self._initialised = True
            except Exception:
                connection.rollback()
                raise
            finally:
                connection.close()

    def close(self) -> None:
        with self._lock:
            self._initialised = False

    def _validate_configuration(self) -> None:
        missing = [
            field_name
            for field_name, value in (
                ("HANA_HOST", self._host),
                ("HANA_USER", self._user),
                ("HANA_PASSWORD", self._password),
            )
            if not value
        ]
        if missing:
            raise ValueError(
                "HANA store backend requires the following settings: " + ", ".join(missing)
            )

    @staticmethod
    def _normalise_table_prefix(value: str) -> str:
        cleaned = re.sub(r"[^A-Za-z0-9_]", "_", value or "").strip("_").upper()
        if not cleaned:
            raise ValueError("HANA store table prefix must contain at least one alphanumeric character")
        return cleaned

    @staticmethod
    def _quote_identifier(identifier: str) -> str:
        return '"' + identifier.replace('"', '""') + '"'

    def _default_connection_factory(self):
        import hdbcli.dbapi as hdbcli  # type: ignore

        return hdbcli.connect(
            address=self._host,
            port=self._port,
            user=self._user,
            password=self._password,
            encrypt=self._encrypt,
        )

    def _open_connection(self):
        return self._connection_factory()

    def _configure_connection(self, connection: Any) -> None:
        if not self._schema:
            return
        cursor = connection.cursor()
        try:
            cursor.execute(f"SET SCHEMA {self._quote_identifier(self._schema)}")
        finally:
            close = getattr(cursor, "close", None)
            if callable(close):
                close()

    def _ensure_initialised(self) -> None:
        if not self._initialised:
            self.initialise()

    @contextmanager
    def _connection(self):
        self._ensure_initialised()
        connection = self._open_connection()
        try:
            self._configure_connection(connection)
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _table_name(self, suffix: str) -> str:
        return f"{self._table_prefix}_{suffix}"

    def _qualified_table(self, suffix: str) -> str:
        table_name = self._table_name(suffix)
        if self._schema:
            return f"{self._quote_identifier(self._schema)}.{self._quote_identifier(table_name)}"
        return self._quote_identifier(table_name)

    def _table_definitions(self) -> dict[str, str]:
        return {
            self._table_name(self._RECORDS_TABLE_SUFFIX): f"""
                CREATE ROW TABLE {self._qualified_table(self._RECORDS_TABLE_SUFFIX)} (
                    "COLLECTION" NVARCHAR(64) NOT NULL,
                    "RECORD_KEY" NVARCHAR(255) NOT NULL,
                    "PAYLOAD" NCLOB NOT NULL,
                    PRIMARY KEY ("COLLECTION", "RECORD_KEY")
                )
            """,
            self._table_name(self._REVOKED_TOKENS_TABLE_SUFFIX): f"""
                CREATE ROW TABLE {self._qualified_table(self._REVOKED_TOKENS_TABLE_SUFFIX)} (
                    "JTI" NVARCHAR(255) NOT NULL,
                    "EXPIRES_AT" BIGINT NOT NULL,
                    PRIMARY KEY ("JTI")
                )
            """,
            self._table_name(self._RATE_LIMITS_TABLE_SUFFIX): f"""
                CREATE ROW TABLE {self._qualified_table(self._RATE_LIMITS_TABLE_SUFFIX)} (
                    "BUCKET_KEY" NVARCHAR(255) NOT NULL,
                    "REQUEST_COUNT" INTEGER NOT NULL,
                    "RESET_AT" BIGINT NOT NULL,
                    PRIMARY KEY ("BUCKET_KEY")
                )
            """,
        }

    def _existing_tables(self, connection: Any) -> set[str]:
        table_names = list(self._table_definitions().keys())
        placeholders = ", ".join("?" for _ in table_names)
        cursor = connection.cursor()
        try:
            cursor.execute(
                f"""
                SELECT "TABLE_NAME"
                FROM SYS.TABLES
                WHERE "SCHEMA_NAME" = CURRENT_SCHEMA
                  AND "TABLE_NAME" IN ({placeholders})
                """,
                tuple(table_names),
            )
            return {str(row[0]) for row in cursor.fetchall()}
        finally:
            close = getattr(cursor, "close", None)
            if callable(close):
                close()

    def snapshot(self, name: StoreCollection) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        f"""
                        SELECT "RECORD_KEY", "PAYLOAD"
                        FROM {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        WHERE "COLLECTION" = ?
                        """,
                        (name,),
                    )
                    rows = cursor.fetchall()
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return {
                key: deepcopy(self._deserialise(payload))
                for key, payload in rows
            }

    def list_records(self, name: StoreCollection) -> list[Dict[str, Any]]:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        f"""
                        SELECT "PAYLOAD"
                        FROM {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        WHERE "COLLECTION" = ?
                        """,
                        (name,),
                    )
                    rows = cursor.fetchall()
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return [deepcopy(self._deserialise(payload)) for (payload,) in rows]

    def get_record(self, name: StoreCollection, key: str) -> Dict[str, Any] | None:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        f"""
                        SELECT "PAYLOAD"
                        FROM {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        WHERE "COLLECTION" = ? AND "RECORD_KEY" = ?
                        """,
                        (name, key),
                    )
                    row = cursor.fetchone()
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return deepcopy(self._deserialise(row[0])) if row is not None else None

    def has_record(self, name: StoreCollection, key: str) -> bool:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        f"""
                        SELECT 1
                        FROM {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        WHERE "COLLECTION" = ? AND "RECORD_KEY" = ?
                        """,
                        (name, key),
                    )
                    row = cursor.fetchone()
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return row is not None

    def set_record(self, name: StoreCollection, key: str, value: Dict[str, Any]) -> Dict[str, Any]:
        with self._lock:
            record = deepcopy(value)
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        f"""
                        UPSERT {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        ("COLLECTION", "RECORD_KEY", "PAYLOAD")
                        VALUES (?, ?, ?)
                        WITH PRIMARY KEY
                        """,
                        (name, key, self._serialise(record)),
                    )
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return deepcopy(record)

    def delete_record(self, name: StoreCollection, key: str) -> bool:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        f"""
                        DELETE FROM {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        WHERE "COLLECTION" = ? AND "RECORD_KEY" = ?
                        """,
                        (name, key),
                    )
                    deleted = cursor.rowcount > 0
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return deleted

    def mutate_record(
        self,
        name: StoreCollection,
        key: str,
        mutator: Callable[[Dict[str, Any]], Dict[str, Any] | None],
    ) -> Dict[str, Any] | None:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        f"""
                        SELECT "PAYLOAD"
                        FROM {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        WHERE "COLLECTION" = ? AND "RECORD_KEY" = ?
                        FOR UPDATE
                        """,
                        (name, key),
                    )
                    row = cursor.fetchone()
                    if row is None:
                        return None

                    current = self._deserialise(row[0])
                    working_copy = deepcopy(current)
                    replacement = mutator(working_copy)
                    updated = working_copy if replacement is None else replacement
                    cursor.execute(
                        f"""
                        UPSERT {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        ("COLLECTION", "RECORD_KEY", "PAYLOAD")
                        VALUES (?, ?, ?)
                        WITH PRIMARY KEY
                        """,
                        (name, key, self._serialise(deepcopy(updated))),
                    )
                    return deepcopy(updated)
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()

    def count(self, name: StoreCollection) -> int:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        f"""
                        SELECT COUNT(*)
                        FROM {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}
                        WHERE "COLLECTION" = ?
                        """,
                        (name,),
                    )
                    row = cursor.fetchone()
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return int(row[0]) if row is not None else 0

    def clear(self) -> None:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute(f'DELETE FROM {self._qualified_table(self._RECORDS_TABLE_SUFFIX)}')
                    cursor.execute(f'DELETE FROM {self._qualified_table(self._REVOKED_TOKENS_TABLE_SUFFIX)}')
                    cursor.execute(f'DELETE FROM {self._qualified_table(self._RATE_LIMITS_TABLE_SUFFIX)}')
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()

    def revoke_jti(self, jti: str, expire_seconds: int) -> None:
        with self._lock:
            now_ts = int(datetime.now(timezone.utc).timestamp())
            expires_at = now_ts + max(expire_seconds, 1)
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    self._cleanup_revoked_tokens(cursor, now_ts)
                    cursor.execute(
                        f"""
                        UPSERT {self._qualified_table(self._REVOKED_TOKENS_TABLE_SUFFIX)}
                        ("JTI", "EXPIRES_AT")
                        VALUES (?, ?)
                        WITH PRIMARY KEY
                        """,
                        (jti, expires_at),
                    )
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()

    def is_jti_revoked(self, jti: str) -> bool:
        with self._lock:
            now_ts = int(datetime.now(timezone.utc).timestamp())
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    self._cleanup_revoked_tokens(cursor, now_ts)
                    cursor.execute(
                        f"""
                        SELECT 1
                        FROM {self._qualified_table(self._REVOKED_TOKENS_TABLE_SUFFIX)}
                        WHERE "JTI" = ?
                        """,
                        (jti,),
                    )
                    row = cursor.fetchone()
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return row is not None

    def _cleanup_revoked_tokens(self, cursor: Any, now_ts: int | None = None) -> None:
        reference = now_ts or int(datetime.now(timezone.utc).timestamp())
        cursor.execute(
            f"""
            DELETE FROM {self._qualified_table(self._REVOKED_TOKENS_TABLE_SUFFIX)}
            WHERE "EXPIRES_AT" <= ?
            """,
            (reference,),
        )

    def consume_rate_limit(self, bucket_key: str, limit: int, window_seconds: int) -> RateLimitResult:
        if limit <= 0:
            return {
                "allowed": True,
                "limit": 0,
                "remaining": 0,
                "retry_after": 0,
            }

        with self._lock:
            now_ts = int(datetime.now(timezone.utc).timestamp())
            reset_at = now_ts + max(window_seconds, 1)
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    self._cleanup_rate_limits(cursor, now_ts)
                    cursor.execute(
                        f"""
                        SELECT "REQUEST_COUNT", "RESET_AT"
                        FROM {self._qualified_table(self._RATE_LIMITS_TABLE_SUFFIX)}
                        WHERE "BUCKET_KEY" = ?
                        FOR UPDATE
                        """,
                        (bucket_key,),
                    )
                    row = cursor.fetchone()

                    if row is not None and int(row[1]) > now_ts:
                        request_count = int(row[0])
                        reset_at = int(row[1])
                    else:
                        request_count = 0

                    if request_count >= limit:
                        return {
                            "allowed": False,
                            "limit": limit,
                            "remaining": 0,
                            "retry_after": max(reset_at - now_ts, 1),
                        }

                    request_count += 1
                    cursor.execute(
                        f"""
                        UPSERT {self._qualified_table(self._RATE_LIMITS_TABLE_SUFFIX)}
                        ("BUCKET_KEY", "REQUEST_COUNT", "RESET_AT")
                        VALUES (?, ?, ?)
                        WITH PRIMARY KEY
                        """,
                        (bucket_key, request_count, reset_at),
                    )
                    return {
                        "allowed": True,
                        "limit": limit,
                        "remaining": max(limit - request_count, 0),
                        "retry_after": max(reset_at - now_ts, 1),
                    }
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()

    def _cleanup_rate_limits(self, cursor: Any, now_ts: int | None = None) -> None:
        reference = now_ts or int(datetime.now(timezone.utc).timestamp())
        cursor.execute(
            f"""
            DELETE FROM {self._qualified_table(self._RATE_LIMITS_TABLE_SUFFIX)}
            WHERE "RESET_AT" <= ?
            """,
            (reference,),
        )

    def health_snapshot(self) -> Dict[str, Any]:
        with self._lock:
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    cursor.execute("SELECT CURRENT_SCHEMA FROM DUMMY")
                    row = cursor.fetchone()
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return {
                "store": "ok",
                "store_backend": self.backend_name,
                "connection_target": self.connection_target,
                "current_schema": row[0] if row is not None else None,
            }

    @property
    def revoked_jtis(self) -> set[str]:
        with self._lock:
            now_ts = int(datetime.now(timezone.utc).timestamp())
            with self._connection() as connection:
                cursor = connection.cursor()
                try:
                    self._cleanup_revoked_tokens(cursor, now_ts)
                    cursor.execute(f'SELECT "JTI" FROM {self._qualified_table(self._REVOKED_TOKENS_TABLE_SUFFIX)}')
                    rows = cursor.fetchall()
                finally:
                    close = getattr(cursor, "close", None)
                    if callable(close):
                        close()
            return {str(jti) for (jti,) in rows}


StoreBackend = BaseStore


def build_store() -> StoreBackend:
    """Build the configured persistent store backend."""
    backend = settings.store_backend.lower()
    if backend == "sqlite":
        return AppStore()
    if backend == "hana":
        return HanaAppStore()
    raise ValueError(f"Unsupported store backend: {settings.store_backend}")


_store = build_store()


def get_store() -> StoreBackend:
    """FastAPI dependency — returns the configured persistent store backend."""
    return _store

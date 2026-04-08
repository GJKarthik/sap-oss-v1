# =============================================================================
# hana_client.py — SAP HANA Cloud connection & query utilities
# =============================================================================
from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any, Generator, Optional

logger = logging.getLogger(__name__)


@dataclass
class HanaConfig:
    """Connection parameters for SAP HANA Cloud."""

    host: str
    port: int = 443
    user: str = ""
    password: str = ""
    schema: str = "PAL_STORE"
    encrypt: bool = True
    sslValidateCertificate: bool = True

    @classmethod
    def from_env(cls) -> HanaConfig:
        """Build config from environment variables."""
        return cls(
            host=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            schema=os.environ.get("HANA_SCHEMA", "PAL_STORE"),
            encrypt=os.environ.get("HANA_ENCRYPT", "true").lower() == "true",
            sslValidateCertificate=os.environ.get("HANA_SSL_VALIDATE", "true").lower() == "true",
        )


class HanaClient:
    """Thin wrapper around hdbcli for SAP HANA Cloud operations."""

    def __init__(self, config: Optional[HanaConfig] = None) -> None:
        self._config = config or HanaConfig.from_env()
        self._conn: Any = None

    def connect(self) -> None:
        """Establish a connection to HANA Cloud."""
        try:
            from hdbcli import dbapi  # type: ignore[import-untyped]
        except ImportError as exc:
            raise ImportError(
                "hdbcli is required for HANA Cloud connectivity. "
                "Install it with: pip install hdbcli"
            ) from exc

        self._conn = dbapi.connect(
            address=self._config.host,
            port=self._config.port,
            user=self._config.user,
            password=self._config.password,
            currentSchema=self._config.schema,
            encrypt=self._config.encrypt,
            sslValidateCertificate=self._config.sslValidateCertificate,
        )
        logger.info("Connected to HANA Cloud at %s:%d", self._config.host, self._config.port)

    def close(self) -> None:
        """Close the HANA connection."""
        if self._conn is not None:
            self._conn.close()
            self._conn = None

    @contextmanager
    def session(self) -> Generator[HanaClient, None, None]:
        """Context manager that auto-connects and disconnects."""
        self.connect()
        try:
            yield self
        finally:
            self.close()

    def execute(self, sql: str, params: tuple = ()) -> list[dict[str, Any]]:
        """Execute a SQL query and return results as list of dicts."""
        if self._conn is None:
            raise RuntimeError("Not connected. Call connect() first or use session().")

        cursor = self._conn.cursor()
        try:
            cursor.execute(sql, params)
            if cursor.description is None:
                return []
            columns = [desc[0] for desc in cursor.description]
            return [dict(zip(columns, row)) for row in cursor.fetchall()]
        finally:
            cursor.close()

    def execute_many(self, sql: str, data: list[tuple]) -> int:
        """Execute a parameterized INSERT/UPDATE for multiple rows."""
        if self._conn is None:
            raise RuntimeError("Not connected. Call connect() first or use session().")

        cursor = self._conn.cursor()
        try:
            cursor.executemany(sql, data)
            self._conn.commit()
            return len(data)
        finally:
            cursor.close()

    def table_exists(self, schema: str, table: str) -> bool:
        """Check if a table exists in HANA."""
        rows = self.execute(
            'SELECT COUNT(*) AS cnt FROM "SYS"."TABLES" WHERE "SCHEMA_NAME" = ? AND "TABLE_NAME" = ?',
            (schema, table),
        )
        return rows[0]["cnt"] > 0 if rows else False

    def get_table_columns(self, schema: str, table: str) -> list[dict[str, Any]]:
        """Retrieve column metadata for a HANA table."""
        return self.execute(
            'SELECT "COLUMN_NAME", "DATA_TYPE_NAME", "LENGTH", "IS_NULLABLE" '
            'FROM "SYS"."TABLE_COLUMNS" '
            'WHERE "SCHEMA_NAME" = ? AND "TABLE_NAME" = ? '
            'ORDER BY "POSITION"',
            (schema, table),
        )

    def upload_training_pairs(
        self,
        pairs: list[dict[str, str]],
        schema: str = "FINSIGHT_CORE",
        table: str = "TRAINING_PAIRS",
    ) -> int:
        """Bulk-insert training pairs into HANA."""
        sql = f'INSERT INTO "{schema}"."{table}" ("QUESTION", "SQL_TEXT", "DOMAIN", "DIFFICULTY") VALUES (?, ?, ?, ?)'
        data = [(p["question"], p["sql"], p["domain"], p["difficulty"]) for p in pairs]
        return self.execute_many(sql, data)

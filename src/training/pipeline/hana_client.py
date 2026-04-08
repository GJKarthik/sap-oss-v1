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

    # =========================================================================
    # Team Context queries
    # =========================================================================

    def get_team_config(self, team_id: str) -> dict[str, Any] | None:
        """Fetch a single team configuration row."""
        rows = self.execute(
            'SELECT "TEAM_ID", "COUNTRY", "DOMAIN", "DISPLAY_NAME", "LOCALE", "IS_ACTIVE" '
            'FROM "FINSIGHT_CORE"."TEAM_CONFIG" WHERE "TEAM_ID" = ? AND "IS_ACTIVE" = TRUE',
            (team_id,),
        )
        return rows[0] if rows else None

    def list_team_configs(self) -> list[dict[str, Any]]:
        """List all active team configurations."""
        return self.execute(
            'SELECT "TEAM_ID", "COUNTRY", "DOMAIN", "DISPLAY_NAME", "LOCALE" '
            'FROM "FINSIGHT_CORE"."TEAM_CONFIG" WHERE "IS_ACTIVE" = TRUE '
            'ORDER BY "COUNTRY", "DOMAIN"'
        )

    def get_team_glossary(self, scope_level: str, scope_key: str) -> list[dict[str, Any]]:
        """Fetch approved glossary entries for a scope level and key."""
        return self.execute(
            'SELECT "ID", "SOURCE_TEXT", "TARGET_TEXT", "SOURCE_LANG", "TARGET_LANG", '
            '"CATEGORY", "PAIR_TYPE", "SCOPE_LEVEL", "TEAM_ID", "IS_APPROVED" '
            'FROM "FINSIGHT_CORE"."TEAM_GLOSSARY" '
            'WHERE "SCOPE_LEVEL" = ? AND "TEAM_ID" = ? AND "IS_APPROVED" = TRUE',
            (scope_level, scope_key),
        )

    def upsert_team_glossary_entry(
        self,
        entry_id: str,
        team_id: str,
        scope_level: str,
        source_text: str,
        target_text: str,
        source_lang: str = "en",
        target_lang: str = "ar",
        category: str = "financial",
        pair_type: str = "translation",
        is_approved: bool = True,
    ) -> int:
        """Insert or update a team glossary entry."""
        return self.execute_many(
            'UPSERT "FINSIGHT_CORE"."TEAM_GLOSSARY" '
            '("ID", "TEAM_ID", "SCOPE_LEVEL", "SOURCE_TEXT", "TARGET_TEXT", '
            '"SOURCE_LANG", "TARGET_LANG", "CATEGORY", "PAIR_TYPE", "IS_APPROVED", '
            '"UPDATED_AT") '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP) '
            'WITH PRIMARY KEY',
            [(entry_id, team_id, scope_level, source_text, target_text,
              source_lang, target_lang, category, pair_type, is_approved)],
        )

    def get_team_product_access(self, team_id: str) -> list[dict[str, Any]]:
        """Fetch data product access entries for a team."""
        return self.execute(
            'SELECT "PRODUCT_ID", "ACCESS_LEVEL" '
            'FROM "FINSIGHT_CORE"."TEAM_PRODUCT_ACCESS" WHERE "TEAM_ID" = ?',
            (team_id,),
        )

    def get_team_prompt_override(self, team_id: str, product_id: str) -> dict[str, Any] | None:
        """Fetch prompt override for a team and product (or wildcard '*')."""
        rows = self.execute(
            'SELECT "SYSTEM_PROMPT_APPEND", "TEMPERATURE", "MAX_TOKENS" '
            'FROM "FINSIGHT_CORE"."TEAM_PROMPT_OVERRIDE" '
            'WHERE "TEAM_ID" = ? AND ("PRODUCT_ID" = ? OR "PRODUCT_ID" = \'*\') '
            'ORDER BY CASE WHEN "PRODUCT_ID" = \'*\' THEN 0 ELSE 1 END',
            (team_id, product_id),
        )
        return rows[0] if rows else None

    def get_team_training_config(self, team_id: str) -> dict[str, Any] | None:
        """Fetch training configuration for a team."""
        rows = self.execute(
            'SELECT "DOMAIN", "INCLUDE_PATTERNS", "EXCLUDE_PATTERNS", '
            '"CUSTOM_TEMPLATES_PATH", "ENABLE_BILINGUAL", "COUNTRY_FILTER" '
            'FROM "FINSIGHT_CORE"."TEAM_TRAINING_CONFIG" WHERE "TEAM_ID" = ?',
            (team_id,),
        )
        return rows[0] if rows else None

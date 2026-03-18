"""HANA Toolkit MCP server with graceful mock fallback for local development."""

from __future__ import annotations

import copy
import json
import os
import re
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse


READ_ONLY_SQL = re.compile(r"^\s*(select|with|explain)\b", re.IGNORECASE)
WRITE_SQL = re.compile(r"\b(insert|update|delete|merge|drop|alter|create|truncate|grant|revoke)\b", re.IGNORECASE)
MAX_ROWS = 500

GOVERNANCE_SCHEMA_SQL = """CREATE SCHEMA IF NOT EXISTS AI_GOVERNANCE;

CREATE COLUMN TABLE IF NOT EXISTS AI_GOVERNANCE.DIMENSION_FACTS (
    FACT_ID NVARCHAR(64) PRIMARY KEY,
    ACTION_NAME NVARCHAR(128),
    DIMENSION_NAME NVARCHAR(64) NOT NULL,
    DESCRIPTION NVARCHAR(500) NOT NULL,
    FRAMEWORK_ID NVARCHAR(64) DEFAULT 'MGF-Agentic-AI',
    FRAMEWORK_STATUS NVARCHAR(32) DEFAULT 'enforced',
    REVIEW_REQUIRED BOOLEAN DEFAULT TRUE,
    SOURCE NVARCHAR(64) DEFAULT 'seed',
    UPDATED_AT TIMESTAMP DEFAULT CURRENT_UTCTIMESTAMP
);

CREATE COLUMN TABLE IF NOT EXISTS AI_GOVERNANCE.AUDIT_LOGS (
    TRACE_ID NVARCHAR(64) NOT NULL,
    SPAN_ID NVARCHAR(64) PRIMARY KEY,
    SERVICE NVARCHAR(128) NOT NULL,
    OPERATION NVARCHAR(256) NOT NULL,
    MODEL NVARCHAR(128),
    SECURITY_CLASS NVARCHAR(64) DEFAULT 'internal',
    MANGLE_RULES_JSON NCLOB,
    ROUTING_DECISION NVARCHAR(64),
    LATENCY_MS INTEGER DEFAULT 0,
    TTFT_MS INTEGER DEFAULT 0,
    TOKENS_IN INTEGER DEFAULT 0,
    TOKENS_OUT INTEGER DEFAULT 0,
    ACCEPTANCE_RATE DOUBLE DEFAULT 0,
    GDPR_SUBJECT_ID NVARCHAR(128),
    REGION NVARCHAR(64),
    OUTCOME NVARCHAR(32) DEFAULT 'allowed',
    TIMESTAMP_MS BIGINT NOT NULL,
    PAYLOAD_JSON NCLOB,
    CREATED_AT TIMESTAMP DEFAULT CURRENT_UTCTIMESTAMP
);

CREATE COLUMN TABLE IF NOT EXISTS AI_GOVERNANCE.AUDIT_VECTOR_INDEX (
    DOC_ID NVARCHAR(64) PRIMARY KEY,
    CONTENT NCLOB NOT NULL,
    CONTENT_VECTOR REAL_VECTOR,
    METADATA_JSON NCLOB,
    CREATED_AT TIMESTAMP DEFAULT CURRENT_UTCTIMESTAMP
);
"""


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _to_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() not in {"", "0", "false", "no", "off"}
    return bool(value)


def _default_mock_governance_facts() -> list[dict[str, Any]]:
    return [
        {
            "factId": "gov-1",
            "action": "impact_assessment",
            "dimension": "accountability",
            "description": "Ensures actors can be held responsible for AI decisions",
            "frameworkId": "MGF-Agentic-AI",
            "frameworkStatus": "enforced",
            "reviewRequired": True,
        },
        {
            "factId": "gov-2",
            "action": "impact_assessment",
            "dimension": "transparency",
            "description": "Requires AI reasoning to be explainable and auditable",
            "frameworkId": "MGF-Agentic-AI",
            "frameworkStatus": "enforced",
            "reviewRequired": True,
        },
        {
            "factId": "gov-3",
            "action": "competitor_analysis",
            "dimension": "fairness",
            "description": "Prohibits discriminatory or biased AI outcomes",
            "frameworkId": "EU-AI-Act",
            "frameworkStatus": "enforced",
            "reviewRequired": True,
        },
        {
            "factId": "gov-4",
            "action": "export_report",
            "dimension": "accountability",
            "description": "Ensures exported reports remain attributable and auditable",
            "frameworkId": "GDPR",
            "frameworkStatus": "enforced",
            "reviewRequired": True,
        },
        {
            "factId": "gov-5",
            "action": "strategic_recommendation",
            "dimension": "safety",
            "description": "Requires AI actions to avoid harm to people or systems",
            "frameworkId": "AI-Agent-Index",
            "frameworkStatus": "enforced",
            "reviewRequired": True,
        },
    ]


def _default_mock_audit_logs(now_ms: int) -> list[dict[str, Any]]:
    return [
        {
            "traceId": "trace-1001",
            "spanId": "span-1001",
            "service": "world-monitor",
            "operation": "summarize_news",
            "model": "gpt-4.1-mini",
            "securityClass": "internal",
            "mangleRulesEvaluated": ["route_to_aicore", "subject_to_review"],
            "routingDecision": "allow",
            "latencyMs": 842,
            "ttftMs": 114,
            "tokensIn": 1860,
            "tokensOut": 322,
            "acceptanceRate": 0.92,
            "gdprSubjectId": "anon-1001",
            "region": "eu10",
            "timestamp": now_ms - 60_000,
            "outcome": "allowed",
        },
        {
            "traceId": "trace-1002",
            "spanId": "span-1002",
            "service": "world-monitor",
            "operation": "competitor_analysis",
            "model": "gpt-4.1",
            "securityClass": "confidential",
            "mangleRulesEvaluated": ["requires_human_review", "implicates_dimension"],
            "routingDecision": "block",
            "latencyMs": 1331,
            "ttftMs": 202,
            "tokensIn": 2142,
            "tokensOut": 0,
            "acceptanceRate": 0.0,
            "gdprSubjectId": "anon-1002",
            "region": "eu10",
            "timestamp": now_ms - 190_000,
            "outcome": "blocked",
        },
        {
            "traceId": "trace-1003",
            "spanId": "span-1003",
            "service": "audit-broker",
            "operation": "record_telemetry",
            "model": "n/a",
            "securityClass": "internal",
            "mangleRulesEvaluated": ["route_to_vllm"],
            "routingDecision": "anonymise",
            "latencyMs": 476,
            "ttftMs": 79,
            "tokensIn": 514,
            "tokensOut": 128,
            "acceptanceRate": 0.77,
            "gdprSubjectId": "anon-1003",
            "region": "us10",
            "timestamp": now_ms - 340_000,
            "outcome": "anonymised",
        },
    ]


def _default_mock_vector_docs() -> list[dict[str, Any]]:
    return [
        {
            "docId": "vec-1",
            "content": "Accountability rules require exported reports and impact assessments to stay reviewable.",
            "metadata": {"dimension": "accountability", "table": "AI_GOVERNANCE.DIMENSION_FACTS"},
        },
        {
            "docId": "vec-2",
            "content": "Fairness checks should be applied before competitor analysis reaches a model endpoint.",
            "metadata": {"dimension": "fairness", "table": "AI_GOVERNANCE.DIMENSION_FACTS"},
        },
        {
            "docId": "vec-3",
            "content": "Audit logs store routing decisions, latency, and evaluated Mangle rules for every AI action.",
            "metadata": {"dimension": "transparency", "table": "AI_GOVERNANCE.AUDIT_LOGS"},
        },
    ]


@dataclass(slots=True)
class HanaToolkitConfig:
    host: str = ""
    port: int = 443
    user: str = ""
    password: str = ""
    database: str = ""
    encrypt: bool = True
    dimension_facts_table: str = "AI_GOVERNANCE.DIMENSION_FACTS"
    audit_logs_table: str = "AI_GOVERNANCE.AUDIT_LOGS"
    vector_table: str = "AI_GOVERNANCE.AUDIT_VECTOR_INDEX"
    pool_size: int = 4
    healthcheck_seconds: int = 30

    @classmethod
    def from_env(cls) -> "HanaToolkitConfig":
        return cls(
            host=os.environ.get("HANA_HOST", "").strip(),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", "").strip(),
            password=os.environ.get("HANA_PASSWORD", "").strip(),
            database=os.environ.get("HANA_DATABASE", "").strip(),
            encrypt=os.environ.get("HANA_ENCRYPT", "true").strip().lower() not in {"0", "false", "no"},
            dimension_facts_table=os.environ.get("HANA_DIMENSION_FACTS_TABLE", "AI_GOVERNANCE.DIMENSION_FACTS").strip(),
            audit_logs_table=os.environ.get("HANA_AUDIT_LOGS_TABLE", "AI_GOVERNANCE.AUDIT_LOGS").strip(),
            vector_table=os.environ.get("HANA_VECTOR_TABLE", "AI_GOVERNANCE.AUDIT_VECTOR_INDEX").strip(),
            pool_size=max(1, int(os.environ.get("HANA_POOL_SIZE", "4"))),
            healthcheck_seconds=max(5, int(os.environ.get("HANA_HEALTHCHECK_SECONDS", "30"))),
        )

    @property
    def configured(self) -> bool:
        return bool(self.host and self.user and self.password)


class HanaConnectionPool:
    def __init__(self, config: HanaToolkitConfig, dbapi_module: Any | None = None):
        self.config = config
        self._dbapi = dbapi_module if dbapi_module is not None else self._load_dbapi()
        self._lock = threading.Lock()
        self._pool: list[Any] = []
        self._last_error = ""
        self._last_checked_at = 0.0
        self._failure_count = 0

    def _load_dbapi(self) -> Any | None:
        try:
            from hdbcli import dbapi  # type: ignore
            return dbapi
        except ImportError:
            return None

    @property
    def driver_available(self) -> bool:
        return self._dbapi is not None

    @property
    def mode(self) -> str:
        if not self.config.configured:
            return "mock-unconfigured"
        if not self.driver_available:
            return "mock-driver-missing"
        if self._last_error:
            return "mock-fallback"
        return "hana"

    def _create_connection(self) -> Any:
        if self._dbapi is None:
            raise RuntimeError("hdbcli not installed")
        return self._dbapi.connect(
            address=self.config.host,
            port=self.config.port,
            user=self.config.user,
            password=self.config.password,
            databaseName=self.config.database or None,
            encrypt=self.config.encrypt,
            sslValidateCertificate=self.config.encrypt,
        )

    def _ping(self, connection: Any) -> bool:
        cursor = connection.cursor()
        try:
            cursor.execute("SELECT 1 AS HEALTH FROM DUMMY")
            row = cursor.fetchone()
            return bool(row)
        finally:
            cursor.close()

    @contextmanager
    def acquire(self):
        connection = None
        if self.config.configured and self.driver_available:
            with self._lock:
                if self._pool:
                    connection = self._pool.pop()
            if connection is None:
                try:
                    connection = self._create_connection()
                    self._last_error = ""
                except Exception as exc:  # pragma: no cover - exercised via tests with fake dbapi
                    self._failure_count += 1
                    self._last_error = str(exc)
                    connection = None
        try:
            yield connection
        finally:
            if connection is not None:
                try:
                    if self._ping(connection):
                        with self._lock:
                            if len(self._pool) < self.config.pool_size:
                                self._pool.append(connection)
                                connection = None
                except Exception:
                    pass
                if connection is not None:
                    try:
                        connection.close()
                    except Exception:
                        pass

    def health(self) -> dict[str, Any]:
        reachable = False
        if self.config.configured and self.driver_available:
            now = time.time()
            if now - self._last_checked_at >= self.config.healthcheck_seconds:
                self._last_checked_at = now
                with self.acquire() as connection:
                    if connection is not None:
                        try:
                            reachable = self._ping(connection)
                            self._last_error = "" if reachable else "HANA ping returned no rows"
                        except Exception as exc:
                            self._failure_count += 1
                            self._last_error = str(exc)
            else:
                reachable = not self._last_error
        status = "healthy" if self.mode == "hana" and (reachable or not self._last_error) else "degraded"
        if self.mode.startswith("mock-") and self._last_error == "":
            status = "unconfigured" if self.mode == "mock-unconfigured" else "mock"
        return {
            "status": status,
            "mode": self.mode,
            "configured": self.config.configured,
            "driverAvailable": self.driver_available,
            "reachable": reachable,
            "poolSize": len(self._pool),
            "failureCount": self._failure_count,
            "lastError": self._last_error,
        }


class HanaToolkitServer:
    def __init__(
        self,
        config: HanaToolkitConfig | None = None,
        dbapi_module: Any | None = None,
        clock: Callable[[], float] | None = None,
    ):
        self.config = config or HanaToolkitConfig.from_env()
        self._clock = clock or time.time
        self._pool = HanaConnectionPool(self.config, dbapi_module=dbapi_module)
        self._governance_facts = _default_mock_governance_facts()
        self._vector_docs = _default_mock_vector_docs()

    def _now_ms(self) -> int:
        return int(self._clock() * 1000)

    def _mock_audit_logs(self) -> list[dict[str, Any]]:
        return _default_mock_audit_logs(self._now_ms())

    def _execute_query(self, sql: str, params: list[Any], max_rows: int) -> dict[str, Any]:
        with self._pool.acquire() as connection:
            if connection is None:
                return self._mock_query(sql, max_rows)
            cursor = connection.cursor()
            try:
                cursor.execute(sql, params)
                columns = [desc[0] for desc in cursor.description] if cursor.description else []
                rows = [dict(zip(columns, row)) for row in cursor.fetchmany(max_rows)]
                return {
                    "columns": columns,
                    "rows": rows,
                    "count": len(rows),
                    "source": "hana",
                    "degraded": False,
                }
            except Exception as exc:
                self._pool._failure_count += 1  # noqa: SLF001 - internal health tracking
                self._pool._last_error = str(exc)  # noqa: SLF001 - internal health tracking
                return self._mock_query(sql, max_rows, error=str(exc))
            finally:
                cursor.close()

    def _mock_query(self, sql: str, max_rows: int, error: str | None = None) -> dict[str, Any]:
        sql_lower = sql.lower()
        rows: list[dict[str, Any]]
        if "dimension_facts" in sql_lower:
            rows = copy.deepcopy(self._governance_facts[:max_rows])
        elif "audit_logs" in sql_lower:
            rows = copy.deepcopy(self._mock_audit_logs()[:max_rows])
        elif "vector" in sql_lower:
            rows = copy.deepcopy(self._vector_docs[:max_rows])
        else:
            rows = [{"message": "HANA unavailable; returned mock development data"}]
        return {
            "columns": list(rows[0].keys()) if rows else [],
            "rows": rows,
            "count": len(rows),
            "source": "mock",
            "degraded": True,
            "error": error or self._pool.health().get("lastError") or "HANA unavailable",
        }

    def query(self, args: dict[str, Any]) -> dict[str, Any]:
        sql = str(args.get("sql", "") or "").strip()
        if not sql:
            return {"error": "sql is required", "rows": [], "columns": [], "count": 0}
        if not READ_ONLY_SQL.match(sql) or WRITE_SQL.search(sql):
            return {"error": "Only read-only SELECT/WITH/EXPLAIN statements are allowed", "rows": [], "columns": [], "count": 0}
        params = args.get("params") or []
        if not isinstance(params, list):
            params = []
        max_rows = max(1, min(int(args.get("max_rows", 100) or 100), MAX_ROWS))
        return self._execute_query(sql, params, max_rows)

    def vector_search(self, args: dict[str, Any]) -> dict[str, Any]:
        query_text = str(args.get("query") or args.get("query_text") or "").strip().lower()
        limit = max(1, min(int(args.get("limit", 5) or 5), 25))
        if not query_text:
            return {"matches": [], "count": 0, "source": "mock", "degraded": True, "error": "query is required"}
        docs = self._vector_docs
        source = "mock"
        degraded = True
        if self._pool.mode == "hana":
            query_result = self._execute_query(
                f"SELECT DOC_ID, CONTENT, METADATA_JSON FROM {self.config.vector_table} WHERE LOWER(CONTENT) LIKE ?",
                [f"%{query_text}%"],
                limit * 5,
            )
            source = str(query_result.get("source", "mock"))
            degraded = bool(query_result.get("degraded", source != "hana"))
            docs = []
            for row in query_result.get("rows", []):
                metadata = row.get("METADATA_JSON", {})
                if isinstance(metadata, str):
                    try:
                        metadata = json.loads(metadata)
                    except json.JSONDecodeError:
                        metadata = {"raw": metadata}
                docs.append({
                    "docId": row.get("DOC_ID", ""),
                    "content": row.get("CONTENT", ""),
                    "metadata": metadata,
                })
        if not docs:
            docs = self._vector_docs
        scored = []
        for doc in docs:
            tokens = set(query_text.split())
            haystack = str(doc["content"]).lower()
            score = sum(1 for token in tokens if token in haystack) / max(len(tokens), 1)
            if score > 0:
                scored.append({
                    "docId": doc["docId"],
                    "content": doc["content"],
                    "metadata": doc["metadata"],
                    "score": round(score, 4),
                })
        scored.sort(key=lambda item: item["score"], reverse=True)
        return {
            "matches": scored[:limit],
            "count": min(len(scored), limit),
            "source": source,
            "degraded": degraded,
        }

    def get_governance_facts(self, args: dict[str, Any]) -> dict[str, Any]:
        action = str(args.get("action", "") or "").strip().lower()
        dimension = str(args.get("dimension", "") or "").strip().lower()
        framework_status = str(args.get("frameworkStatus", "") or "").strip().lower()
        limit = max(1, min(int(args.get("limit", 100) or 100), 250))
        filters = []
        params: list[Any] = []
        if action:
            filters.append("LOWER(ACTION_NAME) = ?")
            params.append(action)
        if dimension:
            filters.append("LOWER(DIMENSION_NAME) = ?")
            params.append(dimension)
        if framework_status:
            filters.append("LOWER(FRAMEWORK_STATUS) = ?")
            params.append(framework_status)
        where_clause = f" WHERE {' AND '.join(filters)}" if filters else ""
        query_result = self._execute_query(
            (
                "SELECT FACT_ID, ACTION_NAME, DIMENSION_NAME, DESCRIPTION, FRAMEWORK_ID, "
                "FRAMEWORK_STATUS, REVIEW_REQUIRED FROM "
                f"{self.config.dimension_facts_table}{where_clause}"
            ),
            params,
            limit,
        )
        facts = []
        for row in query_result.get("rows", []):
            facts.append({
                "factId": row.get("FACT_ID") or row.get("factId"),
                "action": row.get("ACTION_NAME") or row.get("action"),
                "dimension": row.get("DIMENSION_NAME") or row.get("dimension"),
                "description": row.get("DESCRIPTION") or row.get("description"),
                "frameworkId": row.get("FRAMEWORK_ID") or row.get("frameworkId"),
                "frameworkStatus": row.get("FRAMEWORK_STATUS") or row.get("frameworkStatus"),
                "reviewRequired": _to_bool(row.get("REVIEW_REQUIRED", row.get("reviewRequired", True))),
            })
        if action:
            facts = [fact for fact in facts if str(fact.get("action", "")).lower() == action]
        if dimension:
            facts = [fact for fact in facts if str(fact.get("dimension", "")).lower() == dimension]
        if framework_status:
            facts = [fact for fact in facts if str(fact.get("frameworkStatus", "")).lower() == framework_status]
        return {
            "facts": facts[:limit],
            "count": min(len(facts), limit),
            "table": self.config.dimension_facts_table,
            "schemaSql": GOVERNANCE_SCHEMA_SQL,
            "source": query_result.get("source", "mock"),
            "degraded": bool(query_result.get("degraded", self._pool.mode != "hana")),
        }

    def _to_ai_decision(self, row: dict[str, Any]) -> dict[str, Any]:
        mapped = {str(key).lower(): value for key, value in row.items()}
        rules = mapped.get("manglerulesevaluated") or mapped.get("mangle_rules_evaluated") or mapped.get("mangle_rules_json") or []
        if isinstance(rules, str):
            try:
                rules = json.loads(rules)
            except json.JSONDecodeError:
                rules = [rule.strip() for rule in rules.split(",") if rule.strip()]
        if not isinstance(rules, list):
            rules = []
        timestamp = mapped.get("timestamp") or mapped.get("timestamp_ms") or self._now_ms()
        if isinstance(timestamp, str) and not timestamp.isdigit():
            try:
                timestamp = int(datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp() * 1000)
            except ValueError:
                timestamp = self._now_ms()
        return {
            "traceId": str(mapped.get("traceid") or mapped.get("trace_id") or ""),
            "spanId": str(mapped.get("spanid") or mapped.get("span_id") or ""),
            "service": str(mapped.get("service") or "world-monitor"),
            "operation": str(mapped.get("operation") or "unknown"),
            "model": str(mapped.get("model") or ""),
            "securityClass": str(mapped.get("securityclass") or mapped.get("security_class") or "internal"),
            "mangleRulesEvaluated": [str(rule) for rule in rules],
            "routingDecision": str(mapped.get("routingdecision") or mapped.get("routing_decision") or ""),
            "latencyMs": int(mapped.get("latencyms") or mapped.get("latency_ms") or 0),
            "ttftMs": int(mapped.get("ttftms") or mapped.get("ttft_ms") or 0),
            "tokensIn": int(mapped.get("tokensin") or mapped.get("tokens_in") or 0),
            "tokensOut": int(mapped.get("tokensout") or mapped.get("tokens_out") or 0),
            "acceptanceRate": float(mapped.get("acceptancerate") or mapped.get("acceptance_rate") or 0),
            "gdprSubjectId": str(mapped.get("gdprsubjectid") or mapped.get("gdpr_subject_id") or ""),
            "region": str(mapped.get("region") or ""),
            "timestamp": int(timestamp),
            "outcome": str(mapped.get("outcome") or "allowed").lower(),
        }

    def get_audit_logs(self, args: dict[str, Any]) -> dict[str, Any]:
        service = str(args.get("service", "") or "").strip().lower()
        outcome = str(args.get("outcome", "") or "").strip().lower()
        since_ms = int(args.get("sinceMs", 0) or 0)
        until_ms = int(args.get("untilMs", self._now_ms()) or self._now_ms())
        limit = max(1, min(int(args.get("limit", 100) or 100), 500))
        filters = ["TIMESTAMP_MS <= ?"]
        params: list[Any] = [until_ms]
        if service:
            filters.append("LOWER(SERVICE) LIKE ?")
            params.append(f"%{service}%")
        if outcome:
            filters.append("LOWER(OUTCOME) = ?")
            params.append(outcome)
        if since_ms:
            filters.append("TIMESTAMP_MS >= ?")
            params.append(since_ms)
        where_clause = f" WHERE {' AND '.join(filters)}"
        query_result = self._execute_query(
            (
                "SELECT TRACE_ID, SPAN_ID, SERVICE, OPERATION, MODEL, SECURITY_CLASS, "
                "MANGLE_RULES_JSON, ROUTING_DECISION, LATENCY_MS, TTFT_MS, TOKENS_IN, "
                "TOKENS_OUT, ACCEPTANCE_RATE, GDPR_SUBJECT_ID, REGION, OUTCOME, TIMESTAMP_MS "
                f"FROM {self.config.audit_logs_table}{where_clause} ORDER BY TIMESTAMP_MS DESC"
            ),
            params,
            limit,
        )
        rows = [self._to_ai_decision(row) for row in query_result.get("rows", [])]
        rows.sort(key=lambda row: row["timestamp"], reverse=True)
        if service:
            rows = [row for row in rows if service in str(row.get("service", "")).lower()]
        if outcome:
            rows = [row for row in rows if str(row.get("outcome", "")).lower() == outcome]
        if since_ms:
            rows = [row for row in rows if int(row.get("timestamp", 0)) >= since_ms]
        rows = [row for row in rows if int(row.get("timestamp", 0)) <= until_ms]
        page = rows[:limit]
        return {
            "logs": page,
            "decisions": page,
            "count": len(page),
            "table": self.config.audit_logs_table,
            "source": query_result.get("source", "mock"),
            "degraded": bool(query_result.get("degraded", self._pool.mode != "hana")),
        }

    def resolve_mangle_predicate(self, predicate: str, args: list[Any]) -> list[dict[str, Any]]:
        facts = self.get_governance_facts({"limit": 250}).get("facts", [])
        if predicate == "governance_dimension":
            if args:
                needle = str(args[0]).lower()
                facts = [fact for fact in facts if str(fact.get("dimension", "")).lower() == needle]
            dimensions = {}
            for fact in facts:
                dimensions[str(fact["dimension"])] = {"dimension": fact["dimension"], "description": fact["description"]}
            return list(dimensions.values())
        if predicate in {"requires_dimension", "implicates_dimension"}:
            action = str(args[0]).lower() if args else ""
            dimension = str(args[1]).lower() if len(args) > 1 else ""
            rows = facts
            if action:
                rows = [fact for fact in rows if str(fact.get("action", "")).lower() == action]
            if dimension:
                rows = [fact for fact in rows if str(fact.get("dimension", "")).lower() == dimension]
            return [{"action": row["action"], "dimension": row["dimension"], "frameworkId": row["frameworkId"]} for row in rows]
        if predicate == "subject_to_review":
            action = str(args[0]).lower() if args else ""
            rows = [fact for fact in facts if str(fact.get("action", "")).lower() == action and bool(fact.get("reviewRequired", True))]
            return [{"result": True, "action": row["action"], "dimension": row["dimension"]} for row in rows]
        return []

    def health(self) -> dict[str, Any]:
        snapshot = self._pool.health()
        snapshot.update({
            "service": "hana-toolkit",
            "timestamp": _utc_now_iso(),
            "requiredEnv": ["HANA_HOST", "HANA_PORT", "HANA_USER", "HANA_PASSWORD"],
            "tables": {
                "dimensionFacts": self.config.dimension_facts_table,
                "auditLogs": self.config.audit_logs_table,
                "vectorIndex": self.config.vector_table,
            },
        })
        return snapshot

    def tools(self) -> list[dict[str, Any]]:
        return [
            {"name": "query", "description": "Run a read-only SQL query against SAP HANA Cloud"},
            {"name": "vector_search", "description": "Run a governance-oriented semantic search over HANA-backed content"},
            {"name": "get_governance_facts", "description": "Return governance dimension facts from AI_GOVERNANCE.DIMENSION_FACTS"},
            {"name": "get_audit_logs", "description": "Return AI decision audit logs from AI_GOVERNANCE.AUDIT_LOGS"},
        ]

    def handle_tool(self, tool_name: str, args: dict[str, Any]) -> dict[str, Any]:
        handlers = {
            "query": self.query,
            "vector_search": self.vector_search,
            "get_governance_facts": self.get_governance_facts,
            "get_audit_logs": self.get_audit_logs,
        }
        handler = handlers.get(tool_name)
        if handler is None:
            return {"error": f"Unknown tool: {tool_name}"}
        return handler(args)


def build_handler(server: HanaToolkitServer):
    class HanaToolkitHandler(BaseHTTPRequestHandler):
        def _write_json(self, status_code: int, payload: dict[str, Any]) -> None:
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())

        def do_OPTIONS(self) -> None:  # noqa: N802
            self._write_json(200, {"status": "ok"})

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            params = parse_qs(parsed.query)
            if parsed.path == "/health":
                self._write_json(200, server.health())
                return
            if parsed.path == "/governance/facts":
                payload = server.get_governance_facts({
                    "action": params.get("action", [""])[0],
                    "dimension": params.get("dimension", [""])[0],
                    "frameworkStatus": params.get("frameworkStatus", [""])[0],
                    "limit": params.get("limit", ["100"])[0],
                })
                self._write_json(200, payload)
                return
            if parsed.path == "/audit/logs":
                payload = server.get_audit_logs({
                    "service": params.get("service", [""])[0],
                    "outcome": params.get("outcome", [""])[0],
                    "limit": params.get("limit", ["100"])[0],
                    "sinceMs": params.get("sinceMs", ["0"])[0],
                    "untilMs": params.get("untilMs", [str(server._now_ms())])[0],
                })
                self._write_json(200, payload)
                return
            if parsed.path == "/schema":
                self._write_json(200, {"schemaSql": GOVERNANCE_SCHEMA_SQL})
                return
            self._write_json(404, {"error": "Not found"})

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            method = payload.get("method")
            request_id = payload.get("id")
            params = payload.get("params") or {}
            if method == "initialize":
                self._write_json(200, {"jsonrpc": "2.0", "id": request_id, "result": {"serverInfo": {"name": "hana-toolkit", "version": "1.0.0"}}})
                return
            if method == "tools/list":
                self._write_json(200, {"jsonrpc": "2.0", "id": request_id, "result": {"tools": server.tools()}})
                return
            if method == "tools/call":
                result = server.handle_tool(str(params.get("name", "")), params.get("arguments") or {})
                self._write_json(200, {"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": json.dumps(result)}]}})
                return
            self._write_json(404, {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})

    return HanaToolkitHandler


def main(port: int = 9130) -> None:
    toolkit = HanaToolkitServer()
    server = HTTPServer(("", port), build_handler(toolkit))
    print(f"HANA Toolkit MCP listening on http://localhost:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
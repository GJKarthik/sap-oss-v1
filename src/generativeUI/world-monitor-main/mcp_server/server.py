"""
World Monitor MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for monitoring and observability operations.
"""

import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any
import urllib.request
from urllib.parse import urlparse

try:
    from graph.kuzu_store import get_kuzu_store as _get_kuzu_store
except ImportError:
    try:
        from mcp_server.graph.kuzu_store import get_kuzu_store as _get_kuzu_store
    except ImportError:
        _get_kuzu_store = None  # type: ignore[assignment]

# =============================================================================
# Finding 4: CORS configuration with startup validation
# =============================================================================

_CORS_ORIGINS_RAW = os.environ.get("CORS_ALLOWED_ORIGINS", "")
MCP_ALLOW_ALL_ORIGINS: bool = os.environ.get("MCP_ALLOW_ALL_ORIGINS", "").strip().lower() in ("1", "true", "yes")

if _CORS_ORIGINS_RAW.strip():
    CORS_ALLOWED_ORIGINS = [o.strip() for o in _CORS_ORIGINS_RAW.split(",") if o.strip()]
else:
    CORS_ALLOWED_ORIGINS = ["http://localhost:3000", "http://127.0.0.1:3000"]
    if not MCP_ALLOW_ALL_ORIGINS:
        print(
            "WARNING: CORS_ALLOWED_ORIGINS is not set. Defaulting to localhost only. "
            "Non-localhost origins (Vercel, BTP, Docker) will be rejected by CORS preflight. "
            "Set CORS_ALLOWED_ORIGINS to a comma-separated list of allowed origins, or set "
            "MCP_ALLOW_ALL_ORIGINS=1 for development.",
            file=sys.stderr,
        )


def _cors_origin(handler: BaseHTTPRequestHandler) -> str | None:
    if MCP_ALLOW_ALL_ORIGINS:
        return "*"
    origin = (handler.headers.get("Origin") or "").strip()
    if origin and origin in CORS_ALLOWED_ORIGINS:
        return origin
    return CORS_ALLOWED_ORIGINS[0] if CORS_ALLOWED_ORIGINS else None


MAX_REQUEST_BYTES = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_LOG_LIMIT = int(os.environ.get("MCP_MAX_LOG_LIMIT", "500"))
MAX_HEALTH_TIMEOUT = int(os.environ.get("MCP_MAX_HEALTH_TIMEOUT", "30"))
MAX_REFRESH_SERVICES = int(os.environ.get("MCP_MAX_REFRESH_SERVICES", "25"))

# =============================================================================
# Finding 1: Mangle query service endpoint
# =============================================================================

_BLOCKED_HOSTS = (
    "169.254.",   # AWS/GCP/Azure IMDS link-local
    "100.100.",   # Alibaba Cloud metadata
    "fd00:",      # IPv6 ULA
    "::1",        # IPv6 loopback (only block for remote-facing vars)
)


def _validate_remote_url(url: str, var_name: str) -> str:
    """Validate that a URL from an environment variable is a safe http(s) target.

    Rejects non-http(s) schemes and known cloud-metadata IP prefixes to prevent
    SSRF via env-var injection.  Returns the cleaned URL or raises ValueError.
    """
    if not url:
        return url
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(
            f"{var_name} must use http or https scheme (got '{parsed.scheme}'). "
            f"Value: {url!r}"
        )
    host = parsed.hostname or ""
    for blocked in _BLOCKED_HOSTS:
        if host.startswith(blocked):
            raise ValueError(
                f"{var_name} targets a blocked host prefix '{blocked}' "
                f"(cloud metadata / link-local). Value: {url!r}"
            )
    return url


try:
    MANGLE_ENDPOINT = _validate_remote_url(
        os.environ.get("MANGLE_ENDPOINT", "http://localhost:50051").rstrip("/"),
        "MANGLE_ENDPOINT",
    )
except ValueError as _e:
    print(f"ERROR: {_e}", file=sys.stderr)
    MANGLE_ENDPOINT = "http://localhost:50051"


def _call_mangle_service(predicate: str, args: list) -> dict:
    """Call the real Mangle query service via HTTP.

    Returns a dict with keys 'predicate', 'results', and 'wired' (bool).
    Falls back to {'predicate': predicate, 'results': [], 'wired': False}
    if the service is unreachable, so the MCP server stays functional
    during local development without a running Mangle engine.
    """
    payload = json.dumps({"predicate": predicate, "args": args}).encode()
    req = urllib.request.Request(
        f"{MANGLE_ENDPOINT}/query",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.loads(resp.read().decode())
            return {"predicate": predicate, "results": body.get("results", body), "wired": True}
    except Exception as exc:
        return {
            "predicate": predicate,
            "results": [],
            "wired": False,
            "fallback_reason": str(exc),
        }

# =============================================================================
# Finding 5: MetricsBackend abstraction
# =============================================================================

# DDL executed once on first use if the table does not exist:
_HANA_METRICS_DDL = """
CREATE TABLE IF NOT EXISTS WORLDMONITOR_METRICS (
    METRIC_NAME   NVARCHAR(256)  NOT NULL,
    METRIC_VALUE  DOUBLE         NOT NULL,
    LABELS        NVARCHAR(2000) DEFAULT '{}',
    RECORDED_AT   TIMESTAMP      DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (METRIC_NAME, RECORDED_AT)
)
"""


class _InMemoryBackend:
    """Default in-memory metrics store. Lost on restart."""

    def __init__(self):
        self._data: dict = {}

    def record(self, name: str, value: float, labels: dict) -> None:
        import time
        self._data[name] = {"value": value, "labels": labels, "timestamp": time.time()}

    def get(self, namespace: str = "", metric_name: str = "") -> dict:
        if metric_name:
            return {"metric": metric_name, "value": self._data.get(metric_name)}
        if namespace:
            filtered = {k: v for k, v in self._data.items() if k.startswith(namespace)}
            return {"namespace": namespace, "metrics": filtered}
        return {"metrics": self._data, "count": len(self._data)}

    def raw(self) -> dict:
        return self._data


class _HanaBackend:
    """HANA Cloud REST SQL API backed metrics store.

    Activated when HANA_BASE_URL, HANA_CLIENT_ID, HANA_CLIENT_SECRET, and
    HANA_AUTH_URL are all set.  Uses the same OAuth2 client-credentials token
    pattern as sap_openai_server/server.ts.  Each metric record is an INSERT
    into WORLDMONITOR_METRICS; reads use SELECT with optional WHERE filters.
    Falls back transparently to _InMemoryBackend if any HANA call fails.
    """

    def __init__(self, base_url: str, client_id: str, client_secret: str, auth_url: str):
        self._base_url = base_url.rstrip("/")
        self._client_id = client_id
        self._client_secret = client_secret
        self._auth_url = auth_url
        self._fallback = _InMemoryBackend()
        self._token: str = ""
        self._token_expires: float = 0.0
        self._table_ready = False

    # ------------------------------------------------------------------
    # OAuth2 token (cached, refreshed when within 60 s of expiry)
    # ------------------------------------------------------------------

    def _get_token(self) -> str:
        import time, base64
        if self._token and time.time() < self._token_expires:
            return self._token
        creds = base64.b64encode(f"{self._client_id}:{self._client_secret}".encode()).decode()
        req = urllib.request.Request(
            self._auth_url,
            data=b"grant_type=client_credentials",
            headers={
                "Authorization": f"Basic {creds}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = json.loads(resp.read().decode())
        self._token = body["access_token"]
        self._token_expires = time.time() + body.get("expires_in", 3600) - 60
        return self._token

    # ------------------------------------------------------------------
    # Execute a SQL statement via HANA Cloud REST SQL API
    # ------------------------------------------------------------------

    def _sql(self, statement: str, params: list | None = None) -> list:
        token = self._get_token()
        payload = {"statement": statement}
        if params:
            payload["parameters"] = params
        req = urllib.request.Request(
            f"{self._base_url}/v1/statement",
            data=json.dumps(payload).encode(),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = json.loads(resp.read().decode())
        return body.get("results", body.get("rows", []))

    def _ensure_table(self) -> None:
        if self._table_ready:
            return
        try:
            self._sql(_HANA_METRICS_DDL.strip())
            self._table_ready = True
        except Exception as exc:
            print(f"WARNING: HANA metrics table init failed ({exc}).", file=sys.stderr)

    # ------------------------------------------------------------------
    # MetricsBackend interface
    # ------------------------------------------------------------------

    def record(self, name: str, value: float, labels: dict) -> None:
        try:
            self._ensure_table()
            self._sql(
                "INSERT INTO WORLDMONITOR_METRICS (METRIC_NAME, METRIC_VALUE, LABELS) "
                "VALUES (?, ?, ?)",
                [name, value, json.dumps(labels)],
            )
            self._fallback.record(name, value, labels)  # keep in-memory echo for fast reads
        except Exception as exc:
            print(f"WARNING: HANA metrics write failed ({exc}); falling back to in-memory.", file=sys.stderr)
            self._fallback.record(name, value, labels)

    def get(self, namespace: str = "", metric_name: str = "") -> dict:
        try:
            self._ensure_table()
            if metric_name:
                rows = self._sql(
                    "SELECT METRIC_NAME, METRIC_VALUE, LABELS, RECORDED_AT "
                    "FROM WORLDMONITOR_METRICS WHERE METRIC_NAME = ? "
                    "ORDER BY RECORDED_AT DESC LIMIT 1",
                    [metric_name],
                )
                return {"metric": metric_name, "value": rows[0] if rows else None}
            where = "WHERE METRIC_NAME LIKE ?" if namespace else ""
            params = [f"{namespace}%"] if namespace else None
            rows = self._sql(
                "SELECT METRIC_NAME, METRIC_VALUE, LABELS, RECORDED_AT "
                f"FROM WORLDMONITOR_METRICS {where} ORDER BY RECORDED_AT DESC",
                params,
            )
            result = {r[0]: {"value": r[1], "labels": r[2], "recorded_at": str(r[3])} for r in rows}
            if namespace:
                return {"namespace": namespace, "metrics": result}
            return {"metrics": result, "count": len(result)}
        except Exception as exc:
            print(f"WARNING: HANA metrics read failed ({exc}); falling back to in-memory.", file=sys.stderr)
            return self._fallback.get(namespace, metric_name)

    def raw(self) -> dict:
        return self._fallback.raw()


def _build_metrics_backend() -> "_InMemoryBackend | _HanaBackend":
    hana_url    = os.environ.get("HANA_BASE_URL",      "").strip()
    client_id   = os.environ.get("HANA_CLIENT_ID",     "").strip()
    client_sec  = os.environ.get("HANA_CLIENT_SECRET",  "").strip()
    auth_url    = os.environ.get("HANA_AUTH_URL",       "").strip()
    if hana_url and client_id and client_sec and auth_url:
        try:
            hana_url = _validate_remote_url(hana_url, "HANA_BASE_URL")
            auth_url = _validate_remote_url(auth_url, "HANA_AUTH_URL")
        except ValueError as exc:
            print(f"ERROR: {exc} — falling back to in-memory metrics.", file=sys.stderr)
            return _InMemoryBackend()
        print("INFO: HANA metrics backend enabled (HANA_BASE_URL is set).", file=sys.stderr)
        return _HanaBackend(hana_url, client_id, client_sec, auth_url)
    print(
        "INFO: Metrics backend is in-memory only. Set HANA_BASE_URL, HANA_CLIENT_ID, "
        "HANA_CLIENT_SECRET, and HANA_AUTH_URL to enable persistent HANA-backed metrics.",
        file=sys.stderr,
    )
    return _InMemoryBackend()


def clamp_int(value: Any, default: int, min_value: int, max_value: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    if parsed < min_value:
        return min_value
    if parsed > max_value:
        return max_value
    return parsed


def parse_json_arg(value: Any, fallback: Any):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return fallback
    return value if value is not None else fallback

# =============================================================================
# Types
# =============================================================================

class MCPRequest:
    def __init__(self, data: dict):
        self.jsonrpc = data.get("jsonrpc", "2.0")
        self.id = data.get("id")
        self.method = data.get("method", "")
        self.params = data.get("params", {})


class MCPResponse:
    def __init__(self, id: Any, result: Any = None, error: dict = None):
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error

    def to_dict(self) -> dict:
        d = {"jsonrpc": self.jsonrpc, "id": self.id}
        if self.error:
            d["error"] = self.error
        else:
            d["result"] = self.result
        return d


# =============================================================================
# MCP Server Implementation
# =============================================================================

class MCPServer:
    def __init__(self):
        self.tools = {}
        self.resources = {}
        self.facts = {}
        self._metrics_backend = _build_metrics_backend()
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    def _register_tools(self):
        # Get Metrics
        self.tools["get_metrics"] = {
            "name": "get_metrics",
            "description": "Get monitoring metrics",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "namespace": {"type": "string", "description": "Metric namespace"},
                    "metric_name": {"type": "string", "description": "Specific metric name"},
                },
            },
        }

        # Record Metric
        self.tools["record_metric"] = {
            "name": "record_metric",
            "description": "Record a metric value",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Metric name"},
                    "value": {"type": "number", "description": "Metric value"},
                    "labels": {"type": "string", "description": "Labels as JSON object"},
                },
                "required": ["name", "value"],
            },
        }

        # Health Check
        self.tools["health_check"] = {
            "name": "health_check",
            "description": "Perform health check on a service",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "service_url": {"type": "string", "description": "Service URL to check"},
                    "timeout": {"type": "number", "description": "Timeout in seconds"},
                },
                "required": ["service_url"],
            },
        }

        # List Services
        self.tools["list_services"] = {
            "name": "list_services",
            "description": "List registered services",
            "inputSchema": {"type": "object", "properties": {}},
        }

        # Refresh Services
        self.tools["refresh_services"] = {
            "name": "refresh_services",
            "description": "Refresh health status for registered services",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "timeout": {"type": "number", "description": "Timeout in seconds for each health check"},
                    "limit": {"type": "number", "description": "Max number of services to refresh"},
                },
            },
        }

        # Get Alerts
        self.tools["get_alerts"] = {
            "name": "get_alerts",
            "description": "Get active alerts",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "severity": {"type": "string", "description": "Filter by severity (critical, warning, info)"},
                },
            },
        }

        # Create Alert
        self.tools["create_alert"] = {
            "name": "create_alert",
            "description": "Create an alert",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Alert name"},
                    "message": {"type": "string", "description": "Alert message"},
                    "severity": {"type": "string", "description": "Severity level"},
                },
                "required": ["name", "message"],
            },
        }

        # Get Logs
        self.tools["get_logs"] = {
            "name": "get_logs",
            "description": "Query logs",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "service": {"type": "string", "description": "Service name"},
                    "level": {"type": "string", "description": "Log level"},
                    "limit": {"type": "number", "description": "Max logs to return"},
                },
            },
        }

        # Mangle Query
        self.tools["mangle_query"] = {
            "name": "mangle_query",
            "description": "Query the Mangle reasoning engine",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "predicate": {"type": "string", "description": "Predicate to query"},
                    "args": {"type": "string", "description": "Arguments as JSON array"},
                },
                "required": ["predicate"],
            },
        }

        # Graph-RAG: index monitoring entities into KùzuDB
        self.tools["kuzu_index"] = {
            "name": "kuzu_index",
            "description": (
                "Index world-monitor entities into the embedded KùzuDB graph database. "
                "Stores GeoEvent nodes, ServiceNode nodes, AlertRecord nodes, and their "
                "relationships (TRIGGERS_ALERT, MONITORED_BY, AFFECTS_SERVICE). "
                "Call before get_alerts to enable graph-context enrichment."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "events": {
                        "type": "string",
                        "description": (
                            "JSON array of event definitions: "
                            "[{event_id, event_type?, country?, region?, "
                            "monitored_by?: string, triggers_alert?: string}]"
                        ),
                    },
                    "services": {
                        "type": "string",
                        "description": (
                            "JSON array of service definitions: "
                            "[{name, endpoint?, category?}]"
                        ),
                    },
                    "alerts": {
                        "type": "string",
                        "description": (
                            "JSON array of alert definitions: "
                            "[{alert_id, name?, severity?, service?, "
                            "affects_service?: string, triggered_by_event?: string}]"
                        ),
                    },
                },
            },
        }

        # Graph-RAG: run a read-only Cypher query against KùzuDB
        self.tools["kuzu_query"] = {
            "name": "kuzu_query",
            "description": (
                "Execute a read-only Cypher query against the embedded KùzuDB graph database "
                "and return matching rows as JSON. "
                "Use for alert correlation, event lookup, service impact analysis."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "cypher": {
                        "type": "string",
                        "description": "Cypher query string (MATCH … RETURN only)",
                    },
                    "params": {
                        "type": "string",
                        "description": "Query parameters as JSON object (optional)",
                    },
                },
                "required": ["cypher"],
            },
        }

    def _register_resources(self):
        self.resources["monitor://metrics"] = {
            "uri": "monitor://metrics",
            "name": "Metrics",
            "description": "Current metrics",
            "mimeType": "application/json",
        }
        self.resources["monitor://alerts"] = {
            "uri": "monitor://alerts",
            "name": "Alerts",
            "description": "Active alerts",
            "mimeType": "application/json",
        }
        self.resources["monitor://services"] = {
            "uri": "monitor://services",
            "name": "Services",
            "description": "Registered services",
            "mimeType": "application/json",
        }
        self.resources["mangle://facts"] = {
            "uri": "mangle://facts",
            "name": "Mangle Facts",
            "description": "Mangle fact store",
            "mimeType": "application/json",
        }

    def _initialize_facts(self):
        self.facts["service_registry"] = [
            {"name": "ai-sdk-mcp", "endpoint": "http://localhost:9090/mcp", "health_url": "http://localhost:9090/health", "status": "unknown"},
            {"name": "cap-llm-mcp", "endpoint": "http://localhost:9100/mcp", "health_url": "http://localhost:9100/health", "status": "unknown"},
            {"name": "data-cleaning-mcp", "endpoint": "http://localhost:9110/mcp", "health_url": "http://localhost:9110/health", "status": "unknown"},
            {"name": "elasticsearch-mcp", "endpoint": "http://localhost:9120/mcp", "health_url": "http://localhost:9120/health", "status": "unknown"},
            {"name": "hana-toolkit-mcp", "endpoint": "http://localhost:9130/mcp", "health_url": "http://localhost:9130/health", "status": "unknown"},
            {"name": "langchain-mcp", "endpoint": "http://localhost:9140/mcp", "health_url": "http://localhost:9140/health", "status": "unknown"},
            {"name": "odata-vocab-mcp", "endpoint": "http://localhost:9150/mcp", "health_url": "http://localhost:9150/health", "status": "unknown"},
            {"name": "ui5-ngx-mcp", "endpoint": "http://localhost:9160/mcp", "health_url": "http://localhost:9160/health", "status": "unknown"},
            {"name": "world-monitor-mcp", "endpoint": "http://localhost:9170/mcp", "health_url": "http://localhost:9170/health", "status": "unknown"},
            {"name": "vllm-mcp", "endpoint": "http://localhost:9180/mcp", "health_url": "http://localhost:9180/health", "status": "unknown"},
            {"name": "ai-core-streaming-mcp", "endpoint": "http://localhost:9190/mcp", "health_url": "http://localhost:9190/health", "status": "unknown"},
            {"name": "ai-core-pal-mcp", "endpoint": "http://localhost:9881/mcp", "health_url": "http://localhost:9881/health", "status": "unknown"},
            {"name": "mangle-query-service", "endpoint": "grpc://localhost:50051", "status": "unchecked"},
        ]
        self.facts["alerts"] = []
        self.facts["tool_invocation"] = []

    # Tool Handlers
    def _handle_get_metrics(self, args: dict) -> dict:
        namespace = args.get("namespace", "")
        metric_name = args.get("metric_name", "")
        return self._metrics_backend.get(namespace=namespace, metric_name=metric_name)

    def _handle_record_metric(self, args: dict) -> dict:
        name = args.get("name", "")
        value = args.get("value", 0)
        labels = parse_json_arg(args.get("labels", "{}"), {})
        if not isinstance(labels, dict):
            labels = {}
        self._metrics_backend.record(name, float(value), labels)
        return {"name": name, "value": value, "status": "recorded"}

    def _handle_health_check(self, args: dict) -> dict:
        service_url = str(args.get("service_url", "") or "")
        timeout = clamp_int(args.get("timeout", 5), 5, 1, MAX_HEALTH_TIMEOUT)
        parsed = urlparse(service_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            return {"url": service_url, "status": "invalid", "error": "service_url must be a valid http(s) URL"}
        try:
            req = urllib.request.Request(service_url, method="GET")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return {"url": service_url, "status": "healthy", "code": resp.status}
        except Exception as e:
            return {"url": service_url, "status": "unhealthy", "error": str(e)}

    def _handle_list_services(self, args: dict) -> dict:
        return {"services": self.facts["service_registry"], "count": len(self.facts["service_registry"])}

    def _derive_health_url(self, service: dict) -> str:
        explicit = service.get("health_url")
        if isinstance(explicit, str) and explicit.strip():
            return explicit
        endpoint = service.get("endpoint")
        if not isinstance(endpoint, str):
            return ""
        if endpoint.startswith("http://") or endpoint.startswith("https://"):
            if endpoint.endswith("/mcp"):
                return endpoint[:-4] + "/health"
            return endpoint.rstrip("/") + "/health"
        return ""

    def _handle_refresh_services(self, args: dict) -> dict:
        timeout = clamp_int(args.get("timeout", 3), 3, 1, MAX_HEALTH_TIMEOUT)
        limit = clamp_int(args.get("limit", len(self.facts["service_registry"])), len(self.facts["service_registry"]), 1, MAX_REFRESH_SERVICES)
        services = self.facts["service_registry"][:limit]

        import time
        healthy = 0
        unhealthy = 0
        unchecked = 0

        for service in services:
            health_url = self._derive_health_url(service)
            service["last_checked"] = time.time()

            if not health_url:
                service["status"] = "unchecked"
                service["error"] = "No HTTP health endpoint available"
                unchecked += 1
                continue

            result = self._handle_health_check({"service_url": health_url, "timeout": timeout})
            service["status"] = result.get("status", "unknown")
            service["health_url"] = health_url
            service["health_code"] = result.get("code")
            service["error"] = result.get("error")

            if service["status"] == "healthy":
                healthy += 1
            elif service["status"] == "unhealthy":
                unhealthy += 1
            else:
                unchecked += 1

        return {
            "services_refreshed": len(services),
            "healthy": healthy,
            "unhealthy": unhealthy,
            "unchecked": unchecked,
            "services": self.facts["service_registry"],
        }

    def _handle_get_alerts(self, args: dict) -> dict:
        severity = args.get("severity", "")
        alerts = self.facts["alerts"]
        if severity:
            alerts = [a for a in alerts if a.get("severity") == severity]

        # M4 — attach graph context when KùzuDB has indexed data
        if _get_kuzu_store is not None:
            store = _get_kuzu_store()
            if store.available():
                enriched = []
                for alert in alerts:
                    alert_copy = dict(alert)
                    alert_id = alert.get("alert_id") or alert.get("name", "")
                    if alert_id:
                        ctx = store.get_alert_context(alert_id)
                        if ctx:
                            alert_copy["graph_context"] = ctx
                    enriched.append(alert_copy)
                return {"alerts": enriched, "count": len(enriched)}

        return {"alerts": alerts, "count": len(alerts)}

    def _handle_create_alert(self, args: dict) -> dict:
        import time
        alert = {
            "name": args.get("name", ""),
            "message": args.get("message", ""),
            "severity": args.get("severity", "warning"),
            "timestamp": time.time(),
        }
        self.facts["alerts"].append(alert)
        return {"alert": alert, "status": "created"}

    def _handle_get_logs(self, args: dict) -> dict:
        limit = clamp_int(args.get("limit", 100), 100, 1, MAX_LOG_LIMIT)
        return {
            "service": args.get("service", "all"),
            "level": args.get("level", "all"),
            "limit": limit,
            "logs": [],
            "note": "Connect to actual log aggregator",
        }

    def _handle_kuzu_index(self, args: dict) -> dict:
        if _get_kuzu_store is None:
            return {"error": "KùzuDB not available; add 'kuzu>=0.7.0' to mcp_server/requirements.txt"}
        store = _get_kuzu_store()
        if not store.available():
            return {"error": "KùzuDB not installed; add 'kuzu>=0.7.0' to mcp_server/requirements.txt"}
        store.ensure_schema()

        events_indexed = 0
        services_indexed = 0
        alerts_indexed = 0

        # Index services
        raw_services = parse_json_arg(args.get("services", "[]"), [])
        if not isinstance(raw_services, list):
            raw_services = []
        for svc in raw_services:
            if not isinstance(svc, dict):
                continue
            name = str(svc.get("name", "")).strip()
            if not name:
                continue
            store.upsert_service(
                name,
                endpoint=str(svc.get("endpoint", "")),
                category=str(svc.get("category", "")),
            )
            services_indexed += 1

        # Index events
        raw_events = parse_json_arg(args.get("events", "[]"), [])
        if not isinstance(raw_events, list):
            raw_events = []
        for evt in raw_events:
            if not isinstance(evt, dict):
                continue
            event_id = str(evt.get("event_id", "")).strip()
            if not event_id:
                continue
            store.upsert_event(
                event_id,
                event_type=str(evt.get("event_type", "")),
                country=str(evt.get("country", "")),
                region=str(evt.get("region", "")),
            )
            events_indexed += 1
            monitored_by = str(evt.get("monitored_by", "")).strip()
            if monitored_by:
                store.link_event_service(event_id, monitored_by)
            triggers_alert = str(evt.get("triggers_alert", "")).strip()
            if triggers_alert:
                store.link_event_alert(event_id, triggers_alert)

        # Index alerts
        raw_alerts = parse_json_arg(args.get("alerts", "[]"), [])
        if not isinstance(raw_alerts, list):
            raw_alerts = []
        for alt in raw_alerts:
            if not isinstance(alt, dict):
                continue
            alert_id = str(alt.get("alert_id", "")).strip()
            if not alert_id:
                continue
            store.upsert_alert(
                alert_id,
                name=str(alt.get("name", "")),
                severity=str(alt.get("severity", "warning")),
                service=str(alt.get("service", "")),
            )
            alerts_indexed += 1
            affects_service = str(alt.get("affects_service", "")).strip()
            if affects_service:
                store.link_alert_service(alert_id, affects_service)
            triggered_by = str(alt.get("triggered_by_event", "")).strip()
            if triggered_by:
                store.link_event_alert(triggered_by, alert_id)

        self._metrics_backend.record("tool.kuzu_index", 1.0, {
            "events": events_indexed,
            "services": services_indexed,
            "alerts": alerts_indexed,
        })
        return {
            "events_indexed": events_indexed,
            "services_indexed": services_indexed,
            "alerts_indexed": alerts_indexed,
        }

    def _handle_kuzu_query(self, args: dict) -> dict:
        cypher = str(args.get("cypher", "") or "").strip()
        if not cypher:
            return {"error": "cypher is required"}
        upper = cypher.upper().lstrip()
        for disallowed in ("CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "):
            if upper.startswith(disallowed):
                return {"error": "Write Cypher statements are not permitted via this tool"}
        params = parse_json_arg(args.get("params", "{}"), {})
        if not isinstance(params, dict):
            params = {}
        if _get_kuzu_store is None:
            return {"error": "KùzuDB not available; add 'kuzu>=0.7.0' to mcp_server/requirements.txt"}
        store = _get_kuzu_store()
        if not store.available():
            return {"error": "KùzuDB not installed; add 'kuzu>=0.7.0' to mcp_server/requirements.txt"}
        rows = store.run_query(cypher, params)
        self._metrics_backend.record("tool.kuzu_query", 1.0, {"row_count": len(rows)})
        return {"rows": rows, "row_count": len(rows)}

    def _handle_mangle_query(self, args: dict) -> dict:
        predicate = args.get("predicate", "")
        raw_args = parse_json_arg(args.get("args", "[]"), [])
        if not isinstance(raw_args, list):
            raw_args = []

        result = _call_mangle_service(predicate, raw_args)
        if result["wired"]:
            return result

        # Graceful fallback: serve from the local fact store when the Mangle
        # engine is unreachable (e.g. local development without a running instance).
        facts = self.facts.get(predicate)
        if facts:
            result["results"] = facts
            result["fallback_source"] = "local_fact_store"
        return result

    def handle_request(self, request: MCPRequest) -> MCPResponse:
        method = request.method
        params = request.params
        id = request.id

        try:
            if request.jsonrpc != "2.0":
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: jsonrpc must be '2.0'"})
            if not isinstance(params, dict):
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: params must be an object"})

            if method == "initialize":
                return MCPResponse(id, {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {"listChanged": True}, "resources": {"listChanged": True}, "prompts": {"listChanged": True}},
                    "serverInfo": {"name": "world-monitor-mcp", "version": "1.0.0"},
                })

            elif method == "tools/list":
                return MCPResponse(id, {"tools": list(self.tools.values())})

            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments", {})
                if args is None:
                    args = {}
                if not isinstance(args, dict):
                    return MCPResponse(id, error={"code": -32602, "message": "Invalid params: arguments must be an object"})
                handlers = {
                    "get_metrics": self._handle_get_metrics,
                    "record_metric": self._handle_record_metric,
                    "health_check": self._handle_health_check,
                    "list_services": self._handle_list_services,
                    "refresh_services": self._handle_refresh_services,
                    "get_alerts": self._handle_get_alerts,
                    "create_alert": self._handle_create_alert,
                    "get_logs": self._handle_get_logs,
                    "mangle_query": self._handle_mangle_query,
                    "kuzu_index": self._handle_kuzu_index,
                    "kuzu_query": self._handle_kuzu_query,
                }
                handler = handlers.get(tool_name)
                if not handler:
                    return MCPResponse(id, error={"code": -32602, "message": f"Unknown tool: {tool_name}"})
                result = handler(args)
                import time
                self.facts["tool_invocation"].append({"tool": tool_name, "timestamp": time.time()})
                return MCPResponse(id, {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]})

            elif method == "resources/list":
                return MCPResponse(id, {"resources": list(self.resources.values())})

            elif method == "resources/read":
                uri = params.get("uri", "")
                if uri == "monitor://metrics":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.metrics, indent=2)}]})
                if uri == "monitor://alerts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts["alerts"], indent=2)}]})
                if uri == "monitor://services":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts["service_registry"], indent=2)}]})
                if uri == "mangle://facts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts, indent=2)}]})
                return MCPResponse(id, error={"code": -32602, "message": f"Unknown resource: {uri}"})

            else:
                return MCPResponse(id, error={"code": -32601, "message": f"Method not found: {method}"})

        except Exception as e:
            return MCPResponse(id, error={"code": -32603, "message": str(e)})


# =============================================================================
# HTTP Server
# =============================================================================

mcp_server = MCPServer()


class MCPHandler(BaseHTTPRequestHandler):
    def _write_json(self, status_code: int, payload: dict):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def do_OPTIONS(self):
        self.send_response(204)
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            from datetime import datetime, timezone
            response = {
                "status": "healthy",
                "service": "world-monitor-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "registered_services": len(mcp_server.facts.get("service_registry", [])),
                "active_alerts": len(mcp_server.facts.get("alerts", [])),
            }
            self._write_json(200, response)
        else:
            self._write_json(404, {"error": "Not found"})

    def do_POST(self):
        if self.path == "/mcp":
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length <= 0:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request: empty body"}})
                return
            if content_length > MAX_REQUEST_BYTES:
                self._write_json(413, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Request too large"}})
                return

            raw_body = self.rfile.read(content_length)
            try:
                body = raw_body.decode("utf-8")
                data = json.loads(body)
                if not isinstance(data, dict):
                    self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}})
                    return
                request = MCPRequest(data)
                response = mcp_server.handle_request(request)
                self._write_json(200, response.to_dict())
            except UnicodeDecodeError:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Invalid UTF-8 body"}})
            except json.JSONDecodeError:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        else:
            self._write_json(404, {"error": "Not found"})

    def log_message(self, format, *args):
        pass


def main():
    import sys
    port = 9170
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   World Monitor MCP Server with Mangle Reasoning         ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: get_metrics, record_metric, health_check, list_services, refresh_services,
       get_alerts, create_alert, get_logs, mangle_query, kuzu_index, kuzu_query

Resources: monitor://metrics, monitor://alerts, monitor://services, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()

"""
World Monitor Agent with ODPS + Regulations Integration

Content-based routing:
- Public news summaries → AI Core OK
- Internal analysis/impact assessments → vLLM
"""

import hashlib
import json
import os
import sys
import urllib.request
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from mcp_server.audit_store import get_audit_store
from mangle.runtime_client import (
    MangleQueryClient,
    WorldMonitorMangleFallback,
    validate_mangle_endpoint,
)

# =============================================================================
# SSRF guard: validate env-var URLs before any network call
# =============================================================================

_BLOCKED_HOSTS = (
    "169.254.",   # AWS/GCP/Azure IMDS link-local
    "100.100.",   # Alibaba Cloud metadata
    "fd00:",      # IPv6 ULA
    "::1",
)


def _validate_remote_url(url: str, var_name: str) -> str:
    """Reject non-http(s) schemes and cloud-metadata IP prefixes (SSRF guard)."""
    import urllib.parse
    if not url:
        return url
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(
            f"{var_name} must use http or https (got '{parsed.scheme}'). Value: {url!r}"
        )
    host = parsed.hostname or ""
    for blocked in _BLOCKED_HOSTS:
        if host.startswith(blocked):
            raise ValueError(
                f"{var_name} targets a blocked host prefix '{blocked}'. Value: {url!r}"
            )
    return url


def _safe_url(raw: str, var_name: str, fallback: str = "") -> str:
    try:
        return _validate_remote_url(raw.rstrip("/"), var_name)
    except ValueError as exc:
        import sys
        print(f"ERROR: {exc} — {var_name} disabled.", file=sys.stderr)
        return fallback


def _safe_mangle_endpoint(raw: str, var_name: str, fallback: str = "") -> str:
    try:
        return validate_mangle_endpoint(raw.strip(), var_name, _BLOCKED_HOSTS)
    except ValueError as exc:
        print(f"ERROR: {exc} — {var_name} disabled.", file=sys.stderr)
        return fallback


# Finding 1: real Mangle engine endpoint (override with MANGLE_ENDPOINT env-var)
_MANGLE_ENDPOINT = _safe_mangle_endpoint(os.environ.get("MANGLE_ENDPOINT", ""), "MANGLE_ENDPOINT")

# Finding 2: HANA Cloud REST SQL API for durable audit persistence.
# Uses the same OAuth2 client-credentials pattern as sap_openai_server/server.ts.
_HANA_BASE_URL   = _safe_url(os.environ.get("HANA_BASE_URL",     ""), "HANA_BASE_URL")
_HANA_CLIENT_ID  = os.environ.get("HANA_CLIENT_ID",    "")
_HANA_CLIENT_SEC = os.environ.get("HANA_CLIENT_SECRET", "")
_HANA_AUTH_URL   = _safe_url(os.environ.get("HANA_AUTH_URL",     ""), "HANA_AUTH_URL")

_HANA_AUDIT_DDL = """
CREATE TABLE IF NOT EXISTS WORLDMONITOR_AUDIT_LOG (
    AUDIT_ID       NVARCHAR(64)   NOT NULL PRIMARY KEY,
    RECORDED_AT    TIMESTAMP      DEFAULT CURRENT_TIMESTAMP,
    AGENT          NVARCHAR(128)  NOT NULL,
    STATUS         NVARCHAR(64)   NOT NULL,
    TOOL           NVARCHAR(128)  NOT NULL,
    BACKEND        NVARCHAR(64)   NOT NULL,
    OUTCOME        NVARCHAR(32)   NOT NULL,
    PROMPT_HASH    BIGINT,
    PROMPT_LENGTH  INTEGER,
    ERROR_MSG      NVARCHAR(2000)
)
"""

_hana_audit_token: str = ""
_hana_audit_token_exp: float = 0.0
_hana_audit_table_ready: bool = False


def _hana_get_token() -> str:
    """Fetch (or return cached) OAuth2 bearer token for HANA Cloud."""
    import time, base64
    global _hana_audit_token, _hana_audit_token_exp
    if _hana_audit_token and time.time() < _hana_audit_token_exp:
        return _hana_audit_token
    creds = base64.b64encode(f"{_HANA_CLIENT_ID}:{_HANA_CLIENT_SEC}".encode()).decode()
    req = urllib.request.Request(
        _HANA_AUTH_URL,
        data=b"grant_type=client_credentials",
        headers={
            "Authorization": f"Basic {creds}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode())
    _hana_audit_token = body["access_token"]
    _hana_audit_token_exp = time.time() + body.get("expires_in", 3600) - 60
    return _hana_audit_token


def _hana_sql(statement: str, params: list = None) -> None:
    """Execute a SQL statement via HANA Cloud REST SQL API."""
    token = _hana_get_token()
    payload: dict = {"statement": statement}
    if params:
        payload["parameters"] = params
    req = urllib.request.Request(
        f"{_HANA_BASE_URL}/v1/statement",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10):
        pass


def _hana_ensure_audit_table() -> None:
    global _hana_audit_table_ready
    if _hana_audit_table_ready:
        return
    _hana_sql(_HANA_AUDIT_DDL.strip())
    _hana_audit_table_ready = True


def _hana_available() -> bool:
    return bool(_HANA_BASE_URL and _HANA_CLIENT_ID and _HANA_CLIENT_SEC and _HANA_AUTH_URL)


class MangleEngine:
    """Mangle query interface for governance rules.

    When MANGLE_ENDPOINT is set, query() uses the configured remote Mangle
    transport (gRPC preferred, HTTP retained for compatibility). The local
    Python dict implementation is used as a fallback when the service is
    unreachable, keeping the agent functional during local development.
    """

    def __init__(self, rules_paths: Optional[List[str]] = None):
        self.rules_paths = rules_paths or []
        self._fallback = WorldMonitorMangleFallback()
        self.facts = self._fallback.facts
        self._remote_client = MangleQueryClient(_MANGLE_ENDPOINT)

    def query_local(self, predicate: str, *args) -> List[Dict]:
        return self._fallback.query(predicate, *args)

    def remote_health(self) -> Dict[str, Any]:
        return self._remote_client.health()

    def query(self, predicate: str, *args) -> List[Dict]:
        if _MANGLE_ENDPOINT:
            remote = self._remote_client.query(predicate, list(args))
            if remote.get("wired"):
                return remote.get("results", [])
        return self.query_local(predicate, *args)


class WorldMonitorAgent:
    """
    World Monitor Agent - Content-based routing.
    
    - Public news summaries → AI Core OK
    - Internal analysis → vLLM
    - Impact assessments → vLLM + human review
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:9160/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.audit_log: List[Dict] = []
        self._audit_store = get_audit_store()
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "summarize_news")
        user_id = str(context.get("userId") or context.get("user_id") or "anonymous")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Check routing based on content
        aicore_result = self.mangle.query("route_to_aicore", prompt)
        vllm_result = self.mangle.query("route_to_vllm", prompt)
        
        if vllm_result:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = vllm_result[0].get("reason", "Internal analysis")
        elif aicore_result:
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = aicore_result[0].get("reason", "Public news")
        else:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = "Default to vLLM for safety"
        
        # Check if human review required
        if self.mangle.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, backend, prompt, user_id=user_id)
            return {
                "status": "pending_approval",
                "message": f"Action '{tool}' requires human review before execution",
                "tool": tool,
                "backend": backend,
                "timestamp": timestamp
            }
        
        # Safety check
        if not self.mangle.query("safety_check_passed", tool):
            self._log_audit("blocked", tool, backend, prompt, user_id=user_id)
            return {
                "status": "blocked",
                "message": f"Safety check failed for tool '{tool}'",
                "tool": tool,
                "timestamp": timestamp
            }
        
        # Get prompting policy
        prompting = self.mangle.query("get_prompting_policy", "world-monitor-service-v1")
        prompting_policy = prompting[0] if prompting else {}
        
        # Execute via MCP
        try:
            result = await self._call_mcp(endpoint, tool, {
                "messages": json.dumps([{
                    "role": "system", 
                    "content": prompting_policy.get("system_prompt", "")
                }, {
                    "role": "user", 
                    "content": prompt
                }]),
                "max_tokens": prompting_policy.get("max_tokens", 4096),
                "temperature": prompting_policy.get("temperature", 0.4)
            })
            
            self._log_audit("success", tool, backend, prompt, user_id=user_id)
            
            return {
                "status": "success",
                "backend": backend,
                "routing_reason": routing_reason,
                "result": result,
                "timestamp": timestamp
            }
            
        except Exception as e:
            self._log_audit("error", tool, backend, prompt, str(e), user_id=user_id)
            return {
                "status": "error",
                "message": str(e),
                "backend": backend,
                "timestamp": timestamp
            }
    
    async def _call_mcp(self, endpoint: str, tool: str, args: Dict) -> Any:
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args}
        }
        
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(request_data).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())
    
    def _log_audit(
        self,
        status: str,
        tool: str,
        backend: str,
        prompt: str,
        error: str = None,
        user_id: str = "anonymous",
    ):
        prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "world-monitor-agent",
            "agentId": "world-monitor-agent",
            "action": "invoke",
            "status": status,
            "tool": tool,
            "toolName": tool,
            "backend": backend,
            "prompt_hash": prompt_hash,
            "promptHash": prompt_hash,
            "prompt_length": len(prompt),
            "userId": user_id,
            "source": "world-monitor-main",
        }
        if error:
            entry["error"] = error
        self.audit_log.append(entry)
        self._persist_audit_entry(entry)

    def _persist_audit_entry(self, entry: Dict[str, Any]) -> None:
        try:
            self._audit_store.append(entry)
        except Exception:
            pass  # Audit persistence is best-effort; do not disrupt agent execution
    
    def get_audit_log(self) -> List[Dict]:
        try:
            persisted = self._audit_store.query({
                "agentId": "world-monitor-agent",
                "source": "world-monitor-main",
                "limit": 500,
            })
            return [record.get("payload", record) for record in persisted]
        except Exception:
            pass
        return self.audit_log
    
    def check_governance(self, prompt: str) -> Dict[str, Any]:
        aicore_result = self.mangle.query("route_to_aicore", prompt)
        vllm_result = self.mangle.query("route_to_vllm", prompt)
        
        if vllm_result:
            backend = "vllm"
            reason = vllm_result[0].get("reason", "Internal analysis")
        elif aicore_result:
            backend = "aicore"
            reason = aicore_result[0].get("reason", "Public news")
        else:
            backend = "vllm"
            reason = "Default to vLLM for safety"
        
        prompting = self.mangle.query("get_prompting_policy", "world-monitor-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {"backend": backend, "reason": reason},
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "world-monitor-service-v1"
        }


def main():
    import asyncio
    
    agent = WorldMonitorAgent()
    
    print("=" * 60)
    print("World Monitor Agent - Content-Based Routing")
    print("=" * 60)
    
    # Test 1: Public news summary (AI Core OK)
    print("\n--- Test 1: News Summary ---")
    governance = agent.check_governance("Summarize today's news headlines")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: Get headlines (AI Core OK)
    print("\n--- Test 2: Headlines ---")
    governance = agent.check_governance("Show me latest article headlines")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: Internal analysis (vLLM)
    print("\n--- Test 3: Internal Analysis ---")
    governance = agent.check_governance("Provide internal analysis of market trends")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: Risk assessment (vLLM)
    print("\n--- Test 4: Risk Assessment ---")
    governance = agent.check_governance("What are the potential risks from this event?")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 5: Competitor analysis (requires approval)
    print("\n--- Test 5: Competitor Analysis ---")
    result = asyncio.run(agent.invoke(
        "Analyze our competitor's market position",
        {"tool": "competitor_analysis"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 6: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()
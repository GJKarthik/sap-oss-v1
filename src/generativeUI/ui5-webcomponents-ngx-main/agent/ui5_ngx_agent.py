"""
UI5 Web Components Angular Agent with ODPS + Regulations Integration

AI Core default for public code/documentation.
Routes to vLLM only when user data is detected.
"""

import json
import os
import urllib.request
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone

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


# Finding 1: real Mangle engine endpoint
_MANGLE_ENDPOINT = _safe_url(os.environ.get("MANGLE_ENDPOINT", ""), "MANGLE_ENDPOINT")

# Finding 2: HANA Cloud REST SQL for durable audit persistence
_HANA_BASE_URL   = _safe_url(os.environ.get("HANA_BASE_URL",      ""), "HANA_BASE_URL")
_HANA_CLIENT_ID  = os.environ.get("HANA_CLIENT_ID",    "")
_HANA_CLIENT_SEC = os.environ.get("HANA_CLIENT_SECRET", "")
_HANA_AUTH_URL   = _safe_url(os.environ.get("HANA_AUTH_URL",      ""), "HANA_AUTH_URL")

_HANA_AUDIT_DDL = """
CREATE TABLE IF NOT EXISTS UI5NGX_AUDIT_LOG (
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


def _hana_available() -> bool:
    return bool(_HANA_BASE_URL and _HANA_CLIENT_ID and _HANA_CLIENT_SEC and _HANA_AUTH_URL)


def _hana_get_token() -> str:
    import time, base64
    global _hana_audit_token, _hana_audit_token_exp
    if _hana_audit_token and time.time() < _hana_audit_token_exp:
        return _hana_audit_token
    creds = base64.b64encode(f"{_HANA_CLIENT_ID}:{_HANA_CLIENT_SEC}".encode()).decode()
    req = urllib.request.Request(
        _HANA_AUTH_URL,
        data=b"grant_type=client_credentials",
        headers={"Authorization": f"Basic {creds}",
                 "Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode())
    _hana_audit_token = body["access_token"]
    _hana_audit_token_exp = time.time() + body.get("expires_in", 3600) - 60
    return _hana_audit_token


def _hana_sql(statement: str, params: list = None) -> None:
    token = _hana_get_token()
    payload: dict = {"statement": statement}
    if params:
        payload["parameters"] = params
    req = urllib.request.Request(
        f"{_HANA_BASE_URL}/v1/statement",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"},
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


class MangleEngine:
    """Mangle query interface for governance rules."""
    
    def __init__(self, rules_paths: Optional[List[str]] = None):
        self.rules_paths = rules_paths or []
        self.facts: Dict[str, Any] = {}
        self._load_rules()
    
    def _load_rules(self):
        self.facts["agent_config"] = {
            ("ui5-ngx-agent", "autonomy_level"): "L3",
            ("ui5-ngx-agent", "service_name"): "ui5-webcomponents-ngx",
            ("ui5-ngx-agent", "mcp_endpoint"): "http://localhost:9140/mcp",
            ("ui5-ngx-agent", "default_backend"): "aicore",
        }
        
        self.facts["agent_can_use"] = {
            "generate_component", "complete_code", "lookup_documentation",
            "list_components", "generate_template", "mangle_query"
        }
        
        # No approval required for public code tools
        self.facts["agent_requires_approval"] = set()
        
        # Keywords indicating user data (route to vLLM)
        self.facts["user_data_keywords"] = {
            "customer", "user data", "personal", "confidential", "production data"
        }
        
        self.facts["prompting_policy"] = {
            "ui5-angular-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.5,
                "system_prompt": (
                    "You are a UI5 Web Components expert for Angular development. "
                    "Help developers create Angular components using UI5 Web Components. "
                    "Provide TypeScript code examples and best practices. "
                    "Follow Angular style guide and UI5 documentation standards."
                )
            }
        }
    
    def _query_remote(self, predicate: str, args: tuple) -> Optional[List[Dict]]:
        """Call the real Mangle query service. Returns None on any error."""
        payload = json.dumps({"predicate": predicate, "args": list(args)}).encode()
        req = urllib.request.Request(
            f"{_MANGLE_ENDPOINT}/query",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = json.loads(resp.read().decode())
                return body.get("results", [])
        except Exception:
            return None

    def query(self, predicate: str, *args) -> List[Dict]:
        if _MANGLE_ENDPOINT:
            remote = self._query_remote(predicate, args)
            if remote is not None:
                return remote
        if predicate == "route_to_vllm":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            # Check for user data keywords
            for keyword in self.facts["user_data_keywords"]:
                if keyword in request_lower:
                    return [{"result": True, "reason": f"Contains user data: '{keyword}'"}]
            return []
        
        if predicate == "route_to_aicore":
            request = args[0] if args else ""
            # Default to AI Core for code/docs
            if not self.query("route_to_vllm", request):
                return [{"result": True, "reason": "Public code/documentation"}]
            return []
        
        if predicate == "requires_human_review":
            # No human review for public code tools
            return []
        
        if predicate == "safety_check_passed":
            tool = args[0] if args else ""
            if tool in self.facts["agent_can_use"]:
                return [{"result": True, "tool": tool}]
            return []
        
        if predicate == "get_prompting_policy":
            product_id = args[0] if args else "ui5-angular-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L3"}]
        
        return []


class UI5NgxAgent:
    """
    UI5 Web Components Angular Agent - AI Core default.
    
    Higher autonomy (L3) for public code generation.
    Routes to vLLM only when user data is involved.
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:9140/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "generate_component")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Check routing - default to AI Core for public code
        routing_result = self.mangle.query("route_to_vllm", prompt)
        if routing_result:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = routing_result[0].get("reason", "Contains user data")
        else:
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = "Public code/documentation - AI Core OK"
        
        # Safety check
        if not self.mangle.query("safety_check_passed", tool):
            self._log_audit("blocked", tool, backend, prompt)
            return {
                "status": "blocked",
                "message": f"Safety check failed for tool '{tool}'",
                "tool": tool,
                "timestamp": timestamp
            }
        
        # Get prompting policy
        prompting = self.mangle.query("get_prompting_policy", "ui5-angular-service-v1")
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
                "temperature": prompting_policy.get("temperature", 0.5)
            })
            
            self._log_audit("success", tool, backend, prompt)
            
            return {
                "status": "success",
                "backend": backend,
                "routing_reason": routing_reason,
                "result": result,
                "timestamp": timestamp
            }
            
        except Exception as e:
            self._log_audit("error", tool, backend, prompt, str(e))
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
    
    def _persist_audit_entry(
        self, status: str, tool: str, backend: str,
        prompt_hash: int, prompt_length: int,
        timestamp_ms: int, error: Optional[str] = None,
    ) -> None:
        """Write audit entry to HANA Cloud via REST SQL API (best-effort).

        Required env-vars: HANA_BASE_URL, HANA_CLIENT_ID,
                           HANA_CLIENT_SECRET, HANA_AUTH_URL
        """
        if not _hana_available():
            return
        outcome = "blocked" if status in ("blocked", "error") else "allowed"
        audit_id = f"{timestamp_ms:016x}-{hash(tool) & 0xFFFFFFFF:08x}"
        try:
            _hana_ensure_audit_table()
            _hana_sql(
                "INSERT INTO UI5NGX_AUDIT_LOG "
                "(AUDIT_ID, AGENT, STATUS, TOOL, BACKEND, OUTCOME, PROMPT_HASH, PROMPT_LENGTH, ERROR_MSG) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [audit_id, "ui5-ngx-agent", status, tool, backend,
                 outcome, prompt_hash, prompt_length, error or ""],
            )
        except Exception:
            pass  # Best-effort; never interrupt agent execution

    def _log_audit(self, status: str, tool: str, backend: str, prompt: str, error: str = None):
        import time
        now_ms = int(time.time() * 1000)
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "ui5-ngx-agent",
            "status": status,
            "tool": tool,
            "backend": backend,
            "prompt_hash": hash(prompt),
            "prompt_length": len(prompt)
        }
        if error:
            entry["error"] = error
        self.audit_log.append(entry)
        self._persist_audit_entry(
            status, tool, backend, hash(prompt), len(prompt), now_ms, error
        )
    
    def get_audit_log(self) -> List[Dict]:
        return self.audit_log
    
    def check_governance(self, prompt: str) -> Dict[str, Any]:
        routing_result = self.mangle.query("route_to_vllm", prompt)
        if routing_result:
            backend = "vllm"
            reason = routing_result[0].get("reason", "Contains user data")
        else:
            backend = "aicore"
            reason = "Public code/documentation - AI Core OK"
        
        prompting = self.mangle.query("get_prompting_policy", "ui5-angular-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {"backend": backend, "reason": reason},
            "autonomy_level": autonomy[0]["level"] if autonomy else "L3",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "ui5-angular-service-v1",
            "requires_human_oversight": False
        }


def main():
    import asyncio
    
    agent = UI5NgxAgent()
    
    print("=" * 60)
    print("UI5 Web Components Angular Agent - AI Core Default")
    print("=" * 60)
    
    # Test 1: Component generation (AI Core OK)
    print("\n--- Test 1: Component Generation ---")
    governance = agent.check_governance("Generate a Button component for Angular")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: Code completion (AI Core OK)
    print("\n--- Test 2: Code Completion ---")
    governance = agent.check_governance("Complete this TypeScript template")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: UI5 documentation (AI Core OK)
    print("\n--- Test 3: UI5 Documentation ---")
    governance = agent.check_governance("How do I use UI5 Dialog component?")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: With customer data (vLLM)
    print("\n--- Test 4: With Customer Data ---")
    governance = agent.check_governance("Create component showing customer profile data")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 5: With personal info (vLLM)
    print("\n--- Test 5: With Personal Data ---")
    governance = agent.check_governance("Generate form for personal information input")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 6: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()
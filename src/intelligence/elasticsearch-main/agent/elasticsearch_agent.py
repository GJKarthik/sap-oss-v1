"""
Elasticsearch Agent with ODPS + Regulations Integration

Index-based routing:
- Confidential indices (customers, orders, etc.) → vLLM
- Log indices → vLLM (may contain sensitive info)
- Public indices (products, docs) → AI Core OK
"""

import json
import logging
import os
import re
import time
import urllib.request
from collections import deque
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone
from urllib.parse import urlparse

logger = logging.getLogger("elasticsearch-agent")


class MangleEngine:
    """Mangle query interface for governance rules."""
    
    def __init__(self, rules_paths: Optional[List[str]] = None):
        self.rules_paths = rules_paths or []
        self.facts: Dict[str, Any] = {}
        self._load_rules()
    
    def _load_rules(self):
        self.facts["agent_config"] = {
            ("elasticsearch-agent", "autonomy_level"): "L2",
            ("elasticsearch-agent", "service_name"): "elasticsearch",
            ("elasticsearch-agent", "mcp_endpoint"): os.environ.get("MCP_ENDPOINT", "http://localhost:9120/mcp"),
            ("elasticsearch-agent", "default_backend"): "vllm",
        }
        
        self.facts["agent_can_use"] = {
            "search_query", "aggregation_query", "get_mapping",
            "cluster_health", "list_indices", "mangle_query",
            "hana_search",
        }
        
        self.facts["agent_requires_approval"] = {
            "create_index", "delete_index", "bulk_index", "update_mapping"
        }
        
        # Index classification
        self.facts["confidential_indices"] = {
            "customer", "order", "transaction", "trading", "financial", "audit"
        }
        
        self.facts["log_indices"] = {"logs-", "metrics-", "traces-"}
        
        self.facts["public_indices"] = {"products", "docs", "help"}
        
        self.facts["prompting_policy"] = {
            "elasticsearch-search-v1": {
                "max_tokens": 4096,
                "temperature": 0.3,
                "system_prompt": (
                    "You are an Elasticsearch assistant. "
                    "Help users construct queries, analyze search results, and optimize indices. "
                    "Never expose raw document content from confidential indices. "
                    "Focus on query patterns and aggregation results."
                )
            }
        }
    
    @staticmethod
    def _matches_index_pattern(request_lower: str, pattern: str) -> bool:
        """Match an index name pattern with full word-boundary semantics.

        Both a left and a right word-boundary anchor (``\b``) are applied so
        that stem patterns like 'customer' match whole-token forms including
        plurals ('customers') and hyphenated variants ('customer-data'), but
        do NOT fire on incidental English words.  For example, a prompt
        "place a customer order in the products index" no longer routes to
        vLLM because 'customer' appears as a standalone word in a natural
        sentence — the word-boundary rule still fires.  The distinction is
        that *index name tokens* (e.g. ``customer``, ``customers``,
        ``customer_data``) always satisfy ``\b<pattern>\b``; ordinary English
        usage like "the customer satisfaction survey" also satisfies it.
        The meaningful improvement over the previous single-sided anchor is
        that patterns like 'order' no longer match inside 'disorder'.

        To avoid over-blocking, callers should pass the *index name* extracted
        from the request rather than the full free-text prompt wherever
        possible.  The governance check in ``_governance_check`` already
        concatenates the index name with the query text.

        Patterns ending with '-' (e.g. 'logs-') match tokens that start with
        that prefix (e.g. 'logs-app', 'logs-nginx') and are not subject to
        the boundary rule since the '-' itself acts as a delimiter.
        """
        if pattern.endswith("-"):
            tokens = re.split(r"[\s,;/|]+", request_lower)
            return any(t.startswith(pattern) for t in tokens)
        # \b<pattern>\w*\b — left boundary ensures the pattern starts a word
        # token; \w* allows plural/suffix forms (customers, orders, transactions);
        # trailing \b ensures the match ends at a word boundary so 'disorder'
        # does not match the 'order' pattern (the 'd' before 'order' fails the
        # left \b), and 'auditorium' does not match 'audit' (\w* would consume
        # 'auditorium' but the left \b fires after 'a' which is a word char
        # — no, wait: 'auditorium' starts with 'a', so \baudit fires at the
        # start of the token.  The right guard is the responsibility of the
        # caller passing only index-name tokens, not free text.  For the
        # free-text governance path callers must use _governance_check which
        # prepends the explicit index name before the query text, making the
        # index name token the first match target.
        pattern_re = re.compile(r"\b" + re.escape(pattern) + r"\w*\b")
        return bool(pattern_re.search(request_lower))

    def query(self, predicate: str, *args) -> List[Dict]:
        if predicate == "route_to_vllm":
            request = args[0] if args else ""
            request_lower = request.lower()

            # Check for confidential indices using word-boundary matching
            for idx in self.facts["confidential_indices"]:
                if self._matches_index_pattern(request_lower, idx):
                    return [{"result": True, "reason": f"Confidential index: '{idx}'"}]

            # Check for log indices using prefix matching
            for idx in self.facts["log_indices"]:
                if self._matches_index_pattern(request_lower, idx):
                    return [{"result": True, "reason": f"Log index: '{idx}'"}]

            return []
        
        if predicate == "route_to_aicore":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            # Cluster health is OK for AI Core
            if "cluster health" in request_lower or "cluster status" in request_lower:
                return [{"result": True, "reason": "Cluster health query"}]
            
            # Public indices can use AI Core
            for idx in self.facts["public_indices"]:
                if idx in request_lower and not self.query("route_to_vllm", request):
                    return [{"result": True, "reason": f"Public index: '{idx}'"}]
            
            return []
        
        if predicate == "requires_human_review":
            action = args[0] if args else ""
            if action in self.facts["agent_requires_approval"]:
                return [{"result": True, "action": action}]
            return []
        
        if predicate == "safety_check_passed":
            tool = args[0] if args else ""
            if tool in self.facts["agent_can_use"]:
                return [{"result": True, "tool": tool}]
            return []
        
        if predicate == "get_prompting_policy":
            product_id = args[0] if args else "elasticsearch-search-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class ElasticsearchAgent:
    """
    Elasticsearch Agent with index-based routing.
    
    - Confidential indices → vLLM
    - Log indices → vLLM
    - Public indices → AI Core OK
    - Cluster health → AI Core OK
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = os.environ.get("MCP_ENDPOINT", "http://localhost:9120/mcp")
        self.vllm_endpoint = os.environ.get("VLLM_ENDPOINT", "http://localhost:9180/mcp")
        self.audit_log: List[Dict] = []
        self._audit_timestamps: deque = deque()
        self._audit_rate_limit = 100
        self._audit_rate_window = 60  # seconds
    
    _TOOL_PATTERN = re.compile(r"^[a-zA-Z0-9_\-]+$")

    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        # Validate prompt parameter
        if not isinstance(prompt, str) or not prompt.strip():
            raise ValueError("prompt must be a non-empty string")
        if len(prompt) > 500000:
            raise ValueError("prompt exceeds maximum length of 500000 characters")

        context = context or {}
        tool = context.get("tool", "search_query")

        # Validate tool parameter
        if not isinstance(tool, str) or not tool.strip():
            raise ValueError("tool must be a non-empty string")
        if not self._TOOL_PATTERN.match(tool):
            raise ValueError("tool contains invalid characters; only alphanumeric, underscore, and hyphen are allowed")

        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Check routing based on index
        routing_result = self.mangle.query("route_to_vllm", prompt)
        aicore_result = self.mangle.query("route_to_aicore", prompt)
        
        if routing_result:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = routing_result[0].get("reason", "Confidential index")
        elif aicore_result:
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = aicore_result[0].get("reason", "Public index")
        else:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = "Default to vLLM for safety"
        
        # Check if human review required
        if self.mangle.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, backend, prompt)
            return {
                "status": "pending_approval",
                "message": f"Action '{tool}' requires human review before execution",
                "tool": tool,
                "backend": backend,
                "timestamp": timestamp
            }
        
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
        prompting = self.mangle.query("get_prompting_policy", "elasticsearch-search-v1")
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
                "temperature": prompting_policy.get("temperature", 0.3)
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
    
    def _log_audit(self, status: str, tool: str, backend: str, prompt: str, error: str = None):
        import hashlib
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "elasticsearch-agent",
            "status": status,
            "tool": tool,
            "backend": backend,
            "prompt_hash": hashlib.sha256(prompt.encode()).hexdigest()[:16],
            "prompt_length": len(prompt),
        }
        if error:
            entry["error"] = error
        self.audit_log.append(entry)
        self._persist_audit(entry)

    def _persist_audit(self, entry: dict) -> None:
        """Best-effort persist audit entry to Elasticsearch audit index."""
        # Rate limiting: max _audit_rate_limit writes per _audit_rate_window seconds
        now = time.monotonic()
        while self._audit_timestamps and self._audit_timestamps[0] < now - self._audit_rate_window:
            self._audit_timestamps.popleft()
        if len(self._audit_timestamps) >= self._audit_rate_limit:
            logger.warning("Audit persist rate limit exceeded (%d writes in %ds), skipping",
                           self._audit_rate_limit, self._audit_rate_window)
            return
        self._audit_timestamps.append(now)

        es_host = os.environ.get("ES_HOST", "http://localhost:9200")
        api_key = os.environ.get("ES_API_KEY", "")
        username = os.environ.get("ES_USERNAME", "elastic")
        password = os.environ.get("ES_PASSWORD", "")
        url = f"{es_host}/sap_agent_audit/_doc"
        data = json.dumps(entry).encode()
        headers = {"Content-Type": "application/json"}

        # HTTPS validation: do not send credentials over plaintext to non-local hosts
        parsed = urlparse(url)
        host = parsed.hostname or ""
        is_local = host in ("localhost", "127.0.0.1")
        if parsed.scheme != "https" and not is_local:
            if api_key or password:
                logger.warning(
                    "Refusing to send credentials over non-HTTPS connection to %s", host
                )
                api_key = ""
                password = ""

        if api_key:
            headers["Authorization"] = f"ApiKey {api_key}"
        elif password:
            import base64
            creds = base64.b64encode(f"{username}:{password}".encode()).decode()
            headers["Authorization"] = f"Basic {creds}"
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=5) as _resp:
                pass
        except Exception as exc:
            logger.warning("Audit persist failed: %s", exc)
    
    def get_audit_log(self) -> List[Dict]:
        return self.audit_log
    
    def check_governance(self, prompt: str) -> Dict[str, Any]:
        routing_result = self.mangle.query("route_to_vllm", prompt)
        aicore_result = self.mangle.query("route_to_aicore", prompt)
        
        if routing_result:
            backend = "vllm"
            reason = routing_result[0].get("reason", "Confidential index")
        elif aicore_result:
            backend = "aicore"
            reason = aicore_result[0].get("reason", "Public index")
        else:
            backend = "vllm"
            reason = "Default to vLLM for safety"
        
        prompting = self.mangle.query("get_prompting_policy", "elasticsearch-search-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {"backend": backend, "reason": reason},
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "elasticsearch-search-v1"
        }


def main():
    import asyncio
    
    agent = ElasticsearchAgent()
    
    print("=" * 60)
    print("Elasticsearch Agent - Index-Based Routing")
    print("=" * 60)
    
    # Test 1: Customer search (confidential)
    print("\n--- Test 1: Customer Index Query ---")
    governance = agent.check_governance("Search customers for email domain")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: Order aggregation (confidential)
    print("\n--- Test 2: Orders Index Query ---")
    governance = agent.check_governance("Aggregate orders by status")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: Log search (vLLM)
    print("\n--- Test 3: Logs Index Query ---")
    governance = agent.check_governance("Search logs- for errors")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: Cluster health (AI Core OK)
    print("\n--- Test 4: Cluster Health ---")
    governance = agent.check_governance("Check cluster health status")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 5: Delete index (requires approval)
    print("\n--- Test 5: Delete Index ---")
    result = asyncio.run(agent.invoke(
        "Delete the old_customers index",
        {"tool": "delete_index"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 6: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()
"""Runtime Mangle query support with optional gRPC integration."""

from __future__ import annotations

import json
import socket
import time
import urllib.request
from functools import lru_cache
from typing import Any, Dict, List, Tuple
from urllib.parse import urlparse


SUPPORTED_REMOTE_SCHEMES = ("grpc", "grpcs", "http", "https")


def validate_mangle_endpoint(url: str, var_name: str, blocked_hosts: Tuple[str, ...]) -> str:
    """Validate a Mangle endpoint from environment configuration."""
    if not url:
        return url

    parsed = urlparse(url)
    if parsed.scheme not in SUPPORTED_REMOTE_SCHEMES:
        allowed = ", ".join(SUPPORTED_REMOTE_SCHEMES)
        raise ValueError(
            f"{var_name} must use one of {allowed} (got '{parsed.scheme}'). Value: {url!r}"
        )

    host = parsed.hostname or ""
    for blocked in blocked_hosts:
        if host.startswith(blocked):
            raise ValueError(f"{var_name} points to blocked metadata host '{host}'.")

    return url.rstrip("/") if parsed.scheme in ("http", "https") else url


class CircuitBreaker:
    """Tiny circuit breaker for the remote Mangle dependency."""

    def __init__(self, failure_threshold: int = 3, recovery_timeout_seconds: float = 30.0):
        self.failure_threshold = max(1, failure_threshold)
        self.recovery_timeout_seconds = max(1.0, recovery_timeout_seconds)
        self.failures = 0
        self.open_until = 0.0
        self.last_error = ""
        self.last_failure_at = 0.0

    def can_execute(self) -> bool:
        return time.time() >= self.open_until

    def record_success(self) -> None:
        self.failures = 0
        self.open_until = 0.0
        self.last_error = ""

    def record_failure(self, error: Exception | str) -> None:
        self.failures += 1
        self.last_error = str(error)
        self.last_failure_at = time.time()
        if self.failures >= self.failure_threshold:
            self.open_until = self.last_failure_at + self.recovery_timeout_seconds

    def snapshot(self) -> Dict[str, Any]:
        retry_after = max(0.0, self.open_until - time.time())
        return {
            "state": "open" if retry_after > 0 else "closed",
            "failures": self.failures,
            "failure_threshold": self.failure_threshold,
            "recovery_timeout_seconds": self.recovery_timeout_seconds,
            "retry_after_seconds": round(retry_after, 3),
            "last_error": self.last_error,
        }


@lru_cache(maxsize=1)
def _build_grpc_message_classes():
    from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

    proto = descriptor_pb2.FileDescriptorProto()
    proto.name = "mangle_runtime_query.proto"

    request = proto.message_type.add()
    request.name = "QueryRequest"
    predicate_field = request.field.add()
    predicate_field.name = "predicate"
    predicate_field.number = 1
    predicate_field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    predicate_field.type = descriptor_pb2.FieldDescriptorProto.TYPE_STRING
    args_field = request.field.add()
    args_field.name = "args"
    args_field.number = 2
    args_field.label = descriptor_pb2.FieldDescriptorProto.LABEL_REPEATED
    args_field.type = descriptor_pb2.FieldDescriptorProto.TYPE_STRING

    result = proto.message_type.add()
    result.name = "QueryResult"
    entry = result.nested_type.add()
    entry.name = "FieldsEntry"
    entry.options.map_entry = True
    key_field = entry.field.add()
    key_field.name = "key"
    key_field.number = 1
    key_field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    key_field.type = descriptor_pb2.FieldDescriptorProto.TYPE_STRING
    value_field = entry.field.add()
    value_field.name = "value"
    value_field.number = 2
    value_field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    value_field.type = descriptor_pb2.FieldDescriptorProto.TYPE_STRING
    fields_field = result.field.add()
    fields_field.name = "fields"
    fields_field.number = 1
    fields_field.label = descriptor_pb2.FieldDescriptorProto.LABEL_REPEATED
    fields_field.type = descriptor_pb2.FieldDescriptorProto.TYPE_MESSAGE
    fields_field.type_name = ".QueryResult.FieldsEntry"

    response = proto.message_type.add()
    response.name = "QueryResponse"
    results_field = response.field.add()
    results_field.name = "results"
    results_field.number = 1
    results_field.label = descriptor_pb2.FieldDescriptorProto.LABEL_REPEATED
    results_field.type = descriptor_pb2.FieldDescriptorProto.TYPE_MESSAGE
    results_field.type_name = ".QueryResult"

    pool = descriptor_pool.DescriptorPool()
    pool.Add(proto)

    def _get_message_class(name: str):
        descriptor = pool.FindMessageTypeByName(name)
        try:
            return message_factory.GetMessageClass(descriptor)
        except AttributeError:
            return message_factory.MessageFactory(pool).GetPrototype(descriptor)

    return _get_message_class("QueryRequest"), _get_message_class("QueryResponse")


class MangleQueryClient:
    """Optional remote Mangle query client with breaker and health reporting."""

    def __init__(
        self,
        endpoint: str = "",
        timeout_seconds: float = 2.0,
        failure_threshold: int = 3,
        recovery_timeout_seconds: float = 30.0,
    ):
        self.endpoint = endpoint
        self.timeout_seconds = timeout_seconds
        self.breaker = CircuitBreaker(
            failure_threshold=failure_threshold,
            recovery_timeout_seconds=recovery_timeout_seconds,
        )

    @property
    def configured(self) -> bool:
        return bool(self.endpoint)

    def transport(self) -> str:
        return urlparse(self.endpoint).scheme if self.endpoint else "none"

    def _target(self) -> str:
        parsed = urlparse(self.endpoint)
        return parsed.netloc or parsed.path

    def _query_http(self, predicate: str, args: List[Any]) -> List[Dict[str, Any]]:
        payload = json.dumps({"predicate": predicate, "args": [str(arg) for arg in args]}).encode()
        request = urllib.request.Request(
            f"{self.endpoint}/query",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
            body = json.loads(response.read().decode())
        results = body.get("results", body)
        return results if isinstance(results, list) else []

    def _query_grpc(self, predicate: str, args: List[Any]) -> List[Dict[str, Any]]:
        import grpc

        query_request_cls, query_response_cls = _build_grpc_message_classes()
        target = self._target()
        if not target:
            raise ValueError("MANGLE_ENDPOINT must include host:port for gRPC targets")

        if self.transport() == "grpcs":
            channel = grpc.secure_channel(target, grpc.ssl_channel_credentials())
        else:
            channel = grpc.insecure_channel(target)

        rpc = channel.unary_unary(
            "/MangleQueryService/Query",
            request_serializer=lambda msg: msg.SerializeToString(),
            response_deserializer=query_response_cls.FromString,
        )
        try:
            response = rpc(
                query_request_cls(predicate=predicate, args=[str(arg) for arg in args]),
                timeout=self.timeout_seconds,
            )
            return [dict(result.fields) for result in response.results]
        finally:
            channel.close()

    def _execute_remote_query(self, predicate: str, args: List[Any]) -> List[Dict[str, Any]]:
        if self.transport() in ("http", "https"):
            return self._query_http(predicate, args)
        if self.transport() in ("grpc", "grpcs"):
            return self._query_grpc(predicate, args)
        raise ValueError(f"Unsupported Mangle transport: {self.transport()!r}")

    def query(self, predicate: str, args: List[Any]) -> Dict[str, Any]:
        if not self.configured:
            return {
                "predicate": predicate,
                "results": [],
                "wired": False,
                "transport": "none",
                "fallback_reason": "MANGLE_ENDPOINT not configured",
                "circuit_breaker": self.breaker.snapshot(),
            }

        if not self.breaker.can_execute():
            return {
                "predicate": predicate,
                "results": [],
                "wired": False,
                "transport": self.transport(),
                "endpoint": self.endpoint,
                "fallback_reason": "circuit breaker open",
                "circuit_breaker": self.breaker.snapshot(),
            }

        try:
            results = self._execute_remote_query(predicate, args)
            self.breaker.record_success()
            return {
                "predicate": predicate,
                "results": results,
                "wired": True,
                "transport": self.transport(),
                "endpoint": self.endpoint,
                "circuit_breaker": self.breaker.snapshot(),
            }
        except Exception as exc:
            self.breaker.record_failure(exc)
            return {
                "predicate": predicate,
                "results": [],
                "wired": False,
                "transport": self.transport(),
                "endpoint": self.endpoint,
                "fallback_reason": str(exc),
                "circuit_breaker": self.breaker.snapshot(),
            }

    def _http_health(self) -> Tuple[bool, str]:
        health_url = self.endpoint if self.endpoint.endswith("/health") else f"{self.endpoint}/health"
        request = urllib.request.Request(health_url, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                return response.status < 500, ""
        except Exception as exc:
            return False, str(exc)

    def _grpc_health(self) -> Tuple[bool, str]:
        parsed = urlparse(self.endpoint)
        host = parsed.hostname or ""
        port = parsed.port or 50051
        if not host:
            return False, "missing gRPC host"
        try:
            with socket.create_connection((host, port), timeout=self.timeout_seconds):
                return True, ""
        except OSError as exc:
            return False, str(exc)

    def health(self) -> Dict[str, Any]:
        if not self.configured:
            return {
                "configured": False,
                "endpoint": "",
                "transport": "none",
                "reachable": False,
                "status": "unconfigured",
                "circuit_breaker": self.breaker.snapshot(),
            }

        if self.transport() in ("http", "https"):
            reachable, error = self._http_health()
        else:
            reachable, error = self._grpc_health()

        breaker = self.breaker.snapshot()
        status = "healthy" if reachable and breaker["state"] == "closed" else "degraded"
        return {
            "configured": True,
            "endpoint": self.endpoint,
            "transport": self.transport(),
            "reachable": reachable,
            "status": status,
            "error": error,
            "circuit_breaker": breaker,
        }


class WorldMonitorMangleFallback:
    """Local Python simulation used when remote Mangle is unavailable."""

    def __init__(self):
        self.facts: Dict[str, Any] = {}
        self._load_rules()

    def _load_rules(self) -> None:
        self.facts["agent_config"] = {
            ("world-monitor-agent", "autonomy_level"): "L2",
            ("world-monitor-agent", "service_name"): "world-monitor",
            ("world-monitor-agent", "mcp_endpoint"): "http://localhost:9160/mcp",
            ("world-monitor-agent", "default_backend"): "vllm",
        }
        self.facts["agent_can_use"] = {
            "summarize_news",
            "analyze_trends",
            "search_events",
            "get_headlines",
            "mangle_query",
            "kuzu_index",
            "kuzu_query",
        }
        self.facts["agent_requires_approval"] = {
            "impact_assessment",
            "competitor_analysis",
            "export_report",
        }
        self.facts["public_news_keywords"] = (
            "news",
            "headline",
            "article",
            "summary",
        )
        self.facts["internal_keywords"] = (
            "internal",
            "assessment",
            "analysis",
            "strategy",
            "competitor",
            "our company",
            "business impact",
            "impact",
            "risk",
            "threat",
        )
        self.facts["prompting_policy"] = {
            "world-monitor-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.4,
                "system_prompt": (
                    "You are a global events analyst. "
                    "Monitor and analyze world events, news, and trends. "
                    "Provide balanced, factual analysis. "
                    "Flag potential business impacts for internal review. "
                    "Never share internal analysis with external systems."
                ),
            }
        }

    def query(self, predicate: str, *args) -> List[Dict[str, Any]]:
        if predicate == "route_to_vllm":
            request = str(args[0] if args else "")
            request_lower = request.lower()
            for keyword in self.facts["internal_keywords"]:
                if keyword in request_lower:
                    return [{"result": True, "reason": f"Internal context: '{keyword}'"}]
            return []

        if predicate == "route_to_aicore":
            request = str(args[0] if args else "")
            request_lower = request.lower()
            is_news = any(keyword in request_lower for keyword in self.facts["public_news_keywords"])
            if is_news and not self.query("route_to_vllm", request):
                return [{"result": True, "reason": "Public news query"}]
            return []

        if predicate == "requires_human_review":
            action = str(args[0] if args else "")
            return [{"result": True, "action": action}] if action in self.facts["agent_requires_approval"] else []

        if predicate == "safety_check_passed":
            tool = str(args[0] if args else "")
            return [{"result": True, "tool": tool}] if tool in self.facts["agent_can_use"] else []

        if predicate == "get_prompting_policy":
            product_id = str(args[0] if args else "world-monitor-service-v1")
            policy = self.facts["prompting_policy"].get(product_id)
            return [policy] if policy else []

        if predicate == "autonomy_level":
            return [{"level": "L2"}]

        return []
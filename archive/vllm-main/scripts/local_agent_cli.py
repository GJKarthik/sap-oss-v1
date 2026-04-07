#!/usr/bin/env python3
"""Thin local agent CLI for the OpenAI-compatible gateway.

This is intentionally small. It reuses the existing server endpoints instead of
introducing another runtime:
  - GET  /health
  - GET  /v1/models
  - POST /v1/chat/completions
  - POST /v1/embeddings
  - GET  /metrics
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import pathlib
import sys
import textwrap
import urllib.parse
from typing import Any


DEFAULT_BASE_URL = os.environ.get("PRIVATE_LLM_BASE_URL", "http://127.0.0.1:8080")
DEFAULT_MODEL = os.environ.get("PRIVATE_LLM_MODEL", "")
DEFAULT_API_KEY = os.environ.get("PRIVATE_LLM_API_KEY")
DEFAULT_SESSION = os.environ.get("PRIVATE_LLM_SESSION", "default")
PROJECT_DIR = pathlib.Path(__file__).resolve().parent.parent
SESSION_DIR = PROJECT_DIR / ".agent_sessions"


class GatewayClient:
    def __init__(self, base_url: str, api_key: str | None = None, timeout: float = 120.0) -> None:
        parsed = urllib.parse.urlparse(base_url)
        if parsed.scheme not in {"http", "https"}:
            raise ValueError(f"unsupported base URL scheme: {parsed.scheme!r}")
        if not parsed.hostname:
            raise ValueError(f"base URL missing hostname: {base_url!r}")
        self.base_url = base_url.rstrip("/")
        self.scheme = parsed.scheme
        self.host = parsed.hostname
        self.port = parsed.port
        self.base_path = parsed.path.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def _connection(self) -> http.client.HTTPConnection | http.client.HTTPSConnection:
        if self.scheme == "https":
            return http.client.HTTPSConnection(self.host, self.port, timeout=self.timeout)
        return http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)

    def _headers(self, json_body: bool = False) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        if json_body:
            headers["Content-Type"] = "application/json"
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _path(self, path: str) -> str:
        if self.base_path:
            return f"{self.base_path}{path}"
        return path

    def request_json(self, method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        conn = self._connection()
        try:
            conn.request(method, self._path(path), body=body, headers=self._headers(json_body=payload is not None))
            res = conn.getresponse()
            raw = res.read()
        finally:
            conn.close()

        if res.status >= 400:
            message = raw.decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> {res.status}: {message}")
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))

    def request_text(self, method: str, path: str) -> str:
        conn = self._connection()
        try:
            conn.request(method, self._path(path), headers=self._headers())
            res = conn.getresponse()
            raw = res.read()
        finally:
            conn.close()
        if res.status >= 400:
            message = raw.decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> {res.status}: {message}")
        return raw.decode("utf-8", errors="replace")

    def chat(self, payload: dict[str, Any], stream: bool) -> str:
        if not stream:
            data = self.request_json("POST", "/v1/chat/completions", payload)
            return extract_chat_text(data)

        body = json.dumps(payload).encode("utf-8")
        conn = self._connection()
        try:
            conn.request("POST", self._path("/v1/chat/completions"), body=body, headers=self._headers(json_body=True))
            res = conn.getresponse()
            if res.status >= 400:
                raw = res.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"POST /v1/chat/completions -> {res.status}: {raw}")

            text_parts: list[str] = []
            for raw_line in res:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line or not line.startswith("data:"):
                    continue
                payload_text = line[5:].strip()
                if payload_text == "[DONE]":
                    break
                try:
                    event = json.loads(payload_text)
                except json.JSONDecodeError:
                    continue
                delta = extract_stream_delta(event)
                if delta:
                    sys.stdout.write(delta)
                    sys.stdout.flush()
                    text_parts.append(delta)
            if text_parts:
                sys.stdout.write("\n")
                sys.stdout.flush()
            return "".join(text_parts)
        finally:
            conn.close()


def session_path(name: str) -> pathlib.Path:
    safe_name = "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in name)
    return SESSION_DIR / f"{safe_name}.json"


def load_session(name: str) -> list[dict[str, str]]:
    path = session_path(name)
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        return []
    out: list[dict[str, str]] = []
    for item in data:
        if isinstance(item, dict) and isinstance(item.get("role"), str) and isinstance(item.get("content"), str):
            out.append({"role": item["role"], "content": item["content"]})
    return out


def save_session(name: str, messages: list[dict[str, str]]) -> None:
    SESSION_DIR.mkdir(parents=True, exist_ok=True)
    session_path(name).write_text(json.dumps(messages, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def maybe_add_system(messages: list[dict[str, str]], system_text: str | None) -> list[dict[str, str]]:
    if not system_text:
        return list(messages)
    if messages and messages[0].get("role") == "system":
        return list(messages)
    return [{"role": "system", "content": system_text}, *messages]


def extract_chat_text(data: Any) -> str:
    if not isinstance(data, dict):
        return json.dumps(data)
    choices = data.get("choices")
    if not isinstance(choices, list) or not choices:
        return json.dumps(data)
    first = choices[0]
    if not isinstance(first, dict):
        return json.dumps(data)
    message = first.get("message")
    if isinstance(message, dict) and isinstance(message.get("content"), str):
        return message["content"]
    delta = first.get("delta")
    if isinstance(delta, dict) and isinstance(delta.get("content"), str):
        return delta["content"]
    return json.dumps(data)


def extract_stream_delta(event: Any) -> str:
    if not isinstance(event, dict):
        return ""
    choices = event.get("choices")
    if not isinstance(choices, list):
        return ""
    fragments: list[str] = []
    for item in choices:
        if not isinstance(item, dict):
            continue
        delta = item.get("delta")
        if isinstance(delta, dict) and isinstance(delta.get("content"), str):
            fragments.append(delta["content"])
    return "".join(fragments)


def build_chat_payload(
    model: str,
    messages: list[dict[str, str]],
    temperature: float,
    max_tokens: int,
    stream: bool,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "messages": messages,
        "temperature": temperature,
        "stream": stream,
    }
    if model:
        payload["model"] = model
    if max_tokens > 0:
        payload["max_tokens"] = max_tokens
    return payload


def command_health(client: GatewayClient, _args: argparse.Namespace) -> int:
    print(client.request_text("GET", "/health").strip())
    return 0


def command_models(client: GatewayClient, _args: argparse.Namespace) -> int:
    data = client.request_json("GET", "/v1/models")
    models = data.get("data", []) if isinstance(data, dict) else []
    if not isinstance(models, list):
        print(json.dumps(data, indent=2))
        return 0
    for item in models:
        if isinstance(item, dict):
            model_id = item.get("id")
            if isinstance(model_id, str):
                print(model_id)
    return 0


def command_metrics(client: GatewayClient, args: argparse.Namespace) -> int:
    text = client.request_text("GET", "/metrics")
    lines = text.splitlines()
    if args.grep:
        lines = [line for line in lines if args.grep in line]
    for line in lines[: args.limit]:
        print(line)
    return 0


def command_embed(client: GatewayClient, args: argparse.Namespace) -> int:
    payload = {"input": args.text}
    if args.model:
        payload["model"] = args.model
    data = client.request_json("POST", "/v1/embeddings", payload)
    if args.raw:
        print(json.dumps(data, indent=2))
        return 0
    items = data.get("data", []) if isinstance(data, dict) else []
    if not items:
        print(json.dumps(data, indent=2))
        return 0
    first = items[0]
    vector = first.get("embedding", []) if isinstance(first, dict) else []
    preview = ", ".join(f"{value:.4f}" for value in vector[:8]) if isinstance(vector, list) else ""
    print(f"embedding_dims={len(vector)} preview=[{preview}]")
    return 0


def command_chat(client: GatewayClient, args: argparse.Namespace) -> int:
    prompt = " ".join(args.prompt).strip()
    if not prompt:
        raise SystemExit("chat prompt is required")

    history = [] if args.ephemeral else load_session(args.session)
    if args.reset:
        history = []
    request_messages = maybe_add_system(history, args.system)
    request_messages.append({"role": "user", "content": prompt})

    payload = build_chat_payload(args.model, request_messages, args.temperature, args.max_tokens, args.stream)
    reply = client.chat(payload, stream=args.stream)

    if args.raw and not args.stream:
        print(reply)
        return 0

    if not args.ephemeral:
        history = request_messages
        history.append({"role": "assistant", "content": reply})
        save_session(args.session, history)
    return 0


def command_repl(client: GatewayClient, args: argparse.Namespace) -> int:
    history = [] if args.ephemeral else load_session(args.session)
    if args.reset:
        history = []
    history = maybe_add_system(history, args.system)

    print("Local agent REPL. Commands: /exit /clear /history /save", flush=True)
    while True:
        try:
            prompt = input("you> ").strip()
        except EOFError:
            print()
            return 0
        except KeyboardInterrupt:
            print()
            return 0

        if not prompt:
            continue
        if prompt in {"/exit", "/quit"}:
            return 0
        if prompt == "/clear":
            history = maybe_add_system([], args.system)
            if not args.ephemeral:
                save_session(args.session, history)
            print("session cleared")
            continue
        if prompt == "/history":
            print(json.dumps(history, indent=2))
            continue
        if prompt == "/save":
            if args.ephemeral:
                print("ephemeral mode; nothing saved")
            else:
                save_session(args.session, history)
                print(f"saved {args.session}")
            continue

        request_messages = list(history)
        request_messages.append({"role": "user", "content": prompt})
        payload = build_chat_payload(args.model, request_messages, args.temperature, args.max_tokens, args.stream)
        print("assistant> ", end="", flush=True)
        reply = client.chat(payload, stream=args.stream)
        history = request_messages + [{"role": "assistant", "content": reply}]
        if not args.ephemeral:
            save_session(args.session, history)
    return 0


def add_shared_chat_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--model", default=DEFAULT_MODEL, help="model id to send to /v1/chat/completions")
    parser.add_argument("--system", default=None, help="system prompt to prepend when the session is empty")
    parser.add_argument("--session", default=DEFAULT_SESSION, help="session transcript name")
    parser.add_argument("--temperature", type=float, default=0.2, help="sampling temperature")
    parser.add_argument("--max-tokens", type=int, default=512, help="max completion tokens")
    parser.add_argument("--stream", action=argparse.BooleanOptionalAction, default=True, help="use SSE streaming when supported")
    parser.add_argument("--reset", action="store_true", help="clear existing session history before sending this request")
    parser.add_argument("--ephemeral", action="store_true", help="do not read or write session state")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Thin local agent CLI for the vllm-main OpenAI-compatible gateway.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            f"""\
            Examples:
              python3 scripts/local_agent_cli.py health
              python3 scripts/local_agent_cli.py models
              python3 scripts/local_agent_cli.py chat --model lfm2.5 \"Explain shortconv layers\"
              python3 scripts/local_agent_cli.py repl --session demo

            Environment:
              PRIVATE_LLM_BASE_URL={DEFAULT_BASE_URL}
              PRIVATE_LLM_MODEL={DEFAULT_MODEL or '<unset>'}
              PRIVATE_LLM_API_KEY={'<set>' if DEFAULT_API_KEY else '<unset>'}
            """
        ),
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="gateway base URL")
    parser.add_argument("--api-key", default=DEFAULT_API_KEY, help="optional bearer token")
    parser.add_argument("--timeout", type=float, default=120.0, help="HTTP timeout in seconds")

    subparsers = parser.add_subparsers(dest="command", required=True)

    health = subparsers.add_parser("health", help="GET /health")
    health.set_defaults(handler=command_health)

    models = subparsers.add_parser("models", help="GET /v1/models")
    models.set_defaults(handler=command_models)

    metrics = subparsers.add_parser("metrics", help="GET /metrics")
    metrics.add_argument("--grep", default=None, help="filter substring")
    metrics.add_argument("--limit", type=int, default=40, help="max lines to print")
    metrics.set_defaults(handler=command_metrics)

    embed = subparsers.add_parser("embed", help="POST /v1/embeddings")
    embed.add_argument("text", help="text to embed")
    embed.add_argument("--model", default=DEFAULT_MODEL, help="embedding model id")
    embed.add_argument("--raw", action="store_true", help="print raw JSON response")
    embed.set_defaults(handler=command_embed)

    chat = subparsers.add_parser("chat", help="one-shot chat request")
    add_shared_chat_args(chat)
    chat.add_argument("--raw", action="store_true", help="print raw text only")
    chat.add_argument("prompt", nargs=argparse.REMAINDER, help="user prompt")
    chat.set_defaults(handler=command_chat)

    repl = subparsers.add_parser("repl", help="interactive chat loop with session history")
    add_shared_chat_args(repl)
    repl.set_defaults(handler=command_repl)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    client = GatewayClient(args.base_url, api_key=args.api_key, timeout=args.timeout)
    try:
        return args.handler(client, args)
    except KeyboardInterrupt:
        print(file=sys.stderr)
        return 130
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
import argparse
import dataclasses
import http.client
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import List


PREFILL_RE = re.compile(r"generate: prefill (\d+) tokens \(GPU\)")
PREFILL_DONE_RE = re.compile(r"generate: prefill done in (\d+) ms")
DECODE_DONE_RE = re.compile(
    r"generate: decode done tokens=(\d+) elapsed_ms=(\d+) .* first_token_us=(\d+)"
)
FIRST_TOKEN_RE = re.compile(r"generate: first decode token=(\d+) pos=(\d+)")


@dataclasses.dataclass
class Scenario:
    name: str
    prompt_repeat: int
    concurrency: int
    total_requests: int
    max_tokens: int


@dataclasses.dataclass
class RequestResult:
    ok: bool
    status: int
    latency_ms: float
    response_text: str
    error: str = ""


class LogCursor:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.offset = 0

    def reset(self) -> None:
        self.offset = 0

    def read_new(self) -> str:
        with self.path.open("r", encoding="utf-8", errors="replace") as handle:
            handle.seek(self.offset)
            data = handle.read()
            self.offset = handle.tell()
            return data


def prompt_for_repeat(repeat: int) -> str:
    if repeat <= 0:
        return "What is the capital of France?"
    chunk = (
        "Explain how REAM offload, expert-cache hit rate, TTFT, token window, and "
        "decode throughput interact on a T4 GPU for Qwen3.5 models. "
    )
    return chunk * repeat


def percentile(values: List[float], pct: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    rank = (len(ordered) - 1) * pct
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return ordered[int(rank)]
    weight = rank - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def http_post(host: str, port: int, payload: dict, timeout_s: int) -> RequestResult:
    body = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    start = time.perf_counter()
    conn = http.client.HTTPConnection(host, port, timeout=timeout_s)
    try:
        conn.request("POST", "/v1/chat/completions", body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        text = data.decode("utf-8", errors="replace")
        return RequestResult(resp.status < 400, resp.status, elapsed_ms, text)
    except Exception as exc:  # noqa: BLE001
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        return RequestResult(False, 0, elapsed_ms, "", error=str(exc))
    finally:
        conn.close()


def wait_for_health(host: str, port: int, timeout_s: int) -> None:
    deadline = time.time() + timeout_s
    last_err = ""
    while time.time() < deadline:
        conn = http.client.HTTPConnection(host, port, timeout=2)
        try:
            conn.request("GET", "/health")
            resp = conn.getresponse()
            body = resp.read().decode("utf-8", errors="replace")
            if resp.status == 200 and "healthy" in body:
                return
            last_err = f"status={resp.status} body={body}"
        except Exception as exc:  # noqa: BLE001
            last_err = str(exc)
        finally:
            conn.close()
        time.sleep(1.0)
    raise RuntimeError(f"gateway did not become healthy: {last_err}")


def start_gateway(
    zig_dir: Path,
    gateway_bin: Path,
    gguf_path: str,
    port: int,
    log_path: Path,
    startup_timeout_s: int,
) -> subprocess.Popen:
    subprocess.run(["pkill", "-x", "openai-gateway"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log_path.write_text("", encoding="utf-8")
    env = os.environ.copy()
    env["USE_LOCAL_LLAMA"] = "1"
    env["GGUF_PATH"] = gguf_path
    env["PORT"] = str(port)
    proc = subprocess.Popen(  # noqa: S603
        [str(gateway_bin)],
        cwd=str(zig_dir),
        env=env,
        stdout=log_path.open("a", encoding="utf-8"),
        stderr=subprocess.STDOUT,
    )
    wait_for_health("127.0.0.1", port, startup_timeout_s)
    return proc


def parse_log_metrics(log_text: str) -> dict:
    prefill_tokens = [int(m.group(1)) for m in PREFILL_RE.finditer(log_text)]
    prefill_ms = [int(m.group(1)) for m in PREFILL_DONE_RE.finditer(log_text)]
    decode_matches = [m.groups() for m in DECODE_DONE_RE.finditer(log_text)]
    decode_tokens = [int(toks) for toks, _, _ in decode_matches]
    decode_ms = [int(ms) for _, ms, _ in decode_matches]
    first_token_ms = [int(us) / 1000.0 for _, _, us in decode_matches]
    first_decode_tokens = [int(m.group(1)) for m in FIRST_TOKEN_RE.finditer(log_text)]

    avg_prefill_ms = statistics.mean(prefill_ms) if prefill_ms else 0.0
    avg_first_token_ms = statistics.mean(first_token_ms) if first_token_ms else 0.0
    avg_ttft_ms = avg_prefill_ms + avg_first_token_ms if (prefill_ms and first_token_ms) else 0.0
    total_decode_tokens = sum(decode_tokens)
    total_decode_ms = sum(decode_ms)
    decode_tps = (total_decode_tokens * 1000.0 / total_decode_ms) if total_decode_ms else 0.0

    return {
        "log_request_count": len(decode_tokens),
        "avg_prefill_tokens": statistics.mean(prefill_tokens) if prefill_tokens else 0.0,
        "avg_prefill_ms": avg_prefill_ms,
        "avg_first_token_ms": avg_first_token_ms,
        "avg_internal_ttft_ms": avg_ttft_ms,
        "avg_decode_ms": statistics.mean(decode_ms) if decode_ms else 0.0,
        "decode_tps": decode_tps,
        "total_decode_tokens": total_decode_tokens,
        "first_decode_tokens": first_decode_tokens,
    }


def run_scenario(host: str, port: int, model_name: str, scenario: Scenario, timeout_s: int, log_cursor: LogCursor) -> dict:
    payload = {
        "model": model_name,
        "messages": [{"role": "user", "content": prompt_for_repeat(scenario.prompt_repeat)}],
        "stream": False,
        "max_tokens": scenario.max_tokens,
    }
    _ = log_cursor.read_new()
    wall_start = time.perf_counter()
    results: List[RequestResult] = []
    with ThreadPoolExecutor(max_workers=scenario.concurrency) as pool:
        futures = [pool.submit(http_post, host, port, payload, timeout_s) for _ in range(scenario.total_requests)]
        for future in as_completed(futures):
            results.append(future.result())
    wall_ms = (time.perf_counter() - wall_start) * 1000.0
    time.sleep(0.25)
    log_metrics = parse_log_metrics(log_cursor.read_new())

    latencies = [r.latency_ms for r in results]
    oks = [r for r in results if r.ok]
    aggregate_output_tps = (log_metrics["total_decode_tokens"] * 1000.0 / wall_ms) if wall_ms else 0.0

    return {
        "scenario": scenario.name,
        "prompt_repeat": scenario.prompt_repeat,
        "concurrency": scenario.concurrency,
        "total_requests": scenario.total_requests,
        "max_tokens": scenario.max_tokens,
        "successes": len(oks),
        "failures": len(results) - len(oks),
        "wall_ms": wall_ms,
        "req_avg_ms": statistics.mean(latencies) if latencies else 0.0,
        "req_p50_ms": percentile(latencies, 0.50),
        "req_p95_ms": percentile(latencies, 0.95),
        "aggregate_rps": (len(results) * 1000.0 / wall_ms) if wall_ms else 0.0,
        "aggregate_output_tps": aggregate_output_tps,
        "sample_response": oks[0].response_text.strip() if oks else (results[0].error if results else ""),
        "internal": log_metrics,
    }


def default_scenarios(model_key: str) -> List[Scenario]:
    if model_key == "35b":
        return [
            Scenario("single_short", 0, 1, 3, 32),
            Scenario("single_medium_window", 4, 1, 1, 32),
            Scenario("single_long_window", 8, 1, 1, 32),
            Scenario("concurrent_2_short", 0, 2, 4, 32),
            Scenario("concurrent_4_short", 0, 4, 8, 32),
        ]
    if model_key == "9b":
        return [
            Scenario("single_short", 0, 1, 3, 32),
            Scenario("single_medium_window", 8, 1, 1, 32),
            Scenario("single_long_window", 16, 1, 1, 32),
            Scenario("concurrent_2_short", 0, 2, 4, 32),
            Scenario("concurrent_4_short", 0, 4, 8, 32),
        ]
    base = [
        Scenario("single_short", 0, 1, 3, 32),
        Scenario("single_medium_window", 12, 1, 2, 32),
        Scenario("single_long_window", 48, 1, 1, 32),
        Scenario("concurrent_2_short", 0, 2, 4, 32),
        Scenario("concurrent_4_short", 0, 4, 8, 32),
    ]
    if model_key == "0.8b":
        base.append(Scenario("concurrent_8_short", 0, 8, 16, 32))
    return base


def print_summary(model_label: str, results: List[dict]) -> None:
    print(f"\n=== {model_label} ===")
    for item in results:
        internal = item["internal"]
        print(
            json.dumps(
                {
                    "scenario": item["scenario"],
                    "concurrency": item["concurrency"],
                    "requests": item["total_requests"],
                    "successes": item["successes"],
                    "failures": item["failures"],
                    "prefill_tokens": round(internal["avg_prefill_tokens"], 1),
                    "internal_ttft_ms": round(internal["avg_internal_ttft_ms"], 1),
                    "decode_tps": round(internal["decode_tps"], 2),
                    "aggregate_output_tps": round(item["aggregate_output_tps"], 2),
                    "req_avg_ms": round(item["req_avg_ms"], 1),
                    "req_p50_ms": round(item["req_p50_ms"], 1),
                    "req_p95_ms": round(item["req_p95_ms"], 1),
                    "sample_response": item["sample_response"][:120],
                }
            )
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig-dir", required=True)
    parser.add_argument("--gateway-bin", default="./zig-out/bin/openai-gateway")
    parser.add_argument("--model-label", required=True)
    parser.add_argument("--payload-model", required=True)
    parser.add_argument("--gguf-path", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--log-path", default="/tmp/qwen_gateway_perf.log")
    parser.add_argument("--request-timeout", type=int, default=180)
    parser.add_argument("--startup-timeout", type=int, default=300)
    args = parser.parse_args()

    zig_dir = Path(args.zig_dir)
    gateway_bin = (zig_dir / args.gateway_bin).resolve() if not Path(args.gateway_bin).is_absolute() else Path(args.gateway_bin)
    log_path = Path(args.log_path)
    log_cursor = LogCursor(log_path)

    proc = None
    try:
        proc = start_gateway(
            zig_dir,
            gateway_bin,
            args.gguf_path,
            args.port,
            log_path,
            args.startup_timeout,
        )
        log_cursor.reset()
        _ = log_cursor.read_new()
        results = []
        for scenario in default_scenarios(args.model_label):
            results.append(run_scenario(args.host, args.port, args.payload_model, scenario, args.request_timeout, log_cursor))
        print_summary(args.model_label, results)
        print("\nRESULT_JSON_START")
        print(json.dumps({"model": args.model_label, "results": results}, indent=2))
        print("RESULT_JSON_END")
        return 0
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())

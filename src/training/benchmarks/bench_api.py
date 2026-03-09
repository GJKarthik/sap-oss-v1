#!/usr/bin/env python3
"""
Performance benchmarks for the ModelOpt API.

Measures:
- API response latency (p50, p95, p99)
- Request throughput (req/sec)
- Job lifecycle timing

Usage:
    python benchmarks/bench_api.py [--base-url http://localhost:8001] [--iterations 100]
"""

import argparse
import json
import statistics
import sys
import time
import urllib.request
import urllib.error


def bench_endpoint(url: str, iterations: int, method: str = "GET", body: bytes | None = None) -> dict:
    """Benchmark a single endpoint."""
    latencies: list[float] = []
    errors = 0

    for _ in range(iterations):
        req = urllib.request.Request(url, method=method, data=body)
        if body:
            req.add_header("Content-Type", "application/json")
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp.read()
            latencies.append(time.perf_counter() - start)
        except (urllib.error.URLError, urllib.error.HTTPError):
            errors += 1
            latencies.append(time.perf_counter() - start)

    if not latencies:
        return {"error": "no data"}

    latencies.sort()
    n = len(latencies)
    return {
        "iterations": iterations,
        "errors": errors,
        "p50_ms": round(latencies[n // 2] * 1000, 2),
        "p95_ms": round(latencies[int(n * 0.95)] * 1000, 2),
        "p99_ms": round(latencies[int(n * 0.99)] * 1000, 2),
        "mean_ms": round(statistics.mean(latencies) * 1000, 2),
        "min_ms": round(min(latencies) * 1000, 2),
        "max_ms": round(max(latencies) * 1000, 2),
        "throughput_rps": round(n / sum(latencies), 1) if sum(latencies) > 0 else 0,
    }


def run_benchmarks(base_url: str, iterations: int) -> dict:
    """Run all API benchmarks."""
    results = {}

    print(f"Benchmarking {base_url} ({iterations} iterations per endpoint)\n")

    # Health check (baseline)
    print("  /health ...", end="", flush=True)
    results["GET /health"] = bench_endpoint(f"{base_url}/health", iterations)
    print(f" p50={results['GET /health']['p50_ms']}ms")

    # GPU status
    print("  /gpu/status ...", end="", flush=True)
    results["GET /gpu/status"] = bench_endpoint(f"{base_url}/gpu/status", iterations)
    print(f" p50={results['GET /gpu/status']['p50_ms']}ms")

    # Models catalog
    print("  /models/catalog ...", end="", flush=True)
    results["GET /models/catalog"] = bench_endpoint(f"{base_url}/models/catalog", iterations)
    print(f" p50={results['GET /models/catalog']['p50_ms']}ms")

    # Jobs list
    print("  /jobs ...", end="", flush=True)
    results["GET /jobs"] = bench_endpoint(f"{base_url}/jobs", iterations)
    print(f" p50={results['GET /jobs']['p50_ms']}ms")

    # OpenAI models list
    print("  /v1/models ...", end="", flush=True)
    results["GET /v1/models"] = bench_endpoint(f"{base_url}/v1/models", iterations)
    print(f" p50={results['GET /v1/models']['p50_ms']}ms")

    # Metrics
    print("  /metrics ...", end="", flush=True)
    results["GET /metrics"] = bench_endpoint(f"{base_url}/metrics", iterations)
    print(f" p50={results['GET /metrics']['p50_ms']}ms")

    return results


def print_summary(results: dict) -> None:
    """Print results table."""
    print(f"\n{'Endpoint':<25} {'p50':>8} {'p95':>8} {'p99':>8} {'RPS':>8}")
    print("-" * 60)
    for endpoint, data in results.items():
        if "error" in data:
            print(f"{endpoint:<25} {'ERROR':>8}")
        else:
            print(
                f"{endpoint:<25} "
                f"{data['p50_ms']:>7.1f} "
                f"{data['p95_ms']:>7.1f} "
                f"{data['p99_ms']:>7.1f} "
                f"{data['throughput_rps']:>7.1f}"
            )

    # Write JSON artifact for CI
    with open("benchmarks/results.json", "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults written to benchmarks/results.json")


def main() -> int:
    parser = argparse.ArgumentParser(description="ModelOpt API Benchmarks")
    parser.add_argument("--base-url", default="http://localhost:8001")
    parser.add_argument("--iterations", type=int, default=100)
    args = parser.parse_args()

    # Check if API is reachable
    try:
        urllib.request.urlopen(f"{args.base_url}/health", timeout=3)
    except Exception:
        print(f"ERROR: Cannot reach {args.base_url}/health")
        print("Start the API first: cd nvidia-modelopt && uvicorn api.main:app --port 8001")
        return 1

    results = run_benchmarks(args.base_url, args.iterations)
    print_summary(results)
    return 0


if __name__ == "__main__":
    sys.exit(main())


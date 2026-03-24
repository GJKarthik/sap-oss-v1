#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Load testing suite for Data Cleaning Copilot.

Verifies scalability claims and identifies performance bottlenecks.

Usage:
    # Basic test
    python tests/load_test.py --target http://localhost:9110/mcp --duration 60

    # With Locust (advanced)
    locust -f tests/load_test.py --host http://localhost:9110

Requirements:
    pip install locust aiohttp
"""

import argparse
import asyncio
import json
import random
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional
import urllib.request
import urllib.error

# =============================================================================
# Load Test Configuration
# =============================================================================

DEFAULT_CONFIG = {
    "duration_seconds": 60,
    "concurrent_users": 10,
    "ramp_up_seconds": 10,
    "think_time_ms": 100,
    "timeout_seconds": 30,
    "scenarios": ["mcp_tools_list", "mcp_tools_call", "mcp_resources_list"],
}


@dataclass
class LoadTestConfig:
    """Load test configuration."""

    target_url: str
    duration_seconds: int = 60
    concurrent_users: int = 10
    ramp_up_seconds: int = 10
    think_time_ms: int = 100
    timeout_seconds: int = 30
    auth_token: Optional[str] = None
    scenarios: List[str] = field(default_factory=lambda: ["mcp_tools_list"])


@dataclass
class RequestResult:
    """Result of a single request."""

    scenario: str
    success: bool
    status_code: int
    latency_ms: float
    timestamp: float
    error: Optional[str] = None


@dataclass
class LoadTestReport:
    """Load test report with statistics."""

    config: LoadTestConfig
    start_time: datetime
    end_time: datetime
    total_requests: int
    successful_requests: int
    failed_requests: int
    avg_latency_ms: float
    p50_latency_ms: float
    p90_latency_ms: float
    p95_latency_ms: float
    p99_latency_ms: float
    min_latency_ms: float
    max_latency_ms: float
    requests_per_second: float
    error_rate: float
    errors_by_type: Dict[str, int]

    def to_dict(self) -> Dict[str, Any]:
        return {
            "config": {
                "target_url": self.config.target_url,
                "duration_seconds": self.config.duration_seconds,
                "concurrent_users": self.config.concurrent_users,
            },
            "summary": {
                "start_time": self.start_time.isoformat(),
                "end_time": self.end_time.isoformat(),
                "total_requests": self.total_requests,
                "successful_requests": self.successful_requests,
                "failed_requests": self.failed_requests,
                "requests_per_second": round(self.requests_per_second, 2),
                "error_rate": round(self.error_rate * 100, 2),
            },
            "latency": {
                "avg_ms": round(self.avg_latency_ms, 2),
                "p50_ms": round(self.p50_latency_ms, 2),
                "p90_ms": round(self.p90_latency_ms, 2),
                "p95_ms": round(self.p95_latency_ms, 2),
                "p99_ms": round(self.p99_latency_ms, 2),
                "min_ms": round(self.min_latency_ms, 2),
                "max_ms": round(self.max_latency_ms, 2),
            },
            "errors": self.errors_by_type,
        }

    def print_summary(self):
        """Print a human-readable summary."""
        print("\n" + "=" * 60)
        print("LOAD TEST REPORT")
        print("=" * 60)
        print(f"Target: {self.config.target_url}")
        print(f"Duration: {self.config.duration_seconds}s")
        print(f"Concurrent Users: {self.config.concurrent_users}")
        print("-" * 60)
        print(f"Total Requests:    {self.total_requests:,}")
        print(f"Successful:        {self.successful_requests:,}")
        print(f"Failed:            {self.failed_requests:,}")
        print(f"Requests/sec:      {self.requests_per_second:.2f}")
        print(f"Error Rate:        {self.error_rate * 100:.2f}%")
        print("-" * 60)
        print("Latency (ms):")
        print(f"  Average:         {self.avg_latency_ms:.2f}")
        print(f"  Median (p50):    {self.p50_latency_ms:.2f}")
        print(f"  p90:             {self.p90_latency_ms:.2f}")
        print(f"  p95:             {self.p95_latency_ms:.2f}")
        print(f"  p99:             {self.p99_latency_ms:.2f}")
        print(f"  Min:             {self.min_latency_ms:.2f}")
        print(f"  Max:             {self.max_latency_ms:.2f}")
        if self.errors_by_type:
            print("-" * 60)
            print("Errors:")
            for error, count in self.errors_by_type.items():
                print(f"  {error}: {count}")
        print("=" * 60)


# =============================================================================
# Test Scenarios
# =============================================================================


class MCPScenarios:
    """MCP protocol test scenarios."""

    @staticmethod
    def tools_list() -> Dict[str, Any]:
        return {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}

    @staticmethod
    def tools_call_data_quality() -> Dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "data_quality_check",
                "arguments": {"table_name": f"test_table_{random.randint(1, 100)}"},
            },
        }

    @staticmethod
    def tools_call_schema_analysis() -> Dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "schema_analysis",
                "arguments": {"schema_definition": '{"tables": []}'},
            },
        }

    @staticmethod
    def resources_list() -> Dict[str, Any]:
        return {"jsonrpc": "2.0", "id": 4, "method": "resources/list", "params": {}}

    @staticmethod
    def resources_read_facts() -> Dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "resources/read",
            "params": {"uri": "mangle://facts"},
        }

    @staticmethod
    def initialize() -> Dict[str, Any]:
        return {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}}


SCENARIO_MAP = {
    "mcp_initialize": MCPScenarios.initialize,
    "mcp_tools_list": MCPScenarios.tools_list,
    "mcp_tools_call": MCPScenarios.tools_call_data_quality,
    "mcp_schema_analysis": MCPScenarios.tools_call_schema_analysis,
    "mcp_resources_list": MCPScenarios.resources_list,
    "mcp_resources_read": MCPScenarios.resources_read_facts,
}


# =============================================================================
# Load Test Runner
# =============================================================================


class LoadTestRunner:
    """Runs load tests against the target endpoint."""

    def __init__(self, config: LoadTestConfig):
        self.config = config
        self.results: List[RequestResult] = []
        self._stop_flag = False

    def _make_request(self, scenario: str) -> RequestResult:
        """Make a single request and measure latency."""
        start_time = time.monotonic()
        timestamp = time.time()

        try:
            payload = SCENARIO_MAP[scenario]()
            data = json.dumps(payload).encode("utf-8")

            headers = {"Content-Type": "application/json"}
            if self.config.auth_token:
                headers["Authorization"] = f"Bearer {self.config.auth_token}"

            req = urllib.request.Request(
                self.config.target_url,
                data=data,
                headers=headers,
                method="POST",
            )

            with urllib.request.urlopen(req, timeout=self.config.timeout_seconds) as resp:
                status_code = resp.status
                response_body = resp.read().decode("utf-8")

                # Check for JSON-RPC error
                try:
                    response_json = json.loads(response_body)
                    if "error" in response_json:
                        return RequestResult(
                            scenario=scenario,
                            success=False,
                            status_code=status_code,
                            latency_ms=(time.monotonic() - start_time) * 1000,
                            timestamp=timestamp,
                            error=f"RPC Error: {response_json['error'].get('message', 'Unknown')}",
                        )
                except json.JSONDecodeError:
                    pass

                return RequestResult(
                    scenario=scenario,
                    success=True,
                    status_code=status_code,
                    latency_ms=(time.monotonic() - start_time) * 1000,
                    timestamp=timestamp,
                )

        except urllib.error.HTTPError as e:
            return RequestResult(
                scenario=scenario,
                success=False,
                status_code=e.code,
                latency_ms=(time.monotonic() - start_time) * 1000,
                timestamp=timestamp,
                error=f"HTTP {e.code}: {e.reason}",
            )
        except urllib.error.URLError as e:
            return RequestResult(
                scenario=scenario,
                success=False,
                status_code=0,
                latency_ms=(time.monotonic() - start_time) * 1000,
                timestamp=timestamp,
                error=f"Connection error: {e.reason}",
            )
        except Exception as e:
            return RequestResult(
                scenario=scenario,
                success=False,
                status_code=0,
                latency_ms=(time.monotonic() - start_time) * 1000,
                timestamp=timestamp,
                error=str(e),
            )

    def _worker(self, worker_id: int):
        """Worker thread that makes requests."""
        # Ramp-up delay
        ramp_delay = (worker_id / self.config.concurrent_users) * self.config.ramp_up_seconds
        time.sleep(ramp_delay)

        while not self._stop_flag:
            scenario = random.choice(self.config.scenarios)
            result = self._make_request(scenario)
            self.results.append(result)

            # Think time
            if self.config.think_time_ms > 0:
                time.sleep(self.config.think_time_ms / 1000)

    def run(self) -> LoadTestReport:
        """Run the load test and return a report."""
        print(f"Starting load test against {self.config.target_url}")
        print(f"Duration: {self.config.duration_seconds}s, Users: {self.config.concurrent_users}")

        start_time = datetime.now()
        self._stop_flag = False
        self.results = []

        with ThreadPoolExecutor(max_workers=self.config.concurrent_users) as executor:
            futures = [executor.submit(self._worker, i) for i in range(self.config.concurrent_users)]

            # Wait for duration
            time.sleep(self.config.duration_seconds)
            self._stop_flag = True

            # Wait for workers to finish
            for future in futures:
                try:
                    future.result(timeout=5)
                except Exception:
                    pass

        end_time = datetime.now()
        return self._generate_report(start_time, end_time)

    def _generate_report(self, start_time: datetime, end_time: datetime) -> LoadTestReport:
        """Generate a report from the results."""
        if not self.results:
            return LoadTestReport(
                config=self.config,
                start_time=start_time,
                end_time=end_time,
                total_requests=0,
                successful_requests=0,
                failed_requests=0,
                avg_latency_ms=0,
                p50_latency_ms=0,
                p90_latency_ms=0,
                p95_latency_ms=0,
                p99_latency_ms=0,
                min_latency_ms=0,
                max_latency_ms=0,
                requests_per_second=0,
                error_rate=0,
                errors_by_type={},
            )

        total_requests = len(self.results)
        successful_requests = sum(1 for r in self.results if r.success)
        failed_requests = total_requests - successful_requests

        latencies = [r.latency_ms for r in self.results]
        sorted_latencies = sorted(latencies)

        def percentile(data: List[float], p: float) -> float:
            k = (len(data) - 1) * p / 100
            f = int(k)
            c = f + 1 if f + 1 < len(data) else f
            return data[f] + (data[c] - data[f]) * (k - f)

        errors_by_type: Dict[str, int] = {}
        for r in self.results:
            if r.error:
                errors_by_type[r.error] = errors_by_type.get(r.error, 0) + 1

        duration = (end_time - start_time).total_seconds()

        return LoadTestReport(
            config=self.config,
            start_time=start_time,
            end_time=end_time,
            total_requests=total_requests,
            successful_requests=successful_requests,
            failed_requests=failed_requests,
            avg_latency_ms=statistics.mean(latencies),
            p50_latency_ms=percentile(sorted_latencies, 50),
            p90_latency_ms=percentile(sorted_latencies, 90),
            p95_latency_ms=percentile(sorted_latencies, 95),
            p99_latency_ms=percentile(sorted_latencies, 99),
            min_latency_ms=min(latencies),
            max_latency_ms=max(latencies),
            requests_per_second=total_requests / duration if duration > 0 else 0,
            error_rate=failed_requests / total_requests if total_requests > 0 else 0,
            errors_by_type=errors_by_type,
        )


# =============================================================================
# Locust Integration (Optional)
# =============================================================================

try:
    from locust import HttpUser, task, between, events

    class MCPUser(HttpUser):
        """Locust user for MCP load testing."""

        wait_time = between(0.1, 0.5)

        def on_start(self):
            """Initialize connection."""
            self.client.post(
                "/mcp",
                json=MCPScenarios.initialize(),
                headers={"Content-Type": "application/json"},
            )

        @task(3)
        def tools_list(self):
            self.client.post(
                "/mcp",
                json=MCPScenarios.tools_list(),
                headers={"Content-Type": "application/json"},
            )

        @task(5)
        def tools_call(self):
            self.client.post(
                "/mcp",
                json=MCPScenarios.tools_call_data_quality(),
                headers={"Content-Type": "application/json"},
            )

        @task(2)
        def resources_list(self):
            self.client.post(
                "/mcp",
                json=MCPScenarios.resources_list(),
                headers={"Content-Type": "application/json"},
            )

        @task(1)
        def resources_read(self):
            self.client.post(
                "/mcp",
                json=MCPScenarios.resources_read_facts(),
                headers={"Content-Type": "application/json"},
            )

except ImportError:
    # Locust not installed, skip
    pass


# =============================================================================
# CLI Entry Point
# =============================================================================


def main():
    parser = argparse.ArgumentParser(description="Load test Data Cleaning Copilot")
    parser.add_argument("--target", "-t", required=True, help="Target URL (e.g., http://localhost:9110/mcp)")
    parser.add_argument("--duration", "-d", type=int, default=60, help="Test duration in seconds")
    parser.add_argument("--users", "-u", type=int, default=10, help="Number of concurrent users")
    parser.add_argument("--ramp-up", type=int, default=10, help="Ramp-up time in seconds")
    parser.add_argument("--think-time", type=int, default=100, help="Think time between requests (ms)")
    parser.add_argument("--auth-token", help="Authentication token")
    parser.add_argument("--output", "-o", help="Output file for JSON report")
    parser.add_argument(
        "--scenarios",
        nargs="+",
        default=["mcp_tools_list", "mcp_tools_call", "mcp_resources_list"],
        choices=list(SCENARIO_MAP.keys()),
        help="Test scenarios to run",
    )

    args = parser.parse_args()

    config = LoadTestConfig(
        target_url=args.target,
        duration_seconds=args.duration,
        concurrent_users=args.users,
        ramp_up_seconds=args.ramp_up,
        think_time_ms=args.think_time,
        auth_token=args.auth_token,
        scenarios=args.scenarios,
    )

    runner = LoadTestRunner(config)
    report = runner.run()

    report.print_summary()

    if args.output:
        with open(args.output, "w") as f:
            json.dump(report.to_dict(), f, indent=2)
        print(f"\nReport saved to {args.output}")

    # Exit with error if error rate > 5%
    if report.error_rate > 0.05:
        sys.exit(1)


if __name__ == "__main__":
    main()
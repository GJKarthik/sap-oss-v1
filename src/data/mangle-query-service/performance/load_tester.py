"""
Load Testing Framework - Performance Testing Without External Dependencies.

Day 49 Implementation - Week 10 Performance Optimization
Provides load testing, stress testing, and benchmarking capabilities.
No external service dependencies - pure Python implementation.
"""

import asyncio
import logging
import time
import statistics
import random
import string
from typing import Optional, Dict, Any, List, Callable, Awaitable
from dataclasses import dataclass, field
from enum import Enum
from abc import ABC, abstractmethod
import threading
from concurrent.futures import ThreadPoolExecutor

logger = logging.getLogger(__name__)


# =============================================================================
# Load Test Configuration
# =============================================================================

class LoadPattern(str, Enum):
    """Load generation patterns."""
    CONSTANT = "constant"  # Fixed rate
    RAMP_UP = "ramp_up"  # Gradual increase
    SPIKE = "spike"  # Sudden burst
    STEP = "step"  # Step increases
    WAVE = "wave"  # Sine wave pattern


class TestStatus(str, Enum):
    """Test execution status."""
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


@dataclass
class LoadTestConfig:
    """Load test configuration."""
    total_requests: int = 1000
    concurrent_users: int = 10
    duration_seconds: float = 60.0
    ramp_up_seconds: float = 10.0
    pattern: LoadPattern = LoadPattern.CONSTANT
    think_time_ms: float = 100.0  # Delay between requests
    timeout_seconds: float = 30.0
    
    @classmethod
    def light(cls) -> "LoadTestConfig":
        """Light load config."""
        return cls(
            total_requests=100,
            concurrent_users=5,
            duration_seconds=30.0,
        )
    
    @classmethod
    def moderate(cls) -> "LoadTestConfig":
        """Moderate load config."""
        return cls(
            total_requests=1000,
            concurrent_users=20,
            duration_seconds=60.0,
        )
    
    @classmethod
    def heavy(cls) -> "LoadTestConfig":
        """Heavy load config."""
        return cls(
            total_requests=10000,
            concurrent_users=100,
            duration_seconds=120.0,
        )
    
    @classmethod
    def stress(cls) -> "LoadTestConfig":
        """Stress test config."""
        return cls(
            total_requests=50000,
            concurrent_users=500,
            duration_seconds=300.0,
            pattern=LoadPattern.RAMP_UP,
        )


# =============================================================================
# Request Results
# =============================================================================

@dataclass
class RequestResult:
    """Single request result."""
    request_id: int
    start_time: float
    end_time: float
    duration_ms: float
    status_code: int
    success: bool
    error: Optional[str] = None
    response_size: int = 0
    
    @classmethod
    def success_result(
        cls,
        request_id: int,
        start_time: float,
        duration_ms: float,
        response_size: int = 0,
    ) -> "RequestResult":
        """Create successful result."""
        return cls(
            request_id=request_id,
            start_time=start_time,
            end_time=start_time + duration_ms / 1000,
            duration_ms=duration_ms,
            status_code=200,
            success=True,
            response_size=response_size,
        )
    
    @classmethod
    def failure_result(
        cls,
        request_id: int,
        start_time: float,
        duration_ms: float,
        error: str,
        status_code: int = 500,
    ) -> "RequestResult":
        """Create failure result."""
        return cls(
            request_id=request_id,
            start_time=start_time,
            end_time=start_time + duration_ms / 1000,
            duration_ms=duration_ms,
            status_code=status_code,
            success=False,
            error=error,
        )


# =============================================================================
# Load Test Results
# =============================================================================

@dataclass
class LoadTestResults:
    """Aggregated load test results."""
    test_name: str
    config: LoadTestConfig
    status: TestStatus
    start_time: float
    end_time: float
    results: List[RequestResult] = field(default_factory=list)
    
    @property
    def total_requests(self) -> int:
        """Total requests executed."""
        return len(self.results)
    
    @property
    def successful_requests(self) -> int:
        """Successful requests count."""
        return sum(1 for r in self.results if r.success)
    
    @property
    def failed_requests(self) -> int:
        """Failed requests count."""
        return sum(1 for r in self.results if not r.success)
    
    @property
    def success_rate(self) -> float:
        """Success rate percentage."""
        if not self.results:
            return 0.0
        return (self.successful_requests / self.total_requests) * 100
    
    @property
    def duration_seconds(self) -> float:
        """Total test duration."""
        return self.end_time - self.start_time
    
    @property
    def requests_per_second(self) -> float:
        """Throughput in requests/second."""
        if self.duration_seconds == 0:
            return 0.0
        return self.total_requests / self.duration_seconds
    
    def get_latency_stats(self) -> Dict[str, float]:
        """Get latency statistics."""
        if not self.results:
            return {}
        
        durations = [r.duration_ms for r in self.results if r.success]
        if not durations:
            return {}
        
        sorted_durations = sorted(durations)
        
        return {
            "min_ms": min(durations),
            "max_ms": max(durations),
            "mean_ms": statistics.mean(durations),
            "median_ms": statistics.median(durations),
            "stdev_ms": statistics.stdev(durations) if len(durations) > 1 else 0,
            "p50_ms": self._percentile(sorted_durations, 50),
            "p90_ms": self._percentile(sorted_durations, 90),
            "p95_ms": self._percentile(sorted_durations, 95),
            "p99_ms": self._percentile(sorted_durations, 99),
        }
    
    def _percentile(self, sorted_data: List[float], p: int) -> float:
        """Calculate percentile."""
        if not sorted_data:
            return 0.0
        k = (len(sorted_data) - 1) * p / 100
        f = int(k)
        c = f + 1 if f + 1 < len(sorted_data) else f
        return sorted_data[f] + (k - f) * (sorted_data[c] - sorted_data[f])
    
    def get_error_summary(self) -> Dict[str, int]:
        """Get error breakdown."""
        errors: Dict[str, int] = {}
        for r in self.results:
            if not r.success and r.error:
                errors[r.error] = errors.get(r.error, 0) + 1
        return errors
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        latency = self.get_latency_stats()
        return {
            "test_name": self.test_name,
            "status": self.status.value,
            "total_requests": self.total_requests,
            "successful_requests": self.successful_requests,
            "failed_requests": self.failed_requests,
            "success_rate": round(self.success_rate, 2),
            "duration_seconds": round(self.duration_seconds, 2),
            "requests_per_second": round(self.requests_per_second, 2),
            "latency": {k: round(v, 2) for k, v in latency.items()},
            "errors": self.get_error_summary(),
        }


# =============================================================================
# Request Generators
# =============================================================================

class RequestGenerator(ABC):
    """Abstract request generator."""
    
    @abstractmethod
    async def generate(self, request_id: int) -> RequestResult:
        """Generate and execute a request."""
        pass


class MockRequestGenerator(RequestGenerator):
    """Mock request generator for testing."""
    
    def __init__(
        self,
        base_latency_ms: float = 50.0,
        latency_variance: float = 20.0,
        failure_rate: float = 0.01,
        response_size: int = 1024,
    ):
        self.base_latency = base_latency_ms
        self.variance = latency_variance
        self.failure_rate = failure_rate
        self.response_size = response_size
    
    async def generate(self, request_id: int) -> RequestResult:
        """Generate mock request."""
        start_time = time.time()
        
        # Simulate latency
        latency = self.base_latency + random.uniform(-self.variance, self.variance)
        latency = max(1.0, latency)  # Minimum 1ms
        
        await asyncio.sleep(latency / 1000)
        
        # Simulate failures
        if random.random() < self.failure_rate:
            return RequestResult.failure_result(
                request_id=request_id,
                start_time=start_time,
                duration_ms=latency,
                error="Simulated failure",
                status_code=500,
            )
        
        return RequestResult.success_result(
            request_id=request_id,
            start_time=start_time,
            duration_ms=latency,
            response_size=self.response_size,
        )


class CallableRequestGenerator(RequestGenerator):
    """Generator from callable."""
    
    def __init__(self, func: Callable[[int], Awaitable[RequestResult]]):
        self.func = func
    
    async def generate(self, request_id: int) -> RequestResult:
        """Execute callable."""
        return await self.func(request_id)


# =============================================================================
# Load Tester
# =============================================================================

class LoadTester:
    """
    Main load testing engine.
    
    Features:
    - Multiple load patterns
    - Concurrent user simulation
    - Statistics collection
    - Real-time progress
    """
    
    def __init__(
        self,
        config: Optional[LoadTestConfig] = None,
        generator: Optional[RequestGenerator] = None,
    ):
        self.config = config or LoadTestConfig()
        self.generator = generator or MockRequestGenerator()
        self._status = TestStatus.PENDING
        self._results: List[RequestResult] = []
        self._lock = threading.Lock()
        self._cancel_event = asyncio.Event()
    
    async def run(self, test_name: str = "load_test") -> LoadTestResults:
        """Run load test."""
        self._status = TestStatus.RUNNING
        self._results = []
        start_time = time.time()
        
        try:
            # Create semaphore for concurrency control
            semaphore = asyncio.Semaphore(self.config.concurrent_users)
            
            # Create tasks based on pattern
            tasks = []
            for i in range(self.config.total_requests):
                if self._cancel_event.is_set():
                    break
                
                # Apply load pattern delay
                delay = self._get_delay_for_request(i)
                if delay > 0:
                    await asyncio.sleep(delay / 1000)
                
                task = asyncio.create_task(
                    self._execute_request(i, semaphore)
                )
                tasks.append(task)
            
            # Wait for all tasks
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            
            self._status = TestStatus.COMPLETED
            
        except Exception as e:
            self._status = TestStatus.FAILED
            logger.error(f"Load test failed: {e}")
        
        end_time = time.time()
        
        return LoadTestResults(
            test_name=test_name,
            config=self.config,
            status=self._status,
            start_time=start_time,
            end_time=end_time,
            results=list(self._results),
        )
    
    async def _execute_request(
        self,
        request_id: int,
        semaphore: asyncio.Semaphore,
    ) -> None:
        """Execute single request with semaphore."""
        async with semaphore:
            try:
                # Apply think time
                if self.config.think_time_ms > 0:
                    await asyncio.sleep(self.config.think_time_ms / 1000)
                
                # Execute with timeout
                result = await asyncio.wait_for(
                    self.generator.generate(request_id),
                    timeout=self.config.timeout_seconds,
                )
                
                with self._lock:
                    self._results.append(result)
                    
            except asyncio.TimeoutError:
                result = RequestResult.failure_result(
                    request_id=request_id,
                    start_time=time.time(),
                    duration_ms=self.config.timeout_seconds * 1000,
                    error="Timeout",
                    status_code=504,
                )
                with self._lock:
                    self._results.append(result)
            except Exception as e:
                result = RequestResult.failure_result(
                    request_id=request_id,
                    start_time=time.time(),
                    duration_ms=0,
                    error=str(e),
                    status_code=500,
                )
                with self._lock:
                    self._results.append(result)
    
    def _get_delay_for_request(self, request_id: int) -> float:
        """Calculate delay based on load pattern."""
        if self.config.pattern == LoadPattern.CONSTANT:
            return 0
        
        elif self.config.pattern == LoadPattern.RAMP_UP:
            # Gradual increase over ramp_up period
            ramp_requests = int(
                self.config.total_requests *
                (self.config.ramp_up_seconds / self.config.duration_seconds)
            )
            if request_id < ramp_requests:
                progress = request_id / ramp_requests
                delay = (1 - progress) * 100  # Decreasing delay
                return delay
            return 0
        
        elif self.config.pattern == LoadPattern.SPIKE:
            # Sudden burst at 50% mark
            mid_point = self.config.total_requests // 2
            if abs(request_id - mid_point) < 50:
                return 0  # No delay during spike
            return 50
        
        elif self.config.pattern == LoadPattern.STEP:
            # Step increases every 25% of requests
            quarter = self.config.total_requests // 4
            step = request_id // quarter
            delay = max(0, (3 - step) * 50)
            return delay
        
        elif self.config.pattern == LoadPattern.WAVE:
            # Sine wave pattern
            import math
            progress = request_id / self.config.total_requests
            wave = math.sin(progress * math.pi * 4)  # 2 full waves
            delay = 50 + wave * 40  # 10-90ms range
            return delay
        
        return 0
    
    def cancel(self):
        """Cancel running test."""
        self._cancel_event.set()
        self._status = TestStatus.CANCELLED
    
    @property
    def status(self) -> TestStatus:
        """Get current status."""
        return self._status
    
    def get_progress(self) -> Dict[str, Any]:
        """Get current progress."""
        with self._lock:
            completed = len(self._results)
        
        return {
            "status": self._status.value,
            "completed": completed,
            "total": self.config.total_requests,
            "progress_percent": round(completed / self.config.total_requests * 100, 1),
        }


# =============================================================================
# Stress Tester
# =============================================================================

class StressTester:
    """
    Stress testing for finding system limits.
    
    Gradually increases load until failures occur.
    """
    
    def __init__(
        self,
        generator: Optional[RequestGenerator] = None,
        max_users: int = 1000,
        step_users: int = 50,
        step_duration_seconds: float = 30.0,
        failure_threshold: float = 0.05,  # 5% failure rate
    ):
        self.generator = generator or MockRequestGenerator()
        self.max_users = max_users
        self.step_users = step_users
        self.step_duration = step_duration_seconds
        self.failure_threshold = failure_threshold
    
    async def run(self) -> Dict[str, Any]:
        """Run stress test."""
        results = []
        breaking_point = None
        
        for concurrent_users in range(self.step_users, self.max_users + 1, self.step_users):
            config = LoadTestConfig(
                total_requests=concurrent_users * 10,
                concurrent_users=concurrent_users,
                duration_seconds=self.step_duration,
            )
            
            tester = LoadTester(config=config, generator=self.generator)
            result = await tester.run(f"stress_{concurrent_users}")
            
            step_result = {
                "concurrent_users": concurrent_users,
                "success_rate": result.success_rate,
                "rps": result.requests_per_second,
                "p99_ms": result.get_latency_stats().get("p99_ms", 0),
            }
            results.append(step_result)
            
            # Check for breaking point
            if result.success_rate < (1 - self.failure_threshold) * 100:
                breaking_point = concurrent_users
                break
        
        return {
            "steps": results,
            "breaking_point": breaking_point,
            "max_sustainable_users": breaking_point - self.step_users if breaking_point else self.max_users,
        }


# =============================================================================
# Benchmark Runner
# =============================================================================

class BenchmarkRunner:
    """
    Run benchmarks comparing different configurations.
    """
    
    def __init__(self, generator: Optional[RequestGenerator] = None):
        self.generator = generator or MockRequestGenerator()
    
    async def run_comparison(
        self,
        configs: List[LoadTestConfig],
        names: Optional[List[str]] = None,
    ) -> List[Dict[str, Any]]:
        """Run multiple configs and compare."""
        if names is None:
            names = [f"config_{i}" for i in range(len(configs))]
        
        results = []
        for config, name in zip(configs, names):
            tester = LoadTester(config=config, generator=self.generator)
            result = await tester.run(name)
            results.append(result.to_dict())
        
        return results
    
    async def run_standard_benchmarks(self) -> Dict[str, Any]:
        """Run standard benchmark suite."""
        configs = [
            LoadTestConfig.light(),
            LoadTestConfig.moderate(),
            LoadTestConfig.heavy(),
        ]
        names = ["light", "moderate", "heavy"]
        
        results = await self.run_comparison(configs, names)
        
        return {
            "benchmarks": results,
            "summary": self._summarize(results),
        }
    
    def _summarize(self, results: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Summarize benchmark results."""
        if not results:
            return {}
        
        return {
            "total_tests": len(results),
            "all_passed": all(r.get("success_rate", 0) > 95 for r in results),
            "avg_rps": sum(r.get("requests_per_second", 0) for r in results) / len(results),
            "max_p99": max(r.get("latency", {}).get("p99_ms", 0) for r in results),
        }


# =============================================================================
# Factory Functions
# =============================================================================

def create_load_tester(
    config: Optional[LoadTestConfig] = None,
    generator: Optional[RequestGenerator] = None,
) -> LoadTester:
    """Create load tester."""
    return LoadTester(config=config, generator=generator)


def create_mock_generator(
    base_latency_ms: float = 50.0,
    failure_rate: float = 0.01,
) -> MockRequestGenerator:
    """Create mock request generator."""
    return MockRequestGenerator(
        base_latency_ms=base_latency_ms,
        failure_rate=failure_rate,
    )


def create_stress_tester(
    max_users: int = 1000,
    failure_threshold: float = 0.05,
) -> StressTester:
    """Create stress tester."""
    return StressTester(
        max_users=max_users,
        failure_threshold=failure_threshold,
    )


def create_benchmark_runner() -> BenchmarkRunner:
    """Create benchmark runner."""
    return BenchmarkRunner()
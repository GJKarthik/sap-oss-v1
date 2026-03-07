"""
Unit tests for load tester.

Day 49 - Week 10 Performance Optimization
45 tests covering load testing, stress testing, and benchmarking.
No external service dependencies.
"""

import pytest
import asyncio
import time
from unittest.mock import Mock, AsyncMock, patch

from performance.load_tester import (
    LoadPattern,
    TestStatus,
    LoadTestConfig,
    RequestResult,
    LoadTestResults,
    RequestGenerator,
    MockRequestGenerator,
    CallableRequestGenerator,
    LoadTester,
    StressTester,
    BenchmarkRunner,
    create_load_tester,
    create_mock_generator,
    create_stress_tester,
    create_benchmark_runner,
)


# =============================================================================
# LoadPattern Tests (3 tests)
# =============================================================================

class TestLoadPattern:
    """Tests for LoadPattern enum."""
    
    def test_all_patterns_defined(self):
        """Test all patterns are defined."""
        patterns = list(LoadPattern)
        assert len(patterns) == 5
    
    def test_pattern_values(self):
        """Test pattern values."""
        assert LoadPattern.CONSTANT.value == "constant"
        assert LoadPattern.RAMP_UP.value == "ramp_up"
        assert LoadPattern.SPIKE.value == "spike"
    
    def test_step_and_wave(self):
        """Test step and wave patterns."""
        assert LoadPattern.STEP.value == "step"
        assert LoadPattern.WAVE.value == "wave"


# =============================================================================
# TestStatus Tests (2 tests)
# =============================================================================

class TestTestStatus:
    """Tests for TestStatus enum."""
    
    def test_all_statuses_defined(self):
        """Test all statuses are defined."""
        statuses = list(TestStatus)
        assert len(statuses) == 5
    
    def test_status_values(self):
        """Test status values."""
        assert TestStatus.PENDING.value == "pending"
        assert TestStatus.RUNNING.value == "running"
        assert TestStatus.COMPLETED.value == "completed"


# =============================================================================
# LoadTestConfig Tests (5 tests)
# =============================================================================

class TestLoadTestConfig:
    """Tests for LoadTestConfig dataclass."""
    
    def test_default_config(self):
        """Test default configuration."""
        config = LoadTestConfig()
        assert config.total_requests == 1000
        assert config.concurrent_users == 10
        assert config.pattern == LoadPattern.CONSTANT
    
    def test_light_config(self):
        """Test light preset."""
        config = LoadTestConfig.light()
        assert config.total_requests == 100
        assert config.concurrent_users == 5
    
    def test_moderate_config(self):
        """Test moderate preset."""
        config = LoadTestConfig.moderate()
        assert config.total_requests == 1000
        assert config.concurrent_users == 20
    
    def test_heavy_config(self):
        """Test heavy preset."""
        config = LoadTestConfig.heavy()
        assert config.total_requests == 10000
        assert config.concurrent_users == 100
    
    def test_stress_config(self):
        """Test stress preset."""
        config = LoadTestConfig.stress()
        assert config.total_requests == 50000
        assert config.pattern == LoadPattern.RAMP_UP


# =============================================================================
# RequestResult Tests (5 tests)
# =============================================================================

class TestRequestResult:
    """Tests for RequestResult dataclass."""
    
    def test_success_result(self):
        """Test successful result creation."""
        result = RequestResult.success_result(
            request_id=1,
            start_time=1000.0,
            duration_ms=50.0,
        )
        assert result.success is True
        assert result.status_code == 200
        assert result.duration_ms == 50.0
    
    def test_failure_result(self):
        """Test failure result creation."""
        result = RequestResult.failure_result(
            request_id=1,
            start_time=1000.0,
            duration_ms=100.0,
            error="Connection refused",
        )
        assert result.success is False
        assert result.error == "Connection refused"
    
    def test_end_time_calculation(self):
        """Test end time is calculated."""
        result = RequestResult.success_result(
            request_id=1,
            start_time=1000.0,
            duration_ms=500.0,
        )
        assert result.end_time == 1000.5  # 500ms = 0.5s
    
    def test_response_size(self):
        """Test response size."""
        result = RequestResult.success_result(
            request_id=1,
            start_time=1000.0,
            duration_ms=50.0,
            response_size=2048,
        )
        assert result.response_size == 2048
    
    def test_custom_status_code(self):
        """Test custom status code on failure."""
        result = RequestResult.failure_result(
            request_id=1,
            start_time=1000.0,
            duration_ms=30000.0,
            error="Timeout",
            status_code=504,
        )
        assert result.status_code == 504


# =============================================================================
# LoadTestResults Tests (8 tests)
# =============================================================================

class TestLoadTestResults:
    """Tests for LoadTestResults dataclass."""
    
    def test_empty_results(self):
        """Test empty results."""
        results = LoadTestResults(
            test_name="test",
            config=LoadTestConfig(),
            status=TestStatus.COMPLETED,
            start_time=0.0,
            end_time=1.0,
        )
        assert results.total_requests == 0
        assert results.success_rate == 0.0
    
    def test_success_rate(self):
        """Test success rate calculation."""
        results = LoadTestResults(
            test_name="test",
            config=LoadTestConfig(),
            status=TestStatus.COMPLETED,
            start_time=0.0,
            end_time=1.0,
            results=[
                RequestResult.success_result(i, 0.0, 50.0)
                for i in range(90)
            ] + [
                RequestResult.failure_result(i, 0.0, 50.0, "Error")
                for i in range(10)
            ],
        )
        assert results.success_rate == 90.0
    
    def test_requests_per_second(self):
        """Test RPS calculation."""
        results = LoadTestResults(
            test_name="test",
            config=LoadTestConfig(),
            status=TestStatus.COMPLETED,
            start_time=0.0,
            end_time=10.0,  # 10 seconds
            results=[
                RequestResult.success_result(i, 0.0, 50.0)
                for i in range(100)
            ],
        )
        assert results.requests_per_second == 10.0
    
    def test_latency_stats(self):
        """Test latency statistics."""
        results = LoadTestResults(
            test_name="test",
            config=LoadTestConfig(),
            status=TestStatus.COMPLETED,
            start_time=0.0,
            end_time=1.0,
            results=[
                RequestResult.success_result(i, 0.0, 50.0 + i)
                for i in range(10)
            ],
        )
        stats = results.get_latency_stats()
        assert "min_ms" in stats
        assert "max_ms" in stats
        assert "mean_ms" in stats
        assert "p99_ms" in stats
    
    def test_error_summary(self):
        """Test error breakdown."""
        results = LoadTestResults(
            test_name="test",
            config=LoadTestConfig(),
            status=TestStatus.COMPLETED,
            start_time=0.0,
            end_time=1.0,
            results=[
                RequestResult.failure_result(0, 0.0, 50.0, "Timeout"),
                RequestResult.failure_result(1, 0.0, 50.0, "Timeout"),
                RequestResult.failure_result(2, 0.0, 50.0, "Connection refused"),
            ],
        )
        errors = results.get_error_summary()
        assert errors["Timeout"] == 2
        assert errors["Connection refused"] == 1
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        results = LoadTestResults(
            test_name="test",
            config=LoadTestConfig(),
            status=TestStatus.COMPLETED,
            start_time=0.0,
            end_time=1.0,
        )
        d = results.to_dict()
        assert "test_name" in d
        assert "status" in d
        assert "success_rate" in d
    
    def test_duration_seconds(self):
        """Test duration calculation."""
        results = LoadTestResults(
            test_name="test",
            config=LoadTestConfig(),
            status=TestStatus.COMPLETED,
            start_time=100.0,
            end_time=160.0,
        )
        assert results.duration_seconds == 60.0
    
    def test_percentile_calculation(self):
        """Test percentile calculation."""
        results = LoadTestResults(
            test_name="test",
            config=LoadTestConfig(),
            status=TestStatus.COMPLETED,
            start_time=0.0,
            end_time=1.0,
            results=[
                RequestResult.success_result(i, 0.0, float(i + 1))
                for i in range(100)
            ],
        )
        stats = results.get_latency_stats()
        assert stats["p50_ms"] == pytest.approx(50.5, rel=0.1)
        assert stats["p90_ms"] == pytest.approx(90.1, rel=0.1)


# =============================================================================
# MockRequestGenerator Tests (4 tests)
# =============================================================================

class TestMockRequestGenerator:
    """Tests for MockRequestGenerator."""
    
    @pytest.mark.asyncio
    async def test_generates_success(self):
        """Test generates successful requests."""
        gen = MockRequestGenerator(failure_rate=0.0)
        result = await gen.generate(1)
        assert result.success is True
    
    @pytest.mark.asyncio
    async def test_respects_failure_rate(self):
        """Test failure rate is applied."""
        gen = MockRequestGenerator(failure_rate=1.0)  # 100% failure
        result = await gen.generate(1)
        assert result.success is False
    
    @pytest.mark.asyncio
    async def test_latency_variance(self):
        """Test latency has variance."""
        gen = MockRequestGenerator(
            base_latency_ms=50.0,
            latency_variance=20.0,
        )
        durations = []
        for i in range(10):
            result = await gen.generate(i)
            durations.append(result.duration_ms)
        
        # Should have some variance
        assert max(durations) != min(durations)
    
    @pytest.mark.asyncio
    async def test_response_size(self):
        """Test response size is set."""
        gen = MockRequestGenerator(response_size=4096)
        result = await gen.generate(1)
        assert result.response_size == 4096


# =============================================================================
# LoadTester Tests (10 tests)
# =============================================================================

class TestLoadTester:
    """Tests for LoadTester."""
    
    @pytest.mark.asyncio
    async def test_basic_load_test(self):
        """Test basic load test execution."""
        config = LoadTestConfig(
            total_requests=10,
            concurrent_users=2,
            think_time_ms=0,
        )
        tester = LoadTester(config=config)
        results = await tester.run("test")
        
        assert results.total_requests == 10
        assert results.status == TestStatus.COMPLETED
    
    @pytest.mark.asyncio
    async def test_concurrent_users_limit(self):
        """Test concurrent users are limited."""
        config = LoadTestConfig(
            total_requests=20,
            concurrent_users=5,
            think_time_ms=0,
        )
        gen = MockRequestGenerator(base_latency_ms=100)
        tester = LoadTester(config=config, generator=gen)
        
        start = time.time()
        await tester.run("test")
        duration = time.time() - start
        
        # Should take ~400ms (20 req / 5 concurrent * 100ms)
        assert duration >= 0.3
    
    @pytest.mark.asyncio
    async def test_status_tracking(self):
        """Test status is tracked."""
        config = LoadTestConfig(total_requests=5, think_time_ms=0)
        tester = LoadTester(config=config)
        
        assert tester.status == TestStatus.PENDING
        
        results = await tester.run("test")
        assert results.status == TestStatus.COMPLETED
    
    @pytest.mark.asyncio
    async def test_progress_tracking(self):
        """Test progress is tracked."""
        config = LoadTestConfig(total_requests=10, think_time_ms=0)
        tester = LoadTester(config=config)
        
        progress = tester.get_progress()
        assert progress["completed"] == 0
        assert progress["total"] == 10
    
    @pytest.mark.asyncio
    async def test_custom_generator(self):
        """Test with custom generator."""
        async def custom_gen(request_id: int) -> RequestResult:
            return RequestResult.success_result(
                request_id=request_id,
                start_time=time.time(),
                duration_ms=10.0,
            )
        
        gen = CallableRequestGenerator(custom_gen)
        config = LoadTestConfig(total_requests=5, think_time_ms=0)
        tester = LoadTester(config=config, generator=gen)
        
        results = await tester.run("test")
        assert results.success_rate == 100.0
    
    @pytest.mark.asyncio
    async def test_constant_pattern(self):
        """Test constant load pattern."""
        config = LoadTestConfig(
            total_requests=5,
            pattern=LoadPattern.CONSTANT,
            think_time_ms=0,
        )
        tester = LoadTester(config=config)
        delay = tester._get_delay_for_request(0)
        assert delay == 0
    
    @pytest.mark.asyncio
    async def test_ramp_up_pattern(self):
        """Test ramp-up pattern has delays."""
        config = LoadTestConfig(
            total_requests=100,
            pattern=LoadPattern.RAMP_UP,
            ramp_up_seconds=10.0,
            duration_seconds=60.0,
        )
        tester = LoadTester(config=config)
        
        # Early requests should have delay
        early_delay = tester._get_delay_for_request(0)
        assert early_delay > 0
    
    @pytest.mark.asyncio
    async def test_spike_pattern(self):
        """Test spike pattern."""
        config = LoadTestConfig(
            total_requests=100,
            pattern=LoadPattern.SPIKE,
        )
        tester = LoadTester(config=config)
        
        # Mid-point should have no delay (spike)
        mid_delay = tester._get_delay_for_request(50)
        assert mid_delay == 0
    
    @pytest.mark.asyncio
    async def test_timeout_handling(self):
        """Test timeout is handled."""
        async def slow_gen(request_id: int) -> RequestResult:
            await asyncio.sleep(10)  # Very slow
            return RequestResult.success_result(request_id, time.time(), 10000)
        
        gen = CallableRequestGenerator(slow_gen)
        config = LoadTestConfig(
            total_requests=1,
            timeout_seconds=0.1,  # Very short timeout
            think_time_ms=0,
        )
        tester = LoadTester(config=config, generator=gen)
        
        results = await tester.run("test")
        assert results.failed_requests >= 1
    
    @pytest.mark.asyncio
    async def test_cancel(self):
        """Test cancellation."""
        config = LoadTestConfig(total_requests=1000, think_time_ms=10)
        tester = LoadTester(config=config)
        
        # Cancel immediately
        tester.cancel()
        assert tester.status == TestStatus.CANCELLED


# =============================================================================
# StressTester Tests (3 tests)
# =============================================================================

class TestStressTester:
    """Tests for StressTester."""
    
    @pytest.mark.asyncio
    async def test_basic_stress_test(self):
        """Test basic stress test."""
        gen = MockRequestGenerator(
            base_latency_ms=10,
            failure_rate=0.0,
        )
        tester = StressTester(
            generator=gen,
            max_users=100,
            step_users=50,
            step_duration_seconds=1.0,
        )
        
        results = await tester.run()
        assert "steps" in results
        assert len(results["steps"]) > 0
    
    @pytest.mark.asyncio
    async def test_finds_breaking_point(self):
        """Test finding breaking point."""
        # Generator that fails at high concurrency
        class FailAtHighLoadGenerator(RequestGenerator):
            async def generate(self, request_id: int) -> RequestResult:
                # Simulate failure at high request IDs (high load)
                if request_id > 100:
                    return RequestResult.failure_result(
                        request_id, time.time(), 10, "Overload"
                    )
                return RequestResult.success_result(
                    request_id, time.time(), 10
                )
        
        tester = StressTester(
            generator=FailAtHighLoadGenerator(),
            max_users=200,
            step_users=50,
            failure_threshold=0.1,
        )
        
        results = await tester.run()
        assert "breaking_point" in results
    
    def test_configuration(self):
        """Test stress tester configuration."""
        tester = StressTester(
            max_users=500,
            step_users=25,
            failure_threshold=0.10,
        )
        assert tester.max_users == 500
        assert tester.step_users == 25


# =============================================================================
# BenchmarkRunner Tests (3 tests)
# =============================================================================

class TestBenchmarkRunner:
    """Tests for BenchmarkRunner."""
    
    @pytest.mark.asyncio
    async def test_run_comparison(self):
        """Test running comparison."""
        configs = [
            LoadTestConfig(total_requests=5, think_time_ms=0),
            LoadTestConfig(total_requests=10, think_time_ms=0),
        ]
        
        runner = BenchmarkRunner()
        results = await runner.run_comparison(configs, ["small", "medium"])
        
        assert len(results) == 2
        assert results[0]["test_name"] == "small"
    
    @pytest.mark.asyncio
    async def test_standard_benchmarks(self):
        """Test standard benchmark suite."""
        # Use fast mock generator
        gen = MockRequestGenerator(base_latency_ms=1, failure_rate=0)
        runner = BenchmarkRunner(generator=gen)
        
        # Patch configs for speed
        with patch.object(LoadTestConfig, 'light', return_value=LoadTestConfig(
            total_requests=5, concurrent_users=2, think_time_ms=0
        )):
            with patch.object(LoadTestConfig, 'moderate', return_value=LoadTestConfig(
                total_requests=10, concurrent_users=5, think_time_ms=0
            )):
                with patch.object(LoadTestConfig, 'heavy', return_value=LoadTestConfig(
                    total_requests=20, concurrent_users=10, think_time_ms=0
                )):
                    results = await runner.run_standard_benchmarks()
        
        assert "benchmarks" in results
        assert "summary" in results
    
    def test_summarize(self):
        """Test result summarization."""
        runner = BenchmarkRunner()
        
        results = [
            {"success_rate": 99.0, "requests_per_second": 100, "latency": {"p99_ms": 50}},
            {"success_rate": 98.0, "requests_per_second": 200, "latency": {"p99_ms": 75}},
        ]
        
        summary = runner._summarize(results)
        assert summary["total_tests"] == 2
        assert summary["all_passed"] is True


# =============================================================================
# Factory Functions Tests (2 tests)
# =============================================================================

class TestFactoryFunctions:
    """Tests for factory functions."""
    
    def test_create_load_tester(self):
        """Test load tester factory."""
        tester = create_load_tester()
        assert tester is not None
        assert isinstance(tester, LoadTester)
    
    def test_create_mock_generator(self):
        """Test mock generator factory."""
        gen = create_mock_generator(
            base_latency_ms=100,
            failure_rate=0.05,
        )
        assert gen.base_latency == 100
        assert gen.failure_rate == 0.05


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - LoadPattern: 3 tests
# - TestStatus: 2 tests
# - LoadTestConfig: 5 tests
# - RequestResult: 5 tests
# - LoadTestResults: 8 tests
# - MockRequestGenerator: 4 tests
# - LoadTester: 10 tests
# - StressTester: 3 tests
# - BenchmarkRunner: 3 tests
# - Factory Functions: 2 tests
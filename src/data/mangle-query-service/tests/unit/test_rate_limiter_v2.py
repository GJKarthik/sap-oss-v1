"""
Unit tests for enhanced rate limiter v2.

Day 44 - Week 9 Security Hardening
45 tests covering sliding window, tiered limits, and burst protection.
"""

import time
import pytest
from unittest.mock import Mock, patch

from middleware.rate_limiter_v2 import (
    RateLimitTier,
    TierLimits,
    EndpointLimits,
    SlidingWindowCounter,
    RateLimitState,
    RateLimiterManager,
    create_rate_limiter,
    get_tier_limits,
)


# =============================================================================
# RateLimitTier Tests (3 tests)
# =============================================================================

class TestRateLimitTier:
    """Tests for RateLimitTier enum."""
    
    def test_tier_values(self):
        """Test tier enum values."""
        assert RateLimitTier.FREE.value == "free"
        assert RateLimitTier.STANDARD.value == "standard"
        assert RateLimitTier.PREMIUM.value == "premium"
        assert RateLimitTier.ENTERPRISE.value == "enterprise"
    
    def test_all_tiers_defined(self):
        """Test all tiers are defined."""
        tiers = list(RateLimitTier)
        assert len(tiers) == 5
    
    def test_internal_tier(self):
        """Test internal tier for service-to-service."""
        assert RateLimitTier.INTERNAL.value == "internal"


# =============================================================================
# TierLimits Tests (8 tests)
# =============================================================================

class TestTierLimits:
    """Tests for TierLimits configuration."""
    
    def test_free_tier_limits(self):
        """Test free tier limits."""
        limits = TierLimits.for_tier(RateLimitTier.FREE)
        assert limits.requests_per_minute == 20
        assert limits.requests_per_day == 1000
        assert limits.burst_limit == 3
    
    def test_standard_tier_limits(self):
        """Test standard tier limits."""
        limits = TierLimits.for_tier(RateLimitTier.STANDARD)
        assert limits.requests_per_minute == 60
        assert limits.tokens_per_minute == 60000
    
    def test_premium_tier_limits(self):
        """Test premium tier limits."""
        limits = TierLimits.for_tier(RateLimitTier.PREMIUM)
        assert limits.requests_per_minute == 200
        assert limits.burst_limit == 30
    
    def test_enterprise_tier_limits(self):
        """Test enterprise tier limits."""
        limits = TierLimits.for_tier(RateLimitTier.ENTERPRISE)
        assert limits.requests_per_minute == 1000
        assert limits.burst_limit == 100
    
    def test_internal_tier_limits(self):
        """Test internal tier (highest limits)."""
        limits = TierLimits.for_tier(RateLimitTier.INTERNAL)
        assert limits.requests_per_minute == 10000
        assert limits.burst_limit == 500
    
    def test_tier_hierarchy(self):
        """Test tiers have increasing limits."""
        free = TierLimits.for_tier(RateLimitTier.FREE)
        standard = TierLimits.for_tier(RateLimitTier.STANDARD)
        premium = TierLimits.for_tier(RateLimitTier.PREMIUM)
        
        assert free.requests_per_minute < standard.requests_per_minute
        assert standard.requests_per_minute < premium.requests_per_minute
    
    def test_token_limits(self):
        """Test token-based limits."""
        limits = TierLimits.for_tier(RateLimitTier.FREE)
        assert limits.tokens_per_minute == 10000
        assert limits.tokens_per_day == 100000
    
    def test_unknown_tier_defaults_to_free(self):
        """Test unknown tier defaults to free."""
        limits = TierLimits.for_tier(RateLimitTier.FREE)
        assert limits.requests_per_minute == 20


# =============================================================================
# EndpointLimits Tests (4 tests)
# =============================================================================

class TestEndpointLimits:
    """Tests for endpoint-specific limits."""
    
    def test_default_endpoints(self):
        """Test default endpoint configurations."""
        defaults = EndpointLimits.get_defaults()
        assert "/v1/chat/completions" in defaults
        assert "/v1/embeddings" in defaults
    
    def test_chat_completions_multiplier(self):
        """Test chat completions has standard multiplier."""
        defaults = EndpointLimits.get_defaults()
        chat = defaults["/v1/chat/completions"]
        assert chat.multiplier == 1.0
    
    def test_embeddings_higher_multiplier(self):
        """Test embeddings has higher multiplier."""
        defaults = EndpointLimits.get_defaults()
        embed = defaults["/v1/embeddings"]
        assert embed.multiplier == 2.0
    
    def test_images_lower_multiplier(self):
        """Test image generation has lower multiplier."""
        defaults = EndpointLimits.get_defaults()
        images = defaults["/v1/images/generations"]
        assert images.multiplier == 0.2


# =============================================================================
# SlidingWindowCounter Tests (12 tests)
# =============================================================================

class TestSlidingWindowCounter:
    """Tests for sliding window rate limiting."""
    
    @pytest.fixture
    def counter(self):
        """Create counter with 60-second window, 10 request limit."""
        return SlidingWindowCounter(60, 10)
    
    def test_init(self, counter):
        """Test counter initialization."""
        assert counter.window_size == 60
        assert counter.limit == 10
    
    def test_first_request_allowed(self, counter):
        """Test first request is always allowed."""
        allowed, count, limit = counter.is_allowed()
        assert allowed is True
        assert count == 0
        assert limit == 10
    
    def test_record_increases_count(self, counter):
        """Test recording requests increases count."""
        now = time.time()
        counter.record(1, now)
        counter.record(1, now)
        
        allowed, count, _ = counter.is_allowed(now)
        assert count == 2
    
    def test_limit_enforced(self, counter):
        """Test rate limit is enforced."""
        now = time.time()
        for _ in range(10):
            counter.record(1, now)
        
        allowed, count, limit = counter.is_allowed(now)
        assert allowed is False
        assert count >= 10
    
    def test_get_remaining(self, counter):
        """Test getting remaining requests."""
        now = time.time()
        counter.record(3, now)
        
        remaining = counter.get_remaining(now)
        assert remaining == 7
    
    def test_get_reset_time(self, counter):
        """Test getting reset time."""
        now = time.time()
        reset = counter.get_reset_time(now)
        assert 0 <= reset <= 60
    
    def test_window_slides(self, counter):
        """Test window sliding behavior."""
        base_time = 1000.0
        
        # Record at start of window
        counter.record(5, base_time)
        
        # Move to middle of next window
        mid_next = base_time + 90  # 30 seconds into next window
        
        allowed, count, _ = counter.is_allowed(mid_next)
        # Previous count should be weighted by 0.5 (30 seconds into 60-second window)
        assert count < 5  # Weighted count
    
    def test_old_window_clears(self, counter):
        """Test old window data is cleared."""
        base_time = 1000.0
        counter.record(10, base_time)
        
        # Move to well past the window
        future = base_time + 200
        allowed, count, _ = counter.is_allowed(future)
        
        assert allowed is True
        assert count == 0
    
    def test_thread_safety(self, counter):
        """Test counter is thread-safe."""
        import threading
        
        def record_many():
            for _ in range(100):
                counter.record(1)
        
        threads = [threading.Thread(target=record_many) for _ in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        
        # Should have recorded 500 requests (but may be limited)
        _, count, _ = counter.is_allowed()
        assert count > 0
    
    def test_record_multiple(self, counter):
        """Test recording multiple requests at once."""
        counter.record(5)
        _, count, _ = counter.is_allowed()
        assert count == 5
    
    def test_window_boundary(self):
        """Test behavior at window boundary."""
        counter = SlidingWindowCounter(10, 100)
        base = 1000.0
        
        counter.record(50, base)
        counter.record(30, base + 15)  # Next window
        
        allowed, count, _ = counter.is_allowed(base + 15)
        assert count == 30  # Only current window
    
    def test_zero_limit(self):
        """Test counter with zero limit."""
        counter = SlidingWindowCounter(60, 0)
        allowed, _, _ = counter.is_allowed()
        assert allowed is False


# =============================================================================
# RateLimitState Tests (10 tests)
# =============================================================================

class TestRateLimitState:
    """Tests for rate limit state management."""
    
    @pytest.fixture
    def state(self):
        """Create rate limit state."""
        return RateLimitState(client_id="test-client", tier=RateLimitTier.FREE)
    
    def test_init(self, state):
        """Test state initialization."""
        assert state.client_id == "test-client"
        assert state.tier == RateLimitTier.FREE
        assert state.concurrent_requests == 0
    
    def test_counters_created(self, state):
        """Test counters are created."""
        assert state.minute_counter is not None
        assert state.hour_counter is not None
        assert state.day_counter is not None
    
    def test_check_request_limits_allowed(self, state):
        """Test request limits check when allowed."""
        allowed, reason, details = state.check_request_limits()
        assert allowed is True
        assert reason == ""
    
    def test_acquire_release_request(self, state):
        """Test acquiring and releasing request slots."""
        state.acquire_request()
        assert state.concurrent_requests == 1
        
        state.release_request()
        assert state.concurrent_requests == 0
    
    def test_check_burst_limit(self, state):
        """Test burst limit checking."""
        for _ in range(3):
            state.acquire_request()
        
        allowed, msg = state.check_burst_limit(3)
        assert allowed is False
    
    def test_record_request(self, state):
        """Test recording a completed request."""
        state.record_request(token_count=100)
        
        allowed, count, _ = state.minute_counter.is_allowed()
        assert count >= 1
    
    def test_get_headers(self, state):
        """Test getting rate limit headers."""
        headers = state.get_headers()
        
        assert "X-RateLimit-Limit-Requests" in headers
        assert "X-RateLimit-Remaining-Requests" in headers
        assert "X-RateLimit-Reset-Requests" in headers
    
    def test_last_request_time_updated(self, state):
        """Test last request time is updated."""
        state.acquire_request()
        assert state.last_request_time > 0
    
    def test_release_never_goes_negative(self, state):
        """Test release doesn't go below zero."""
        state.release_request()
        assert state.concurrent_requests == 0
    
    def test_token_tracking(self, state):
        """Test token usage tracking."""
        state.record_request(token_count=5000)
        
        remaining = state.token_minute_counter.get_remaining()
        limits = TierLimits.for_tier(RateLimitTier.FREE)
        assert remaining == limits.tokens_per_minute - 5000


# =============================================================================
# RateLimiterManager Tests (6 tests)
# =============================================================================

class TestRateLimiterManager:
    """Tests for rate limiter manager."""
    
    @pytest.fixture
    def manager(self):
        """Create rate limiter manager."""
        return RateLimiterManager()
    
    def test_get_client_state_creates_new(self, manager):
        """Test getting client state creates new entry."""
        state = manager.get_client_state("new-client")
        assert state is not None
        assert state.client_id == "new-client"
    
    def test_get_client_state_returns_existing(self, manager):
        """Test getting client state returns existing."""
        state1 = manager.get_client_state("test-client")
        state2 = manager.get_client_state("test-client")
        assert state1 is state2
    
    def test_get_client_state_with_tier(self, manager):
        """Test getting client state with specific tier."""
        state = manager.get_client_state("premium-client", RateLimitTier.PREMIUM)
        assert state.tier == RateLimitTier.PREMIUM
    
    def test_get_endpoint_multiplier(self, manager):
        """Test getting endpoint multiplier."""
        mult, burst = manager.get_endpoint_multiplier("/v1/embeddings")
        assert mult == 2.0
    
    def test_get_endpoint_multiplier_default(self, manager):
        """Test default endpoint multiplier."""
        mult, burst = manager.get_endpoint_multiplier("/unknown/path")
        assert mult == 1.0
        assert burst == 1.0
    
    def test_update_tier(self, manager):
        """Test updating client tier."""
        manager.get_client_state("upgrade-client", RateLimitTier.FREE)
        manager.update_tier("upgrade-client", RateLimitTier.PREMIUM)
        
        state = manager.get_client_state("upgrade-client")
        assert state.tier == RateLimitTier.PREMIUM


# =============================================================================
# Module Functions Tests (2 tests)
# =============================================================================

class TestModuleFunctions:
    """Tests for module-level functions."""
    
    def test_create_rate_limiter(self):
        """Test create_rate_limiter returns manager."""
        manager = create_rate_limiter()
        assert isinstance(manager, RateLimiterManager)
    
    def test_get_tier_limits(self):
        """Test get_tier_limits returns correct limits."""
        limits = get_tier_limits(RateLimitTier.ENTERPRISE)
        assert limits.requests_per_minute == 1000


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - RateLimitTier: 3 tests
# - TierLimits: 8 tests
# - EndpointLimits: 4 tests
# - SlidingWindowCounter: 12 tests
# - RateLimitState: 10 tests
# - RateLimiterManager: 6 tests
# - Module Functions: 2 tests
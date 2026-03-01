/*
 * Security Middleware for Elasticsearch
 *
 * Provides:
 * - Rate limiting (token bucket)
 * - Security headers (OWASP recommended)
 * - Input validation
 * - Health checks
 * 
 * SPDX-License-Identifier: Apache-2.0
 */
package org.elasticsearch.security;

import java.time.Instant;
import java.util.Map;
import java.util.HashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Pattern;

/**
 * Security middleware providing rate limiting, security headers, and input validation.
 */
public class SecurityMiddleware {

    // ========================================================================
    // Rate Limiting
    // ========================================================================

    /**
     * Rate limit configuration
     */
    public static class RateLimitConfig {
        public int requestsPerWindow = 100;
        public int windowSeconds = 60;
        public int burstSize = 20;
        public boolean perIp = true;
        public boolean perUser = true;

        public RateLimitConfig() {}

        public RateLimitConfig(int requestsPerWindow, int windowSeconds, int burstSize) {
            this.requestsPerWindow = requestsPerWindow;
            this.windowSeconds = windowSeconds;
            this.burstSize = burstSize;
        }
    }

    /**
     * Token bucket implementation for rate limiting
     */
    private static class TokenBucket {
        private double tokens;
        private long lastUpdateMs;
        private final double maxTokens;
        private final double refillRate;

        public TokenBucket(double maxTokens, double refillRate) {
            this.tokens = maxTokens;
            this.maxTokens = maxTokens;
            this.refillRate = refillRate;
            this.lastUpdateMs = System.currentTimeMillis();
        }

        private synchronized void refill() {
            long now = System.currentTimeMillis();
            double elapsedSeconds = (now - lastUpdateMs) / 1000.0;
            double tokensToAdd = elapsedSeconds * refillRate;
            tokens = Math.min(maxTokens, tokens + tokensToAdd);
            lastUpdateMs = now;
        }

        public synchronized boolean tryConsume(double count) {
            refill();
            if (tokens >= count) {
                tokens -= count;
                return true;
            }
            return false;
        }

        public synchronized int remaining() {
            refill();
            return (int) tokens;
        }

        public long getLastUpdateMs() {
            return lastUpdateMs;
        }
    }

    /**
     * Result of a rate limit check
     */
    public static class RateLimitResult {
        public final boolean allowed;
        public final int remaining;
        public final int resetSeconds;
        public final Integer retryAfter;

        public RateLimitResult(boolean allowed, int remaining, int resetSeconds, Integer retryAfter) {
            this.allowed = allowed;
            this.remaining = remaining;
            this.resetSeconds = resetSeconds;
            this.retryAfter = retryAfter;
        }
    }

    /**
     * Rate limiter with per-key tracking
     */
    public static class RateLimiter {
        private final RateLimitConfig config;
        private final ConcurrentHashMap<String, TokenBucket> buckets = new ConcurrentHashMap<>();
        private final long cleanupIntervalMs = 300_000; // 5 minutes
        private final AtomicLong lastCleanup = new AtomicLong(System.currentTimeMillis());

        public RateLimiter() {
            this(new RateLimitConfig());
        }

        public RateLimiter(RateLimitConfig config) {
            this.config = config;
        }

        private TokenBucket getBucket(String key) {
            return buckets.computeIfAbsent(key, k -> {
                double maxTokens = config.requestsPerWindow + config.burstSize;
                double refillRate = (double) config.requestsPerWindow / config.windowSeconds;
                return new TokenBucket(maxTokens, refillRate);
            });
        }

        public RateLimitResult checkLimit(String key) {
            maybeCleanup();
            TokenBucket bucket = getBucket(key);

            if (bucket.tryConsume(1)) {
                return new RateLimitResult(true, bucket.remaining(), config.windowSeconds, null);
            } else {
                double refillRate = (double) config.requestsPerWindow / config.windowSeconds;
                int retryAfter = (int) Math.ceil(1.0 / refillRate);
                return new RateLimitResult(false, 0, config.windowSeconds, retryAfter);
            }
        }

        public RateLimitResult checkIpLimit(String ip) {
            if (!config.perIp) {
                return new RateLimitResult(true, 999, 0, null);
            }
            return checkLimit("ip:" + ip);
        }

        public RateLimitResult checkUserLimit(String userId) {
            if (!config.perUser) {
                return new RateLimitResult(true, 999, 0, null);
            }
            return checkLimit("user:" + userId);
        }

        private void maybeCleanup() {
            long now = System.currentTimeMillis();
            long last = lastCleanup.get();
            if (now - last > cleanupIntervalMs && lastCleanup.compareAndSet(last, now)) {
                buckets.entrySet().removeIf(entry ->
                    now - entry.getValue().getLastUpdateMs() > cleanupIntervalMs
                );
            }
        }
    }

    // ========================================================================
    // Security Headers
    // ========================================================================

    /**
     * Security headers configuration
     */
    public static class SecurityHeadersConfig {
        public boolean enableHsts = true;
        public int hstsMaxAge = 31536000;
        public boolean hstsIncludeSubdomains = true;
        public String frameOptions = "DENY";
        public boolean contentTypeNosniff = true;
        public boolean xssProtection = true;
        public String referrerPolicy = "strict-origin-when-cross-origin";
        public boolean cspEnabled = true;
        public String cacheControl = "no-store, no-cache, must-revalidate";
    }

    /**
     * Generate security headers map
     */
    public static Map<String, String> getSecurityHeaders() {
        return getSecurityHeaders(new SecurityHeadersConfig());
    }

    public static Map<String, String> getSecurityHeaders(SecurityHeadersConfig config) {
        Map<String, String> headers = new HashMap<>();

        // HSTS
        if (config.enableHsts) {
            StringBuilder hsts = new StringBuilder("max-age=" + config.hstsMaxAge);
            if (config.hstsIncludeSubdomains) {
                hsts.append("; includeSubDomains");
            }
            headers.put("Strict-Transport-Security", hsts.toString());
        }

        // X-Frame-Options
        if (config.frameOptions != null) {
            headers.put("X-Frame-Options", config.frameOptions);
        }

        // X-Content-Type-Options
        if (config.contentTypeNosniff) {
            headers.put("X-Content-Type-Options", "nosniff");
        }

        // X-XSS-Protection
        if (config.xssProtection) {
            headers.put("X-XSS-Protection", "1; mode=block");
        }

        // Referrer-Policy
        headers.put("Referrer-Policy", config.referrerPolicy);

        // CSP
        if (config.cspEnabled) {
            headers.put("Content-Security-Policy",
                "default-src 'none'; " +
                "script-src 'none'; " +
                "connect-src 'self'; " +
                "frame-ancestors 'none'"
            );
        }

        // Cache-Control
        if (config.cacheControl != null) {
            headers.put("Cache-Control", config.cacheControl);
        }

        // Additional headers
        headers.put("X-DNS-Prefetch-Control", "off");
        headers.put("X-Download-Options", "noopen");
        headers.put("X-Permitted-Cross-Domain-Policies", "none");
        headers.put("Cross-Origin-Embedder-Policy", "require-corp");
        headers.put("Cross-Origin-Opener-Policy", "same-origin");
        headers.put("Cross-Origin-Resource-Policy", "same-origin");

        return headers;
    }

    // ========================================================================
    // Health Checks
    // ========================================================================

    /**
     * Component health status
     */
    public static class ComponentHealth {
        public final String name;
        public final String status; // "healthy", "degraded", "unhealthy"
        public final Long latencyMs;
        public final String message;

        public ComponentHealth(String name, String status, Long latencyMs, String message) {
            this.name = name;
            this.status = status;
            this.latencyMs = latencyMs;
            this.message = message;
        }
    }

    /**
     * Health response
     */
    public static class HealthResponse {
        public final String status;
        public final String version;
        public final double uptimeSeconds;
        public final java.util.List<ComponentHealth> components;

        public HealthResponse(String status, String version, double uptimeSeconds,
                              java.util.List<ComponentHealth> components) {
            this.status = status;
            this.version = version;
            this.uptimeSeconds = uptimeSeconds;
            this.components = components;
        }
    }

    /**
     * Health check interface
     */
    @FunctionalInterface
    public interface HealthChecker {
        ComponentHealth check();
    }

    /**
     * Health service
     */
    public static class HealthService {
        private final String version;
        private final long startTimeMs;
        private final Map<String, HealthChecker> checkers = new HashMap<>();

        public HealthService(String version) {
            this.version = version;
            this.startTimeMs = System.currentTimeMillis();
        }

        public void registerChecker(String name, HealthChecker checker) {
            checkers.put(name, checker);
        }

        public HealthResponse liveness() {
            double uptimeSeconds = (System.currentTimeMillis() - startTimeMs) / 1000.0;
            return new HealthResponse("healthy", version, uptimeSeconds, java.util.Collections.emptyList());
        }

        public HealthResponse readiness() {
            java.util.List<ComponentHealth> components = new java.util.ArrayList<>();
            String overallStatus = "healthy";

            for (Map.Entry<String, HealthChecker> entry : checkers.entrySet()) {
                try {
                    long start = System.currentTimeMillis();
                    ComponentHealth health = entry.getValue().check();
                    ComponentHealth withLatency = new ComponentHealth(
                        health.name, health.status,
                        System.currentTimeMillis() - start,
                        health.message
                    );
                    components.add(withLatency);

                    if ("unhealthy".equals(health.status)) {
                        overallStatus = "unhealthy";
                    } else if ("degraded".equals(health.status) && "healthy".equals(overallStatus)) {
                        overallStatus = "degraded";
                    }
                } catch (Exception e) {
                    components.add(new ComponentHealth(entry.getKey(), "unhealthy", null, e.getMessage()));
                    overallStatus = "unhealthy";
                }
            }

            double uptimeSeconds = (System.currentTimeMillis() - startTimeMs) / 1000.0;
            return new HealthResponse(overallStatus, version, uptimeSeconds, components);
        }
    }

    // ========================================================================
    // Input Validation
    // ========================================================================

    /**
     * Input validation utilities
     */
    public static class InputValidator {
        public static final int MAX_STRING_LENGTH = 10000;

        private static final Pattern EMAIL_PATTERN = Pattern.compile(
            "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"
        );

        private static final Pattern INDEX_NAME_PATTERN = Pattern.compile(
            "^[a-z0-9][a-z0-9_.-]*$"
        );

        public static String sanitizeString(String value, int maxLength) {
            if (value == null) {
                return null;
            }
            // Truncate
            if (value.length() > maxLength) {
                value = value.substring(0, maxLength);
            }
            // Remove null bytes
            value = value.replace("\0", "");
            return value;
        }

        public static String sanitizeString(String value) {
            return sanitizeString(value, MAX_STRING_LENGTH);
        }

        public static boolean validateEmail(String email) {
            if (email == null || email.length() > 254) {
                return false;
            }
            return EMAIL_PATTERN.matcher(email).matches();
        }

        public static boolean validateIndexName(String name) {
            if (name == null || name.isEmpty() || name.length() > 255) {
                return false;
            }
            // Index names must be lowercase
            if (!name.equals(name.toLowerCase())) {
                return false;
            }
            // Cannot start with _, -, or +
            if (name.startsWith("_") || name.startsWith("-") || name.startsWith("+")) {
                return false;
            }
            return INDEX_NAME_PATTERN.matcher(name).matches();
        }

        public static String escapeHtml(String value) {
            if (value == null) {
                return null;
            }
            return value
                .replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&#x27;");
        }

        public static boolean validateQueryString(String query) {
            if (query == null) {
                return true; // null is valid (no query)
            }
            // Basic validation - prevent obvious injection
            String[] forbidden = {"<script>", "javascript:", "data:", "vbscript:"};
            String lower = query.toLowerCase();
            for (String f : forbidden) {
                if (lower.contains(f)) {
                    return false;
                }
            }
            return query.length() <= MAX_STRING_LENGTH;
        }
    }

    // ========================================================================
    // Tests
    // ========================================================================

    public static void main(String[] args) {
        System.out.println("Running security middleware tests...");

        // Test rate limiter
        RateLimiter limiter = new RateLimiter(new RateLimitConfig(5, 60, 0));
        for (int i = 0; i < 5; i++) {
            RateLimitResult result = limiter.checkLimit("test");
            assert result.allowed : "Request " + (i + 1) + " should be allowed";
        }
        RateLimitResult blocked = limiter.checkLimit("test");
        assert !blocked.allowed : "6th request should be blocked";
        System.out.println("✓ Rate limiter tests passed");

        // Test security headers
        Map<String, String> headers = getSecurityHeaders();
        assert "DENY".equals(headers.get("X-Frame-Options"));
        assert "nosniff".equals(headers.get("X-Content-Type-Options"));
        assert headers.containsKey("Strict-Transport-Security");
        System.out.println("✓ Security headers tests passed");

        // Test health service
        HealthService health = new HealthService("2.0.0");
        HealthResponse liveness = health.liveness();
        assert "healthy".equals(liveness.status);
        assert "2.0.0".equals(liveness.version);
        System.out.println("✓ Health service tests passed");

        // Test input validator
        assert InputValidator.validateEmail("test@example.com");
        assert !InputValidator.validateEmail("invalid");
        assert InputValidator.validateIndexName("valid_index");
        assert !InputValidator.validateIndexName("Invalid_Index"); // uppercase
        assert !InputValidator.validateIndexName("_internal"); // starts with _
        System.out.println("✓ Input validator tests passed");

        System.out.println("\nAll tests passed! ✅");
    }
}
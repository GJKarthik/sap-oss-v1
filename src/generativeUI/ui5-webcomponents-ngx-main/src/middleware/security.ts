/**
 * Security Middleware for UI5 Web Components Angular
 *
 * Provides:
 * - Rate limiting (token bucket)
 * - Security headers (OWASP recommended)
 * - Input validation
 * - Health checks
 */

// ============================================================================
// Rate Limiting
// ============================================================================

export interface RateLimitConfig {
  requestsPerWindow: number;
  windowSeconds: number;
  burstSize: number;
  perIp: boolean;
  perUser: boolean;
}

const defaultRateLimitConfig: RateLimitConfig = {
  requestsPerWindow: 100,
  windowSeconds: 60,
  burstSize: 20,
  perIp: true,
  perUser: true,
};

class TokenBucket {
  private tokens: number;
  private lastUpdate: number;
  private readonly maxTokens: number;
  private readonly refillRate: number;

  constructor(maxTokens: number, refillRate: number) {
    this.tokens = maxTokens;
    this.maxTokens = maxTokens;
    this.refillRate = refillRate;
    this.lastUpdate = Date.now();
  }

  private refill(): void {
    const now = Date.now();
    const elapsed = (now - this.lastUpdate) / 1000;
    const tokensToAdd = elapsed * this.refillRate;
    this.tokens = Math.min(this.maxTokens, this.tokens + tokensToAdd);
    this.lastUpdate = now;
  }

  tryConsume(count: number = 1): boolean {
    this.refill();
    if (this.tokens >= count) {
      this.tokens -= count;
      return true;
    }
    return false;
  }

  remaining(): number {
    this.refill();
    return Math.floor(this.tokens);
  }
}

export interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  resetSeconds: number;
  retryAfter?: number;
}

export class RateLimiter {
  private config: RateLimitConfig;
  private buckets: Map<string, TokenBucket> = new Map();
  private cleanupInterval: number = 300000; // 5 minutes
  private lastCleanup: number = Date.now();

  constructor(config: Partial<RateLimitConfig> = {}) {
    this.config = { ...defaultRateLimitConfig, ...config };
  }

  private getBucket(key: string): TokenBucket {
    if (!this.buckets.has(key)) {
      const maxTokens = this.config.requestsPerWindow + this.config.burstSize;
      const refillRate = this.config.requestsPerWindow / this.config.windowSeconds;
      this.buckets.set(key, new TokenBucket(maxTokens, refillRate));
    }
    return this.buckets.get(key)!;
  }

  checkLimit(key: string): RateLimitResult {
    this.maybeCleanup();
    const bucket = this.getBucket(key);

    if (bucket.tryConsume(1)) {
      return {
        allowed: true,
        remaining: bucket.remaining(),
        resetSeconds: this.config.windowSeconds,
      };
    } else {
      const refillRate = this.config.requestsPerWindow / this.config.windowSeconds;
      return {
        allowed: false,
        remaining: 0,
        resetSeconds: this.config.windowSeconds,
        retryAfter: Math.ceil(1 / refillRate),
      };
    }
  }

  checkIpLimit(ip: string): RateLimitResult {
    if (!this.config.perIp) {
      return { allowed: true, remaining: 999, resetSeconds: 0 };
    }
    return this.checkLimit(`ip:${ip}`);
  }

  checkUserLimit(userId: string): RateLimitResult {
    if (!this.config.perUser) {
      return { allowed: true, remaining: 999, resetSeconds: 0 };
    }
    return this.checkLimit(`user:${userId}`);
  }

  private maybeCleanup(): void {
    const now = Date.now();
    if (now - this.lastCleanup > this.cleanupInterval) {
      // Simple cleanup: just clear old entries
      if (this.buckets.size > 10000) {
        this.buckets.clear();
      }
      this.lastCleanup = now;
    }
  }
}

// ============================================================================
// Security Headers
// ============================================================================

export interface SecurityHeadersConfig {
  enableHsts: boolean;
  hstsMaxAge: number;
  hstsIncludeSubdomains: boolean;
  frameOptions: 'DENY' | 'SAMEORIGIN' | null;
  contentTypeNosniff: boolean;
  xssProtection: boolean;
  referrerPolicy: string;
  cspEnabled: boolean;
  cacheControl: string | null;
}

const defaultSecurityHeadersConfig: SecurityHeadersConfig = {
  enableHsts: true,
  hstsMaxAge: 31536000,
  hstsIncludeSubdomains: true,
  frameOptions: 'DENY',
  contentTypeNosniff: true,
  xssProtection: true,
  referrerPolicy: 'strict-origin-when-cross-origin',
  cspEnabled: true,
  cacheControl: 'no-store, no-cache, must-revalidate',
};

export function getSecurityHeaders(
  config: Partial<SecurityHeadersConfig> = {}
): Record<string, string> {
  const cfg = { ...defaultSecurityHeadersConfig, ...config };
  const headers: Record<string, string> = {};

  // HSTS
  if (cfg.enableHsts) {
    let hsts = `max-age=${cfg.hstsMaxAge}`;
    if (cfg.hstsIncludeSubdomains) {
      hsts += '; includeSubDomains';
    }
    headers['Strict-Transport-Security'] = hsts;
  }

  // X-Frame-Options
  if (cfg.frameOptions) {
    headers['X-Frame-Options'] = cfg.frameOptions;
  }

  // X-Content-Type-Options
  if (cfg.contentTypeNosniff) {
    headers['X-Content-Type-Options'] = 'nosniff';
  }

  // X-XSS-Protection
  if (cfg.xssProtection) {
    headers['X-XSS-Protection'] = '1; mode=block';
  }

  // Referrer-Policy
  headers['Referrer-Policy'] = cfg.referrerPolicy;

  // CSP
  if (cfg.cspEnabled) {
    headers['Content-Security-Policy'] = [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline'", // Angular requires unsafe-inline
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "font-src 'self'",
      "connect-src 'self'",
      "frame-ancestors 'none'",
    ].join('; ');
  }

  // Cache-Control
  if (cfg.cacheControl) {
    headers['Cache-Control'] = cfg.cacheControl;
  }

  // Additional headers
  headers['X-DNS-Prefetch-Control'] = 'off';
  headers['X-Download-Options'] = 'noopen';
  headers['X-Permitted-Cross-Domain-Policies'] = 'none';
  headers['Cross-Origin-Embedder-Policy'] = 'require-corp';
  headers['Cross-Origin-Opener-Policy'] = 'same-origin';
  headers['Cross-Origin-Resource-Policy'] = 'same-origin';

  return headers;
}

// ============================================================================
// Health Checks
// ============================================================================

export interface ComponentHealth {
  name: string;
  status: 'healthy' | 'degraded' | 'unhealthy';
  latencyMs?: number;
  message?: string;
}

export interface HealthResponse {
  status: 'healthy' | 'degraded' | 'unhealthy';
  version: string;
  uptimeSeconds: number;
  components: ComponentHealth[];
}

export type HealthChecker = () => Promise<ComponentHealth>;

export class HealthService {
  private version: string;
  private startTime: number;
  private checkers: Map<string, HealthChecker> = new Map();

  constructor(version: string = '1.0.0') {
    this.version = version;
    this.startTime = Date.now();
  }

  registerChecker(name: string, checker: HealthChecker): void {
    this.checkers.set(name, checker);
  }

  liveness(): HealthResponse {
    return {
      status: 'healthy',
      version: this.version,
      uptimeSeconds: (Date.now() - this.startTime) / 1000,
      components: [],
    };
  }

  async readiness(): Promise<HealthResponse> {
    const components: ComponentHealth[] = [];
    let overallStatus: 'healthy' | 'degraded' | 'unhealthy' = 'healthy';

    for (const [name, checker] of this.checkers) {
      try {
        const start = Date.now();
        const health = await checker();
        health.latencyMs = Date.now() - start;
        components.push(health);

        if (health.status === 'unhealthy') {
          overallStatus = 'unhealthy';
        } else if (health.status === 'degraded' && overallStatus === 'healthy') {
          overallStatus = 'degraded';
        }
      } catch (error) {
        components.push({
          name,
          status: 'unhealthy',
          message: error instanceof Error ? error.message : String(error),
        });
        overallStatus = 'unhealthy';
      }
    }

    return {
      status: overallStatus,
      version: this.version,
      uptimeSeconds: (Date.now() - this.startTime) / 1000,
      components,
    };
  }
}

// ============================================================================
// Input Validation
// ============================================================================

export class InputValidator {
  static readonly MAX_STRING_LENGTH = 10000;

  static sanitizeString(value: string, maxLength: number = InputValidator.MAX_STRING_LENGTH): string {
    if (typeof value !== 'string') {
      throw new Error('Expected string input');
    }
    // Truncate
    value = value.slice(0, maxLength);
    // Remove null bytes
    value = value.replace(/\0/g, '');
    return value;
  }

  static validateEmail(email: string): boolean {
    const pattern = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
    return pattern.test(email) && email.length <= 254;
  }

  static validateUrl(url: string): boolean {
    try {
      const parsed = new URL(url);
      return ['http:', 'https:'].includes(parsed.protocol);
    } catch {
      return false;
    }
  }

  static escapeHtml(value: string): string {
    return value
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#x27;');
  }

  static validateComponentId(id: string): boolean {
    // Angular component IDs should be alphanumeric with hyphens
    const pattern = /^[a-zA-Z][a-zA-Z0-9-]*$/;
    return pattern.test(id) && id.length <= 128;
  }
}

// ============================================================================
// Angular HTTP Interceptor Helper
// ============================================================================

export function createSecurityInterceptor(config?: Partial<SecurityHeadersConfig>) {
  const headers = getSecurityHeaders(config);
  
  return {
    intercept(request: any, next: any) {
      // Clone request with security headers
      const secureRequest = request.clone({
        setHeaders: headers,
      });
      return next.handle(secureRequest);
    },
  };
}

// ============================================================================
// Exports for Angular Module
// ============================================================================

export const SECURITY_PROVIDERS = {
  rateLimiter: new RateLimiter(),
  healthService: new HealthService(),
};

// ============================================================================
// Tests
// ============================================================================

export function runSecurityTests(): void {
  console.log('Running security middleware tests...');

  // Test rate limiter
  const limiter = new RateLimiter({ requestsPerWindow: 5, windowSeconds: 60, burstSize: 0 });
  for (let i = 0; i < 5; i++) {
    const result = limiter.checkLimit('test');
    if (!result.allowed) throw new Error(`Request ${i + 1} should be allowed`);
  }
  const blocked = limiter.checkLimit('test');
  if (blocked.allowed) throw new Error('6th request should be blocked');
  console.log('✓ Rate limiter tests passed');

  // Test security headers
  const headers = getSecurityHeaders();
  if (headers['X-Frame-Options'] !== 'DENY') throw new Error('X-Frame-Options should be DENY');
  if (headers['X-Content-Type-Options'] !== 'nosniff') throw new Error('X-Content-Type-Options should be nosniff');
  console.log('✓ Security headers tests passed');

  // Test health service
  const health = new HealthService('2.0.0');
  const liveness = health.liveness();
  if (liveness.status !== 'healthy') throw new Error('Liveness should be healthy');
  if (liveness.version !== '2.0.0') throw new Error('Version should be 2.0.0');
  console.log('✓ Health service tests passed');

  // Test input validator
  if (!InputValidator.validateEmail('test@example.com')) throw new Error('Should validate email');
  if (InputValidator.validateEmail('invalid')) throw new Error('Should reject invalid email');
  if (!InputValidator.validateComponentId('my-component')) throw new Error('Should validate component ID');
  console.log('✓ Input validator tests passed');

  console.log('\nAll tests passed! ✅');
}

// To run tests, call runSecurityTests() from a test file or console

/**
 * SAP SAC Rest API automation HTTP Client
 *
 * Provides typed HTTP transport to the nUniversalPrompt-zig backend.
 * Handles authentication, retries, error normalisation, and event callbacks.
 */

// ---------------------------------------------------------------------------
// Config & error types
// ---------------------------------------------------------------------------

export interface ClientConfig {
  serverUrl: string;
  apiBasePath?: string;
  apiVersion?: string;
  timeout?: number;
  maxRetries?: number;
  retryDelay?: number;
  headers?: Record<string, string>;
  getAuthToken?: () => string | null | undefined;
  onError?: (error: SACError) => void;
  onTelemetry?: (data: TelemetryData) => void;
}

export interface TelemetryData {
  endpoint: string;
  method: string;
  status: number;
  durationMs: number;
  attempts: number;
  success: boolean;
  errorCode?: string;
}

export class SACError extends Error {
// ... existing SACError class ...
  constructor(
    message: string,
    public readonly statusCode: number,
    public readonly errorCode?: string,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = 'SACError';
  }
}

export interface ApiResponse<T> {
  success: boolean;
  data?: T;
  error?: string;
  errorCode?: string;
}

// ---------------------------------------------------------------------------
// Event system
// ---------------------------------------------------------------------------

export type EventHandler<T = unknown> = (payload: T) => void;

export class EventEmitter {
  private listeners = new Map<string, Set<EventHandler>>();

  on<T = unknown>(event: string, handler: EventHandler<T>): () => void {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    const set = this.listeners.get(event)!;
    set.add(handler as EventHandler);
    return () => set.delete(handler as EventHandler);
  }

  off<T = unknown>(event: string, handler: EventHandler<T>): void {
    this.listeners.get(event)?.delete(handler as EventHandler);
  }

  emit<T = unknown>(event: string, payload: T): void {
    this.listeners.get(event)?.forEach((h) => h(payload));
  }

  removeAll(event?: string): void {
    if (event) this.listeners.delete(event);
    else this.listeners.clear();
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export class SACRestAPIClient extends EventEmitter {
  private readonly cfg: Required<
    Pick<ClientConfig, 'serverUrl' | 'apiBasePath' | 'apiVersion' | 'timeout' | 'maxRetries' | 'retryDelay'>
  > & {
    headers: Record<string, string>;
    getAuthToken?: () => string | null | undefined;
    onError?: (e: SACError) => void;
    onTelemetry?: (data: TelemetryData) => void;
  };

  constructor(config: ClientConfig) {
    super();
    const { serverUrl, ...rest } = config;
    const normalised = serverUrl.replace(/\/+$/, '');
    this.cfg = {
      serverUrl: normalised,
      apiBasePath: this.normaliseApiBasePath(rest.apiBasePath ?? '/api/v1/sac'),
      apiVersion: rest.apiVersion ?? '2025.19',
      timeout: rest.timeout ?? 30_000,
      maxRetries: rest.maxRetries ?? 2,
      retryDelay: rest.retryDelay ?? 500,
      headers: rest.headers ?? {},
      getAuthToken: rest.getAuthToken,
      onError: rest.onError,
      onTelemetry: rest.onTelemetry,
    };
  }

  get baseUrl(): string {
    return `${this.cfg.serverUrl}${this.cfg.apiBasePath}`;
  }

  get serverUrl(): string {
    return this.cfg.serverUrl;
  }

  get apiVersion(): string {
    return this.cfg.apiVersion;
  }

  setAuthToken(token: string | null | undefined): void {
    if (token?.trim()) {
      this.cfg.headers['Authorization'] = `Bearer ${token.trim()}`;
      return;
    }

    delete this.cfg.headers['Authorization'];
  }

  clearAuthToken(): void {
    delete this.cfg.headers['Authorization'];
  }

  setHeader(name: string, value: string | null | undefined): void {
    if (value == null || value === '') {
      delete this.cfg.headers[name];
      return;
    }

    this.cfg.headers[name] = value;
  }

  // -- Core request ---------------------------------------------------------

  async request<T>(endpoint: string, options?: RequestInit): Promise<T> {
    const url = this.resolveUrl(endpoint);
    let lastError: SACError | undefined;
    const startTime = Date.now();
    let attempts = 0;

    for (let attempt = 0; attempt <= this.cfg.maxRetries; attempt++) {
      attempts++;
      if (attempt > 0) {
        await this.delay(this.cfg.retryDelay * attempt);
      }

      const controller = new AbortController();
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        controller.abort();
      }, this.cfg.timeout);
      const method = options?.method ?? 'GET';

      try {
        const res = await fetch(url, {
          ...options,
          signal: controller.signal,
          headers: this.resolveHeaders(options?.headers),
        });

        clearTimeout(timer);

        if (!res.ok) {
          throw await this.parseErrorResponse(res);
        }

        const data = await this.parseSuccessResponse<T>(res, method);
        
        // Emit telemetry on success
        this.emitTelemetry({
          endpoint,
          method,
          status: res.status,
          durationMs: Date.now() - startTime,
          attempts,
          success: true
        });

        return data;
      } catch (err) {
        clearTimeout(timer);
        if (err instanceof SACError) {
          lastError = err;
          if (!this.shouldRetry(err, attempt)) break;
        } else {
          lastError = this.normaliseTransportError(err, timedOut);
        }
      }
    }

    if (lastError) {
      // Emit telemetry on failure
      this.emitTelemetry({
        endpoint,
        method: options?.method ?? 'GET',
        status: lastError.statusCode,
        durationMs: Date.now() - startTime,
        attempts,
        success: false,
        errorCode: lastError.errorCode
      });

      this.cfg.onError?.(lastError);
      this.emit('error', lastError);
    }
    throw lastError ?? new SACError('Request failed', 0);
  }

  private emitTelemetry(data: TelemetryData): void {
    this.cfg.onTelemetry?.(data);
    this.emit('telemetry', data);
  }

  // -- Convenience verbs ----------------------------------------------------

  async get<T>(endpoint: string): Promise<T> {
    return this.request<T>(endpoint, { method: 'GET' });
  }

  async post<T>(endpoint: string, body?: unknown): Promise<T> {
    return this.request<T>(endpoint, {
      method: 'POST',
      body: body != null ? JSON.stringify(body) : undefined,
      headers: body != null ? { 'Content-Type': 'application/json' } : undefined,
    });
  }

  async put<T>(endpoint: string, body?: unknown): Promise<T> {
    return this.request<T>(endpoint, {
      method: 'PUT',
      body: body != null ? JSON.stringify(body) : undefined,
      headers: body != null ? { 'Content-Type': 'application/json' } : undefined,
    });
  }

  async del<T>(endpoint: string): Promise<T> {
    return this.request<T>(endpoint, { method: 'DELETE' });
  }

  // -- Health ---------------------------------------------------------------

  async health(): Promise<{ status: string; service: string; version: string }> {
    return this.request<{ status: string; service: string; version: string }>(
      `${this.cfg.serverUrl}/health`,
      { method: 'GET' },
    );
  }

  // -- Internals ------------------------------------------------------------

  private delay(ms: number): Promise<void> {
    return new Promise((r) => setTimeout(r, ms));
  }

  private normaliseApiBasePath(path: string): string {
    const trimmed = path.trim();
    if (!trimmed) {
      return '';
    }

    const prefixed = trimmed.startsWith('/') ? trimmed : `/${trimmed}`;
    return prefixed.replace(/\/+$/, '');
  }

  private resolveUrl(endpoint: string): string {
    if (/^https?:\/\//i.test(endpoint)) {
      return endpoint;
    }

    if (endpoint.startsWith('/api/')) {
      return `${this.cfg.serverUrl}${endpoint}`;
    }

    const path = endpoint.startsWith('/') ? endpoint : `/${endpoint}`;
    return `${this.baseUrl}${path}`;
  }

  private resolveHeaders(headers?: HeadersInit): Headers {
    const resolved = new Headers();

    resolved.set('X-SAC-API-Version', this.cfg.apiVersion);

    for (const [name, value] of Object.entries(this.cfg.headers)) {
      resolved.set(name, value);
    }

    const authToken = this.cfg.getAuthToken?.()?.trim();
    if (authToken) {
      resolved.set('Authorization', `Bearer ${authToken}`);
    }

    if (headers instanceof Headers) {
      headers.forEach((value, name) => resolved.set(name, value));
      return resolved;
    }

    if (Array.isArray(headers)) {
      for (const [name, value] of headers) {
        resolved.set(name, value);
      }
      return resolved;
    }

    for (const [name, value] of Object.entries(headers ?? {})) {
      if (value != null) {
        resolved.set(name, value);
      }
    }

    return resolved;
  }

  private async parseSuccessResponse<T>(response: Response, method: string): Promise<T> {
    if (method.toUpperCase() === 'HEAD' || [204, 205, 304].includes(response.status)) {
      return undefined as T;
    }

    if (response.headers.get('content-length') === '0') {
      return undefined as T;
    }

    const contentType = (response.headers.get('content-type') ?? '').toLowerCase();

    if (this.isBinaryContentType(contentType)) {
      return await response.blob() as T;
    }

    const text = await response.text();
    if (!text) {
      return undefined as T;
    }

    if (contentType.includes('json') || contentType.includes('+json')) {
      return JSON.parse(text) as T;
    }

    try {
      return JSON.parse(text) as T;
    } catch {
      return text as T;
    }
  }

  private async parseErrorResponse(response: Response): Promise<SACError> {
    const contentType = (response.headers.get('content-type') ?? '').toLowerCase();
    const text = await response.text();
    let parsed: { error?: string; errorCode?: string; details?: unknown; message?: string } = {};

    if (text && (contentType.includes('json') || contentType.includes('+json'))) {
      try {
        parsed = JSON.parse(text) as typeof parsed;
      } catch {
        parsed = {};
      }
    }

    return new SACError(
      (parsed.error ?? parsed.message ?? text) || `HTTP ${response.status}`,
      response.status,
      parsed.errorCode,
      parsed.details ?? text,
    );
  }

  private shouldRetry(error: SACError, attempt: number): boolean {
    if (attempt >= this.cfg.maxRetries) {
      return false;
    }

    return (
      error.statusCode === 0
      || error.statusCode === 408
      || error.statusCode === 429
      || error.statusCode >= 500
    );
  }

  private normaliseTransportError(error: unknown, timedOut: boolean): SACError {
    if (error instanceof SACError) {
      return error;
    }

    if (error instanceof Error && error.name === 'AbortError') {
      return new SACError(
        timedOut ? 'Request timed out' : 'Request was aborted',
        0,
        timedOut ? 'REQUEST_TIMEOUT' : 'REQUEST_ABORTED',
      );
    }

    return new SACError(
      (error as Error)?.message ?? 'Network error',
      0,
      'NETWORK_ERROR',
    );
  }

  private isBinaryContentType(contentType: string): boolean {
    return (
      contentType.startsWith('application/octet-stream')
      || contentType.startsWith('image/')
      || contentType.startsWith('audio/')
      || contentType.startsWith('video/')
      || contentType.startsWith('application/pdf')
    );
  }
}

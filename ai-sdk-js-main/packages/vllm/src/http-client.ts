/**
 * HTTP client for vLLM API communication.
 */

import {
  VllmConnectionError,
  VllmTimeoutError,
  VllmServerError,
  VllmRateLimitError,
  VllmInvalidRequestError,
  VllmModelNotFoundError,
  VllmAuthenticationError,
} from './errors.js';

/**
 * HTTP client configuration.
 */
export interface HttpClientConfig {
  /**
   * Base URL for API requests.
   */
  baseURL: string;

  /**
   * Request timeout in milliseconds.
   */
  timeout: number;

  /**
   * Default headers for all requests.
   */
  headers: Record<string, string>;

  /**
   * Enable debug logging.
   */
  debug: boolean;
}

/**
 * HTTP request options.
 */
export interface HttpRequestOptions {
  /**
   * HTTP method.
   */
  method: 'GET' | 'POST' | 'PUT' | 'DELETE';

  /**
   * Request path (appended to baseURL).
   */
  path: string;

  /**
   * Request body (will be JSON serialized).
   */
  body?: unknown;

  /**
   * Additional headers for this request.
   */
  headers?: Record<string, string>;

  /**
   * Override timeout for this request.
   */
  timeout?: number;

  /**
   * AbortController signal.
   */
  signal?: AbortSignal;
}

/**
 * HTTP response wrapper.
 */
export interface HttpResponse<T> {
  /**
   * Response status code.
   */
  status: number;

  /**
   * Response headers.
   */
  headers: Record<string, string>;

  /**
   * Parsed response body.
   */
  data: T;

  /**
   * Request duration in milliseconds.
   */
  duration: number;
}

/**
 * HTTP client for making requests to vLLM server.
 */
export class HttpClient {
  private readonly config: HttpClientConfig;

  constructor(config: HttpClientConfig) {
    this.config = config;
  }

  /**
   * Makes an HTTP request and returns parsed JSON response.
   */
  async request<T>(options: HttpRequestOptions): Promise<HttpResponse<T>> {
    const url = `${this.config.baseURL}${options.path}`;
    const timeout = options.timeout ?? this.config.timeout;
    const startTime = Date.now();

    // Create abort controller for timeout
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), timeout);

    // Combine signals if provided
    const signal = options.signal
      ? this.combineSignals(options.signal, controller.signal)
      : controller.signal;

    try {
      this.log('request', { method: options.method, url, body: options.body });

      const response = await fetch(url, {
        method: options.method,
        headers: {
          ...this.config.headers,
          ...options.headers,
        },
        body: options.body ? JSON.stringify(options.body) : undefined,
        signal,
      });

      clearTimeout(timeoutId);

      const duration = Date.now() - startTime;

      // Parse response headers
      const headers: Record<string, string> = {};
      response.headers.forEach((value, key) => {
        headers[key.toLowerCase()] = value;
      });

      // Handle error responses
      if (!response.ok) {
        const errorBody = await this.parseErrorBody(response);
        this.handleErrorResponse(response.status, errorBody, headers);
      }

      // Parse response body
      const data = (await response.json()) as T;

      this.log('response', { status: response.status, duration, data });

      return {
        status: response.status,
        headers,
        data,
        duration,
      };
    } catch (error) {
      clearTimeout(timeoutId);

      // Handle abort/timeout
      if (error instanceof Error && error.name === 'AbortError') {
        throw new VllmTimeoutError(timeout);
      }

      // Handle network errors
      if (error instanceof TypeError && error.message.includes('fetch')) {
        throw new VllmConnectionError(
          `Failed to connect to ${url}: ${error.message}`,
          error
        );
      }

      // Re-throw vLLM errors
      if (
        error instanceof VllmConnectionError ||
        error instanceof VllmTimeoutError ||
        error instanceof VllmServerError
      ) {
        throw error;
      }

      // Wrap unknown errors
      throw new VllmConnectionError(
        `Request failed: ${error instanceof Error ? error.message : String(error)}`,
        error instanceof Error ? error : undefined
      );
    }
  }

  /**
   * Makes a GET request.
   */
  async get<T>(path: string, options?: Partial<HttpRequestOptions>): Promise<HttpResponse<T>> {
    return this.request<T>({ method: 'GET', path, ...options });
  }

  /**
   * Makes a POST request.
   */
  async post<T>(
    path: string,
    body?: unknown,
    options?: Partial<HttpRequestOptions>
  ): Promise<HttpResponse<T>> {
    return this.request<T>({ method: 'POST', path, body, ...options });
  }

  /**
   * Makes a streaming POST request and returns a ReadableStream.
   */
  async postStream(
    path: string,
    body?: unknown,
    options?: Partial<HttpRequestOptions>
  ): Promise<ReadableStream<Uint8Array>> {
    const url = `${this.config.baseURL}${path}`;
    const timeout = options?.timeout ?? this.config.timeout;

    // Create abort controller for timeout
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), timeout);

    // Combine signals if provided
    const signal = options?.signal
      ? this.combineSignals(options.signal, controller.signal)
      : controller.signal;

    try {
      this.log('stream-request', { url, body });

      const response = await fetch(url, {
        method: 'POST',
        headers: {
          ...this.config.headers,
          ...options?.headers,
        },
        body: body ? JSON.stringify(body) : undefined,
        signal,
      });

      clearTimeout(timeoutId);

      // Handle error responses
      if (!response.ok) {
        const headers: Record<string, string> = {};
        response.headers.forEach((value, key) => {
          headers[key.toLowerCase()] = value;
        });
        const errorBody = await this.parseErrorBody(response);
        this.handleErrorResponse(response.status, errorBody, headers);
      }

      if (!response.body) {
        throw new VllmConnectionError('Response body is null');
      }

      return response.body;
    } catch (error) {
      clearTimeout(timeoutId);

      // Handle abort/timeout
      if (error instanceof Error && error.name === 'AbortError') {
        throw new VllmTimeoutError(timeout);
      }

      // Re-throw vLLM errors
      if (
        error instanceof VllmConnectionError ||
        error instanceof VllmTimeoutError ||
        error instanceof VllmServerError
      ) {
        throw error;
      }

      throw new VllmConnectionError(
        `Stream request failed: ${error instanceof Error ? error.message : String(error)}`,
        error instanceof Error ? error : undefined
      );
    }
  }

  /**
   * Combines multiple AbortSignals into one.
   */
  private combineSignals(...signals: AbortSignal[]): AbortSignal {
    const controller = new AbortController();

    for (const signal of signals) {
      if (signal.aborted) {
        controller.abort();
        break;
      }

      signal.addEventListener('abort', () => controller.abort(), { once: true });
    }

    return controller.signal;
  }

  /**
   * Parses error response body.
   */
  private async parseErrorBody(response: Response): Promise<{ error?: { message?: string; type?: string } }> {
    try {
      return await response.json();
    } catch {
      return {};
    }
  }

  /**
   * Handles error responses by throwing appropriate error classes.
   */
  private handleErrorResponse(
    status: number,
    body: { error?: { message?: string; type?: string } },
    headers: Record<string, string>
  ): never {
    const message = body.error?.message ?? `HTTP error ${status}`;

    switch (status) {
      case 400:
        throw new VllmInvalidRequestError(message, body);
      case 401:
      case 403:
        throw new VllmAuthenticationError(message);
      case 404:
        throw new VllmModelNotFoundError(message);
      case 429: {
        const retryAfter = headers['retry-after']
          ? parseInt(headers['retry-after'], 10)
          : undefined;
        throw new VllmRateLimitError(message, retryAfter);
      }
      default:
        if (status >= 500) {
          throw new VllmServerError(message, status);
        }
        throw new VllmServerError(message, status);
    }
  }

  /**
   * Logs debug messages.
   */
  private log(event: string, data: unknown): void {
    if (this.config.debug) {
      const timestamp = new Date().toISOString();
      // eslint-disable-next-line no-console
      console.log(`[HttpClient ${timestamp}] ${event}:`, data);
    }
  }
}
import { afterEach, describe, expect, it, vi } from 'vitest';

import { SACError, SACRestAPIClient } from '../libs/sac-sdk/client';

describe('SACRestAPIClient', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('returns undefined for no-content responses', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);

    const client = new SACRestAPIClient({ serverUrl: 'https://tenant.example' });

    const result = await client.del<void>('/datasource/Sales/filters');

    expect(result).toBeUndefined();
    expect(fetchMock).toHaveBeenCalledWith(
      'https://tenant.example/api/v1/sac/datasource/Sales/filters',
      expect.objectContaining({ method: 'DELETE' }),
    );
  });

  it('returns plain-text success bodies without forcing json parsing', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('ok', {
        status: 200,
        headers: { 'Content-Type': 'text/plain' },
      }),
    );
    vi.stubGlobal('fetch', fetchMock);

    const client = new SACRestAPIClient({ serverUrl: 'https://tenant.example' });

    await expect(client.get<string>('/healthz')).resolves.toBe('ok');
  });

  it('uses the dynamic auth token provider and preserves absolute api paths', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );
    vi.stubGlobal('fetch', fetchMock);

    const client = new SACRestAPIClient({
      serverUrl: 'https://tenant.example/',
      getAuthToken: () => 'secret-token',
    });

    await client.get<{ ok: boolean }>('/api/v1/planning/models/model-1/versions');

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const headers = new Headers(init.headers);

    expect(url).toBe('https://tenant.example/api/v1/planning/models/model-1/versions');
    expect(headers.get('Authorization')).toBe('Bearer secret-token');
    expect(headers.get('X-SAC-API-Version')).toBe('2025.19');
  });

  it('retries transient failures and emits success telemetry for the final attempt', async () => {
    const onTelemetry = vi.fn();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ error: 'temporary' }), {
          status: 503,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      );
    vi.stubGlobal('fetch', fetchMock);

    const client = new SACRestAPIClient({
      serverUrl: 'https://tenant.example',
      maxRetries: 1,
      retryDelay: 0,
      onTelemetry,
    });

    await expect(client.get<{ ok: boolean }>('/retry-me')).resolves.toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(onTelemetry).toHaveBeenLastCalledWith(
      expect.objectContaining({
        endpoint: '/retry-me',
        attempts: 2,
        success: true,
        status: 200,
      }),
    );
  });

  it('raises a typed error for failed responses after retries are exhausted', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: 'boom', errorCode: 'E_BROKEN' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    );
    vi.stubGlobal('fetch', fetchMock);

    const client = new SACRestAPIClient({
      serverUrl: 'https://tenant.example',
      maxRetries: 0,
    });

    await expect(client.get('/broken')).rejects.toEqual(
      expect.objectContaining<SACError>({
        name: 'SACError',
        message: 'boom',
        statusCode: 500,
        errorCode: 'E_BROKEN',
      }),
    );
  });
});

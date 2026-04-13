import { measureLatency, safeError } from '../common.mjs';

const ROUTES = ['/', '/generative', '/components', '/mcp', '/readiness', '/joule'];

async function checkRoute(route) {
  const startMs = Date.now();
  const url = route === '/' ? 'http://localhost:4200/' : `http://localhost:4200/#${route}`;
  try {
    const response = await fetch(url, { method: 'GET', signal: AbortSignal.timeout(5000) });
    return {
      route,
      ok: response.ok,
      status: response.status,
      latencyMs: measureLatency(startMs),
      lastError: response.ok ? null : `HTTP ${response.status}`,
    };
  } catch (error) {
    return {
      route,
      ok: false,
      status: 0,
      latencyMs: measureLatency(startMs),
      lastError: safeError(error),
    };
  }
}

export async function runRoutesCheck({ policy }) {
  const routes = await Promise.all(ROUTES.map(checkRoute));
  const failed = routes.filter((item) => !item.ok);
  return {
    name: 'routes-check',
    required: policy.strictRealBackends,
    status: failed.length === 0 ? 'pass' : 'fail',
    code: failed.length === 0 ? null : 'UI_ROUTE_BLOCKED',
    message: failed.length === 0 ? 'All required routes are reachable' : `${failed.length} routes failed`,
    evidence: { routes },
    remediation:
      failed.length === 0
        ? null
        : `Ensure dev server is running on :4200. Failed: ${failed.map((r) => r.route).join(', ')}`,
  };
}

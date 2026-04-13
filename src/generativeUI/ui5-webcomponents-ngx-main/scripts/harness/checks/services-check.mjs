import { measureLatency, safeError } from '../common.mjs';

const defaults = {
  AG_UI_URL: 'http://localhost:9160/health',
  OPENAI_URL: 'http://localhost:8400/health',
  MCP_URL: 'http://localhost:9160/health',
  MCP_RPC_URL: 'http://localhost:9160/mcp',
};

function env(name) {
  return process.env[name] || defaults[name];
}

async function checkHealth(name, url) {
  const startMs = Date.now();
  try {
    const response = await fetch(url, { method: 'GET', signal: AbortSignal.timeout(5000) });
    return {
      name,
      url,
      ok: response.ok,
      status: response.status,
      latencyMs: measureLatency(startMs),
      lastError: response.ok ? null : `HTTP ${response.status}`,
    };
  } catch (error) {
    return {
      name,
      url,
      ok: false,
      status: 0,
      latencyMs: measureLatency(startMs),
      lastError: safeError(error),
    };
  }
}

async function checkMcpRpc(url) {
  const startMs = Date.now();
  const token = process.env.MCP_AUTH_TOKEN;
  const headers = { 'content-type': 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify({ jsonrpc: '2.0', id: 'harness-tools-list', method: 'tools/list' }),
      signal: AbortSignal.timeout(5000),
    });
    const data = await response.json().catch(() => ({}));
    const ok = response.ok && Array.isArray(data?.result?.tools);
    return {
      name: 'MCP tools/list',
      url,
      ok,
      status: response.status,
      latencyMs: measureLatency(startMs),
      lastError: ok ? null : 'tools/list contract mismatch',
    };
  } catch (error) {
    return {
      name: 'MCP tools/list',
      url,
      ok: false,
      status: 0,
      latencyMs: measureLatency(startMs),
      lastError: safeError(error),
    };
  }
}

export async function runServicesCheck() {
  const services = await Promise.all([
    checkHealth('AG-UI', env('AG_UI_URL')),
    checkHealth('OpenAI', env('OPENAI_URL')),
    checkHealth('MCP', env('MCP_URL')),
    checkMcpRpc(env('MCP_RPC_URL')),
  ]);

  const failed = services.filter((item) => !item.ok);
  return {
    name: 'services-check',
    required: true,
    status: failed.length === 0 ? 'pass' : 'fail',
    code: failed.length === 0 ? null : 'SERVICE_UNHEALTHY',
    message:
      failed.length === 0
        ? 'All core services are reachable'
        : `${failed.length} service checks failed`,
    evidence: { services },
    remediation:
      failed.length === 0
        ? null
        : `Start missing services: ${failed.map((s) => s.name).join(', ')}. Run: yarn start:all`,
  };
}

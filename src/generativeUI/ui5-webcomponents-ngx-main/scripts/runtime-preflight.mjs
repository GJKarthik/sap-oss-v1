#!/usr/bin/env node
/* eslint-disable no-console */

const defaults = {
  AG_UI_URL: 'http://localhost:9160/health',
  OPENAI_URL: 'http://localhost:8400/health',
  MCP_URL: 'http://localhost:9160/health',
  MCP_RPC_URL: 'http://localhost:9160/mcp',
};

function env(name) {
  return process.env[name] || defaults[name];
}

async function checkHttp(url) {
  try {
    const response = await fetch(url, { method: 'GET' });
    return { ok: response.ok, status: response.status, statusText: response.statusText };
  } catch (error) {
    return { ok: false, status: 0, statusText: String(error?.message || error) };
  }
}

async function checkMcpRpc(url) {
  const token = process.env.MCP_AUTH_TOKEN;
  const headers = { 'content-type': 'application/json' };
  if (token) {
    headers.authorization = `Bearer ${token}`;
  }

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 'preflight-tools-list',
        method: 'tools/list',
      }),
    });
    if (!response.ok) {
      return {
        ok: false,
        status: response.status,
        statusText: response.statusText,
      };
    }
    const data = await response.json();
    const tools = data?.result?.tools;
    return {
      ok: Array.isArray(tools),
      status: response.status,
      statusText: Array.isArray(tools)
        ? `tools: ${tools.length}`
        : 'tools/list response missing tools array',
    };
  } catch (error) {
    return { ok: false, status: 0, statusText: String(error?.message || error) };
  }
}

async function main() {
  const checks = [
    { name: 'AG-UI health', run: () => checkHttp(env('AG_UI_URL')) },
    { name: 'OpenAI health', run: () => checkHttp(env('OPENAI_URL')) },
    { name: 'MCP health', run: () => checkHttp(env('MCP_URL')) },
    { name: 'MCP tools/list', run: () => checkMcpRpc(env('MCP_RPC_URL')) },
  ];

  console.log('Live workspace preflight');
  console.log('-------------------');
  let failed = 0;
  for (const check of checks) {
    // eslint-disable-next-line no-await-in-loop
    const result = await check.run();
    const prefix = result.ok ? 'PASS' : 'FAIL';
    console.log(`${prefix} ${check.name} -> ${result.status} ${result.statusText}`);
    if (!result.ok) failed++;
  }

  if (failed > 0) {
    console.error(`\nPreflight failed: ${failed} checks failing.`);
    process.exit(1);
  }

  console.log('\nPreflight passed: all live dependencies are reachable.');
}

main().catch((error) => {
  console.error('Preflight crashed:', error);
  process.exit(1);
});

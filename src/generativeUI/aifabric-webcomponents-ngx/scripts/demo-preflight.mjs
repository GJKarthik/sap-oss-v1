#!/usr/bin/env node
/* eslint-disable no-console */

const API_ORIGIN = process.env.SAP_API_UPSTREAM || 'http://127.0.0.1:8000';
const FRONTEND_ORIGIN = process.env.DEMO_FRONTEND_ORIGIN || 'http://127.0.0.1:4200';
const FRONTEND_PATH = process.env.DEMO_FRONTEND_PATH || '/';
const REQUIRE_MCP = String(process.env.DEMO_REQUIRE_MCP || 'false').toLowerCase() === 'true';
const REQUIRE_AUTH = String(process.env.DEMO_REQUIRE_AUTH || 'false').toLowerCase() === 'true';
const DEMO_USERNAME = process.env.DEMO_USERNAME || 'admin';
const DEMO_PASSWORD = process.env.DEMO_PASSWORD || 'changeme';

function normalizeOrigin(origin) {
  return String(origin).replace(/\/+$/, '');
}

async function checkHttp(url) {
  try {
    const response = await fetch(url, { method: 'GET' });
    return { ok: response.ok, status: response.status, detail: response.statusText };
  } catch (error) {
    return { ok: false, status: 0, detail: String(error?.message || error) };
  }
}

async function login(apiOrigin) {
  const params = new URLSearchParams();
  params.set('username', DEMO_USERNAME);
  params.set('password', DEMO_PASSWORD);
  try {
    const response = await fetch(`${apiOrigin}/api/v1/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: params.toString(),
    });
    if (!response.ok) {
      return { ok: false, token: null, detail: `HTTP ${response.status} ${response.statusText}` };
    }
    const payload = await response.json();
    if (!payload?.access_token) {
      return { ok: false, token: null, detail: 'Missing access_token in login response' };
    }
    return { ok: true, token: payload.access_token, detail: 'Authenticated' };
  } catch (error) {
    return { ok: false, token: null, detail: String(error?.message || error) };
  }
}

async function checkProtected(url, token) {
  try {
    const response = await fetch(url, {
      method: 'GET',
      headers: { authorization: `Bearer ${token}` },
    });
    return { ok: response.ok, status: response.status, detail: response.statusText };
  } catch (error) {
    return { ok: false, status: 0, detail: String(error?.message || error) };
  }
}

async function run() {
  const apiOrigin = normalizeOrigin(API_ORIGIN);
  const frontendOrigin = normalizeOrigin(FRONTEND_ORIGIN);
  const checks = [
    { name: 'API health', required: true, run: () => checkHttp(`${apiOrigin}/health`) },
    { name: 'API ready', required: true, run: () => checkHttp(`${apiOrigin}/ready`) },
    { name: `Frontend route (${FRONTEND_PATH})`, required: true, run: () => checkHttp(`${frontendOrigin}${FRONTEND_PATH}`) },
  ];

  const loginResult = await login(apiOrigin);
  checks.push({
    name: 'Demo login credentials',
    required: REQUIRE_AUTH,
    run: async () => ({
      ok: loginResult.ok,
      status: loginResult.ok ? 200 : 401,
      detail: loginResult.detail,
    }),
  });

  if (REQUIRE_MCP) {
    checks.push(
      {
        name: 'LangChain MCP health',
        required: true,
        run: async () =>
          loginResult.token
            ? checkProtected(`${apiOrigin}/api/v1/mcp/langchain/health`, loginResult.token)
            : { ok: false, status: 401, detail: 'Skipped because login failed' },
      },
      {
        name: 'Streaming MCP health',
        required: true,
        run: async () =>
          loginResult.token
            ? checkProtected(`${apiOrigin}/api/v1/mcp/streaming/health`, loginResult.token)
            : { ok: false, status: 401, detail: 'Skipped because login failed' },
      },
      {
        name: 'Data Cleaning MCP health',
        required: false,
        run: async () =>
          loginResult.token
            ? checkProtected(`${apiOrigin}/api/v1/mcp/data-cleaning/health`, loginResult.token)
            : { ok: false, status: 401, detail: 'Skipped because login failed' },
      }
    );
  }

  console.log('SAP AI Fabric Console demo preflight');
  console.log('------------------------------------');
  console.log(`API origin: ${apiOrigin}`);
  console.log(`Frontend origin: ${frontendOrigin}`);
  console.log(`Require auth check: ${REQUIRE_AUTH}`);
  console.log(`Require MCP checks: ${REQUIRE_MCP}`);

  let failedRequired = 0;
  for (const check of checks) {
    // eslint-disable-next-line no-await-in-loop
    const result = await check.run();
    const status = result.ok ? 'PASS' : check.required ? 'FAIL' : 'WARN';
    console.log(`${status} ${check.name} -> ${result.status} ${result.detail}`);
    if (check.required && !result.ok) failedRequired += 1;
  }

  if (failedRequired > 0) {
    console.error(`\nPreflight failed: ${failedRequired} required check(s) failing.`);
    process.exit(1);
  }

  console.log('\nPreflight passed: required live-demo dependencies look healthy.');
}

run().catch((error) => {
  console.error('Preflight crashed:', error);
  process.exit(1);
});

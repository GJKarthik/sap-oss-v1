// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE
/**
 * Validates collaboration WebSocket URLs to reduce SSRF-style misuse when
 * `websocketUrl` is misconfigured or derived from untrusted input.
 *
 * Aligns with private/metadata host blocking used in the MCP server
 * (see validateRemoteUrl in mcp-server).
 */

const BLOCKED_HOST_PREFIXES = ['169.254.', '100.100.', 'fd00:', '::1', '10.', '192.168.', '127.0.0.'];

function isBlockedHost(host: string): boolean {
  const normalized = host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host;
  if (BLOCKED_HOST_PREFIXES.some((prefix) => normalized.startsWith(prefix))) {
    return true;
  }
  if (normalized === 'localhost' || normalized === '::1') {
    return true;
  }
  const match172 = normalized.match(/^172\.(\d+)\./);
  if (match172) {
    const octet = parseInt(match172[1], 10);
    if (octet >= 16 && octet <= 31) {
      return true;
    }
  }
  return false;
}

/**
 * Same-origin path-only URLs (e.g. `/collab`) are allowed: the browser resolves them
 * against the current origin, so they cannot target arbitrary internal IPs.
 */
function isSafeSameOriginPath(trimmed: string): boolean {
  if (!trimmed.startsWith('/') || trimmed.startsWith('//')) {
    return false;
  }
  if (trimmed.includes('..')) {
    return false;
  }
  return true;
}

/**
 * Throws if the URL is not a safe WebSocket target for collaboration.
 * Accepts absolute `ws:` / `wss:` URLs (with blocked-host rules) or a path-only
 * same-origin URL such as `/collab`.
 */
export function assertSafeCollaborationWebSocketUrl(raw: string, context = 'CollaborationService'): void {
  const trimmed = (raw || '').trim();
  if (!trimmed) {
    throw new Error(`${context}: websocketUrl is required`);
  }

  if (isSafeSameOriginPath(trimmed)) {
    return;
  }

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new Error(`${context}: websocketUrl is not a valid URL: ${raw}`);
  }

  if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') {
    throw new Error(
      `${context}: websocketUrl must use ws or wss (got '${parsed.protocol}'). Value: ${raw}`
    );
  }

  const host = parsed.hostname;
  if (isBlockedHost(host)) {
    throw new Error(
      `${context}: websocketUrl targets a blocked host '${host}' (private/metadata addresses are not allowed). Value: ${raw}`
    );
  }
}

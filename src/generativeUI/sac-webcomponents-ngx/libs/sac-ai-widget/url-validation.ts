// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

const LOCAL_HOSTNAMES = new Set(['localhost', '127.0.0.1', '::1']);

export function isLocalHostname(hostname: string): boolean {
  return LOCAL_HOSTNAMES.has(hostname) || hostname.endsWith('.localhost');
}

export function normalizeConfiguredUrl(rawValue: string | undefined, fieldName: string): string {
  const value = rawValue?.trim() ?? '';
  if (!value) {
    throw new Error(`${fieldName} is required`);
  }

  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${fieldName} must be an absolute URL`);
  }

  if (parsed.username || parsed.password) {
    throw new Error(`${fieldName} must not include credentials`);
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error(`${fieldName} must use http or https`);
  }

  if (parsed.protocol !== 'https:' && !isLocalHostname(parsed.hostname)) {
    throw new Error(`${fieldName} must use https outside localhost`);
  }

  return parsed.toString();
}

export function getTenantFromTenantUrl(tenantUrl: string): string {
  const hostname = new URL(tenantUrl).hostname;
  return hostname.split('.')[0] ?? 'default';
}

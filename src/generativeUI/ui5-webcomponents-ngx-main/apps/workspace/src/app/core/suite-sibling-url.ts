// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2025 SAP SE
/**
 * When the workspace app is served from `nx serve` on `/`, root-relative
 * `/training/` would stay on the dev server. Under the suite gateway
 * (`/ui5/`, …) relative paths are correct.
 *
 * Overrides (first wins):
 * 1. `window.__SUITE_GATEWAY_ORIGIN__`
 * 2. `localStorage['sap.suiteGatewayOrigin']`
 * 3. `<meta name="sap-suite-gateway-origin" />` (localhost / 127.0.0.1 only)
 */
const LS_KEY = 'sap.suiteGatewayOrigin';

function explicitSuiteOrigin(): string {
  if (typeof window === 'undefined') {
    return '';
  }
  const fromWin = (window as Window & { __SUITE_GATEWAY_ORIGIN__?: string }).__SUITE_GATEWAY_ORIGIN__?.trim();
  if (fromWin && (fromWin.startsWith('http://') || fromWin.startsWith('https://'))) {
    return fromWin.replace(/\/$/, '');
  }
  try {
    const fromLs = typeof localStorage !== 'undefined' ? localStorage.getItem(LS_KEY)?.trim() : '';
    if (fromLs && (fromLs.startsWith('http://') || fromLs.startsWith('https://'))) {
      return fromLs.replace(/\/$/, '');
    }
  } catch {
    /* private mode */
  }
  return '';
}

function metaSuiteOrigin(): string {
  if (typeof document === 'undefined') {
    return '';
  }
  return (
    document.querySelector<HTMLMetaElement>('meta[name="sap-suite-gateway-origin"]')?.content?.trim().replace(/\/$/, '') ??
    ''
  );
}

export function absolutizeSuiteSiblingPath(path: string): string {
  const normalized = path.startsWith('/') ? path : `/${path}`;
  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return normalized;
  }
  if (/^\/(training|aifabric|ui5)(\/|$)/.test(window.location.pathname)) {
    return normalized;
  }

  const explicit = explicitSuiteOrigin();
  if (explicit) {
    return `${explicit}${normalized}`;
  }

  const raw = metaSuiteOrigin();
  if (!raw) {
    return normalized;
  }
  const h = window.location.hostname;
  if (h !== 'localhost' && h !== '127.0.0.1') {
    return normalized;
  }
  return `${raw}${normalized}`;
}

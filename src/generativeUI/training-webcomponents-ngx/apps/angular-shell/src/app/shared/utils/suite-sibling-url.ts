/**
 * When shells are served from `nx serve` (e.g. / on :4200), root-relative
 * `/training/` and `/ui5/` would hit the wrong origin. Under the suite
 * gateway (`/training/`, `/ui5/`, …) same-origin relative paths are correct.
 *
 * Overrides (first wins):
 * 1. `window.__SUITE_GATEWAY_ORIGIN__` (e.g. injected by hosting)
 * 2. `localStorage['sap.suiteGatewayOrigin']` (e.g. `http://localhost:8088`)
 * 3. `<meta name="sap-suite-gateway-origin" content="http://localhost:8080" />`
 *    — only applied on localhost / 127.0.0.1 so production hosts are unaffected.
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

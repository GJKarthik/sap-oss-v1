import { absolutizeSuiteSiblingPath } from './suite-sibling-url';

describe('absolutizeSuiteSiblingPath', () => {
  afterEach(() => {
    delete (window as unknown as { __SUITE_GATEWAY_ORIGIN__?: string }).__SUITE_GATEWAY_ORIGIN__;
    try {
      localStorage.removeItem('sap.suiteGatewayOrigin');
    } catch {
      /* ignore */
    }
    document.querySelectorAll('meta[name="sap-suite-gateway-origin"]').forEach((m) => m.remove());
    window.history.pushState({}, '', '/');
  });

  it('keeps relative paths when already under a suite-mounted product path', () => {
    window.history.pushState({}, '', '/ui5/joule');
    expect(absolutizeSuiteSiblingPath('/training/dashboard')).toBe('/training/dashboard');
  });

  it('prefixes meta gateway origin on localhost when not under suite paths', () => {
    window.history.pushState({}, '', '/');
    const meta = document.createElement('meta');
    meta.setAttribute('name', 'sap-suite-gateway-origin');
    meta.setAttribute('content', 'http://localhost:8080');
    document.head.appendChild(meta);
    expect(absolutizeSuiteSiblingPath('/training/')).toBe('http://localhost:8080/training/');
  });

  it('prefers localStorage over meta', () => {
    window.history.pushState({}, '', '/');
    const meta = document.createElement('meta');
    meta.setAttribute('name', 'sap-suite-gateway-origin');
    meta.setAttribute('content', 'http://localhost:8080');
    document.head.appendChild(meta);
    localStorage.setItem('sap.suiteGatewayOrigin', 'http://localhost:8088');
    expect(absolutizeSuiteSiblingPath('/training/')).toBe('http://localhost:8088/training/');
  });
});

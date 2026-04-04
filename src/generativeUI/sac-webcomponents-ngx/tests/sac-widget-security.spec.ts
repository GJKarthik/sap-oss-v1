import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

import { getTenantFromTenantUrl, normalizeConfiguredUrl } from '../libs/sac-ai-widget/url-validation';

describe('normalizeConfiguredUrl', () => {
  it('accepts https widget endpoints', () => {
    expect(normalizeConfiguredUrl('https://cap.example.com/api', 'capBackendUrl')).toBe('https://cap.example.com/api');
  });

  it('accepts localhost http endpoints for local harnesses', () => {
    expect(normalizeConfiguredUrl('http://localhost:4173/mock-sac', 'tenantUrl')).toBe('http://localhost:4173/mock-sac');
  });

  it('rejects relative URLs', () => {
    expect(() => normalizeConfiguredUrl('/mock-sac', 'tenantUrl')).toThrow('tenantUrl must be an absolute URL');
  });

  it('rejects remote http URLs', () => {
    expect(() => normalizeConfiguredUrl('http://cap.example.com/api', 'capBackendUrl')).toThrow(
      'capBackendUrl must use https outside localhost',
    );
  });

  it('rejects embedded credentials', () => {
    expect(() => normalizeConfiguredUrl('https://user:pass@tenant.example.com', 'tenantUrl')).toThrow(
      'tenantUrl must not include credentials',
    );
  });
});

describe('getTenantFromTenantUrl', () => {
  it('extracts the SAC tenant from the hostname', () => {
    expect(getTenantFromTenantUrl('https://acme.sapanalytics.cloud')).toBe('acme');
  });
});

describe('widget manifest integrity', () => {
  it('requires integrity checks for the production widget bundle', () => {
    const manifestPath = fileURLToPath(new URL('../widget.json', import.meta.url));
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      webcomponents: Array<{ tag: string; ignoreIntegrity?: boolean; integrity?: string }>;
    };

    expect(manifest.webcomponents).toContainEqual(
      expect.objectContaining({
        tag: 'sac-ai-widget',
        ignoreIntegrity: false,
        integrity: expect.stringMatching(/^sha256-/),
      }),
    );
  });
});

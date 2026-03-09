import { describe, expect, it } from 'vitest';

import { SacAuthService } from '../libs/sac-core/src/lib/services/sac-auth.service';

describe('SacAuthService', () => {
  it('normalizes the initial token and exposes an authorization header', () => {
    const service = new SacAuthService('  initial-token  ');

    expect(service.getToken()).toBe('initial-token');
    expect(service.getAuthorizationHeader()).toBe('Bearer initial-token');
  });

  it('clears authentication when given a blank token', () => {
    const service = new SacAuthService('seed-token');

    service.setToken('   ');

    expect(service.getToken()).toBeNull();
    expect(service.getAuthorizationHeader()).toBeNull();
  });
});

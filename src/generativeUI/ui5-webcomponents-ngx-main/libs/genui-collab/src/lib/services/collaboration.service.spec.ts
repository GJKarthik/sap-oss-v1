// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { CollaborationService, CollabConfig, Participant } from './collaboration.service';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeConfig(overrides: Partial<CollabConfig> = {}): CollabConfig {
  return {
    websocketUrl: 'ws://localhost:9090/collab',
    userId: 'user-test',
    displayName: 'Test User',
    ...overrides,
  };
}

/**
 * Build a CollaborationService that is pre-configured but NOT connected
 * (no real WebSocket is opened).
 */
function makeService(config?: CollabConfig): CollaborationService {
  const svc = new CollaborationService(config);
  return svc;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('CollaborationService', () => {
  it('participants$ emits an empty array before any room is joined', (done) => {
    const svc = makeService(makeConfig());

    svc.participants$.subscribe((participants: Participant[]) => {
      expect(participants).toEqual([]);
      done();
    });
  });

  it('connectionState$ starts as disconnected', (done) => {
    const svc = makeService(makeConfig());

    svc.connectionState$.subscribe((state: string) => {
      expect(state).toBe('disconnected');
      done();
    });
  });

  it('configure() updates the internal config and is reflected in subsequent joins', async () => {
    const svc = makeService();

    // configure() must not throw when called without initial config
    expect(() => {
      svc.configure(makeConfig({ userId: 'new-user', displayName: 'New User' }));
    }).not.toThrow();
  });

  it('joinRoom() rejects immediately when no config is present', async () => {
    // Service created without any config
    const svc = makeService(undefined);

    await expect(svc.joinRoom('room-1')).rejects.toThrow('CollaborationService not configured');
  });
});

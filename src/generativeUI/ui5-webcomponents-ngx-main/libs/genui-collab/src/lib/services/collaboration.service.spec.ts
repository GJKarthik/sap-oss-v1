// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

import {
  CollabConfig,
  CollaborationService,
  Participant,
  StateChange,
} from './collaboration.service';
import { GCounter, ORSet } from '../crdt';

function makeConfig(overrides: Partial<CollabConfig> = {}): CollabConfig {
  return {
    websocketUrl: 'wss://example.com/collab',
    userId: 'user-test',
    displayName: 'Test User',
    ...overrides,
  };
}

function makeService(config?: CollabConfig): CollaborationService {
  return new CollaborationService(config);
}

function deliver(service: CollaborationService, message: unknown): void {
  (service as unknown as { handleMessage: (msg: unknown) => void }).handleMessage(message);
}

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

  it('applies optimistic local updates with version and vector clock metadata', () => {
    const svc = makeService(makeConfig());

    const change = svc.broadcastStateChange({
      type: 'component_update',
      componentId: 'chart-1',
      changes: { filter: 'Q4 2026' },
    });

    expect(change).toBeDefined();
    expect(change?.version).toBe(1);
    expect(change?.previousVersion).toBe(0);
    expect(change?.vectorClock).toEqual({ 'user-test': 1 });

    const snapshot = svc.getStateSnapshot('chart-1');
    expect(snapshot?.version).toBe(1);
    expect(snapshot?.state).toEqual({ filter: 'Q4 2026' });
    expect(snapshot?.vectorClock).toEqual({ 'user-test': 1 });
  });

  it('uses the conflict resolver when plain values diverge from previousVersion', () => {
    const svc = makeService(
      makeConfig({
        conflictResolver: ({ localValue, remoteValue }) => ({
          resolvedValue: `resolved:${String(localValue)}|${String(remoteValue)}`,
        }),
      })
    );
    const emitted: StateChange[] = [];
    svc.stateChanges$.subscribe((change) => emitted.push(change));

    svc.broadcastStateChange({
      type: 'component_update',
      componentId: 'title-1',
      changes: { title: 'local-title' },
    });

    deliver(svc, {
      type: 'state',
      id: 'remote-1',
      userId: 'user-2',
      timestamp: 100,
      componentId: 'title-1',
      changes: { title: 'remote-title' },
      version: 1,
      previousVersion: 0,
      vectorClock: { 'user-2': 1 },
    });

    const snapshot = svc.getStateSnapshot('title-1');
    expect(snapshot?.version).toBe(2);
    expect(snapshot?.state.title).toBe('resolved:local-title|remote-title');

    expect(emitted).toHaveLength(2);
    expect(emitted[1].conflictDetected).toBe(true);
    expect(emitted[1].rollbackApplied).toBe(true);
    expect(emitted[1].resolutionStrategy).toBe('callback');
    expect(emitted[1].changes.title).toBe('resolved:local-title|remote-title');
  });

  it('auto-merges CRDT counter conflicts when concurrent increments arrive', () => {
    const svc = makeService(makeConfig());
    const localCounter = new GCounter();
    localCounter.increment('user-test');

    svc.broadcastStateChange({
      type: 'component_update',
      componentId: 'counter-1',
      changes: { count: localCounter },
    });

    const remoteCounter = new GCounter();
    remoteCounter.increment('user-2');

    deliver(svc, {
      type: 'state',
      id: 'remote-2',
      userId: 'user-2',
      timestamp: 200,
      componentId: 'counter-1',
      changes: { count: remoteCounter },
      version: 1,
      previousVersion: 0,
      vectorClock: { 'user-2': 1 },
    });

    const snapshot = svc.getStateSnapshot('counter-1');
    const mergedCounter = snapshot?.state.count as GCounter;

    expect(mergedCounter).toBeInstanceOf(GCounter);
    expect(mergedCounter.value).toBe(2);
  });

  it('reconciles concurrent OR-set snapshots during sync after partition', () => {
    const svc = makeService(makeConfig());
    const localSet = new ORSet<string>();
    localSet.add('local-tag', 'local-1');

    svc.broadcastStateChange({
      type: 'component_update',
      componentId: 'filters-1',
      changes: { tags: localSet },
    });

    const remoteSet = new ORSet<string>();
    remoteSet.add('remote-tag', 'remote-1');

    deliver(svc, {
      type: 'sync',
      participants: [],
      state: {
        'filters-1': {
          componentId: 'filters-1',
          version: 1,
          state: { tags: remoteSet },
          vectorClock: { 'user-2': 1 },
          lastUpdatedBy: 'user-2',
          updatedAt: 300,
        },
      },
    });

    const snapshot = svc.getStateSnapshot('filters-1');
    const mergedSet = snapshot?.state.tags as ORSet<string>;

    expect(mergedSet).toBeInstanceOf(ORSet);
    expect(Array.from(mergedSet.value).sort()).toEqual(['local-tag', 'remote-tag']);
  });
});
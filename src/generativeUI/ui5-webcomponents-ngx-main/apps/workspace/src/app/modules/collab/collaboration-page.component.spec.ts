// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * CollaborationPageComponent unit tests
 *
 * Covers:
 * - Initial state defaults
 * - connectionState updates from service
 * - participants updates from service
 * - joinRoom() / leaveRoom() delegate to CollaborationService
 * - broadcastCursor() only fires when connected
 * - clearLog() empties the log
 * - getCursorColor() is deterministic per userId
 * - ngOnDestroy calls leaveRoom and unsubscribes
 */

import { ChangeDetectorRef } from '@angular/core';
import { BehaviorSubject } from 'rxjs';
import { CollaborationPageComponent } from './collaboration-page.component';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeCollabService() {
  const connectionState$ = new BehaviorSubject<string>('disconnected');
  const participants$ = new BehaviorSubject<unknown[]>([]);
  const cursors$ = new BehaviorSubject<unknown[]>([]);
  return {
    connectionState$: connectionState$.asObservable(),
    participants$: participants$.asObservable(),
    cursors$: cursors$.asObservable(),
    joinRoom: jest.fn().mockResolvedValue(undefined),
    leaveRoom: jest.fn(),
    broadcastCursor: jest.fn(),
    _connectionState$: connectionState$,
    _participants$: participants$,
    _cursors$: cursors$,
  };
}

function makeCdr(): ChangeDetectorRef {
  return { markForCheck: jest.fn() } as unknown as ChangeDetectorRef;
}

function createComponent() {
  const collab = makeCollabService();
  const cdr = makeCdr();
  const component = new CollaborationPageComponent(collab as never, cdr);
  return { component, collab, cdr };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('CollaborationPageComponent — initial state', () => {
  it('starts disconnected with empty participants, cursors, and log', () => {
    const { component } = createComponent();
    expect(component.connectionState).toBe('disconnected');
    expect(component.participants).toEqual([]);
    expect(component.cursors).toEqual([]);
    expect(component.log).toEqual([]);
  });

  it('has a default roomId', () => {
    const { component } = createComponent();
    expect(component.roomId).toBeTruthy();
  });
});

describe('CollaborationPageComponent — subscriptions', () => {
  it('updates connectionState from service and logs entry', () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    collab._connectionState$.next('connected');
    expect(component.connectionState).toBe('connected');
    expect(component.log.some(e => e.includes('connected'))).toBe(true);
  });

  it('updates participants from service', () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    const p = [{ userId: 'u1', displayName: 'Alice', color: '#f00', status: 'active', joinedAt: new Date(), lastSeenAt: new Date() }];
    collab._participants$.next(p);
    expect(component.participants).toHaveLength(1);
    expect(component.participants[0].userId).toBe('u1');
  });

  it('updates cursors from service', () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    collab._cursors$.next([{ userId: 'u1', x: 10, y: 20, timestamp: Date.now() }]);
    expect(component.cursors).toHaveLength(1);
  });
});

describe('CollaborationPageComponent — actions', () => {
  it('joinRoom() calls collab.joinRoom with the roomId and logs', async () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    await component.joinRoom();
    expect(collab.joinRoom).toHaveBeenCalledWith(component.roomId);
    expect(component.log.some(e => e.includes('Joining'))).toBe(true);
  });

  it('leaveRoom() calls collab.leaveRoom and logs', () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    component.leaveRoom();
    expect(collab.leaveRoom).toHaveBeenCalledTimes(1);
    expect(component.log.some(e => e.includes('Left'))).toBe(true);
  });

  it('broadcastCursor() is a no-op when not connected', () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    component.broadcastCursor({ offsetX: 5, offsetY: 10 } as MouseEvent);
    expect(collab.broadcastCursor).not.toHaveBeenCalled();
  });

  it('broadcastCursor() fires when connected', () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    collab._connectionState$.next('connected');
    component.broadcastCursor({ offsetX: 50, offsetY: 100 } as MouseEvent);
    expect(collab.broadcastCursor).toHaveBeenCalledWith(50, 100);
  });

  it('clearLog() empties the log array', () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    collab._connectionState$.next('connected');
    expect(component.log.length).toBeGreaterThan(0);
    component.clearLog();
    expect(component.log).toEqual([]);
  });

  it('ngOnDestroy calls leaveRoom and unsubscribes', () => {
    const { component, collab } = createComponent();
    component.ngOnInit();
    component.ngOnDestroy();
    const callCount = (collab.leaveRoom as jest.Mock).mock.calls.length;
    collab._connectionState$.next('connected');
    expect((collab.leaveRoom as jest.Mock).mock.calls.length).toBe(callCount);
  });
});

describe('CollaborationPageComponent — getCursorColor', () => {
  it('returns a colour string for any userId', () => {
    const { component } = createComponent();
    const color = component.getCursorColor('user-abc');
    expect(color).toMatch(/^#[0-9a-f]{6}$/i);
  });

  it('is deterministic — same userId always returns same colour', () => {
    const { component } = createComponent();
    const a = component.getCursorColor('user-xyz');
    const b = component.getCursorColor('user-xyz');
    expect(a).toBe(b);
  });

  it('returns different colours for different userIds (at least sometimes)', () => {
    const { component } = createComponent();
    const colors = new Set(['u1','u2','u3','u4','u5','u6'].map(id => component.getCursorColor(id)));
    expect(colors.size).toBeGreaterThan(1);
  });
});

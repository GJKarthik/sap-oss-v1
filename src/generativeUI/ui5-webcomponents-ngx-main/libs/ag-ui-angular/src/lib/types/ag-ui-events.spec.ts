// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * ag-ui-events unit + snapshot tests
 *
 * Covers:
 * - SequenceTracker: outgoing seq numbering
 * - SequenceTracker: incoming gap detection
 * - SequenceTracker: run reset
 * - parseAgUiEvent: defaults, type guard
 */

import { SequenceTracker, parseAgUiEvent } from './ag-ui-events';

// ---------------------------------------------------------------------------
// SequenceTracker
// ---------------------------------------------------------------------------

describe('SequenceTracker', () => {
  let tracker: SequenceTracker;

  beforeEach(() => {
    tracker = new SequenceTracker();
  });

  describe('nextOutSeq()', () => {
    it('starts at 1 for a new run', () => {
      expect(tracker.nextOutSeq('run-1')).toBe(1);
    });

    it('increments on every call', () => {
      expect(tracker.nextOutSeq('run-1')).toBe(1);
      expect(tracker.nextOutSeq('run-1')).toBe(2);
      expect(tracker.nextOutSeq('run-1')).toBe(3);
    });

    it('tracks separate runs independently', () => {
      expect(tracker.nextOutSeq('run-a')).toBe(1);
      expect(tracker.nextOutSeq('run-b')).toBe(1);
      expect(tracker.nextOutSeq('run-a')).toBe(2);
    });
  });

  describe('trackIncoming()', () => {
    const makeEvent = (runId: string, seq?: number) => ({
      type: 'text.delta' as const,
      id: 'evt-1',
      runId,
      timestamp: new Date().toISOString(),
      seq,
      delta: 'hello',
    });

    it('returns no-seq when event has no seq field', () => {
      expect(tracker.trackIncoming(makeEvent('run-1'))).toBe('no-seq');
    });

    it('accepts first event with seq=1', () => {
      expect(tracker.trackIncoming(makeEvent('run-1', 1))).toBe('ok');
    });

    it('accepts sequential events', () => {
      tracker.trackIncoming(makeEvent('run-1', 1));
      expect(tracker.trackIncoming(makeEvent('run-1', 2))).toBe('ok');
      expect(tracker.trackIncoming(makeEvent('run-1', 3))).toBe('ok');
    });

    it('detects a gap', () => {
      tracker.trackIncoming(makeEvent('run-1', 1));
      const result = tracker.trackIncoming(makeEvent('run-1', 3));
      expect(result).toBe('gap:2:3');
    });

    it('treats seq=1 as run reset (allows reconnect)', () => {
      tracker.trackIncoming(makeEvent('run-1', 1));
      tracker.trackIncoming(makeEvent('run-1', 2));
      expect(tracker.trackIncoming(makeEvent('run-1', 1))).toBe('ok');
    });
  });

  describe('reset()', () => {
    it('resets outgoing seq for a run', () => {
      tracker.nextOutSeq('run-1');
      tracker.nextOutSeq('run-1');
      tracker.reset('run-1');
      expect(tracker.nextOutSeq('run-1')).toBe(1);
    });

    it('does not reset other runs', () => {
      tracker.nextOutSeq('run-a');
      tracker.nextOutSeq('run-b');
      tracker.reset('run-a');
      expect(tracker.nextOutSeq('run-b')).toBe(2);
    });
  });

  describe('clear()', () => {
    it('clears all state', () => {
      tracker.nextOutSeq('run-1');
      tracker.nextOutSeq('run-2');
      tracker.clear();
      expect(tracker.nextOutSeq('run-1')).toBe(1);
      expect(tracker.nextOutSeq('run-2')).toBe(1);
    });
  });
});

// ---------------------------------------------------------------------------
// parseAgUiEvent
// ---------------------------------------------------------------------------

describe('parseAgUiEvent', () => {
  it('returns null for non-object input', () => {
    expect(parseAgUiEvent(null)).toBeNull();
    expect(parseAgUiEvent('string')).toBeNull();
    expect(parseAgUiEvent(42)).toBeNull();
  });

  it('returns null when type field is missing', () => {
    expect(parseAgUiEvent({ id: 'x', runId: 'r' })).toBeNull();
  });

  it('fills in id when missing', () => {
    const event = parseAgUiEvent({ type: 'text.delta', runId: 'r', delta: 'hi' });
    expect(event).not.toBeNull();
    expect(typeof event!.id).toBe('string');
    expect(event!.id.length).toBeGreaterThan(0);
  });

  it('fills in runId=unknown when missing', () => {
    const event = parseAgUiEvent({ type: 'text.delta', delta: 'hi' });
    expect(event!.runId).toBe('unknown');
  });

  it('fills in timestamp when missing', () => {
    const event = parseAgUiEvent({ type: 'text.delta', delta: 'hi' });
    expect(typeof event!.timestamp).toBe('string');
  });

  it('preserves provided id and runId', () => {
    const event = parseAgUiEvent({ type: 'text.delta', id: 'my-id', runId: 'my-run', delta: 'hi' });
    expect(event!.id).toBe('my-id');
    expect(event!.runId).toBe('my-run');
  });

  it('matches snapshot for a well-formed text.delta event', () => {
    const event = parseAgUiEvent({
      type: 'text.delta',
      id: 'snap-id',
      runId: 'snap-run',
      timestamp: '2024-01-01T00:00:00.000Z',
      seq: 1,
      delta: 'Hello',
    });
    expect(event).toMatchSnapshot();
  });
});

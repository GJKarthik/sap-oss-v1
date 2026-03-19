// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

import { GCounter, LWWMap, ORSet, PNCounter, VectorClock } from './index';

describe('CRDT primitives', () => {
  it('tracks causal ordering with vector clocks', () => {
    const before = new VectorClock({ 'node-a': 1 });
    const after = before.clone();
    after.increment('node-a');
    const concurrent = new VectorClock({ 'node-b': 1 });

    expect(before.happensBefore(after)).toBe(true);
    expect(after.happensBefore(before)).toBe(false);
    expect(before.happensBefore(concurrent)).toBe(false);
    expect(concurrent.happensBefore(before)).toBe(false);
  });

  it('merges grow-only counters by taking the max contribution per node', () => {
    const left = new GCounter();
    left.increment('node-a', 2);
    const right = new GCounter();
    right.increment('node-a', 1);
    right.increment('node-b', 3);

    expect(left.merge(right).value).toBe(5);
  });

  it('merges positive-negative counters across increments and decrements', () => {
    const left = new PNCounter();
    left.increment('node-a', 5);
    left.decrement('node-a', 1);

    const right = new PNCounter();
    right.increment('node-b', 2);
    right.decrement('node-b', 1);

    expect(left.merge(right).value).toBe(5);
  });

  it('preserves concurrent OR-set additions after an observed remove', () => {
    const base = new ORSet<string>();
    base.add('alpha', 'seed');

    const removed = base.clone();
    removed.remove('alpha', 'remove-op');

    const concurrentAdd = base.clone();
    concurrentAdd.add('alpha', 'new-tag');

    const merged = removed.merge(concurrentAdd);
    expect(Array.from(merged.value)).toEqual(['alpha']);
  });

  it('merges nested CRDT values inside an LWW map', () => {
    const clockA = new VectorClock({ 'node-a': 1 });
    const clockB = new VectorClock({ 'node-b': 1 });
    const countA = new GCounter();
    countA.increment('node-a');
    const countB = new GCounter();
    countB.increment('node-b');

    const left = new LWWMap<string, GCounter>();
    left.set('count', countA, 'node-a', 10, clockA);

    const right = new LWWMap<string, GCounter>();
    right.set('count', countB, 'node-b', 11, clockB);

    const merged = left.merge(right).get('count');
    expect(merged).toBeInstanceOf(GCounter);
    expect(merged?.value).toBe(2);
  });
});
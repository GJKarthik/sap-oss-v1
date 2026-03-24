// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

/**
 * CRDT primitives for collaborative state synchronisation.
 */

export type SerializedVectorClock = Record<string, number>;

export interface SerializedGCounter {
  __crdtType: 'GCounter';
  counts: Record<string, number>;
}

export interface SerializedPNCounter {
  __crdtType: 'PNCounter';
  pos: SerializedGCounter;
  neg: SerializedGCounter;
}

export interface SerializedORSet<T = unknown> {
  __crdtType: 'ORSet';
  additions: Array<{ value: T; tags: string[] }>;
  removals: Record<string, string[]>;
}

export interface SerializedLWWMapEntry<K = unknown, V = unknown> {
  key: K;
  value: V;
  nodeId: string;
  timestamp: number;
  clock: SerializedVectorClock;
}

export interface SerializedLWWMap<K = unknown, V = unknown> {
  __crdtType: 'LWWMap';
  entries: Array<SerializedLWWMapEntry<K, V>>;
}

export type SerializedCRDTValue =
  | SerializedGCounter
  | SerializedPNCounter
  | SerializedORSet<unknown>
  | SerializedLWWMap<unknown, unknown>;

type CrdtValue = GCounter | PNCounter | ORSet<unknown> | LWWMap<unknown, unknown>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function stableSerialize(value: unknown): string {
  if (value === null) {
    return 'null';
  }

  if (value === undefined) {
    return 'undefined';
  }

  if (Array.isArray(value)) {
    return `[${value.map((item) => stableSerialize(item)).join(',')}]`;
  }

  if (value instanceof Date) {
    return `date:${value.toISOString()}`;
  }

  if (value instanceof Set) {
    return `set:${Array.from(value).map((item) => stableSerialize(item)).sort().join(',')}`;
  }

  if (value instanceof VectorClock) {
    return `clock:${JSON.stringify(value.toJSON())}`;
  }

  if (isCRDTValue(value)) {
    return stableSerialize(value.toJSON());
  }

  if (isRecord(value)) {
    const keys = Object.keys(value).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${stableSerialize(value[key])}`).join(',')}}`;
  }

  return JSON.stringify(value);
}

function cloneValue<T>(value: T): T {
  if (value instanceof Date) {
    return new Date(value.getTime()) as T;
  }

  if (value instanceof VectorClock) {
    return value.clone() as T;
  }

  if (value instanceof GCounter || value instanceof PNCounter || value instanceof ORSet || value instanceof LWWMap) {
    return value.clone() as T;
  }

  if (Array.isArray(value)) {
    return value.map((item) => cloneValue(item)) as T;
  }

  if (value instanceof Set) {
    return new Set(Array.from(value).map((item) => cloneValue(item))) as T;
  }

  if (isRecord(value)) {
    const clone: Record<string, unknown> = {};
    for (const [key, entryValue] of Object.entries(value)) {
      clone[key] = cloneValue(entryValue);
    }
    return clone as T;
  }

  return value;
}

function mergeStrategyRank(strategy: 'crdt' | 'lww' | 'none'): number {
  switch (strategy) {
    case 'crdt':
      return 2;
    case 'lww':
      return 1;
    default:
      return 0;
  }
}

function sortEntries<T>(entries: Iterable<[string, T]>): Array<[string, T]> {
  return Array.from(entries).sort(([left], [right]) => left.localeCompare(right));
}

export type VectorClockLike = VectorClock | Map<string, number> | Record<string, number>;

function isVectorClockLike(value: unknown): value is VectorClockLike {
  return value instanceof VectorClock || value instanceof Map || (isRecord(value) && Object.values(value).every((entry) => typeof entry === 'number'));
}

export class VectorClock {
  private readonly clock = new Map<string, number>();

  constructor(initial?: VectorClockLike) {
    if (!initial) {
      return;
    }

    if (initial instanceof VectorClock) {
      for (const [nodeId, counter] of initial.clock.entries()) {
        this.clock.set(nodeId, counter);
      }
      return;
    }

    if (initial instanceof Map) {
      for (const [nodeId, counter] of initial.entries()) {
        this.clock.set(nodeId, counter);
      }
      return;
    }

    for (const [nodeId, counter] of Object.entries(initial)) {
      this.clock.set(nodeId, counter);
    }
  }

  static from(initial?: VectorClockLike): VectorClock {
    return new VectorClock(initial);
  }

  increment(nodeId: string): void {
    this.clock.set(nodeId, this.get(nodeId) + 1);
  }

  get(nodeId: string): number {
    return this.clock.get(nodeId) ?? 0;
  }

  merge(other: VectorClock): VectorClock {
    const merged = new VectorClock(this);
    for (const [nodeId, counter] of other.clock.entries()) {
      merged.clock.set(nodeId, Math.max(merged.get(nodeId), counter));
    }
    return merged;
  }

  happensBefore(other: VectorClock): boolean {
    let hasStrictlySmallerValue = false;
    const nodeIds = new Set<string>([...this.clock.keys(), ...other.clock.keys()]);

    for (const nodeId of nodeIds) {
      const current = this.get(nodeId);
      const next = other.get(nodeId);

      if (current > next) {
        return false;
      }

      if (current < next) {
        hasStrictlySmallerValue = true;
      }
    }

    return hasStrictlySmallerValue;
  }

  equals(other: VectorClock): boolean {
    return !this.happensBefore(other) && !other.happensBefore(this);
  }

  clone(): VectorClock {
    return new VectorClock(this);
  }

  toJSON(): SerializedVectorClock {
    return Object.fromEntries(sortEntries(this.clock.entries()));
  }
}

export class GCounter {
  private readonly counts = new Map<string, number>();

  constructor(initial?: Map<string, number> | Record<string, number>) {
    if (!initial) {
      return;
    }

    if (initial instanceof Map) {
      for (const [nodeId, count] of initial.entries()) {
        this.counts.set(nodeId, count);
      }
      return;
    }

    for (const [nodeId, count] of Object.entries(initial)) {
      this.counts.set(nodeId, count);
    }
  }

  increment(nodeId: string, amount = 1): void {
    if (amount < 0) {
      throw new Error('GCounter only supports non-negative increments');
    }

    this.counts.set(nodeId, (this.counts.get(nodeId) ?? 0) + amount);
  }

  get value(): number {
    return Array.from(this.counts.values()).reduce((sum, count) => sum + count, 0);
  }

  merge(other: GCounter): GCounter {
    const merged = new GCounter(this.counts);
    for (const [nodeId, count] of other.counts.entries()) {
      merged.counts.set(nodeId, Math.max(merged.counts.get(nodeId) ?? 0, count));
    }
    return merged;
  }

  clone(): GCounter {
    return new GCounter(this.counts);
  }

  toJSON(): SerializedGCounter {
    return {
      __crdtType: 'GCounter',
      counts: Object.fromEntries(sortEntries(this.counts.entries())),
    };
  }
}

export class PNCounter {
  private readonly pos: GCounter;
  private readonly neg: GCounter;

  constructor(pos?: GCounter, neg?: GCounter) {
    this.pos = pos?.clone() ?? new GCounter();
    this.neg = neg?.clone() ?? new GCounter();
  }

  increment(nodeId: string, amount = 1): void {
    this.pos.increment(nodeId, amount);
  }

  decrement(nodeId: string, amount = 1): void {
    this.neg.increment(nodeId, amount);
  }

  get value(): number {
    return this.pos.value - this.neg.value;
  }

  merge(other: PNCounter): PNCounter {
    return new PNCounter(this.pos.merge(other.pos), this.neg.merge(other.neg));
  }

  clone(): PNCounter {
    return new PNCounter(this.pos, this.neg);
  }

  toJSON(): SerializedPNCounter {
    return {
      __crdtType: 'PNCounter',
      pos: this.pos.toJSON(),
      neg: this.neg.toJSON(),
    };
  }
}

interface ORSetEntry<T> {
  value: T;
  tags: Set<string>;
}

export class ORSet<T> {
  private readonly additions = new Map<string, ORSetEntry<T>>();
  private readonly removals = new Map<string, Set<string>>();

  add(element: T, tag: string): void {
    const key = stableSerialize(element);
    const current = this.additions.get(key);

    if (current) {
      current.tags.add(tag);
      return;
    }

    this.additions.set(key, {
      value: cloneValue(element),
      tags: new Set([tag]),
    });
  }

  remove(element: T, _tag: string): void {
    const key = stableSerialize(element);
    const current = this.additions.get(key);

    if (!current) {
      return;
    }

    const removed = this.removals.get(key) ?? new Set<string>();
    for (const observedTag of current.tags) {
      removed.add(observedTag);
    }

    this.removals.set(key, removed);
  }

  has(element: T): boolean {
    const key = stableSerialize(element);
    const current = this.additions.get(key);

    if (!current) {
      return false;
    }

    const removed = this.removals.get(key) ?? new Set<string>();
    return Array.from(current.tags).some((tag) => !removed.has(tag));
  }

  get value(): Set<T> {
    const active = new Set<T>();

    for (const [key, entry] of this.additions.entries()) {
      const removed = this.removals.get(key) ?? new Set<string>();
      if (Array.from(entry.tags).some((tag) => !removed.has(tag))) {
        active.add(cloneValue(entry.value));
      }
    }

    return active;
  }

  merge(other: ORSet<T>): ORSet<T> {
    const merged = this.clone();

    for (const [key, entry] of other.additions.entries()) {
      const current = merged.additions.get(key);
      if (!current) {
        merged.additions.set(key, {
          value: cloneValue(entry.value),
          tags: new Set(entry.tags),
        });
      } else {
        for (const tag of entry.tags) {
          current.tags.add(tag);
        }
      }
    }

    for (const [key, tags] of other.removals.entries()) {
      const removed = merged.removals.get(key) ?? new Set<string>();
      for (const tag of tags) {
        removed.add(tag);
      }
      merged.removals.set(key, removed);
    }

    return merged;
  }

  clone(): ORSet<T> {
    const cloned = new ORSet<T>();

    for (const [key, entry] of this.additions.entries()) {
      cloned.additions.set(key, {
        value: cloneValue(entry.value),
        tags: new Set(entry.tags),
      });
    }

    for (const [key, tags] of this.removals.entries()) {
      cloned.removals.set(key, new Set(tags));
    }

    return cloned;
  }

  toJSON(): SerializedORSet<T> {
    const additions = Array.from(this.additions.entries())
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([, entry]) => ({
        value: serializeCrdtValue(cloneValue(entry.value)) as T,
        tags: Array.from(entry.tags).sort(),
      }));

    const removals = Object.fromEntries(
      sortEntries(this.removals.entries()).map(([key, tags]) => [key, Array.from(tags).sort()])
    );

    return {
      __crdtType: 'ORSet',
      additions,
      removals,
    };
  }
}

interface LWWMapRecord<K, V> {
  key: K;
  value: V;
  nodeId: string;
  timestamp: number;
  clock: VectorClock;
}

function pickLwwWinner<K, V>(left: LWWMapRecord<K, V>, right: LWWMapRecord<K, V>): LWWMapRecord<K, V> {
  if (left.clock.happensBefore(right.clock)) {
    return right;
  }

  if (right.clock.happensBefore(left.clock)) {
    return left;
  }

  if (left.timestamp !== right.timestamp) {
    return left.timestamp > right.timestamp ? left : right;
  }

  if (left.nodeId !== right.nodeId) {
    return left.nodeId > right.nodeId ? left : right;
  }

  return left;
}

function tryMergeRecordValues<K, V>(left: LWWMapRecord<K, V>, right: LWWMapRecord<K, V>): LWWMapRecord<K, V> {
  const mergedValue = mergeCrdtValues(left.value, right.value);
  if (mergedValue !== undefined) {
    const winner = pickLwwWinner(left, right);
    return {
      key: cloneValue(winner.key),
      value: mergedValue as V,
      nodeId: winner.nodeId,
      timestamp: Math.max(left.timestamp, right.timestamp),
      clock: left.clock.merge(right.clock),
    };
  }

  const winner = pickLwwWinner(left, right);
  return {
    key: cloneValue(winner.key),
    value: cloneValue(winner.value),
    nodeId: winner.nodeId,
    timestamp: winner.timestamp,
    clock: winner.clock.clone(),
  };
}

export class LWWMap<K, V> {
  private readonly entries = new Map<string, LWWMapRecord<K, V>>();

  set(key: K, value: V, nodeId: string, timestamp: number, clock: VectorClock): void {
    this.entries.set(stableSerialize(key), {
      key: cloneValue(key),
      value: cloneValue(value),
      nodeId,
      timestamp,
      clock: clock.clone(),
    });
  }

  get(key: K): V | undefined {
    const record = this.entries.get(stableSerialize(key));
    return record ? cloneValue(record.value) : undefined;
  }

  merge(other: LWWMap<K, V>): LWWMap<K, V> {
    const merged = this.clone();

    for (const [key, otherRecord] of other.entries.entries()) {
      const current = merged.entries.get(key);
      if (!current) {
        merged.entries.set(key, {
          key: cloneValue(otherRecord.key),
          value: cloneValue(otherRecord.value),
          nodeId: otherRecord.nodeId,
          timestamp: otherRecord.timestamp,
          clock: otherRecord.clock.clone(),
        });
        continue;
      }

      merged.entries.set(key, tryMergeRecordValues(current, otherRecord));
    }

    return merged;
  }

  clone(): LWWMap<K, V> {
    const cloned = new LWWMap<K, V>();
    for (const [key, record] of this.entries.entries()) {
      cloned.entries.set(key, {
        key: cloneValue(record.key),
        value: cloneValue(record.value),
        nodeId: record.nodeId,
        timestamp: record.timestamp,
        clock: record.clock.clone(),
      });
    }
    return cloned;
  }

  toJSON(): SerializedLWWMap<K, V> {
    const entries = Array.from(this.entries.values())
      .sort((left, right) => stableSerialize(left.key).localeCompare(stableSerialize(right.key)))
      .map((record) => ({
        key: serializeCrdtValue(cloneValue(record.key)) as K,
        value: serializeCrdtValue(cloneValue(record.value)) as V,
        nodeId: record.nodeId,
        timestamp: record.timestamp,
        clock: record.clock.toJSON(),
      }));

    return {
      __crdtType: 'LWWMap',
      entries,
    };
  }
}

export function isCRDTValue(value: unknown): value is CrdtValue {
  return value instanceof GCounter || value instanceof PNCounter || value instanceof ORSet || value instanceof LWWMap;
}

export function mergeCrdtValues<T>(left: T, right: T): T | undefined {
  if (left instanceof GCounter && right instanceof GCounter) {
    return left.merge(right) as T;
  }

  if (left instanceof PNCounter && right instanceof PNCounter) {
    return left.merge(right) as T;
  }

  if (left instanceof ORSet && right instanceof ORSet) {
    return left.merge(right as ORSet<unknown>) as T;
  }

  if (left instanceof LWWMap && right instanceof LWWMap) {
    return left.merge(right as LWWMap<unknown, unknown>) as T;
  }

  return undefined;
}

export function serializeCrdtValue<T>(value: T): T | SerializedCRDTValue {
  if (value instanceof GCounter || value instanceof PNCounter || value instanceof ORSet || value instanceof LWWMap) {
    return value.toJSON() as SerializedCRDTValue;
  }

  if (Array.isArray(value)) {
    return value.map((entry) => serializeCrdtValue(entry)) as T;
  }

  if (isRecord(value)) {
    const serialized: Record<string, unknown> = {};
    for (const [key, entryValue] of Object.entries(value)) {
      serialized[key] = serializeCrdtValue(entryValue);
    }
    return serialized as T;
  }

  return value;
}

export function deserializeCrdtValue<T>(value: T): T {
  if (Array.isArray(value)) {
    return value.map((entry) => deserializeCrdtValue(entry)) as T;
  }

  if (!isRecord(value)) {
    return value;
  }

  const crdtType = value['__crdtType'];
  if (crdtType === 'GCounter') {
    return new GCounter((value as unknown as SerializedGCounter).counts) as T;
  }

  if (crdtType === 'PNCounter') {
    const serialized = value as unknown as SerializedPNCounter;
    return new PNCounter(
      deserializeCrdtValue(serialized.pos) as unknown as GCounter,
      deserializeCrdtValue(serialized.neg) as unknown as GCounter
    ) as T;
  }

  if (crdtType === 'ORSet') {
    const serialized = value as unknown as SerializedORSet<unknown>;
    const set = new ORSet<unknown>();
    for (const addition of serialized.additions) {
      for (const tag of addition.tags) {
        set.add(deserializeCrdtValue(addition.value), tag);
      }
    }
    for (const [key, tags] of Object.entries(serialized.removals)) {
      (set as unknown as { removals: Map<string, Set<string>> }).removals.set(key, new Set(tags));
    }
    return set as T;
  }

  if (crdtType === 'LWWMap') {
    const serialized = value as unknown as SerializedLWWMap<unknown, unknown>;
    const map = new LWWMap<unknown, unknown>();
    for (const entry of serialized.entries) {
      map.set(
        deserializeCrdtValue(entry.key),
        deserializeCrdtValue(entry.value),
        entry.nodeId,
        entry.timestamp,
        new VectorClock(entry.clock)
      );
    }
    return map as T;
  }

  const deserialized: Record<string, unknown> = {};
  for (const [key, entryValue] of Object.entries(value)) {
    deserialized[key] = deserializeCrdtValue(entryValue);
  }
  return deserialized as T;
}

export function compareSerializableValues(left: unknown, right: unknown): boolean {
  return stableSerialize(serializeCrdtValue(left)) === stableSerialize(serializeCrdtValue(right));
}

export function choosePreferredStrategy(
  current: 'crdt' | 'lww' | 'none',
  next: 'crdt' | 'lww' | 'none'
): 'crdt' | 'lww' | 'none' {
  return mergeStrategyRank(next) > mergeStrategyRank(current) ? next : current;
}
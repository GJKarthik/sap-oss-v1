// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import type {
  ColoredToken,
  CpnNetDefinition,
  RunResult,
  TraceEntry,
  TransitionDef,
} from './types';

function stableTokenKey(t: ColoredToken): string {
  return JSON.stringify({
    c: t.color ?? null,
    p: t.payload ?? {},
  });
}

function tokensEqual(a: ColoredToken, b: ColoredToken): boolean {
  return stableTokenKey(a) === stableTokenKey(b);
}

function getPath(obj: Record<string, unknown> | undefined, path: string): unknown {
  if (!obj) return undefined;
  const parts = path.split('.').filter(Boolean);
  let cur: unknown = obj;
  for (const p of parts) {
    if (cur === null || cur === undefined || typeof cur !== 'object') return undefined;
    cur = (cur as Record<string, unknown>)[p];
  }
  return cur;
}

function evaluateGuard(
  guard: TransitionDef['guard'],
  mergedPayload: Record<string, unknown>,
): boolean {
  if (!guard?.all?.length) return true;
  for (const clause of guard.all) {
    const v = getPath(mergedPayload, clause.path);
    if (clause.op === 'eq' && v !== clause.value) return false;
    if (clause.op === 'neq' && v === clause.value) return false;
  }
  return true;
}

function mergePayload(
  base: Record<string, unknown> | undefined,
  patch: Record<string, unknown> | undefined,
): Record<string, unknown> {
  return { ...(base ?? {}), ...(patch ?? {}) };
}

/**
 * Colored Petri net runtime: places hold multisets of tokens; transitions consume/produce
 * with optional guards over merged input token payloads.
 */
export class CpnEngine {
  private net: CpnNetDefinition | null = null;
  private marking: Map<string, ColoredToken[]> = new Map();

  loadNet(def: CpnNetDefinition): void {
    for (const p of def.places) {
      if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(p)) {
        throw new Error(`Invalid place id: ${p}`);
      }
    }
    const placeSet = new Set(def.places);
    for (const t of def.transitions) {
      for (const a of t.inputArcs) {
        if (!placeSet.has(a.place)) throw new Error(`Unknown input place ${a.place} for ${t.id}`);
        if (a.weight < 1) throw new Error(`Arc weight must be >= 1 (${t.id})`);
      }
      for (const a of t.outputArcs) {
        if (!placeSet.has(a.place)) throw new Error(`Unknown output place ${a.place} for ${t.id}`);
        if (a.weight < 1) throw new Error(`Output arc weight must be >= 1 (${t.id})`);
      }
    }
    this.net = def;
    this.reset();
  }

  reset(): void {
    if (!this.net) return;
    this.marking = new Map();
    for (const p of this.net.places) {
      this.marking.set(p, []);
    }
    for (const [place, tokens] of Object.entries(this.net.initialMarking)) {
      if (!this.marking.has(place)) {
        throw new Error(`initialMarking references unknown place: ${place}`);
      }
      this.marking.set(place, tokens.map((t) => ({ ...t, payload: { ...(t.payload ?? {}) } })));
    }
  }

  getNetId(): string | null {
    return this.net?.id ?? null;
  }

  markingSnapshot(): Record<string, ColoredToken[]> {
    const out: Record<string, ColoredToken[]> = {};
    this.marking.forEach((tokens, place) => {
      out[place] = tokens.map((t) => ({
        color: t.color,
        payload: t.payload ? { ...t.payload } : undefined,
      }));
    });
    return out;
  }

  /**
   * Try to pick multiset of tokens from `place` matching `pattern` (undefined = any token).
   * Returns null if not enough matching tokens.
   */
  private takeTokens(
    place: string,
    weight: number,
    pattern: ColoredToken | undefined,
    work: Map<string, ColoredToken[]>,
  ): ColoredToken[] | null {
    const bag = work.get(place);
    if (!bag || bag.length < weight) return null;
    const picked: ColoredToken[] = [];
    const remaining: ColoredToken[] = [];
    const pat = pattern;
    for (const tok of bag) {
      if (picked.length >= weight) {
        remaining.push(tok);
        continue;
      }
      if (!pat || tokensEqual(tok, pat)) {
        picked.push(tok);
      } else {
        remaining.push(tok);
      }
    }
    if (picked.length < weight) return null;
    work.set(place, remaining);
    return picked;
  }

  private canFireTransition(tr: TransitionDef, work: Map<string, ColoredToken[]>): boolean {
    const consumed: ColoredToken[] = [];
    const trial = new Map<string, ColoredToken[]>();
    work.forEach((v, k) => trial.set(k, [...v]));

    for (const arc of tr.inputArcs) {
      const bag = trial.get(arc.place);
      if (!bag || bag.length < arc.weight) return false;
      const taken = this.takeTokens(arc.place, arc.weight, undefined, trial);
      if (!taken) return false;
      consumed.push(...taken);
    }

    const merged: Record<string, unknown> = {};
    for (const t of consumed) {
      Object.assign(merged, t.payload ?? {});
    }
    return evaluateGuard(tr.guard, merged);
  }

  /** Apply appId (and optional extra payload) to every token in initial marking places. */
  seedInitialWithApp(net: CpnNetDefinition, appId: string, extra?: Record<string, unknown>): void {
    const seeded: Record<string, ColoredToken[]> = {};
    for (const [place, tokens] of Object.entries(net.initialMarking)) {
      seeded[place] = tokens.map((t) => ({
        color: t.color,
        payload: { appId, ...(t.payload ?? {}), ...(extra ?? {}) },
      }));
    }
    this.loadNet({ ...net, initialMarking: seeded });
  }

  enabledTransitions(): string[] {
    if (!this.net) return [];
    const work = new Map<string, ColoredToken[]>();
    this.marking.forEach((v, k) => work.set(k, [...v]));
    const enabled: string[] = [];
    for (const tr of this.net.transitions) {
      if (this.canFireTransition(tr, work)) enabled.push(tr.id);
    }
    return enabled;
  }

  /**
   * Fire one occurrence of transition. Atomic: rollback if guard fails after consume (should not happen if enabled check used same logic).
   */
  fire(transitionId: string): { ok: boolean; error?: string } {
    if (!this.net) return { ok: false, error: 'No net loaded' };
    const tr = this.net.transitions.find((t) => t.id === transitionId);
    if (!tr) return { ok: false, error: `Unknown transition: ${transitionId}` };

    const snapshot = new Map<string, ColoredToken[]>();
    this.marking.forEach((v, k) => snapshot.set(k, [...v]));

    const consumed: ColoredToken[] = [];
    for (const arc of tr.inputArcs) {
      const taken = this.takeTokens(arc.place, arc.weight, undefined, snapshot);
      if (!taken) {
        return { ok: false, error: `Insufficient tokens in ${arc.place} for ${transitionId}` };
      }
      consumed.push(...taken);
    }

    const merged: Record<string, unknown> = {};
    for (const t of consumed) {
      Object.assign(merged, t.payload ?? {});
    }
    if (!evaluateGuard(tr.guard, merged)) {
      return { ok: false, error: `Guard failed for transition ${transitionId}` };
    }

    const basePayload = consumed[0]?.payload ?? {};
    for (const arc of tr.outputArcs) {
      const newTok: ColoredToken = {
        color: consumed[0]?.color,
        payload: mergePayload(basePayload, arc.payloadPatch),
      };
      const bag = snapshot.get(arc.place) ?? [];
      for (let i = 0; i < arc.weight; i++) {
        bag.push({
          color: newTok.color,
          payload: { ...(newTok.payload ?? {}) },
        });
      }
      snapshot.set(arc.place, bag);
    }

    this.marking = snapshot;
    return { ok: true };
  }

  run(options: {
    mode: 'max' | 'until';
    maxSteps?: number;
    untilPlace?: string;
    /** Stop when this place has at least one token. */
  }): RunResult {
    if (!this.net) {
      return {
        status: 'failed',
        trace: [],
        finalMarking: {},
        message: 'No net loaded',
      };
    }

    const maxSteps = options.maxSteps ?? 10_000;
    const trace: TraceEntry[] = [];
    let steps = 0;

    while (steps < maxSteps) {
      const enabled = this.enabledTransitions();
      if (enabled.length === 0) {
        return {
          status: options.mode === 'until' && options.untilPlace ? 'blocked' : 'completed',
          trace,
          finalMarking: this.markingSnapshot(),
          message:
            enabled.length === 0 && options.untilPlace
              ? 'Deadlock or target not reached'
              : undefined,
        };
      }

      const pick = enabled[0]!;
      const fr = this.fire(pick);
      if (!fr.ok) {
        return {
          status: 'failed',
          trace,
          finalMarking: this.markingSnapshot(),
          message: fr.error,
        };
      }
      trace.push({ transitionId: pick, markingAfter: this.markingSnapshot() });
      steps++;

      if (options.mode === 'until' && options.untilPlace) {
        const bag = this.marking.get(options.untilPlace);
        if (bag && bag.length > 0) {
          return {
            status: 'completed',
            trace,
            finalMarking: this.markingSnapshot(),
          };
        }
      }
    }

    return {
      status: 'maxSteps',
      trace,
      finalMarking: this.markingSnapshot(),
      message: `Stopped after ${maxSteps} steps`,
    };
  }
}

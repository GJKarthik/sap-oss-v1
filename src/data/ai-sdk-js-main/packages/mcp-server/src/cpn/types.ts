// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

/** Colored token: multiset element with optional color and JSON payload. */
export interface ColoredToken {
  color?: string;
  payload?: Record<string, unknown>;
}

export interface ArcPT {
  place: string;
  weight: number;
}

/** Clause: payload[path] === value (path is dot-separated). */
export interface GuardClause {
  path: string;
  op: 'eq' | 'neq';
  value: unknown;
}

export interface TransitionGuard {
  all?: GuardClause[];
}

export interface TransitionDef {
  id: string;
  inputArcs: ArcPT[];
  outputArcs: Array<{
    place: string;
    weight: number;
    /** Shallow-merge onto the first consumed token's payload for produced tokens. */
    payloadPatch?: Record<string, unknown>;
  }>;
  guard?: TransitionGuard;
}

export interface CpnNetDefinition {
  id: string;
  places: string[];
  transitions: TransitionDef[];
  /** Place id -> initial tokens (multiset as list). */
  initialMarking: Record<string, ColoredToken[]>;
}

export interface TraceEntry {
  transitionId: string;
  markingAfter: Record<string, ColoredToken[]>;
}

export type RunStatus = 'completed' | 'blocked' | 'maxSteps' | 'failed';

export interface RunResult {
  status: RunStatus;
  trace: TraceEntry[];
  finalMarking: Record<string, ColoredToken[]>;
  message?: string;
}

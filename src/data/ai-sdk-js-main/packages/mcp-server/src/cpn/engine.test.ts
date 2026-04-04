// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { CpnEngine } from './engine';
import { odpsCloseProcessNet } from './nets/odps-close-process';

describe('CpnEngine', () => {
  it('computes enabled transitions for ODPS close-process net', () => {
    const e = new CpnEngine();
    e.seedInitialWithApp(odpsCloseProcessNet, 'app-a');
    expect(e.enabledTransitions()).toEqual(['advance_S01_to_S02']);
  });

  it('fires transitions and updates stage in token payload', () => {
    const e = new CpnEngine();
    e.seedInitialWithApp(odpsCloseProcessNet, 'app-b');
    expect(e.fire('advance_S01_to_S02').ok).toBe(true);
    const m = e.markingSnapshot();
    expect(m.opened).toEqual([]);
    expect(m.after_maker_checker).toHaveLength(1);
    expect(m.after_maker_checker![0]!.payload?.stage).toBe('S02');
    expect(m.after_maker_checker![0]!.payload?.appId).toBe('app-b');
  });

  it('guard blocks wrong stage', () => {
    const e = new CpnEngine();
    e.loadNet({
      id: 'g',
      places: ['p1', 'p2'],
      transitions: [
        {
          id: 't_bad',
          inputArcs: [{ place: 'p1', weight: 1 }],
          outputArcs: [{ place: 'p2', weight: 1 }],
          guard: { all: [{ path: 'x', op: 'eq', value: 1 }] },
        },
      ],
      initialMarking: { p1: [{ payload: { x: 0 } }] },
    });
    expect(e.enabledTransitions()).toEqual([]);
    expect(e.fire('t_bad').ok).toBe(false);
  });

  it('run(max) completes linear ODPS net', () => {
    const e = new CpnEngine();
    e.seedInitialWithApp(odpsCloseProcessNet, 'app-c');
    const r = e.run({ mode: 'max', maxSteps: 100 });
    expect(r.status).toBe('completed');
    expect(r.trace).toHaveLength(2);
    expect(r.trace[0]!.transitionId).toBe('advance_S01_to_S02');
    expect(r.trace[1]!.transitionId).toBe('advance_S02_to_S03');
    const closed = r.finalMarking.closed;
    expect(closed).toHaveLength(1);
    expect(closed![0]!.payload?.stage).toBe('S03');
  });

  it('run(until) stops when closed place is marked', () => {
    const e = new CpnEngine();
    e.seedInitialWithApp(odpsCloseProcessNet, 'app-d');
    const r = e.run({ mode: 'until', untilPlace: 'closed', maxSteps: 100 });
    expect(r.status).toBe('completed');
    expect(r.finalMarking.closed?.length).toBe(1);
  });
});

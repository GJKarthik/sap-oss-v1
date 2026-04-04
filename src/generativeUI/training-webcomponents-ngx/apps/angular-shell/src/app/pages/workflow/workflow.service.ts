import { Injectable, signal, computed, OnDestroy } from '@angular/core';
import {
  PetriNet, Place, Transition, Arc, Token, FiringEvent, ExecutionState,
  DesignerState, DesignerMode, DesignerTool,
  cloneNet, createToken, createId,
} from './workflow.models';
import { WORKFLOW_TEMPLATES } from './workflow-templates';
import { environment } from '../../../environments/environment';

const SPEED_MS: Record<string, number> = { slow: 1500, normal: 800, fast: 300 };

@Injectable()
export class WorkflowService implements OnDestroy {
  readonly net = signal<PetriNet>({ id: '', name: '', places: [], transitions: [], arcs: [] });
  readonly mode = signal<DesignerMode>('design');
  readonly exec = signal<ExecutionState>({
    running: false, speed: 'normal', history: [], deadlock: false, stepCount: 0,
  });
  readonly designer = signal<DesignerState>({
    tool: 'select', selectedId: null, selectedType: null,
    undoStack: [], redoStack: [], arcSourceId: null, arcSourceType: null,
  });

  readonly enabledTransitions = computed(() => {
    const n = this.net();
    return n.transitions.filter(t => this.isEnabled(t, n));
  });

  private timerId: ReturnType<typeof setInterval> | null = null;
  private ws: WebSocket | null = null;

  ngOnDestroy(): void { this.stopExecution(); this.disconnectWs(); }

  /* --- Designer helpers --- */
  pushUndo(): void {
    const d = this.designer();
    this.designer.set({ ...d, undoStack: [...d.undoStack, cloneNet(this.net())], redoStack: [] });
  }

  undo(): void {
    const d = this.designer();
    if (!d.undoStack.length) return;
    const prev = d.undoStack[d.undoStack.length - 1];
    this.designer.set({ ...d, undoStack: d.undoStack.slice(0, -1), redoStack: [...d.redoStack, cloneNet(this.net())] });
    this.net.set(prev);
  }

  redo(): void {
    const d = this.designer();
    if (!d.redoStack.length) return;
    const next = d.redoStack[d.redoStack.length - 1];
    this.designer.set({ ...d, redoStack: d.redoStack.slice(0, -1), undoStack: [...d.undoStack, cloneNet(this.net())] });
    this.net.set(next);
  }

  setTool(tool: DesignerTool): void {
    this.designer.update(d => ({ ...d, tool, arcSourceId: null, arcSourceType: null }));
  }

  selectElement(id: string | null, type: 'place' | 'transition' | 'arc' | null): void {
    this.designer.update(d => ({ ...d, selectedId: id, selectedType: type }));
  }

  loadTemplate(templateId: string): void {
    const tpl = WORKFLOW_TEMPLATES.find(t => t.id === templateId);
    if (tpl) { this.pushUndo(); this.net.set(tpl.build()); }
  }

  /* --- Execution engine --- */
  private isEnabled(t: Transition, n: PetriNet): boolean {
    const inArcs = n.arcs.filter(a => a.targetId === t.id && a.sourceType === 'place');
    return inArcs.every(a => {
      const p = n.places.find(pl => pl.id === a.sourceId);
      if (!p) return false;
      return a.inhibitor ? p.tokens.length === 0 : p.tokens.length >= a.weight;
    });
  }

  fireTransition(transitionId: string): FiringEvent | null {
    const n = cloneNet(this.net());
    const t = n.transitions.find(tr => tr.id === transitionId);
    if (!t || !this.isEnabled(t, n)) return null;

    const consumed: FiringEvent['consumedTokens'] = [];
    const produced: FiringEvent['producedTokens'] = [];

    const inArcs = n.arcs.filter(a => a.targetId === t.id && a.sourceType === 'place' && !a.inhibitor);
    for (const a of inArcs) {
      const p = n.places.find(pl => pl.id === a.sourceId)!;
      const taken = p.tokens.splice(0, a.weight);
      consumed.push({ placeId: p.id, tokenIds: taken.map(tk => tk.id) });
    }

    const outArcs = n.arcs.filter(a => a.sourceId === t.id && a.sourceType === 'transition');
    for (const a of outArcs) {
      const p = n.places.find(pl => pl.id === a.targetId)!;
      const newTokens: Token[] = [];
      for (let i = 0; i < a.weight; i++) {
        const tk = createToken(p.tokenType);
        newTokens.push(tk);
        if (p.tokens.length < p.capacity) p.tokens.push(tk);
      }
      produced.push({ placeId: p.id, tokens: newTokens });
    }

    t.state = 'firing';
    n.transitions.forEach(tr => { if (tr.id !== t.id) tr.state = this.isEnabled(tr, n) ? 'enabled' : 'disabled'; });
    this.net.set(n);

    const ev: FiringEvent = { transitionId, timestamp: Date.now(), consumedTokens: consumed, producedTokens: produced };
    this.exec.update(e => ({ ...e, history: [...e.history, ev], stepCount: e.stepCount + 1 }));

    setTimeout(() => {
      const cur = cloneNet(this.net());
      const tr = cur.transitions.find(x => x.id === transitionId);
      if (tr) tr.state = this.isEnabled(tr, cur) ? 'enabled' : 'disabled';
      cur.transitions.forEach(x => { x.state = this.isEnabled(x, cur) ? 'enabled' : 'disabled'; });
      const deadlock = cur.transitions.every(x => x.state === 'disabled');
      this.net.set(cur);
      this.exec.update(e => ({ ...e, deadlock }));
    }, 400);

    return ev;
  }

  step(): void {
    const enabled = this.enabledTransitions();
    if (enabled.length) this.fireTransition(enabled[0].id);
  }

  play(): void {
    this.exec.update(e => ({ ...e, running: true, deadlock: false }));
    this.updateTransitionStates();
    this.scheduleNext();
  }

  pause(): void { this.exec.update(e => ({ ...e, running: false })); this.clearTimer(); }

  reset(): void {
    this.stopExecution();
    const d = this.designer();
    if (d.undoStack.length) this.net.set(d.undoStack[0]);
    this.exec.set({ running: false, speed: 'normal', history: [], deadlock: false, stepCount: 0 });
  }

  setSpeed(speed: 'slow' | 'normal' | 'fast'): void {
    this.exec.update(e => ({ ...e, speed }));
    if (this.exec().running) { this.clearTimer(); this.scheduleNext(); }
  }

  private scheduleNext(): void {
    this.clearTimer();
    this.timerId = setInterval(() => {
      if (!this.exec().running || this.exec().deadlock) { this.clearTimer(); return; }
      this.step();
    }, SPEED_MS[this.exec().speed]);
  }

  private clearTimer(): void { if (this.timerId) { clearInterval(this.timerId); this.timerId = null; } }
  private stopExecution(): void { this.pause(); }
  private updateTransitionStates(): void {
    const n = cloneNet(this.net());
    n.transitions.forEach(t => { t.state = this.isEnabled(t, n) ? 'enabled' : 'disabled'; });
    this.net.set(n);
  }

  /* --- WebSocket --- */
  connectWs(netId: string): void {
    this.disconnectWs();
    const base = environment.apiBaseUrl.replace(/^http/, 'ws');
    try {
      this.ws = new WebSocket(`${base}/api/cpn/nets/${netId}/stream`);
      this.ws.onmessage = (e) => {
        try { const ev = JSON.parse(e.data) as FiringEvent; this.fireTransition(ev.transitionId); } catch {}
      };
    } catch {}
  }

  disconnectWs(): void { if (this.ws) { this.ws.close(); this.ws = null; } }

  /* --- Export / Import --- */
  exportJson(): string { return JSON.stringify(this.net(), null, 2); }

  importJson(json: string): boolean {
    try { const n = JSON.parse(json) as PetriNet; if (n.places && n.transitions && n.arcs) { this.pushUndo(); this.net.set(n); return true; } } catch {}
    return false;
  }
}

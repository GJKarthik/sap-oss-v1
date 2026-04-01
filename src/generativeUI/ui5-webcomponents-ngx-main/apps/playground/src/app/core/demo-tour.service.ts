import { Injectable } from '@angular/core';
import { BehaviorSubject } from 'rxjs';

export interface DemoTourStep {
  route: '/generative' | '/joule' | '/components' | '/mcp';
  label: string;
}

interface DemoTourState {
  active: boolean;
  index: number;
}

@Injectable({ providedIn: 'root' })
export class DemoTourService {
  readonly steps: DemoTourStep[] = [
    { route: '/generative', label: 'Generative Renderer' },
    { route: '/joule', label: 'Joule Chat' },
    { route: '/components', label: 'Component Playground' },
    { route: '/mcp', label: 'MCP Flow' },
  ];

  private readonly state$ = new BehaviorSubject<DemoTourState>({
    active: false,
    index: 0,
  });

  get active(): boolean {
    return this.state$.value.active;
  }

  get currentIndex(): number {
    return this.state$.value.index;
  }

  get currentStep(): DemoTourStep | null {
    if (!this.active) {
      return null;
    }
    return this.steps[this.currentIndex] ?? null;
  }

  start(): DemoTourStep {
    this.state$.next({ active: true, index: 0 });
    return this.steps[0];
  }

  next(): DemoTourStep | null {
    if (!this.active) {
      return null;
    }

    const nextIndex = this.currentIndex + 1;
    if (nextIndex >= this.steps.length) {
      this.stop();
      return null;
    }

    this.state$.next({ active: true, index: nextIndex });
    return this.steps[nextIndex];
  }

  stop(): void {
    this.state$.next({ active: false, index: 0 });
  }

  syncWithUrl(url: string): void {
    if (!this.active) {
      return;
    }
    const cleanUrl = url.split('?')[0];
    const index = this.steps.findIndex((step) => cleanUrl.startsWith(step.route));
    if (index >= 0 && index !== this.currentIndex) {
      this.state$.next({ active: true, index });
    }
  }
}

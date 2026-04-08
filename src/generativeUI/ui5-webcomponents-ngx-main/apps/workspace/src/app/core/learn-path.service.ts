import { Injectable } from '@angular/core';
import { BehaviorSubject } from 'rxjs';

export interface LearnPathStep {
  route: '/generative' | '/joule' | '/components' | '/mcp';
  label: string;
}

interface LearnPathState {
  active: boolean;
  index: number;
}

@Injectable({ providedIn: 'root' })
export class LearnPathService {
  readonly steps: LearnPathStep[] = [
    { route: '/generative', label: 'UI Composer' },
    { route: '/joule', label: 'Joule' },
    { route: '/components', label: 'Model Catalog' },
    { route: '/mcp', label: 'Tooling' },
  ];

  private readonly state$ = new BehaviorSubject<LearnPathState>({
    active: false,
    index: 0,
  });

  get active(): boolean {
    return this.state$.value.active;
  }

  get currentIndex(): number {
    return this.state$.value.index;
  }

  get currentStep(): LearnPathStep | null {
    if (!this.active) {
      return null;
    }
    return this.steps[this.currentIndex] ?? null;
  }

  start(): LearnPathStep {
    this.state$.next({ active: true, index: 0 });
    return this.steps[0];
  }

  next(): LearnPathStep | null {
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

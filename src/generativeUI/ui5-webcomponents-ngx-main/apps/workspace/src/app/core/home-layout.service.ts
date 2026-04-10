import { Injectable, computed, signal } from '@angular/core';

export type HomeWidgetId =
  | 'journeys'
  | 'quickAccess'
  | 'productAreas'
  | 'serviceHealth'
  | 'productFamily';

interface HomeLayoutState {
  order: HomeWidgetId[];
  hidden: HomeWidgetId[];
}

const STORAGE_KEY = 'sap-ai-experience.home-layout.v1';
const DEFAULT_ORDER: HomeWidgetId[] = [
  'journeys',
  'quickAccess',
  'productAreas',
  'serviceHealth',
  'productFamily',
];

const DEFAULT_STATE: HomeLayoutState = {
  order: DEFAULT_ORDER,
  hidden: [],
};

@Injectable({ providedIn: 'root' })
export class HomeLayoutService {
  private readonly state = signal<HomeLayoutState>(this.loadState());

  readonly orderedWidgets = computed(() =>
    this.state().order.filter((widgetId) => !this.state().hidden.includes(widgetId)),
  );

  isVisible(widgetId: HomeWidgetId): boolean {
    return !this.state().hidden.includes(widgetId);
  }

  toggleVisibility(widgetId: HomeWidgetId): void {
    const hidden = this.state().hidden.includes(widgetId)
      ? this.state().hidden.filter((id) => id !== widgetId)
      : [...this.state().hidden, widgetId];
    this.persist({ ...this.state(), hidden });
  }

  move(widgetId: HomeWidgetId, direction: 'up' | 'down'): void {
    const order = [...this.state().order];
    const currentIndex = order.indexOf(widgetId);
    if (currentIndex === -1) {
      return;
    }

    const targetIndex = direction === 'up' ? currentIndex - 1 : currentIndex + 1;
    if (targetIndex < 0 || targetIndex >= order.length) {
      return;
    }

    [order[currentIndex], order[targetIndex]] = [order[targetIndex], order[currentIndex]];
    this.persist({ ...this.state(), order });
  }

  reset(): void {
    this.persist(DEFAULT_STATE);
  }

  private persist(state: HomeLayoutState): void {
    this.state.set(state);
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch {
      // storage unavailable
    }
  }

  private loadState(): HomeLayoutState {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) {
        return DEFAULT_STATE;
      }

      const parsed = JSON.parse(raw) as Partial<HomeLayoutState>;
      const order = Array.isArray(parsed.order)
        ? DEFAULT_ORDER.filter((id) => parsed.order?.includes(id))
        : DEFAULT_ORDER;

      return {
        order: order.length === DEFAULT_ORDER.length ? order : DEFAULT_ORDER,
        hidden: Array.isArray(parsed.hidden)
          ? parsed.hidden.filter((id): id is HomeWidgetId => DEFAULT_ORDER.includes(id as HomeWidgetId))
          : [],
      };
    } catch {
      return DEFAULT_STATE;
    }
  }
}

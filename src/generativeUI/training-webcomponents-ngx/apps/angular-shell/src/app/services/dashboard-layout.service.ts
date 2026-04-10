import { Injectable, computed, signal } from '@angular/core';

export type DashboardWidgetId =
  | 'hubMap'
  | 'quickAccess'
  | 'liveSignals'
  | 'priorityActions'
  | 'productFamily';

interface DashboardLayoutState {
  order: DashboardWidgetId[];
  hidden: DashboardWidgetId[];
}

const STORAGE_KEY = 'training.dashboard.layout.v1';
const DEFAULT_ORDER: DashboardWidgetId[] = [
  'hubMap',
  'priorityActions',
  'quickAccess',
  'liveSignals',
  'productFamily',
];

const DEFAULT_STATE: DashboardLayoutState = {
  order: DEFAULT_ORDER,
  hidden: [],
};

@Injectable({ providedIn: 'root' })
export class DashboardLayoutService {
  private readonly state = signal<DashboardLayoutState>(this.loadState());

  readonly orderedWidgets = computed(() =>
    this.state().order.filter((widgetId) => !this.state().hidden.includes(widgetId)),
  );

  isVisible(widgetId: DashboardWidgetId): boolean {
    return !this.state().hidden.includes(widgetId);
  }

  toggleVisibility(widgetId: DashboardWidgetId): void {
    const hidden = this.state().hidden.includes(widgetId)
      ? this.state().hidden.filter((id) => id !== widgetId)
      : [...this.state().hidden, widgetId];
    this.persist({ ...this.state(), hidden });
  }

  move(widgetId: DashboardWidgetId, direction: 'up' | 'down'): void {
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

  private persist(state: DashboardLayoutState): void {
    this.state.set(state);
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch {
      // storage unavailable
    }
  }

  private loadState(): DashboardLayoutState {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) {
        return DEFAULT_STATE;
      }

      const parsed = JSON.parse(raw) as Partial<DashboardLayoutState>;
      const order = Array.isArray(parsed.order)
        ? DEFAULT_ORDER.filter((id) => parsed.order?.includes(id))
        : DEFAULT_ORDER;

      return {
        order: order.length === DEFAULT_ORDER.length ? order : DEFAULT_ORDER,
        hidden: Array.isArray(parsed.hidden)
          ? parsed.hidden.filter((id): id is DashboardWidgetId => DEFAULT_ORDER.includes(id as DashboardWidgetId))
          : [],
      };
    } catch {
      return DEFAULT_STATE;
    }
  }
}

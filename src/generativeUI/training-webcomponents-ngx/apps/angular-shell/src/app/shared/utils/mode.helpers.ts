import { AppMode, ModeConfig, ModePill, ModeRelevance } from './mode.types';
import { MODE_CONFIG, MODE_PILLS, ALL_MODES, DEFAULT_MODE, MODE_STORAGE_KEY } from './mode.config';
import { TrainingRouteGroupId } from '../../app.navigation';

/** Get full config for a mode */
export function getModeConfig(mode: AppMode): ModeConfig {
  return MODE_CONFIG[mode];
}

/** Get pills visible in a given mode */
export function getPillsForMode(mode: AppMode): ModePill[] {
  return MODE_PILLS.filter(p => p.modes.includes(mode));
}

/** Get group relevance score (0.0–1.0) for a nav group in a mode */
export function getGroupRelevance(mode: AppMode, group: TrainingRouteGroupId): number {
  return MODE_CONFIG[mode].groupRelevance[group] ?? 0.5;
}

/** Get route relevance: uses route-level override if present, else falls back to group */
export function getRouteRelevance(
  mode: AppMode,
  group: TrainingRouteGroupId,
  routeRelevance?: ModeRelevance,
): number {
  if (routeRelevance && routeRelevance[mode] !== undefined) {
    return routeRelevance[mode]!;
  }
  return getGroupRelevance(mode, group);
}

/** Cycle to next mode */
export function nextMode(current: AppMode): AppMode {
  const idx = ALL_MODES.indexOf(current);
  return ALL_MODES[(idx + 1) % ALL_MODES.length];
}

/** Cycle to previous mode */
export function prevMode(current: AppMode): AppMode {
  const idx = ALL_MODES.indexOf(current);
  return ALL_MODES[(idx - 1 + ALL_MODES.length) % ALL_MODES.length];
}

/** Load persisted mode from localStorage */
export function loadPersistedMode(): AppMode {
  if (typeof localStorage === 'undefined') return DEFAULT_MODE;
  const stored = localStorage.getItem(MODE_STORAGE_KEY);
  if (stored && ALL_MODES.includes(stored as AppMode)) {
    return stored as AppMode;
  }
  return DEFAULT_MODE;
}

/** Persist mode to localStorage */
export function persistMode(mode: AppMode): void {
  if (typeof localStorage === 'undefined') return;
  localStorage.setItem(MODE_STORAGE_KEY, mode);
}

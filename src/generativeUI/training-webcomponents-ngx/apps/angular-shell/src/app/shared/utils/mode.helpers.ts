import { MODE_CONFIG, MODE_PILLS } from './mode.config';
import { TRAINING_ROUTE_LINKS } from '../../app.navigation';
import type { AppMode, AiCapabilities, RouteRelevance, ContextPill } from './mode.types';

export function getModeCapabilities(mode: AppMode): AiCapabilities {
  const config = MODE_CONFIG[mode];
  return {
    systemPromptPrefix: config.systemPromptPrefix,
    confirmationLevel: config.confirmationLevel,
  };
}

export function getRouteRelevance(mode: AppMode): RouteRelevance {
  return {
    suggested: TRAINING_ROUTE_LINKS
      .filter(r => r.modeRelevance.includes(mode))
      .map(r => r.path),
    all: TRAINING_ROUTE_LINKS.map(r => r.path),
  };
}

export function getContextPills(mode: AppMode): ContextPill[] {
  return MODE_PILLS[mode];
}

import { Injectable, computed, inject } from '@angular/core';
import { UserSettingsService, Persona } from './user-settings.service';
import { TRAINING_ROUTE_LINKS, TrainingRouteLink } from '../app.navigation';

const CORE_ROUTES = new Set(['/dashboard', '/chat', '/rag-studio']);

const PERSONA_ROUTES: Record<Persona, Set<string>> = {
  'analyst': new Set([
    ...CORE_ROUTES,
    '/data-explorer', '/schema-browser', '/data-quality', '/semantic-search',
    '/analytical-dashboard', '/analytics',
  ]),
  'data-engineer': new Set([
    ...CORE_ROUTES,
    '/data-explorer', '/schema-browser', '/data-cleaning', '/data-quality', '/lineage',
    '/vocab-search', '/pipeline', '/streaming',
  ]),
  'ml-engineer': new Set([
    ...CORE_ROUTES,
    '/model-optimizer', '/compare', '/registry', '/glossary-manager', '/document-ocr',
    '/semantic-search', '/pipeline', '/deployments', '/governance',
  ]),
  'developer': new Set(TRAINING_ROUTE_LINKS.map((r) => r.path)),
};

const TIER_BY_MODE: Record<string, Set<string>> = {
  novice: new Set(['primary']),
  intermediate: new Set(['primary', 'secondary']),
  expert: new Set(['primary', 'secondary', 'expert']),
};

@Injectable({ providedIn: 'root' })
export class PageVisibilityService {
  private readonly settings = inject(UserSettingsService);

  readonly visibleRoutes = computed<TrainingRouteLink[]>(() => {
    const persona = this.settings.persona();
    const mode = this.settings.mode();
    const allowed = PERSONA_ROUTES[persona];
    const tiers = TIER_BY_MODE[mode] ?? TIER_BY_MODE['expert'];
    return TRAINING_ROUTE_LINKS.filter(
      (link) => allowed.has(link.path) && tiers.has(link.tier),
    );
  });

  isRouteVisible(path: string): boolean {
    return this.visibleRoutes().some((r) => r.path === path);
  }
}

import { Injectable, computed, signal } from '@angular/core';
import {
  TRAINING_ROUTE_LINKS,
  TrainingRouteGroupId,
  TrainingRouteLink,
} from '../app.navigation';

interface QuickAccessState {
  pinnedPaths: string[];
  recentPaths: string[];
}

const STORAGE_KEY = 'training.quick-access.v1';
const RECENT_LIMIT = 8;

const ROUTE_SEARCH_TERMS: Record<string, string[]> = {
  '/dashboard': ['overview', 'home', 'status', 'health', 'platform'],
  '/data-products': ['data products', 'publish data', 'catalog', 'data assets', 'datasets', 'browse data'],
  '/data-cleaning': ['prepare data', 'clean data', 'fix records', 'sanitize'],
  '/schema-browser': ['schema', 'columns', 'structure', 'data model'],
  '/data-quality': ['quality checks', 'validate data', 'quality'],
  '/lineage': ['knowledge graph', 'memory graph', 'relationships', 'concepts', 'lineage', 'dependencies'],
  '/vocab-search': ['business terms', 'vocabulary', 'taxonomy'],
  '/chat': ['ask ai', 'assistant', 'conversation', 'copilot'],
  '/rag-studio': ['knowledge sources', 'personal knowledge', 'personal wiki', 'memory', 'rag', 'retrieval'],
  '/semantic-search': ['knowledge search', 'find documents', 'semantic lookup'],
  '/document-ocr': ['ocr', 'invoice extraction', 'document intake', 'extract invoice'],
  '/pal-workbench': ['business analysis', 'forecast', 'analysis'],
  '/sparql-explorer': ['linked data', 'sparql', 'graph query'],
  '/analytical-dashboard': ['business metrics', 'analytics dashboard', 'calc view'],
  '/streaming': ['live search', 'streaming ingestion', 'continuous updates'],
  '/pipeline': ['training runs', 'pipeline', 'jobs', 'run model'],
  '/deployments': ['releases', 'deployments', 'ship model', 'rollout'],
  '/model-optimizer': ['model tuning', 'model forge', 'optimize model', 'quantization', 'compression'],
  '/registry': ['model registry', 'registered models', 'artifacts'],
  '/hana-explorer': ['hana workspace', 'database', 'sql', 'query hana'],
  '/compare': ['outcome compare', 'compare runs', 'diff results'],
  '/governance': ['governance', 'policy', 'compliance'],
  '/analytics': ['financial insights', 'business analytics', 'reports'],
  '/pair-studio': ['pair builder', 'terminology pairs', 'translation pairs'],
  '/glossary-manager': ['glossary', 'translation memory', 'approved terms'],
  '/document-linguist': ['document linguist', 'arabic document assistant', 'guided intake', 'ocr review'],
  '/prompts': ['guidance library', 'prompts', 'templates'],
  '/workspace': ['settings', 'preferences', 'workspace'],
};

const GROUP_SEARCH_TERMS: Record<TrainingRouteGroupId, string[]> = {
  home: ['overview', 'home'],
  data: ['prepare data', 'data work'],
  assist: ['ask and analyze', 'ai assistance'],
  operations: ['run and optimize', 'operations'],
};

const EMPTY_STATE: QuickAccessState = {
  pinnedPaths: [],
  recentPaths: [],
};

@Injectable({ providedIn: 'root' })
export class NavigationAssistantService {
  private readonly state = signal<QuickAccessState>(this.loadState());

  readonly pinnedEntries = computed(() => this.pathsToRoutes(this.state().pinnedPaths));
  readonly recentEntries = computed(() => {
    const pinned = new Set(this.state().pinnedPaths);
    return this.pathsToRoutes(this.state().recentPaths.filter((path) => !pinned.has(path)));
  });

  canPin(path: string): boolean {
    return Boolean(this.findRoute(path));
  }

  isPinned(path: string): boolean {
    return this.state().pinnedPaths.includes(this.normalizePath(path));
  }

  togglePinned(path: string): void {
    const normalizedPath = this.normalizePath(path);
    if (!this.findRoute(normalizedPath)) {
      return;
    }

    const current = this.state();
    const pinnedPaths = current.pinnedPaths.includes(normalizedPath)
      ? current.pinnedPaths.filter((item) => item !== normalizedPath)
      : [normalizedPath, ...current.pinnedPaths];

    this.persist({
      ...current,
      pinnedPaths,
    });
  }

  recordVisit(path: string): void {
    const normalizedPath = this.normalizePath(path);
    if (!this.findRoute(normalizedPath)) {
      return;
    }

    const current = this.state();
    const recentPaths = [
      normalizedPath,
      ...current.recentPaths.filter((item) => item !== normalizedPath),
    ].slice(0, RECENT_LIMIT);

    this.persist({
      ...current,
      recentPaths,
    });
  }

  suggestedEntries(limit = 6): TrainingRouteLink[] {
    return TRAINING_ROUTE_LINKS
      .filter((link) => link.tier === 'primary' && link.path !== '/dashboard')
      .slice(0, limit);
  }

  search(
    query: string,
    resolveLabel: (key: string) => string,
    resolveGroupLabel: (group: TrainingRouteGroupId) => string,
  ): TrainingRouteLink[] {
    const normalizedQuery = query.trim().toLowerCase();
    if (!normalizedQuery) {
      return this.suggestedEntries();
    }

    return TRAINING_ROUTE_LINKS
      .map((link) => ({
        link,
        score: this.scoreLink(link, normalizedQuery, resolveLabel, resolveGroupLabel),
      }))
      .filter((result) => result.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((result) => result.link)
      .slice(0, 8);
  }

  private scoreLink(
    link: TrainingRouteLink,
    query: string,
    resolveLabel: (key: string) => string,
    resolveGroupLabel: (group: TrainingRouteGroupId) => string,
  ): number {
    const label = resolveLabel(link.labelKey).toLowerCase();
    const group = resolveGroupLabel(link.group).toLowerCase();
    const path = link.path.replace(/[/-]/g, ' ').toLowerCase();
    const routeTerms = ROUTE_SEARCH_TERMS[link.path] ?? [];
    const groupTerms = GROUP_SEARCH_TERMS[link.group] ?? [];
    const combinedTerms = [label, group, path, ...routeTerms, ...groupTerms].join(' ').toLowerCase();
    const tokens = query.split(/\s+/).filter(Boolean);

    if (!tokens.every((token) => combinedTerms.includes(token))) {
      return 0;
    }

    let score = 25;

    if (label === query) {
      score += 300;
    } else if (label.startsWith(query)) {
      score += 220;
    } else if (label.includes(query)) {
      score += 140;
    }

    if (routeTerms.some((term) => term === query)) {
      score += 220;
    } else if (routeTerms.some((term) => term.startsWith(query))) {
      score += 180;
    } else if (routeTerms.some((term) => term.includes(query))) {
      score += 110;
    }

    if (group.includes(query) || groupTerms.some((term) => term.includes(query))) {
      score += 45;
    }

    if (this.isPinned(link.path)) {
      score += 20;
    }

    if (this.state().recentPaths.includes(link.path)) {
      score += 10;
    }

    return score;
  }

  private pathsToRoutes(paths: string[]): TrainingRouteLink[] {
    return paths
      .map((path) => this.findRoute(path))
      .filter((link): link is TrainingRouteLink => Boolean(link));
  }

  private findRoute(path: string): TrainingRouteLink | undefined {
    const normalizedPath = this.normalizePath(path);
    return TRAINING_ROUTE_LINKS.find((link) => link.path === normalizedPath);
  }

  private normalizePath(path: string): string {
    const normalized = path.split('?')[0].split('#')[0].trim();
    if (!normalized) {
      return '/dashboard';
    }
    return normalized.startsWith('/') ? normalized : `/${normalized}`;
  }

  private persist(state: QuickAccessState): void {
    this.state.set(state);
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch {
      // storage unavailable
    }
  }

  private loadState(): QuickAccessState {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) {
        return EMPTY_STATE;
      }
      const parsed = JSON.parse(raw) as Partial<QuickAccessState>;
      return {
        pinnedPaths: Array.isArray(parsed.pinnedPaths) ? parsed.pinnedPaths : [],
        recentPaths: Array.isArray(parsed.recentPaths) ? parsed.recentPaths : [],
      };
    } catch {
      return EMPTY_STATE;
    }
  }
}

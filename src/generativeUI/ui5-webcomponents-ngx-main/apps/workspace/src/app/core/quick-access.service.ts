import { Injectable, computed, signal } from '@angular/core';
import { NAV_LINK_DATA, NavLinkDatum } from './workspace.types';

interface QuickAccessState {
  pinnedPaths: string[];
  recentPaths: string[];
}

const STORAGE_KEY = 'sap-ai-experience.quick-access.v1';
const RECENT_LIMIT = 8;

const SEARCH_TERMS: Record<string, string[]> = {
  '/forms': ['design patterns', 'forms', 'approvals', 'validation', 'learn workspace'],
  '/joule': ['joule', 'assistant', 'agent workspace', 'guided work'],
  '/collab': ['collaboration', 'shared presence', 'team room', 'live cursors'],
  '/generative': ['ui composer', 'generative ui', 'schema generation', 'compose ui'],
  '/components': ['models', 'model catalog', 'available models'],
  '/mcp': ['connected tools', 'tool catalog', 'integrations', 'tooling'],
  '/ocr': ['document intelligence', 'ocr', 'invoice extraction', 'extract document'],
  '/readiness': ['readiness', 'service health', 'system status', 'availability'],
  '/workspace': ['workspace settings', 'settings', 'preferences', 'appearance'],
};

const EMPTY_STATE: QuickAccessState = {
  pinnedPaths: [],
  recentPaths: [],
};

@Injectable({ providedIn: 'root' })
export class QuickAccessService {
  private readonly state = signal<QuickAccessState>(this.loadState());

  readonly pinnedEntries = computed(() => this.pathsToEntries(this.state().pinnedPaths));
  readonly recentEntries = computed(() => {
    const pinned = new Set(this.state().pinnedPaths);
    return this.pathsToEntries(this.state().recentPaths.filter((path) => !pinned.has(path)));
  });

  canPin(path: string): boolean {
    return Boolean(this.findEntry(path));
  }

  isPinned(path: string): boolean {
    return this.state().pinnedPaths.includes(this.normalizePath(path));
  }

  togglePinned(path: string): void {
    const normalizedPath = this.normalizePath(path);
    if (!this.findEntry(normalizedPath)) {
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
    if (!this.findEntry(normalizedPath)) {
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

  suggestedEntries(limit = 6): NavLinkDatum[] {
    return NAV_LINK_DATA
      .filter((entry) => entry.path !== '/workspace')
      .slice(0, limit);
  }

  search(query: string): NavLinkDatum[] {
    const normalizedQuery = query.trim().toLowerCase();
    if (!normalizedQuery) {
      return this.suggestedEntries();
    }

    return NAV_LINK_DATA
      .map((entry) => ({
        entry,
        score: this.scoreEntry(entry, normalizedQuery),
      }))
      .filter((result) => result.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((result) => result.entry)
      .slice(0, 8);
  }

  private scoreEntry(entry: NavLinkDatum, query: string): number {
    const path = entry.path.replace(/[/-]/g, ' ').toLowerCase();
    const terms = SEARCH_TERMS[entry.path] ?? [];
    const combined = [path, ...terms].join(' ').toLowerCase();
    const tokens = query.split(/\s+/).filter(Boolean);

    if (!tokens.every((token) => combined.includes(token))) {
      return 0;
    }

    let score = 25;

    if (terms.some((term) => term === query)) {
      score += 260;
    } else if (terms.some((term) => term.startsWith(query))) {
      score += 200;
    } else if (terms.some((term) => term.includes(query))) {
      score += 120;
    }

    if (path.startsWith(query)) {
      score += 80;
    }

    if (this.isPinned(entry.path)) {
      score += 20;
    }

    if (this.state().recentPaths.includes(entry.path)) {
      score += 10;
    }

    return score;
  }

  private pathsToEntries(paths: string[]): NavLinkDatum[] {
    return paths
      .map((path) => this.findEntry(path))
      .filter((entry): entry is NavLinkDatum => Boolean(entry));
  }

  private findEntry(path: string): NavLinkDatum | undefined {
    const normalizedPath = this.normalizePath(path);
    return NAV_LINK_DATA.find((entry) => entry.path === normalizedPath);
  }

  private normalizePath(path: string): string {
    const normalized = path.split('?')[0].split('#')[0].trim();
    if (!normalized) {
      return '/';
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

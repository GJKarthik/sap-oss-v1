/**
 * Team Context Service — Country × Domain scoping
 *
 * Provides reactive team context (country + domain) that flows through
 * the entire UI. Defaults from JWT claims, user can override via UI.
 * Auto-attaches X-Team-Context header to all API requests.
 */

import { Injectable, computed, inject, signal } from '@angular/core';
import { HttpInterceptorFn } from '@angular/common/http';

export interface TeamContextState {
  country: string;   // ISO code: AE, GB, US, SG, …
  domain: string;    // treasury, esg, performance
}

export type ScopeLevel = 'global' | 'domain' | 'country' | 'team';

const STORAGE_KEY = 'team_context';

const SUPPORTED_COUNTRIES: Record<string, string> = {
  CN: 'China', HK: 'Hong Kong', IN: 'India', SG: 'Singapore',
  TW: 'Taiwan', AE: 'United Arab Emirates', GB: 'United Kingdom',
  US: 'United States of America',
};

const SUPPORTED_DOMAINS: Record<string, string> = {
  treasury: 'Treasury & Capital Markets',
  esg: 'ESG & Sustainability',
  performance: 'Performance Analytics',
};

const COUNTRY_FLAGS: Record<string, string> = {
  CN: '🇨🇳', HK: '🇭🇰', IN: '🇮🇳', SG: '🇸🇬',
  TW: '🇹🇼', AE: '🇦🇪', GB: '🇬🇧', US: '🇺🇸',
};

@Injectable({ providedIn: 'root' })
export class TeamContextService {
  private readonly _country = signal<string>('');
  private readonly _domain = signal<string>('');

  readonly country = this._country.asReadonly();
  readonly domain = this._domain.asReadonly();

  readonly teamId = computed(() => {
    const c = this._country();
    const d = this._domain();
    if (c && d) return `${c}:${d}`;
    return c || d || 'global';
  });

  readonly scopeLevel = computed<ScopeLevel>(() => {
    const c = this._country();
    const d = this._domain();
    if (c && d) return 'team';
    if (c) return 'country';
    if (d) return 'domain';
    return 'global';
  });

  readonly displayLabel = computed(() => {
    const c = this._country();
    const d = this._domain();
    const flag = COUNTRY_FLAGS[c] || '';
    const countryName = SUPPORTED_COUNTRIES[c] || '';
    const domainName = SUPPORTED_DOMAINS[d] || '';
    if (c && d) return `${flag} ${countryName} × ${domainName}`.trim();
    if (c) return `${flag} ${countryName}`.trim();
    if (d) return domainName;
    return 'Global';
  });

  readonly isGlobal = computed(() => !this._country() && !this._domain());

  constructor() {
    this.restoreFromStorage();
  }

  /** Set team context — persists to localStorage. */
  setContext(country: string, domain: string): void {
    this._country.set(country.toUpperCase().trim());
    this._domain.set(domain.toLowerCase().trim());
    this.persistToStorage();
  }

  setCountry(country: string): void {
    this._country.set(country.toUpperCase().trim());
    this.persistToStorage();
  }

  setDomain(domain: string): void {
    this._domain.set(domain.toLowerCase().trim());
    this.persistToStorage();
  }

  reset(): void {
    this._country.set('');
    this._domain.set('');
    localStorage.removeItem(STORAGE_KEY);
  }

  /** Returns the header value for X-Team-Context (request scoping only). */
  getHeaderValue(): string {
    return JSON.stringify({
      country: this._country(),
      domain: this._domain(),
    });
  }

  /** Static accessors for use by interceptor. */
  static readonly supportedCountries = SUPPORTED_COUNTRIES;
  static readonly supportedDomains = SUPPORTED_DOMAINS;
  static readonly countryFlags = COUNTRY_FLAGS;

  /** Ordered list of countries for dropdown. */
  getCountryOptions(): { code: string; name: string; flag: string }[] {
    return Object.entries(SUPPORTED_COUNTRIES)
      .map(([code, name]) => ({ code, name, flag: COUNTRY_FLAGS[code] || '' }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  /** Ordered list of domains for dropdown. */
  getDomainOptions(): { id: string; name: string }[] {
    return Object.entries(SUPPORTED_DOMAINS)
      .map(([id, name]) => ({ id, name }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  private persistToStorage(): void {
    const state: TeamContextState = { country: this._country(), domain: this._domain() };
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  }

  private restoreFromStorage(): void {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const state: TeamContextState = JSON.parse(raw);
        this._country.set(state.country || '');
        this._domain.set(state.domain || '');
      }
    } catch {
      // Ignore corrupt storage
    }
  }
}

/**
 * HTTP interceptor that attaches X-Team-Context header to every API request.
 * Register in app config: provideHttpClient(withInterceptors([teamContextInterceptor]))
 */
export const teamContextInterceptor: HttpInterceptorFn = (req, next) => {
  const teamCtx = inject(TeamContextService);
  const headerValue = teamCtx.getHeaderValue();

  // Only attach to our own API requests
  if (req.url.startsWith('/api') || req.url.startsWith('/v1')) {
    const cloned = req.clone({
      setHeaders: { 'X-Team-Context': headerValue },
    });
    return next(cloned);
  }

  return next(req);
};

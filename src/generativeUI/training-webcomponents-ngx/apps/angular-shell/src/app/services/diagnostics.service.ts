import { Injectable, computed, signal } from '@angular/core';

interface RouteDiagnostic {
  route: string;
  method: string;
  status: number;
  latencyMs: number;
  correlationId: string;
  lastError: string;
  updatedAt: number;
}

@Injectable({ providedIn: 'root' })
export class DiagnosticsService {
  private readonly records = signal<Record<string, RouteDiagnostic>>({});

  readonly entries = computed(() =>
    Object.values(this.records()).sort((a, b) => b.updatedAt - a.updatedAt),
  );

  record(params: {
    url: string;
    method: string;
    status: number;
    latencyMs: number;
    correlationId?: string | null;
    error?: string | null;
  }): void {
    const key = this.routeFromUrl(params.url);
    this.records.update((current) => ({
      ...current,
      [key]: {
        route: key,
        method: params.method,
        status: params.status,
        latencyMs: Math.max(0, Math.round(params.latencyMs)),
        correlationId: params.correlationId ?? '-',
        lastError: params.error ?? '-',
        updatedAt: Date.now(),
      },
    }));
  }

  private routeFromUrl(url: string): string {
    const withoutOrigin = url.replace(/^https?:\/\/[^/]+/i, '');
    const path = withoutOrigin.split('?')[0];
    const normalized = path.replace(/^\/api/, '') || '/';
    const segments = normalized.split('/').filter(Boolean);
    if (!segments.length) return '/';
    return `/${segments[0]}`;
  }
}


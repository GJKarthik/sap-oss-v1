import { Injectable, inject } from '@angular/core';
import { Router } from '@angular/router';
import { TRAINING_ROUTE_LINKS } from '../app.navigation';
import { WorkspaceService } from './workspace.service';

export type AppId = 'aifabric' | 'training' | 'experience';

const CURRENT_APP_ID: AppId = 'training';

const APP_BASE_PATHS: Record<AppId, string> = {
  aifabric: '/aifabric',
  training: '/training',
  experience: '/ui5',
};

const EXTERNAL_ROUTE_LABEL_KEYS: Partial<Record<AppId, Record<string, string>>> = {
  aifabric: {
    '/data': 'crossApp.target.aifabricData',
    '/data-quality': 'crossApp.target.aifabricDataQuality',
    '/rag': 'crossApp.target.aifabricRag',
  },
  experience: {
    '/ocr': 'nav.documentOcr',
  },
};

@Injectable({ providedIn: 'root' })
export class AppLinkService {
  private readonly router = inject(Router);
  private readonly workspace = inject(WorkspaceService);

  appDisplayNameKey(appId: AppId): string {
    const keys: Record<AppId, string> = {
      aifabric: 'product.aiFabric',
      training: 'product.training',
      experience: 'product.joule',
    };
    return keys[appId];
  }

  targetLabelKey(appId: AppId, route: string): string | null {
    const normalizedRoute = this.normalizeRoute(route);

    if (appId === 'training') {
      return TRAINING_ROUTE_LINKS.find((link) => link.path === normalizedRoute)?.labelKey ?? null;
    }

    return EXTERNAL_ROUTE_LABEL_KEYS[appId]?.[normalizedRoute] ?? null;
  }

  buildUrl(appId: AppId, route = '/'): string {
    const normalizedRoute = this.normalizeRoute(route);
    if (appId === CURRENT_APP_ID) {
      return normalizedRoute;
    }

    const basePath = APP_BASE_PATHS[appId].replace(/\/$/, '');
    const path = normalizedRoute === '/' ? `${basePath}/` : `${basePath}${normalizedRoute}`;
    const workspaceId = this.workspace.activeWorkspace()?.id;

    if (!workspaceId) {
      return path;
    }

    return `${path}?workspace=${encodeURIComponent(workspaceId)}`;
  }

  navigate(appId: AppId, route = '/'): void {
    const normalizedRoute = this.normalizeRoute(route);
    if (appId === CURRENT_APP_ID) {
      void this.router.navigateByUrl(normalizedRoute);
      return;
    }

    window.location.href = this.buildUrl(appId, normalizedRoute);
  }

  private normalizeRoute(route: string): string {
    if (!route || route === '/') {
      return '/';
    }
    return route.startsWith('/') ? route : `/${route}`;
  }
}

import { Injectable } from '@angular/core';
import { Router } from '@angular/router';
import { absolutizeSuiteSiblingPath } from './suite-sibling-url';
import { WorkspaceService } from './workspace.service';

export type ProductAppId = 'aifabric' | 'training' | 'sac' | 'experience';

const APP_BASE_PATHS: Record<ProductAppId, string> = {
  aifabric: '/aifabric',
  training: '/training',
  sac: '/sac',
  experience: '/ui5',
};

@Injectable({ providedIn: 'root' })
export class ProductNavigationService {
  constructor(
    private readonly router: Router,
    private readonly workspace: WorkspaceService,
  ) {}

  navigateToLanding(): void {
    void this.router.navigateByUrl(this.defaultLandingPath());
  }

  navigateToApp(appId: ProductAppId, route = '/'): void {
    const normalizedRoute = this.normalizeRoute(route);
    if (appId === 'experience') {
      const target = normalizedRoute === '/' ? this.defaultLandingPath() : normalizedRoute;
      void this.router.navigateByUrl(target);
      return;
    }

    window.location.href = this.buildAppUrl(appId, normalizedRoute);
  }

  buildAppUrl(appId: ProductAppId, route = '/'): string {
    const normalizedRoute = this.normalizeRoute(route);
    const basePath = APP_BASE_PATHS[appId].replace(/\/$/, '');
    const path = normalizedRoute === '/' ? `${basePath}/` : `${basePath}${normalizedRoute}`;
    const workspaceId = this.workspace.activeWorkspace()?.id;

    const withWorkspace =
      !workspaceId || appId === 'sac' ? path : `${path}?workspace=${encodeURIComponent(workspaceId)}`;
    return absolutizeSuiteSiblingPath(withWorkspace);
  }

  private defaultLandingPath(): string {
    return this.workspace.navConfig().defaultLandingPath || '/';
  }

  private normalizeRoute(route: string): string {
    if (!route || route === '/') {
      return '/';
    }
    return route.startsWith('/') ? route : `/${route}`;
  }
}

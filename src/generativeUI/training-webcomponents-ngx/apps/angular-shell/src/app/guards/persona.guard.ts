import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { PageVisibilityService } from '../services/page-visibility.service';

export const personaGuard: CanActivateFn = (route) => {
  const visibility = inject(PageVisibilityService);
  const router = inject(Router);
  const path = '/' + (route.routeConfig?.path ?? '');
  if (visibility.isRouteVisible(path)) {
    return true;
  }
  return router.createUrlTree(['/overview']);
};

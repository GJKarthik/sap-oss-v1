import { Routes } from '@angular/router';

export const routes: Routes = [
  {
    path: '',
    redirectTo: 'welcome',
    pathMatch: 'full',
  },
  {
    path: 'welcome',
    loadComponent: () => import('./features/welcome/welcome.component').then((m) => m.WelcomeComponent),
  },
  {
    path: 'getting-started',
    loadComponent: () => import('./features/getting-started/getting-started.component').then((m) => m.GettingStartedComponent),
  },
  {
    path: 'process-checks',
    loadComponent: () => import('./features/process-checks/process-checks.component').then((m) => m.ProcessChecksComponent),
  },
  {
    path: 'upload-results',
    loadComponent: () => import('./features/upload-results/upload-results.component').then((m) => m.UploadResultsComponent),
  },
  {
    path: 'generate-report',
    loadComponent: () => import('./features/generate-report/generate-report.component').then((m) => m.GenerateReportComponent),
  },
  {
    path: 'overview',
    loadComponent: () => import('./features/overview/overview.component').then((m) => m.OverviewComponent),
  },
  {
    path: 'catalog',
    loadComponent: () => import('./features/catalog/catalog.component').then((m) => m.CatalogComponent),
  },
  {
    path: 'runs',
    loadComponent: () => import('./features/runs/runs.component').then((m) => m.RunsComponent),
  },
  {
    path: 'history',
    loadComponent: () => import('./features/history/history.component').then((m) => m.HistoryComponent),
  },
  {
    path: 'settings',
    loadComponent: () => import('./features/settings/settings.component').then((m) => m.SettingsComponent),
  },
  {
    path: '**',
    redirectTo: 'welcome',
  },
];

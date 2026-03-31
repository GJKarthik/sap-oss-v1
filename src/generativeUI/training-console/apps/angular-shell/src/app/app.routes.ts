import { Routes } from '@angular/router';
import { authGuard } from './guards/auth.guard';
import { ShellComponent } from './components/shell/shell.component';

export const routes: Routes = [
  {
    path: 'login',
    loadComponent: () => import('./pages/login/login.component').then((m) => m.LoginComponent),
  },
  {
    path: '',
    component: ShellComponent,
    canActivate: [authGuard],
    children: [
      { path: '', redirectTo: 'dashboard', pathMatch: 'full' },
      {
        path: 'dashboard',
        loadComponent: () =>
          import('./pages/dashboard/dashboard.component').then((m) => m.DashboardComponent),
      },
      {
        path: 'pipeline',
        loadComponent: () =>
          import('./pages/pipeline/pipeline.component').then((m) => m.PipelineComponent),
      },
      {
        path: 'model-optimizer',
        loadComponent: () =>
          import('./pages/model-optimizer/model-optimizer.component').then(
            (m) => m.ModelOptimizerComponent
          ),
      },
      {
        path: 'hippocpp',
        loadComponent: () =>
          import('./pages/hippocpp/hippocpp.component').then((m) => m.HippocppComponent),
      },
      {
        path: 'data-explorer',
        loadComponent: () =>
          import('./pages/data-explorer/data-explorer.component').then(
            (m) => m.DataExplorerComponent
          ),
      },
      {
        path: 'data-cleaning',
        loadComponent: () =>
          import('./pages/data-cleaning/data-cleaning.component').then(
            (m) => m.DataCleaningComponent
          ),
      },
      {
        path: 'chat',
        loadComponent: () => import('./pages/chat/chat.component').then((m) => m.ChatComponent),
      },
      {
        path: 'compare',
        loadComponent: () =>
          import('./pages/compare/compare.component').then((m) => m.CompareComponent),
      },
      {
        path: 'registry',
        loadComponent: () =>
          import('./pages/registry/registry.component').then((m) => m.RegistryComponent),
      },
    ],
  },
  { path: '**', redirectTo: 'dashboard' },
];

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
        path: 'chat',
        loadComponent: () => import('./pages/chat/chat.component').then((m) => m.ChatComponent),
      },
    ],
  },
  { path: '**', redirectTo: 'dashboard' },
];

import { Routes } from '@angular/router';

export const routes: Routes = [
  { path: '', redirectTo: '/dashboard', pathMatch: 'full' },
  {
    path: 'dashboard',
    loadComponent: () =>
      import('./dashboard/dashboard.component').then((m) => m.DashboardComponent),
  },
  {
    path: 'chat',
    loadComponent: () =>
      import('./chat/chat.component').then((m) => m.ChatComponent),
  },
  {
    path: 'models',
    loadComponent: () =>
      import('./models/models.component').then((m) => m.ModelsComponent),
  },
  {
    path: 'jobs',
    loadComponent: () =>
      import('./jobs/jobs.component').then((m) => m.JobsComponent),
  },
  { path: '**', redirectTo: '/dashboard' },
];


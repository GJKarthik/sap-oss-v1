/**
 * App Routing Module - Angular/UI5 Version
 * Uses lazy loading for all page components.
 */

import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';

import { ShellComponent } from './components/shell/shell.component';
import { authGuard } from './guards/auth.guard';

const routes: Routes = [
  {
    path: 'login',
    loadComponent: () => import('./pages/login/login.component').then(m => m.LoginComponent),
  },
  {
    path: '',
    component: ShellComponent,
    canActivate: [authGuard],
    children: [
      { path: '', redirectTo: 'dashboard', pathMatch: 'full' },
      {
        path: 'dashboard',
        loadComponent: () => import('./pages/dashboard/dashboard.component').then(m => m.DashboardComponent),
      },
      {
        path: 'streaming',
        loadComponent: () => import('./pages/streaming/streaming.component').then(m => m.StreamingComponent),
      },
      {
        path: 'deployments',
        loadComponent: () => import('./pages/deployments/deployments.component').then(m => m.DeploymentsComponent),
      },
      {
        path: 'rag',
        loadComponent: () => import('./pages/rag-studio/rag-studio.component').then(m => m.RagStudioComponent),
      },
      {
        path: 'governance',
        loadComponent: () => import('./pages/governance/governance.component').then(m => m.GovernanceComponent),
      },
      {
        path: 'data',
        loadComponent: () => import('./pages/data-explorer/data-explorer.component').then(m => m.DataExplorerComponent),
      },
      {
        path: 'playground',
        loadComponent: () => import('./pages/playground/playground.component').then(m => m.PlaygroundComponent),
      },
      {
        path: 'lineage',
        loadComponent: () => import('./pages/lineage/lineage.component').then(m => m.LineageComponent),
      },
      {
        path: 'data-quality',
        loadComponent: () => import('./pages/data-quality/data-quality.component').then(m => m.DataQualityComponent),
      },
    ]
  },
  { path: '**', redirectTo: 'dashboard' }
];

@NgModule({
  imports: [RouterModule.forRoot(routes)],
  exports: [RouterModule]
})
export class AppRoutingModule { }

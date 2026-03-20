/**
 * App Routing Module - Angular/UI5 Version
 */

import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';

import { ShellComponent } from './components/shell/shell.component';
import { DashboardComponent } from './pages/dashboard/dashboard.component';
import { StreamingComponent } from './pages/streaming/streaming.component';
import { PlaygroundComponent } from './pages/playground/playground.component';
import { RagStudioComponent } from './pages/rag-studio/rag-studio.component';
import { DataExplorerComponent } from './pages/data-explorer/data-explorer.component';
import { LineageComponent } from './pages/lineage/lineage.component';
import { GovernanceComponent } from './pages/governance/governance.component';
import { LoginComponent } from './pages/login/login.component';
import { AuthGuard } from './guards/auth.guard';

const routes: Routes = [
  {
    path: 'login',
    component: LoginComponent
  },
  {
    path: '',
    component: ShellComponent,
    canActivate: [AuthGuard],
    children: [
      { path: '', redirectTo: 'dashboard', pathMatch: 'full' },
      { path: 'dashboard', component: DashboardComponent },
      { path: 'streaming', component: StreamingComponent },
      { path: 'playground', component: PlaygroundComponent },
      { path: 'rag', component: RagStudioComponent },
      { path: 'data', component: DataExplorerComponent },
      { path: 'lineage', component: LineageComponent },
      { path: 'governance', component: GovernanceComponent },
    ]
  },
  { path: '**', redirectTo: 'dashboard' }
];

@NgModule({
  imports: [RouterModule.forRoot(routes)],
  exports: [RouterModule]
})
export class AppRoutingModule { }
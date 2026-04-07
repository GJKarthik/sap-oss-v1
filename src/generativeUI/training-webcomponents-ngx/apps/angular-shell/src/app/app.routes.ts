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
      {
        path: 'document-ocr',
        loadComponent: () =>
          import('./pages/document-ocr/document-ocr.component').then(
            (m) => m.DocumentOcrComponent
          ),
      },
      {
        path: 'semantic-search',
        loadComponent: () =>
          import('./pages/semantic-search/semantic-search.component').then(
            (m) => m.SemanticSearchComponent
          ),
      },
      {
        path: 'analytics',
        loadComponent: () =>
          import('./pages/analytics/analytics.component').then(
            (m) => m.AnalyticsComponent
          ),
      },
      {
        path: 'glossary-manager',
        loadComponent: () =>
          import('./pages/glossary-manager/glossary-manager.component').then(
            (m) => m.GlossaryManagerComponent
          ),
      },
      {
        path: 'arabic-wizard',
        loadComponent: () =>
          import('./pages/arabic-wizard/arabic-wizard.component').then(
            (m) => m.ArabicWizardComponent
          ),
      },
      {
        path: 'governance',
        loadComponent: () =>
          import('./pages/governance/governance.component').then(
            (m) => m.GovernanceComponent
          ),
      },
      {
        path: 'prompts',
        loadComponent: () =>
          import('./pages/prompt-library/prompt-library.component').then(
            (m) => m.PromptLibraryComponent
          ),
      },
      {
        path: 'workspace',
        loadComponent: () =>
          import('./pages/workspace/workspace.component').then(
            (m) => m.WorkspaceComponent
          ),
      },
      {
        path: 'streaming',
        loadComponent: () =>
          import('./pages/streaming/streaming.component').then(
            (m) => m.StreamingComponent
          ),
      },
      {
        path: 'data-quality',
        loadComponent: () =>
          import('./pages/data-quality/data-quality.component').then(
            (m) => m.DataQualityComponent
          ),
      },
      {
        path: 'vocab-search',
        loadComponent: () =>
          import('./pages/vocab-search/vocab-search.component').then(
            (m) => m.VocabSearchComponent
          ),
      },
      {
        path: 'schema-browser',
        loadComponent: () =>
          import('./pages/schema-browser/schema-browser.component').then(
            (m) => m.SchemaBrowserComponent
          ),
      },
      {
        path: 'analytical-dashboard',
        loadComponent: () =>
          import('./pages/analytical-dashboard/analytical-dashboard.component').then(
            (m) => m.AnalyticalDashboardComponent
          ),
      },
      {
        path: 'rag-studio',
        loadComponent: () =>
          import('./pages/rag-studio/rag-studio.component').then(
            (m) => m.RagStudioComponent
          ),
      },
      {
        path: 'lineage',
        loadComponent: () =>
          import('./pages/lineage/lineage.component').then(
            (m) => m.LineageComponent
          ),
      },
      {
        path: 'playground',
        loadComponent: () =>
          import('./pages/playground/playground.component').then(
            (m) => m.PlaygroundComponent
          ),
      },
      {
        path: 'sparql-explorer',
        loadComponent: () =>
          import('./pages/sparql-explorer/sparql-explorer.component').then(
            (m) => m.SparqlExplorerComponent
          ),
      },
      {
        path: 'deployments',
        loadComponent: () =>
          import('./pages/deployments/deployments.component').then(
            (m) => m.DeploymentsComponent
          ),
      },
    ],
  },
  { path: '**', redirectTo: 'dashboard' },
];

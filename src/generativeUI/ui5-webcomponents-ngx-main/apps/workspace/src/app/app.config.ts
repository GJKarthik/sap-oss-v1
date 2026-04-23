// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { ApplicationConfig, inject, provideZoneChangeDetection, importProvidersFrom } from '@angular/core';
import { provideRouter, Routes } from '@angular/router';
import { HttpClient, HTTP_INTERCEPTORS, provideHttpClient, withInterceptorsFromDi } from '@angular/common/http';
import { provideAppInitializer } from '@angular/core';
import { Ui5ThemingModule } from '@ui5/theming-ngx';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { Ui5WebcomponentsConfigModule } from '@ui5/webcomponents-ngx/config';
import { RequestTraceInterceptor } from './core/request-trace.interceptor';
import { WorkspaceService } from './core/workspace.service';
import { firstValueFrom } from 'rxjs';
import { MainComponent } from './main.component';

const routes: Routes = [
  { path: '', component: MainComponent },
  { path: 'forms', redirectTo: 'readiness', pathMatch: 'full' },
  { path: 'joule', loadChildren: () => import('./modules/joule/joule.module').then(m => m.JouleModule) },
  { path: 'collab', loadChildren: () => import('./modules/collab/collab.module').then(m => m.CollabModule) },
  { path: 'generative', loadChildren: () => import('./modules/generative/generative.module').then(m => m.GenerativeModule) },
  { path: 'components', loadChildren: () => import('./modules/model-catalog/model-catalog.module').then(m => m.ModelCatalogModule) },
  { path: 'mcp', loadChildren: () => import('./modules/mcp/mcp.module').then(m => m.McpModule) },
  { path: 'ocr', loadChildren: () => import('./modules/ocr/ocr.module').then(m => m.OcrModule) },
  { path: 'readiness', loadChildren: () => import('./modules/readiness/readiness.module').then(m => m.ReadinessModule) },
  { path: 'workspace', loadChildren: () => import('./modules/workspace/workspace.module').then(m => m.WorkspaceModule) },
  { path: '**', loadChildren: () => import('./modules/not-found/not-found.module').then(m => m.NotFoundModule) },
];

export const appConfig: ApplicationConfig = {
  providers: [
    provideZoneChangeDetection({ eventCoalescing: true }),
    provideRouter(routes),
    provideHttpClient(withInterceptorsFromDi()),
    { provide: HTTP_INTERCEPTORS, useClass: RequestTraceInterceptor, multi: true },
    importProvidersFrom(
      Ui5ThemingModule.forRoot({ defaultTheme: 'sap_horizon' }),
      Ui5WebcomponentsConfigModule.forRoot({}),
      Ui5I18nModule.forRoot({
        language: 'en',
        fetchDefaultLanguage: true,
        bundle: {
          name: 'i18n_root',
          translations: {
            useFactory: () => {
              const http = inject(HttpClient);
              return {
                en: http.get('assets/i18n/messages_en', { responseType: 'text' }),
                ar: http.get('assets/i18n/messages_ar', { responseType: 'text' }),
                fr: http.get('assets/i18n/messages_fr', { responseType: 'text' }),
                de: http.get('assets/i18n/messages_de', { responseType: 'text' }),
                ko: http.get('assets/i18n/messages_ko', { responseType: 'text' }),
                zh: http.get('assets/i18n/messages_zh', { responseType: 'text' }),
                zh_CN: http.get('assets/i18n/messages_zh', { responseType: 'text' }),
                id: http.get('assets/i18n/messages_id', { responseType: 'text' }),
              };
            },
          },
        },
      }),
    ),
    provideAppInitializer(() => {
      const ws = inject(WorkspaceService);
      return firstValueFrom(ws.initialize());
    }),
  ],
};

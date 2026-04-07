// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {inject, NgModule, APP_INITIALIZER} from '@angular/core';
import {BrowserModule} from '@angular/platform-browser';

import {AppComponent} from './app.component';
import {FormsModule, ReactiveFormsModule} from '@angular/forms';
import {Ui5ThemingModule} from '@ui5/theming-ngx';
import {FundamentalStylesComponentsModule} from "@fundamental-styles/theming-ngx";
import {Ui5FundamentalThemingModule} from "@fundamental-styles/theming-ngx/theming";
import {Ui5WebcomponentsThemingModule} from "@ui5/webcomponents-ngx/theming";
import {Ui5WebcomponentsIconsModule} from "@ui5/webcomponents-ngx/icons";
import {Ui5WebcomponentsModule} from '@ui5/webcomponents-ngx';
import {Ui5WebcomponentsConfigModule} from '@ui5/webcomponents-ngx/config';
import {Ui5I18nModule} from "@ui5/webcomponents-ngx/i18n";
import {RouterModule} from "@angular/router";
import {MainComponent} from "./main.component";
import {
  HttpClient,
  HTTP_INTERCEPTORS,
  provideHttpClient,
  withInterceptorsFromDi,
} from '@angular/common/http';
import { RequestTraceInterceptor } from './core/request-trace.interceptor';
import { LiveHealthPanelComponent } from './shared/live-health-panel/live-health-panel.component';
import { WorkspaceService } from './core/workspace.service';
import { firstValueFrom } from 'rxjs';

@NgModule({ declarations: [AppComponent, MainComponent, LiveHealthPanelComponent],
    bootstrap: [AppComponent], imports: [Ui5WebcomponentsModule,
        BrowserModule,
        FormsModule,
        ReactiveFormsModule,
        Ui5ThemingModule.forRoot({ defaultTheme: 'sap_horizon' }),
        Ui5WebcomponentsIconsModule.forRoot(['sap-icons', 'tnt-icons', "business-suite-icons"]),
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
                            id: http.get('assets/i18n/messages_id', { responseType: 'text' }),
                        };
                    }
                }
            }
        }),
        RouterModule.forRoot([
            {
                path: '',
                component: MainComponent
            },
            {
                path: 'forms',
                loadChildren: () => import('./modules/forms/forms.module').then(m => m.FormsModule)
            },
            {
                path: 'child-module',
                loadChildren: () => import('./modules/child/child.module').then(m => m.ChildModule)
            },
            {
                path: 'joule',
                loadChildren: () => import('./modules/joule/joule.module').then(m => m.JouleModule)
            },
            {
                path: 'collab',
                loadChildren: () => import('./modules/collab/collab.module').then(m => m.CollabModule)
            },
            {
                path: 'generative',
                loadChildren: () => import('./modules/generative/generative.module').then(m => m.GenerativeModule)
            },
            {
                path: 'components',
                loadChildren: () => import('./modules/component-playground/component-playground.module').then(m => m.ComponentPlaygroundModule)
            },
            {
                path: 'mcp',
                loadChildren: () => import('./modules/mcp/mcp.module').then(m => m.McpModule)
            },
            {
                path: 'ocr',
                loadChildren: () => import('./modules/ocr/ocr.module').then(m => m.OcrModule)
            },
            {
                path: 'readiness',
                loadChildren: () => import('./modules/readiness/readiness.module').then(m => m.ReadinessModule)
            },
            {
                path: 'workspace',
                loadChildren: () => import('./modules/workspace/workspace.module').then(m => m.WorkspaceModule)
            },
            {
                path: '**',
                loadChildren: () => import('./modules/not-found/not-found.module').then(m => m.NotFoundModule)
            }
        ]),
        Ui5WebcomponentsModule,
        Ui5WebcomponentsThemingModule.forRoot(),
        FundamentalStylesComponentsModule,
        Ui5FundamentalThemingModule], providers: [
        provideHttpClient(withInterceptorsFromDi()),
        { provide: HTTP_INTERCEPTORS, useClass: RequestTraceInterceptor, multi: true },
        {
          provide: APP_INITIALIZER,
          useFactory: (ws: WorkspaceService) => () => firstValueFrom(ws.initialize()),
          deps: [WorkspaceService],
          multi: true,
        },
    ] })
export class AppModule {
}

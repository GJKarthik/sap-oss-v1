// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {inject, NgModule} from '@angular/core';
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
import { HttpClient, provideHttpClient, withInterceptorsFromDi } from "@angular/common/http";

const Russian = {
  SOMETHING: 'значение {0}'
}

@NgModule({ declarations: [AppComponent, MainComponent],
    bootstrap: [AppComponent], imports: [Ui5WebcomponentsModule,
        BrowserModule,
        FormsModule,
        ReactiveFormsModule,
        Ui5ThemingModule.forRoot({ defaultTheme: 'sap_horizon' }),
        Ui5WebcomponentsIconsModule.forRoot(['sap-icons', 'tnt-icons', "business-suite-icons"]),
        Ui5WebcomponentsConfigModule.forRoot({}),
        Ui5I18nModule.forRoot({
            language: 'ru',
            fetchDefaultLanguage: true,
            bundle: {
                name: 'i18n_root',
                translations: {
                    useFactory: () => {
                        const http = inject(HttpClient);
                        return {
                            en: http.get('assets/i18n/messages_en', { responseType: 'text' }),
                            ru: Russian
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
                path: '**',
                loadChildren: () => import('./modules/not-found/not-found.module').then(m => m.NotFoundModule)
            }
        ]),
        Ui5WebcomponentsModule,
        Ui5WebcomponentsThemingModule.forRoot(),
        FundamentalStylesComponentsModule,
        Ui5FundamentalThemingModule], providers: [provideHttpClient(withInterceptorsFromDi())] })
export class AppModule {
}

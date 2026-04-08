// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {NgModule} from "@angular/core";
import {ChildComponent} from "./child.component";
import {CommonModule} from "@angular/common";
import {RouterModule} from "@angular/router";
import {Ui5I18nModule} from "@ui5/webcomponents-ngx/i18n";
import { provideHttpClient, withInterceptorsFromDi } from "@angular/common/http";
import { Ui5WorkspaceComponentsModule } from "../../shared/ui5-workspace-components.module";

@NgModule({ declarations: [ChildComponent],
    exports: [RouterModule], imports: [CommonModule,
        Ui5WorkspaceComponentsModule,
        Ui5I18nModule.forChild({
            name: 'i18n_child',
            translations: {
                en: fetch('assets/i18n/child/messages_en').then(r => r.text()),
                ru: fetch('assets/i18n/child/messages_ru').then(r => r.text())
            }
        }),
        RouterModule.forChild([
            {
                path: '',
                component: ChildComponent
            }
        ])], providers: [provideHttpClient(withInterceptorsFromDi())] })
export class ChildModule {}

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { NgModule, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { NotFoundComponent } from './not-found.component';
import { Ui5WorkspaceComponentsModule } from '../../shared/ui5-workspace-components.module';

@NgModule({
  declarations: [NotFoundComponent],
  imports: [
    CommonModule,
    Ui5WorkspaceComponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: NotFoundComponent }]),
  ],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
})
export class NotFoundModule {}

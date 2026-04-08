// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { NgModule, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ReactiveFormsModule } from '@angular/forms';
import { RouterModule } from '@angular/router';
import { FormsPageComponent } from './forms-page.component';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { Ui5WorkspaceComponentsModule } from '../../shared/ui5-workspace-components.module';

@NgModule({
  declarations: [FormsPageComponent],
  imports: [
    CommonModule,
    ReactiveFormsModule,
    Ui5WorkspaceComponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: FormsPageComponent }]),
  ],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
})
export class FormsModule {}

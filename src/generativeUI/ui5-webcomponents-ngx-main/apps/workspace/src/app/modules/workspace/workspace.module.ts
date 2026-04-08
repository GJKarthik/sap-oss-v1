// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { NgModule, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterModule } from '@angular/router';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { WorkspaceSettingsComponent } from './workspace-settings.component';
import { Ui5WorkspaceComponentsModule } from '../../shared/ui5-workspace-components.module';

@NgModule({
  declarations: [WorkspaceSettingsComponent],
  imports: [
    CommonModule,
    FormsModule,
    Ui5WorkspaceComponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: WorkspaceSettingsComponent }]),
  ],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
})
export class WorkspaceModule {}

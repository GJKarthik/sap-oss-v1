// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { NgModule, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ReactiveFormsModule } from '@angular/forms';
import { RouterModule } from '@angular/router';
import { FormsPageComponent } from './forms-page.component';
import { Ui5MainModule } from '@ui5/webcomponents-ngx';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';

@NgModule({
  declarations: [FormsPageComponent],
  imports: [
    CommonModule,
    ReactiveFormsModule,
    Ui5MainModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: FormsPageComponent }]),
  ],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
})
export class FormsModule {}

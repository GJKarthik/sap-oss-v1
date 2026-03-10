// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { NgModule, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { AgUiModule } from '@ui5/ag-ui-angular';
import { GenUiRendererModule } from '@ui5/genui-renderer';
import { GenUiStreamingModule } from '@ui5/genui-streaming';
import { GenUiGovernanceModule } from '@ui5/genui-governance';
import { JouleShellComponent } from './joule-shell.component';

@NgModule({
  declarations: [JouleShellComponent],
  imports: [
    CommonModule,
    AgUiModule,
    GenUiRendererModule,
    GenUiStreamingModule,
    GenUiGovernanceModule,
    RouterModule.forChild([
      { path: '', component: JouleShellComponent },
    ]),
  ],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
})
export class JouleModule {}

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * GenUI Collaboration Module
 */

import { NgModule, ModuleWithProviders } from '@angular/core';
import { CommonModule } from '@angular/common';
import { CollaborationService, COLLAB_CONFIG, CollabConfig } from './services/collaboration.service';

@NgModule({
  imports: [CommonModule],
})
export class GenUiCollabModule {
  static forRoot(config?: CollabConfig): ModuleWithProviders<GenUiCollabModule> {
    return {
      ngModule: GenUiCollabModule,
      providers: [
        { provide: COLLAB_CONFIG, useValue: config || null },
        CollaborationService,
      ],
    };
  }

  static forChild(): ModuleWithProviders<GenUiCollabModule> {
    return {
      ngModule: GenUiCollabModule,
      providers: [],
    };
  }
}
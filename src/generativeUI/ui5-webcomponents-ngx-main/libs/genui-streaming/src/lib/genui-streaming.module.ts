// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * GenUI Streaming Module
 */

import { NgModule, ModuleWithProviders } from '@angular/core';
import { CommonModule } from '@angular/common';
import { StreamingUiService } from './services/streaming-ui.service';
import { GENUI_STREAMING_CONFIG, GenUiStreamingConfig } from './genui-streaming.config';

@NgModule({
  imports: [CommonModule],
})
export class GenUiStreamingModule {
  static forRoot(config?: GenUiStreamingConfig): ModuleWithProviders<GenUiStreamingModule> {
    return {
      ngModule: GenUiStreamingModule,
      providers: [
        { provide: GENUI_STREAMING_CONFIG, useValue: config || {} },
        StreamingUiService,
      ],
    };
  }

  static forChild(): ModuleWithProviders<GenUiStreamingModule> {
    return {
      ngModule: GenUiStreamingModule,
      providers: [],
    };
  }
}

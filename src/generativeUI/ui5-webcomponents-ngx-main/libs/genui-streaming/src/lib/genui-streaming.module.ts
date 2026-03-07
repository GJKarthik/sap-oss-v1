// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * GenUI Streaming Module
 */

import { NgModule, ModuleWithProviders, InjectionToken } from '@angular/core';
import { CommonModule } from '@angular/common';
import { StreamingUiService } from './services/streaming-ui.service';

/** Configuration for GenUI Streaming */
export interface GenUiStreamingConfig {
  /** Enable skeleton loading states */
  enableSkeletons?: boolean;
  /** Transition duration in ms */
  transitionDuration?: number;
  /** Buffer size for event batching */
  bufferSize?: number;
  /** Debounce time for rapid updates */
  debounceMs?: number;
}

export const GENUI_STREAMING_CONFIG = new InjectionToken<GenUiStreamingConfig>('GENUI_STREAMING_CONFIG');

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
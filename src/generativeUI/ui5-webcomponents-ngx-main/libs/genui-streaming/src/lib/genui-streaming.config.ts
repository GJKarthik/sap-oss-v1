// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

import { InjectionToken } from '@angular/core';

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
  /** Maximum number of replay-log entries retained in memory */
  maxReplayLogEntries?: number;
  /** Maximum number of schema history snapshots retained for undo/redo */
  maxSchemaHistoryEntries?: number;
}

export const GENUI_STREAMING_CONFIG = new InjectionToken<GenUiStreamingConfig>('GENUI_STREAMING_CONFIG');

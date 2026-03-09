// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { Injectable } from '@angular/core';

@Injectable({ providedIn: 'root' })
export class SacAiSessionService {
  private threadId: string | null = null;

  getThreadId(): string {
    if (!this.threadId) {
      this.threadId = this.generateThreadId();
    }
    return this.threadId;
  }

  reset(threadId?: string): string {
    this.threadId = threadId?.trim() || this.generateThreadId();
    return this.threadId;
  }

  private generateThreadId(): string {
    return `sac-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  }
}

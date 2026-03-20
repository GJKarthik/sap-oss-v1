// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { Injectable } from '@angular/core';

export interface SacAiAuditEntry {
  id: string;
  timestamp: string;
  eventType: string;
  status: 'processing' | 'approved' | 'rejected' | 'completed' | 'error';
  detail: string;
}

@Injectable({ providedIn: 'root' })
export class SacAiSessionService {
  private threadId: string | null = null;
  private auditEntries: SacAiAuditEntry[] = [];
  private readonly auditLimit = 20;

  getThreadId(): string {
    if (!this.threadId) {
      this.threadId = this.generateThreadId();
    }
    return this.threadId;
  }

  reset(threadId?: string): string {
    this.threadId = threadId?.trim() || this.generateThreadId();
    this.clearAudit();
    return this.threadId;
  }

  recordAudit(
    eventType: SacAiAuditEntry['eventType'],
    status: SacAiAuditEntry['status'],
    detail: string,
  ): SacAiAuditEntry {
    const entry: SacAiAuditEntry = {
      id: this.generateAuditId(),
      timestamp: new Date().toISOString(),
      eventType,
      status,
      detail,
    };

    this.auditEntries = [entry, ...this.auditEntries].slice(0, this.auditLimit);
    return entry;
  }

  getAuditEntries(): SacAiAuditEntry[] {
    return [...this.auditEntries];
  }

  clearAudit(): void {
    this.auditEntries = [];
  }

  private generateThreadId(): string {
    return `sac-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  }

  private generateAuditId(): string {
    return `audit-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  }
}

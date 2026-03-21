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

export interface SacAiReplayEntry {
  id: string;
  sequence: number;
  timestamp: string;
  kind:
    | 'request.sent'
    | 'stream.chunk'
    | 'stream.complete'
    | 'stream.error'
    | 'tool.requested'
    | 'tool.result'
    | 'tool.error'
    | 'approval.required'
    | 'approval.queued'
    | 'approval.approved'
    | 'approval.rejected';
  detail: string;
}

@Injectable({ providedIn: 'root' })
export class SacAiSessionService {
  private threadId: string | null = null;
  private auditEntries: SacAiAuditEntry[] = [];
  private replayEntries: SacAiReplayEntry[] = [];
  private readonly auditLimit = 20;
  private readonly replayLimit = 100;
  private replaySequence = 0;

  getThreadId(): string {
    if (!this.threadId) {
      this.threadId = this.generateThreadId();
    }
    return this.threadId;
  }

  reset(threadId?: string): string {
    this.threadId = threadId?.trim() || this.generateThreadId();
    this.clearAudit();
    this.clearReplay();
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

  recordReplay(kind: SacAiReplayEntry['kind'], detail: string): SacAiReplayEntry {
    this.replaySequence += 1;
    const entry: SacAiReplayEntry = {
      id: this.generateReplayId(),
      sequence: this.replaySequence,
      timestamp: new Date().toISOString(),
      kind,
      detail,
    };

    this.replayEntries = [entry, ...this.replayEntries].slice(0, this.replayLimit);
    return entry;
  }

  getReplayEntries(): SacAiReplayEntry[] {
    return [...this.replayEntries];
  }

  clearAudit(): void {
    this.auditEntries = [];
  }

  clearReplay(): void {
    this.replayEntries = [];
    this.replaySequence = 0;
  }

  private generateThreadId(): string {
    return `sac-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  }

  private generateAuditId(): string {
    return `audit-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  }

  private generateReplayId(): string {
    return `replay-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  }
}

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { catchError, map } from 'rxjs/operators';
import { environment } from '../../environments/environment';
import { WorkspaceService } from './workspace.service';

export interface HistoryEntry {
  id: string;
  module: string;
  userId: string;
  createdAt: string;
  payload: Record<string, unknown>;
}

@Injectable({ providedIn: 'root' })
export class WorkspaceHistoryService {
  constructor(
    private readonly http: HttpClient,
    private readonly workspaceService: WorkspaceService,
  ) {}

  loadHistory(module: 'joule' | 'ocr' | 'generative'): Observable<HistoryEntry[]> {
    const userId = this.workspaceService.identity().userId;
    const baseUrl = this.workspaceService.effectiveOpenAiBaseUrl().replace(/\/$/, '');
    const url = `${baseUrl}/v1/workspace/history/${module}?userId=${encodeURIComponent(userId)}`;
    return this.http.get<{ data?: HistoryEntry[] }>(url).pipe(
      map(response => response?.data ?? []),
      catchError(() => of([])),
    );
  }

  saveEntry(module: string, payload: Record<string, unknown>): Observable<HistoryEntry> {
    const userId = this.workspaceService.identity().userId;
    const baseUrl = this.workspaceService.effectiveOpenAiBaseUrl().replace(/\/$/, '');
    const url = `${baseUrl}/v1/workspace/history/${module}`;
    return this.http.post<HistoryEntry>(url, { userId, payload }).pipe(
      catchError(() => of({
        id: `local-${Date.now()}`,
        module,
        userId,
        createdAt: new Date().toISOString(),
        payload,
      })),
    );
  }

  deleteEntry(module: string, entryId: string): Observable<void> {
    const userId = this.workspaceService.identity().userId;
    const baseUrl = this.workspaceService.effectiveOpenAiBaseUrl().replace(/\/$/, '');
    const url = `${baseUrl}/v1/workspace/history/${module}/${encodeURIComponent(entryId)}?userId=${encodeURIComponent(userId)}`;
    return this.http.delete(url).pipe(
      map(() => void 0),
      catchError(() => of(void 0)),
    );
  }
}

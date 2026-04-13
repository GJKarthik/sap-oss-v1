// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { Injectable, signal, computed, OnDestroy } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { catchError, of } from 'rxjs';
import { environment } from '../../environments/environment';

export interface Notification {
  id: string;
  user_id: string;
  icon: string;
  title: string;
  description: string;
  severity: string;
  read: boolean;
  created_at: string | null;
}

interface NotificationListResponse {
  notifications: Notification[];
  unread_count: number;
}

const POLL_INTERVAL_MS = 30_000;

@Injectable({ providedIn: 'root' })
export class NotificationService implements OnDestroy {
  private readonly _notifications = signal<Notification[]>([]);
  private readonly _unreadCount = signal(0);
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  readonly notifications = this._notifications.asReadonly();
  readonly unreadCount = this._unreadCount.asReadonly();
  readonly hasUnread = computed(() => this._unreadCount() > 0);

  private get baseUrl(): string {
    return `${environment.trainingApiUrl.replace(/\/$/, '')}/notifications`;
  }

  constructor(private readonly http: HttpClient) {}

  startPolling(): void {
    this.fetch();
    if (!this.pollTimer) {
      this.pollTimer = setInterval(() => this.fetch(), POLL_INTERVAL_MS);
    }
  }

  stopPolling(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  fetch(): void {
    this.http
      .get<NotificationListResponse>(this.baseUrl)
      .pipe(catchError(() => of({ notifications: [], unread_count: 0 })))
      .subscribe((resp) => {
        this._notifications.set(resp.notifications);
        this._unreadCount.set(resp.unread_count);
      });
  }

  markRead(notificationId: string): void {
    this.http
      .put(`${this.baseUrl}/${notificationId}/read`, {})
      .pipe(catchError(() => of(null)))
      .subscribe(() => {
        this._notifications.update((list) =>
          list.map((n) => (n.id === notificationId ? { ...n, read: true } : n)),
        );
        this._unreadCount.update((c) => Math.max(0, c - 1));
      });
  }

  markAllRead(): void {
    this.http
      .put(`${this.baseUrl}/read-all`, {})
      .pipe(catchError(() => of(null)))
      .subscribe(() => {
        this._notifications.update((list) => list.map((n) => ({ ...n, read: true })));
        this._unreadCount.set(0);
      });
  }

  ngOnDestroy(): void {
    this.stopPolling();
  }
}

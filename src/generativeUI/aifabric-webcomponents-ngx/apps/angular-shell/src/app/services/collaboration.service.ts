/**
 * Collaboration Service for AI Fabric Console
 *
 * Manages real-time team presence and collaboration state.
 * Lightweight adaptation of @ui5/genui-collab for the AI Fabric workspace.
 */

import { Injectable, OnDestroy } from '@angular/core';
import { BehaviorSubject, Subject, interval } from 'rxjs';
import { filter, takeUntil } from 'rxjs/operators';

export interface TeamMember {
  userId: string;
  displayName: string;
  avatarUrl?: string;
  color: string;
  status: 'active' | 'idle' | 'away';
  location?: string;
  language?: string;
  joinedAt: Date;
  lastSeenAt: Date;
}

export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'reconnecting';

export interface CollabConfig {
  websocketUrl: string;
  userId: string;
  displayName: string;
  avatarUrl?: string;
  language?: string;
  presenceIntervalMs?: number;
  reconnectDelayMs?: number;
  maxReconnectAttempts?: number;
}

type CollabMessage =
  | { type: 'join'; roomId: string; userId: string; displayName: string; avatarUrl?: string; language?: string }
  | { type: 'leave'; roomId: string; userId: string }
  | { type: 'presence'; userId: string; status: TeamMember['status']; location?: string; language?: string }
  | { type: 'sync'; participants: TeamMember[] };

@Injectable({ providedIn: 'root' })
export class CollaborationService implements OnDestroy {
  private readonly destroy$ = new Subject<void>();
  private readonly heartbeatStop$ = new Subject<void>();
  private config: CollabConfig | null = null;
  private ws: WebSocket | null = null;
  private currentRoomId: string | null = null;
  private reconnectAttempts = 0;

  private readonly connectionStateSubject = new BehaviorSubject<ConnectionState>('disconnected');
  readonly connectionState$ = this.connectionStateSubject.asObservable();

  private readonly membersMap = new Map<string, TeamMember>();
  private readonly membersSubject = new BehaviorSubject<TeamMember[]>([]);
  readonly members$ = this.membersSubject.asObservable();

  private readonly userColors = [
    '#e91e63', '#9c27b0', '#673ab7', '#3f51b5', '#2196f3',
    '#03a9f4', '#00bcd4', '#009688', '#4caf50', '#ff9800',
  ];
  private colorIndex = 0;

  configure(config: CollabConfig): void {
    this.config = config;
  }

  async joinRoom(roomId: string): Promise<void> {
    if (!this.config) {
      throw new Error('CollaborationService not configured');
    }
    if (this.currentRoomId) {
      await this.leaveRoom();
    }
    this.currentRoomId = roomId;
    this.connectionStateSubject.next('connecting');

    return new Promise((resolve, reject) => {
      try {
        const url = `${this.config!.websocketUrl}?room=${roomId}`;
        this.ws = new WebSocket(url);
        this.ws.onopen = () => {
          this.connectionStateSubject.next('connected');
          this.reconnectAttempts = 0;
          this.send({ type: 'join', roomId, userId: this.config!.userId, displayName: this.config!.displayName, avatarUrl: this.config!.avatarUrl, language: this.config!.language });
          this.startHeartbeat();
          resolve();
        };
        this.ws.onmessage = (event) => this.handleMessage(JSON.parse(event.data));
        this.ws.onclose = () => { this.connectionStateSubject.next('disconnected'); this.handleDisconnect(); };
        this.ws.onerror = () => { if (this.connectionStateSubject.value === 'connecting') reject(new Error('WebSocket connection failed')); };
      } catch (error) { reject(error); }
    });
  }

  async leaveRoom(): Promise<void> {
    this.heartbeatStop$.next();
    if (this.ws && this.currentRoomId && this.config) {
      this.send({ type: 'leave', roomId: this.currentRoomId, userId: this.config.userId });
      this.ws.close();
      this.ws = null;
    }
    this.currentRoomId = null;
    this.membersMap.clear();
    this.membersSubject.next([]);
  }

  updatePresence(status: TeamMember['status'], location?: string): void {
    if (!this.ws || !this.config) return;
    this.send({ type: 'presence', userId: this.config.userId, status, location, language: this.config.language });
  }

  updateLanguage(language: string): void {
    if (this.config) {
      this.config.language = language;
      this.updatePresence('active');
    }
  }

  getMembers(): TeamMember[] {
    return Array.from(this.membersMap.values());
  }

  getCurrentRoomId(): string | null {
    return this.currentRoomId;
  }

  private handleMessage(msg: CollabMessage): void {
    switch (msg.type) {
      case 'join':
        if (msg.userId !== this.config?.userId) {
          this.membersMap.set(msg.userId, {
            userId: msg.userId, displayName: msg.displayName, avatarUrl: msg.avatarUrl,
            color: this.getNextColor(), status: 'active', language: msg.language, joinedAt: new Date(), lastSeenAt: new Date(),
          });
          this.membersSubject.next(this.getMembers());
        }
        break;
      case 'leave':
        this.membersMap.delete(msg.userId);
        this.membersSubject.next(this.getMembers());
        break;
      case 'presence': {
        const member = this.membersMap.get(msg.userId);
        if (member) { member.status = msg.status; member.location = msg.location; if (msg.language) member.language = msg.language; member.lastSeenAt = new Date(); this.membersSubject.next(this.getMembers()); }
        break;
      }
      case 'sync':
        this.membersMap.clear();
        for (const p of msg.participants) { if (p.userId !== this.config?.userId) this.membersMap.set(p.userId, p); }
        this.membersSubject.next(this.getMembers());
        break;
    }
  }

  private handleDisconnect(): void {
    const maxAttempts = this.config?.maxReconnectAttempts ?? 5;
    const baseDelay = this.config?.reconnectDelayMs ?? 3000;
    if (this.currentRoomId && this.reconnectAttempts < maxAttempts) {
      this.connectionStateSubject.next('reconnecting');
      this.reconnectAttempts++;
      const delay = Math.min(baseDelay * Math.pow(2, this.reconnectAttempts - 1), 30_000);
      setTimeout(() => { if (this.currentRoomId) this.joinRoom(this.currentRoomId).catch(() => {}); }, delay);
    }
  }

  private startHeartbeat(): void {
    this.heartbeatStop$.next();
    const ms = this.config?.presenceIntervalMs ?? 30_000;
    interval(ms).pipe(takeUntil(this.destroy$), takeUntil(this.heartbeatStop$), filter(() => this.connectionStateSubject.value === 'connected'))
      .subscribe(() => this.updatePresence('active'));
  }

  private send(message: CollabMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(message));
  }

  private getNextColor(): string {
    return this.userColors[this.colorIndex++ % this.userColors.length];
  }

  ngOnDestroy(): void {
    this.leaveRoom();
    this.heartbeatStop$.next();
    this.heartbeatStop$.complete();
    this.destroy$.next();
    this.destroy$.complete();
    this.membersSubject.complete();
    this.connectionStateSubject.complete();
  }
}

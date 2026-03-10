// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Collaboration Service
 *
 * Real-time collaboration for multi-user generative UI workspaces.
 * Manages presence, cursors, and state synchronization.
 */

import { Injectable, OnDestroy, Inject, Optional, InjectionToken } from '@angular/core';
import { Subject, BehaviorSubject, Observable, interval } from 'rxjs';
import { takeUntil, filter, throttleTime } from 'rxjs/operators';

// =============================================================================
// Types
// =============================================================================

/** Participant in a collaboration session */
export interface Participant {
  userId: string;
  displayName: string;
  avatarUrl?: string;
  color: string;
  status: 'active' | 'idle' | 'away';
  location?: string;
  joinedAt: Date;
  lastSeenAt: Date;
}

/** Cursor position */
export interface CursorPosition {
  userId: string;
  x: number;
  y: number;
  componentId?: string;
  timestamp: number;
}

/** State change broadcast */
export interface StateChange {
  id: string;
  userId: string;
  timestamp: number;
  type: 'component_update' | 'selection' | 'navigation' | 'custom';
  componentId?: string;
  changes: Record<string, unknown>;
}

/** Collaboration message */
export type CollabMessage =
  | JoinMessage
  | LeaveMessage
  | PresenceMessage
  | CursorMessage
  | StateMessage
  | SyncMessage;

interface JoinMessage {
  type: 'join';
  roomId: string;
  userId: string;
  displayName: string;
  avatarUrl?: string;
}

interface LeaveMessage {
  type: 'leave';
  roomId: string;
  userId: string;
}

interface PresenceMessage {
  type: 'presence';
  userId: string;
  status: Participant['status'];
  location?: string;
}

interface CursorMessage {
  type: 'cursor';
  userId: string;
  x: number;
  y: number;
  componentId?: string;
}

interface StateMessage {
  type: 'state';
  userId: string;
  componentId?: string;
  changes: Record<string, unknown>;
}

interface SyncMessage {
  type: 'sync';
  participants: Participant[];
  state: Record<string, unknown>;
}

/** Connection state */
export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'reconnecting';

/** Collab configuration */
export interface CollabConfig {
  websocketUrl: string;
  userId: string;
  displayName: string;
  avatarUrl?: string;
  cursorThrottleMs?: number;
  presenceIntervalMs?: number;
  reconnectDelayMs?: number;
  maxReconnectAttempts?: number;
}

export const COLLAB_CONFIG = new InjectionToken<CollabConfig>('COLLAB_CONFIG');

// =============================================================================
// Collaboration Service
// =============================================================================

@Injectable()
export class CollaborationService implements OnDestroy {
  private destroy$ = new Subject<void>();
  private config: CollabConfig | null = null;
  private ws: WebSocket | null = null;
  private currentRoomId: string | null = null;
  private reconnectAttempts = 0;

  // Connection state
  private connectionStateSubject = new BehaviorSubject<ConnectionState>('disconnected');
  readonly connectionState$ = this.connectionStateSubject.asObservable();

  // Participants
  private participantsMap = new Map<string, Participant>();
  private participantsSubject = new BehaviorSubject<Participant[]>([]);
  readonly participants$ = this.participantsSubject.asObservable();

  // Cursors
  private cursorsMap = new Map<string, CursorPosition>();
  private cursorsSubject = new BehaviorSubject<CursorPosition[]>([]);
  readonly cursors$ = this.cursorsSubject.asObservable();

  // State changes
  private stateChangesSubject = new Subject<StateChange>();
  readonly stateChanges$ = this.stateChangesSubject.asObservable();

  // User colors (for cursor/avatar display)
  private userColors = [
    '#e91e63', '#9c27b0', '#673ab7', '#3f51b5', '#2196f3',
    '#03a9f4', '#00bcd4', '#009688', '#4caf50', '#ff9800',
  ];
  private colorIndex = 0;

  constructor(@Optional() @Inject(COLLAB_CONFIG) config?: CollabConfig) {
    if (config) {
      this.config = config;
    }
  }

  /**
   * Configure the service
   */
  configure(config: CollabConfig): void {
    this.config = config;
  }

  /**
   * Join a collaboration room
   */
  async joinRoom(roomId: string): Promise<void> {
    if (!this.config) {
      throw new Error('CollaborationService not configured');
    }

    // Leave current room if any
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

          // Send join message
          this.send({
            type: 'join',
            roomId,
            userId: this.config!.userId,
            displayName: this.config!.displayName,
            avatarUrl: this.config!.avatarUrl,
          });

          // Start presence heartbeat
          this.startPresenceHeartbeat();

          resolve();
        };

        this.ws.onmessage = (event) => {
          this.handleMessage(JSON.parse(event.data));
        };

        this.ws.onclose = () => {
          this.connectionStateSubject.next('disconnected');
          this.handleDisconnect();
        };

        this.ws.onerror = (error) => {
          if (this.connectionStateSubject.value === 'connecting') {
            reject(new Error('WebSocket connection failed'));
          }
        };
      } catch (error) {
        reject(error);
      }
    });
  }

  /**
   * Leave current room
   */
  async leaveRoom(): Promise<void> {
    if (this.ws && this.currentRoomId) {
      this.send({
        type: 'leave',
        roomId: this.currentRoomId,
        userId: this.config!.userId,
      });

      this.ws.close();
      this.ws = null;
    }

    this.currentRoomId = null;
    this.participantsMap.clear();
    this.cursorsMap.clear();
    this.emitParticipants();
    this.emitCursors();
  }

  /**
   * Update presence status
   */
  updatePresence(status: Participant['status'], location?: string): void {
    if (!this.ws || !this.config) return;

    this.send({
      type: 'presence',
      userId: this.config.userId,
      status,
      location,
    });
  }

  /**
   * Broadcast cursor position
   */
  broadcastCursor(x: number, y: number, componentId?: string): void {
    if (!this.ws || !this.config) return;

    this.send({
      type: 'cursor',
      userId: this.config.userId,
      x,
      y,
      componentId,
    });
  }

  /**
   * Broadcast state change
   */
  broadcastStateChange(change: Omit<StateChange, 'id' | 'userId' | 'timestamp'>): void {
    if (!this.ws || !this.config) return;

    const fullChange: StateChange = {
      id: this.generateId(),
      userId: this.config.userId,
      timestamp: Date.now(),
      ...change,
    };

    this.send({
      type: 'state',
      userId: this.config.userId,
      componentId: change.componentId,
      changes: change.changes,
    });

    // Also emit locally
    this.stateChangesSubject.next(fullChange);
  }

  /**
   * Get current participants
   */
  getParticipants(): Participant[] {
    return Array.from(this.participantsMap.values());
  }

  /**
   * Get current room ID
   */
  getCurrentRoomId(): string | null {
    return this.currentRoomId;
  }

  /**
   * Handle incoming message
   */
  private handleMessage(message: CollabMessage | Record<string, unknown>): void {
    const msg = message as CollabMessage;

    switch (msg.type) {
      case 'join':
        this.handleJoin(msg);
        break;
      case 'leave':
        this.handleLeave(msg);
        break;
      case 'presence':
        this.handlePresence(msg);
        break;
      case 'cursor':
        this.handleCursor(msg);
        break;
      case 'state':
        this.handleState(msg);
        break;
      case 'sync':
        this.handleSync(msg);
        break;
    }
  }

  private handleJoin(msg: JoinMessage): void {
    if (msg.userId === this.config?.userId) return; // Ignore self

    const participant: Participant = {
      userId: msg.userId,
      displayName: msg.displayName,
      avatarUrl: msg.avatarUrl,
      color: this.getNextColor(),
      status: 'active',
      joinedAt: new Date(),
      lastSeenAt: new Date(),
    };

    this.participantsMap.set(msg.userId, participant);
    this.emitParticipants();
  }

  private handleLeave(msg: LeaveMessage): void {
    this.participantsMap.delete(msg.userId);
    this.cursorsMap.delete(msg.userId);
    this.emitParticipants();
    this.emitCursors();
  }

  private handlePresence(msg: PresenceMessage): void {
    const participant = this.participantsMap.get(msg.userId);
    if (participant) {
      participant.status = msg.status;
      participant.location = msg.location;
      participant.lastSeenAt = new Date();
      this.emitParticipants();
    }
  }

  private handleCursor(msg: CursorMessage): void {
    if (msg.userId === this.config?.userId) return; // Ignore self

    const cursor: CursorPosition = {
      userId: msg.userId,
      x: msg.x,
      y: msg.y,
      componentId: msg.componentId,
      timestamp: Date.now(),
    };

    this.cursorsMap.set(msg.userId, cursor);
    this.emitCursors();
  }

  private handleState(msg: StateMessage): void {
    if (msg.userId === this.config?.userId) return; // Ignore self

    const change: StateChange = {
      id: this.generateId(),
      userId: msg.userId,
      timestamp: Date.now(),
      type: 'component_update',
      componentId: msg.componentId,
      changes: msg.changes,
    };

    this.stateChangesSubject.next(change);
  }

  private handleSync(msg: SyncMessage): void {
    // Sync participants
    this.participantsMap.clear();
    for (const p of msg.participants) {
      if (p.userId !== this.config?.userId) {
        this.participantsMap.set(p.userId, p);
      }
    }
    this.emitParticipants();
  }

  /**
   * Handle disconnect and reconnection
   */
  private handleDisconnect(): void {
    const maxAttempts = this.config?.maxReconnectAttempts ?? 5;
    const baseDelay = this.config?.reconnectDelayMs ?? 3000;

    if (this.currentRoomId && this.reconnectAttempts < maxAttempts) {
      this.connectionStateSubject.next('reconnecting');
      this.reconnectAttempts++;

      // Exponential backoff with 30s ceiling: baseDelay * 2^(attempt-1)
      const backoffDelay = Math.min(baseDelay * Math.pow(2, this.reconnectAttempts - 1), 30_000);

      setTimeout(() => {
        if (this.currentRoomId) {
          this.joinRoom(this.currentRoomId).catch(() => {
            // Reconnect failed, will retry on next disconnect event
          });
        }
      }, backoffDelay);
    }
  }

  /**
   * Start presence heartbeat
   */
  private startPresenceHeartbeat(): void {
    const intervalMs = this.config?.presenceIntervalMs ?? 30000;

    interval(intervalMs)
      .pipe(
        takeUntil(this.destroy$),
        filter(() => this.connectionStateSubject.value === 'connected')
      )
      .subscribe(() => {
        this.updatePresence('active');
      });
  }

  /**
   * Send message over WebSocket
   */
  private send(message: CollabMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message));
    }
  }

  /**
   * Get next color for participant
   */
  private getNextColor(): string {
    const color = this.userColors[this.colorIndex % this.userColors.length];
    this.colorIndex++;
    return color;
  }

  /**
   * Emit participants list
   */
  private emitParticipants(): void {
    this.participantsSubject.next(Array.from(this.participantsMap.values()));
  }

  /**
   * Emit cursors list
   */
  private emitCursors(): void {
    this.cursorsSubject.next(Array.from(this.cursorsMap.values()));
  }

  /**
   * Generate unique ID
   */
  private generateId(): string {
    return crypto.randomUUID();
  }

  ngOnDestroy(): void {
    this.leaveRoom();
    this.destroy$.next();
    this.destroy$.complete();
    this.participantsSubject.complete();
    this.cursorsSubject.complete();
    this.stateChangesSubject.complete();
    this.connectionStateSubject.complete();
  }
}
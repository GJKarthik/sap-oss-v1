// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE
/**
 * Collaboration Service
 *
 * Real-time collaboration for multi-user generative UI workspaces.
 * Manages presence, cursors, and CRDT-aware state synchronization.
 */

import { Inject, Injectable, InjectionToken, Optional, OnDestroy } from '@angular/core';
import { BehaviorSubject, Subject, interval } from 'rxjs';
import { filter, takeUntil } from 'rxjs/operators';

import {
  VectorClock,
  compareSerializableValues,
  deserializeCrdtValue,
  mergeCrdtValues,
  serializeCrdtValue,
} from '../crdt';

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

export type StateChangeType = 'component_update' | 'selection' | 'navigation' | 'custom';

export type ConflictResolutionStrategy = 'none' | 'crdt' | 'callback' | 'lww' | 'sync';

/** State change broadcast */
export interface StateChange {
  id: string;
  userId: string;
  timestamp: number;
  type: StateChangeType;
  componentId?: string;
  changes: Record<string, unknown>;
  version: number;
  previousVersion?: number;
  vectorClock: Record<string, number>;
  conflictDetected?: boolean;
  rollbackApplied?: boolean;
  resolutionStrategy?: ConflictResolutionStrategy;
}

export interface BroadcastStateChangeInput {
  type: StateChangeType;
  componentId?: string;
  changes: Record<string, unknown>;
  previousVersion?: number;
}

export interface ComponentStateSnapshot {
  componentId: string;
  version: number;
  state: Record<string, unknown>;
  vectorClock: Record<string, number>;
  lastUpdatedBy?: string;
  updatedAt: number;
}

export interface ConflictResolutionContext {
  componentId: string;
  key: string;
  baseValue: unknown;
  localValue: unknown;
  remoteValue: unknown;
  localSnapshot: ComponentStateSnapshot;
  remoteChange: StateChange;
}

export interface ConflictResolutionDecision {
  resolvedValue: unknown;
  strategy?: Extract<ConflictResolutionStrategy, 'callback' | 'lww'>;
}

export type ConflictResolver = (
  context: ConflictResolutionContext
) => unknown | ConflictResolutionDecision;

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
  authToken?: string;
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

interface StateMessage extends Omit<StateChange, 'type'> {
  type: 'state';
  changeType?: StateChangeType;
}

interface SyncMessage {
  type: 'sync';
  participants: Participant[];
  state: Record<string, ComponentStateSnapshot>;
}

interface InternalComponentStateSnapshot {
  componentId: string;
  version: number;
  state: Record<string, unknown>;
  vectorClock: VectorClock;
  lastUpdatedBy?: string;
  updatedAt: number;
}

interface MergeResult {
  state: Record<string, unknown>;
  changes: Record<string, unknown>;
  strategy: ConflictResolutionStrategy;
}

/** Connection state */
export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'reconnecting';

/** Collab configuration */
export interface CollabConfig {
  websocketUrl: string;
  userId: string;
  displayName: string;
  avatarUrl?: string;
  authToken?: string;
  authTokenProvider?: () => string | null | undefined;
  cursorThrottleMs?: number;
  presenceIntervalMs?: number;
  reconnectDelayMs?: number;
  maxReconnectAttempts?: number;
  nodeId?: string;
  conflictResolver?: ConflictResolver;
  snapshotHistoryLimit?: number;
}

export const COLLAB_CONFIG = new InjectionToken<CollabConfig>('COLLAB_CONFIG');

const ROOT_COMPONENT_ID = '__root__';

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function cloneRecord(record: Record<string, unknown>): Record<string, unknown> {
  return deserializeCrdtValue(serializeCrdtValue(record)) as unknown as Record<string, unknown>;
}

function normalizeComponentId(componentId?: string): string {
  return componentId ?? ROOT_COMPONENT_ID;
}

function denormalizeComponentId(componentId: string): string | undefined {
  return componentId === ROOT_COMPONENT_ID ? undefined : componentId;
}

function resolveWebSocketUrl(baseUrl: string, roomId: string, authToken?: string): string {
  const normalizedBase = /^wss?:\/\//i.test(baseUrl)
    ? new URL(baseUrl)
    : new URL(
        `${globalThis.location?.protocol === 'https:' ? 'wss:' : 'ws:'}//${globalThis.location?.host ?? 'localhost'}${baseUrl.startsWith('/') ? baseUrl : `/${baseUrl}`}`
      );
  normalizedBase.searchParams.set('room', roomId);
  if (authToken) {
    normalizedBase.searchParams.set('token', authToken);
  }
  return normalizedBase.toString();
}

function toPublicSnapshot(snapshot: InternalComponentStateSnapshot): ComponentStateSnapshot {
  return {
    componentId: snapshot.componentId,
    version: snapshot.version,
    state: cloneRecord(snapshot.state),
    vectorClock: snapshot.vectorClock.toJSON(),
    lastUpdatedBy: snapshot.lastUpdatedBy,
    updatedAt: snapshot.updatedAt,
  };
}

function createEmptySnapshot(componentId: string, version = 0): InternalComponentStateSnapshot {
  return {
    componentId,
    version,
    state: {},
    vectorClock: new VectorClock(),
    updatedAt: 0,
  };
}

function applyStateChanges(
  currentState: Record<string, unknown>,
  changes: Record<string, unknown>
): Record<string, unknown> {
  const nextState = cloneRecord(currentState);

  for (const [key, value] of Object.entries(changes)) {
    nextState[key] = deserializeCrdtValue(serializeCrdtValue(value));
  }

  return nextState;
}

function diffState(
  previousState: Record<string, unknown>,
  nextState: Record<string, unknown>
): Record<string, unknown> {
  const changes: Record<string, unknown> = {};
  const keys = new Set<string>([...Object.keys(previousState), ...Object.keys(nextState)]);

  for (const key of keys) {
    if (!compareSerializableValues(previousState[key], nextState[key])) {
      changes[key] = deserializeCrdtValue(serializeCrdtValue(nextState[key]));
    }
  }

  return changes;
}

function selectPreferredStrategy(
  current: ConflictResolutionStrategy,
  next: ConflictResolutionStrategy
): ConflictResolutionStrategy {
  const priority: Record<ConflictResolutionStrategy, number> = {
    none: 0,
    lww: 1,
    crdt: 2,
    sync: 3,
    callback: 4,
  };

  return priority[next] > priority[current] ? next : current;
}

function asDecision(result: unknown): ConflictResolutionDecision {
  if (isRecord(result) && 'resolvedValue' in result) {
    return result as unknown as ConflictResolutionDecision;
  }

  return {
    resolvedValue: result,
    strategy: 'callback',
  };
}

// =============================================================================
// Collaboration Service
// =============================================================================

@Injectable()
export class CollaborationService implements OnDestroy {
  private readonly destroy$ = new Subject<void>();
  private readonly heartbeatStop$ = new Subject<void>();
  private config: CollabConfig | null = null;
  private ws: WebSocket | null = null;
  private currentRoomId: string | null = null;
  private reconnectAttempts = 0;

  private readonly connectionStateSubject = new BehaviorSubject<ConnectionState>('disconnected');
  readonly connectionState$ = this.connectionStateSubject.asObservable();

  private readonly participantsMap = new Map<string, Participant>();
  private readonly participantsSubject = new BehaviorSubject<Participant[]>([]);
  readonly participants$ = this.participantsSubject.asObservable();

  private readonly cursorsMap = new Map<string, CursorPosition>();
  private readonly cursorsSubject = new BehaviorSubject<CursorPosition[]>([]);
  readonly cursors$ = this.cursorsSubject.asObservable();

  private readonly componentSnapshots = new Map<string, InternalComponentStateSnapshot>();
  private readonly snapshotHistory = new Map<string, Map<number, InternalComponentStateSnapshot>>();

  private readonly stateChangesSubject = new Subject<StateChange>();
  readonly stateChanges$ = this.stateChangesSubject.asObservable();

  private readonly userColors = [
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
   * Configure the service.
   */
  configure(config: CollabConfig): void {
    this.config = config;
  }

  private resolveAuthToken(): string | undefined {
    const dynamic = this.config?.authTokenProvider?.()?.trim();
    if (dynamic) return dynamic;
    const configured = this.config?.authToken?.trim();
    return configured || undefined;
  }

  /**
   * Join a collaboration room.
   */
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
        const authToken = this.resolveAuthToken();
        const url = resolveWebSocketUrl(this.config!.websocketUrl, roomId, authToken);
        this.ws = new WebSocket(url);

        this.ws.onopen = () => {
          this.connectionStateSubject.next('connected');
          this.reconnectAttempts = 0;

          this.send({
            type: 'join',
            roomId,
            userId: this.config!.userId,
            displayName: this.config!.displayName,
            avatarUrl: this.config!.avatarUrl,
            authToken,
          });

          this.startPresenceHeartbeat();
          resolve();
        };

        this.ws.onmessage = (event) => {
          const message = deserializeCrdtValue(JSON.parse(event.data));
          this.handleMessage(message);
        };

        this.ws.onclose = () => {
          this.connectionStateSubject.next('disconnected');
          this.handleDisconnect();
        };

        this.ws.onerror = () => {
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
   * Leave current room.
   */
  async leaveRoom(): Promise<void> {
    this.heartbeatStop$.next();

    if (this.ws && this.currentRoomId && this.config) {
      this.send({
        type: 'leave',
        roomId: this.currentRoomId,
        userId: this.config.userId,
      });

      this.ws.close();
      this.ws = null;
    }

    this.currentRoomId = null;
    this.participantsMap.clear();
    this.cursorsMap.clear();
    this.componentSnapshots.clear();
    this.snapshotHistory.clear();
    this.emitParticipants();
    this.emitCursors();
  }

  /**
   * Update presence status.
   */
  updatePresence(status: Participant['status'], location?: string): void {
    if (!this.ws || !this.config) {
      return;
    }

    this.send({
      type: 'presence',
      userId: this.config.userId,
      status,
      location,
    });
  }

  /**
   * Broadcast cursor position.
   */
  broadcastCursor(x: number, y: number, componentId?: string): void {
    if (!this.ws || !this.config) {
      return;
    }

    this.send({
      type: 'cursor',
      userId: this.config.userId,
      x,
      y,
      componentId,
    });
  }

  /**
   * Broadcast a state change using optimistic local application.
   */
  broadcastStateChange(change: BroadcastStateChangeInput): StateChange | undefined {
    if (!this.config) {
      return undefined;
    }

    const componentKey = normalizeComponentId(change.componentId);
    const currentSnapshot = this.getOrCreateSnapshot(componentKey);
    const nextClock = currentSnapshot.vectorClock.clone();
    nextClock.increment(this.getNodeId());

    const fullChange: StateChange = {
      id: this.generateId(),
      userId: this.config.userId,
      timestamp: Date.now(),
      type: change.type,
      componentId: change.componentId,
      changes: cloneRecord(change.changes),
      version: currentSnapshot.version + 1,
      previousVersion: change.previousVersion ?? currentSnapshot.version,
      vectorClock: nextClock.toJSON(),
      resolutionStrategy: 'none',
    };

    const nextSnapshot: InternalComponentStateSnapshot = {
      componentId: componentKey,
      version: fullChange.version,
      state: applyStateChanges(currentSnapshot.state, fullChange.changes),
      vectorClock: nextClock,
      lastUpdatedBy: fullChange.userId,
      updatedAt: fullChange.timestamp,
    };

    this.storeSnapshot(nextSnapshot);
    this.send({ ...fullChange, type: 'state', changeType: fullChange.type });
    this.stateChangesSubject.next(fullChange);

    return fullChange;
  }

  /**
   * Get current participants.
   */
  getParticipants(): Participant[] {
    return Array.from(this.participantsMap.values());
  }

  /**
   * Get current room ID.
   */
  getCurrentRoomId(): string | null {
    return this.currentRoomId;
  }

  /**
   * Get the latest state snapshot for a component.
   */
  getStateSnapshot(componentId?: string): ComponentStateSnapshot | undefined {
    const snapshot = this.componentSnapshots.get(normalizeComponentId(componentId));
    return snapshot ? toPublicSnapshot(snapshot) : undefined;
  }

  /**
   * Handle incoming message.
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
      default:
        break;
    }
  }

  private handleJoin(msg: JoinMessage): void {
    if (msg.userId === this.config?.userId) {
      return;
    }

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
    if (!participant) {
      return;
    }

    participant.status = msg.status;
    participant.location = msg.location;
    participant.lastSeenAt = new Date();
    this.emitParticipants();
  }

  private handleCursor(msg: CursorMessage): void {
    if (msg.userId === this.config?.userId) {
      return;
    }

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
    if (msg.userId === this.config?.userId) {
      return;
    }

    const componentKey = normalizeComponentId(msg.componentId);
    const currentSnapshot = this.getOrCreateSnapshot(componentKey);
    const remoteClock = new VectorClock(msg.vectorClock);
    const { type: _messageType, ...statePayload } = msg;
    const remoteChange: StateChange = {
      ...statePayload,
      type: msg.changeType ?? 'component_update',
      changes: cloneRecord(msg.changes),
      vectorClock: remoteClock.toJSON(),
      resolutionStrategy: 'none',
    };

    if (msg.previousVersion !== undefined && msg.previousVersion !== currentSnapshot.version) {
      const baseSnapshot =
        this.getSnapshotAtVersion(componentKey, msg.previousVersion) ?? createEmptySnapshot(componentKey, msg.previousVersion);
      const resolved = this.resolveConflict(baseSnapshot, currentSnapshot, remoteChange, remoteClock);

      this.storeSnapshot(resolved.snapshot);
      this.stateChangesSubject.next({
        ...remoteChange,
        componentId: denormalizeComponentId(componentKey),
        changes: resolved.changes,
        version: resolved.snapshot.version,
        vectorClock: resolved.snapshot.vectorClock.toJSON(),
        conflictDetected: true,
        rollbackApplied: true,
        resolutionStrategy: resolved.strategy,
      });
      return;
    }

    const nextSnapshot: InternalComponentStateSnapshot = {
      componentId: componentKey,
      version: msg.version,
      state: applyStateChanges(currentSnapshot.state, remoteChange.changes),
      vectorClock: currentSnapshot.vectorClock.merge(remoteClock),
      lastUpdatedBy: msg.userId,
      updatedAt: msg.timestamp,
    };

    this.storeSnapshot(nextSnapshot);
    this.stateChangesSubject.next({
      ...remoteChange,
      componentId: denormalizeComponentId(componentKey),
      vectorClock: nextSnapshot.vectorClock.toJSON(),
    });
  }

  private handleSync(msg: SyncMessage): void {
    this.participantsMap.clear();
    for (const participant of msg.participants) {
      if (participant.userId !== this.config?.userId) {
        this.participantsMap.set(participant.userId, participant);
      }
    }
    this.emitParticipants();

    for (const [componentKey, incomingSnapshot] of Object.entries(msg.state)) {
      const remoteSnapshot = this.fromPublicSnapshot(componentKey, incomingSnapshot);
      const currentSnapshot = this.componentSnapshots.get(componentKey);

      if (!currentSnapshot) {
        this.storeSnapshot(remoteSnapshot);
        continue;
      }

      const localClock = currentSnapshot.vectorClock;
      const remoteClock = remoteSnapshot.vectorClock;

      if (localClock.happensBefore(remoteClock)) {
        const changes = diffState(currentSnapshot.state, remoteSnapshot.state);
        this.storeSnapshot(remoteSnapshot);
        if (Object.keys(changes).length > 0) {
          this.stateChangesSubject.next({
            id: this.generateId(),
            userId: remoteSnapshot.lastUpdatedBy ?? 'sync',
            timestamp: remoteSnapshot.updatedAt,
            type: 'component_update',
            componentId: denormalizeComponentId(componentKey),
            changes,
            version: remoteSnapshot.version,
            previousVersion: currentSnapshot.version,
            vectorClock: remoteSnapshot.vectorClock.toJSON(),
            resolutionStrategy: 'sync',
          });
        }
        continue;
      }

      if (remoteClock.happensBefore(localClock)) {
        continue;
      }

      const merged = this.mergeStates(
        createEmptySnapshot(componentKey).state,
        currentSnapshot,
        remoteSnapshot.state,
        {
          id: this.generateId(),
          userId: remoteSnapshot.lastUpdatedBy ?? 'sync',
          timestamp: remoteSnapshot.updatedAt,
          type: 'component_update',
          componentId: denormalizeComponentId(componentKey),
          changes: cloneRecord(remoteSnapshot.state),
          version: remoteSnapshot.version,
          previousVersion: currentSnapshot.version,
          vectorClock: remoteSnapshot.vectorClock.toJSON(),
          resolutionStrategy: 'sync',
        }
      );

      const nextSnapshot: InternalComponentStateSnapshot = {
        componentId: componentKey,
        version: Math.max(currentSnapshot.version, remoteSnapshot.version) + 1,
        state: merged.state,
        vectorClock: currentSnapshot.vectorClock.merge(remoteSnapshot.vectorClock),
        lastUpdatedBy: remoteSnapshot.lastUpdatedBy,
        updatedAt: Math.max(currentSnapshot.updatedAt, remoteSnapshot.updatedAt),
      };

      this.storeSnapshot(nextSnapshot);
      if (Object.keys(merged.changes).length > 0) {
        this.stateChangesSubject.next({
          id: this.generateId(),
          userId: remoteSnapshot.lastUpdatedBy ?? 'sync',
          timestamp: nextSnapshot.updatedAt,
          type: 'component_update',
          componentId: denormalizeComponentId(componentKey),
          changes: merged.changes,
          version: nextSnapshot.version,
          previousVersion: currentSnapshot.version,
          vectorClock: nextSnapshot.vectorClock.toJSON(),
          conflictDetected: true,
          rollbackApplied: true,
          resolutionStrategy: 'sync',
        });
      }
    }
  }

  /**
   * Handle disconnect and reconnection.
   */
  private handleDisconnect(): void {
    const maxAttempts = this.config?.maxReconnectAttempts ?? 5;
    const baseDelay = this.config?.reconnectDelayMs ?? 3000;

    if (this.currentRoomId && this.reconnectAttempts < maxAttempts) {
      this.connectionStateSubject.next('reconnecting');
      this.reconnectAttempts++;

      const backoffDelay = Math.min(baseDelay * Math.pow(2, this.reconnectAttempts - 1), 30_000);

      setTimeout(() => {
        if (this.currentRoomId) {
          this.joinRoom(this.currentRoomId).catch(() => {
            // Reconnect failed, will retry on a subsequent disconnect event.
          });
        }
      }, backoffDelay);
    }
  }

  /**
   * Start presence heartbeat.
   */
  private startPresenceHeartbeat(): void {
    this.heartbeatStop$.next();

    const intervalMs = this.config?.presenceIntervalMs ?? 30_000;
    interval(intervalMs)
      .pipe(
        takeUntil(this.destroy$),
        takeUntil(this.heartbeatStop$),
        filter(() => this.connectionStateSubject.value === 'connected')
      )
      .subscribe(() => {
        this.updatePresence('active');
      });
  }

  private resolveConflict(
    baseSnapshot: InternalComponentStateSnapshot,
    currentSnapshot: InternalComponentStateSnapshot,
    remoteChange: StateChange,
    remoteClock: VectorClock
  ): { snapshot: InternalComponentStateSnapshot; changes: Record<string, unknown>; strategy: ConflictResolutionStrategy } {
    const remoteState = applyStateChanges(baseSnapshot.state, remoteChange.changes);
    const merged = this.mergeStates(baseSnapshot.state, currentSnapshot, remoteState, remoteChange);

    return {
      snapshot: {
        componentId: currentSnapshot.componentId,
        version: Math.max(currentSnapshot.version, remoteChange.version) + 1,
        state: merged.state,
        vectorClock: currentSnapshot.vectorClock.merge(remoteClock),
        lastUpdatedBy: remoteChange.userId,
        updatedAt: Math.max(currentSnapshot.updatedAt, remoteChange.timestamp),
      },
      changes: merged.changes,
      strategy: merged.strategy,
    };
  }

  private mergeStates(
    baseState: Record<string, unknown>,
    currentSnapshot: InternalComponentStateSnapshot,
    remoteState: Record<string, unknown>,
    remoteChange: StateChange
  ): MergeResult {
    const mergedState = cloneRecord(baseState);
    let strategy: ConflictResolutionStrategy = 'none';
    const keys = new Set<string>([
      ...Object.keys(baseState),
      ...Object.keys(currentSnapshot.state),
      ...Object.keys(remoteState),
    ]);

    for (const key of keys) {
      const baseValue = baseState[key];
      const localValue = currentSnapshot.state[key];
      const nextRemoteValue = remoteState[key];
      const localChanged = !compareSerializableValues(localValue, baseValue);
      const remoteChanged = !compareSerializableValues(nextRemoteValue, baseValue);

      if (!localChanged && !remoteChanged) {
        if (baseValue !== undefined) {
          mergedState[key] = deserializeCrdtValue(serializeCrdtValue(baseValue));
        }
        continue;
      }

      if (localChanged && !remoteChanged) {
        mergedState[key] = deserializeCrdtValue(serializeCrdtValue(localValue));
        continue;
      }

      if (!localChanged && remoteChanged) {
        mergedState[key] = deserializeCrdtValue(serializeCrdtValue(nextRemoteValue));
        continue;
      }

      const mergedCrdt = mergeCrdtValues(localValue, nextRemoteValue);
      if (mergedCrdt !== undefined) {
        mergedState[key] = mergedCrdt;
        strategy = selectPreferredStrategy(strategy, 'crdt');
        continue;
      }

      const resolver = this.config?.conflictResolver;
      if (resolver) {
        const decision = asDecision(
          resolver({
            componentId: currentSnapshot.componentId,
            key,
            baseValue,
            localValue,
            remoteValue: nextRemoteValue,
            localSnapshot: toPublicSnapshot(currentSnapshot),
            remoteChange,
          })
        );

        mergedState[key] = deserializeCrdtValue(serializeCrdtValue(decision.resolvedValue));
        strategy = selectPreferredStrategy(strategy, decision.strategy ?? 'callback');
        continue;
      }

      const localClock = currentSnapshot.vectorClock;
      const incomingClock = new VectorClock(remoteChange.vectorClock);

      if (localClock.happensBefore(incomingClock)) {
        mergedState[key] = deserializeCrdtValue(serializeCrdtValue(nextRemoteValue));
      } else if (incomingClock.happensBefore(localClock)) {
        mergedState[key] = deserializeCrdtValue(serializeCrdtValue(localValue));
      } else {
        mergedState[key] = remoteChange.timestamp >= currentSnapshot.updatedAt
          ? deserializeCrdtValue(serializeCrdtValue(nextRemoteValue))
          : deserializeCrdtValue(serializeCrdtValue(localValue));
      }

      strategy = selectPreferredStrategy(strategy, 'lww');
    }

    return {
      state: mergedState,
      changes: diffState(currentSnapshot.state, mergedState),
      strategy,
    };
  }

  /**
   * Send message over WebSocket.
   */
  private send(message: CollabMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(serializeCrdtValue(message)));
    }
  }

  private getNodeId(): string {
    return this.config?.nodeId ?? this.config?.userId ?? 'unknown-node';
  }

  private fromPublicSnapshot(
    componentId: string,
    snapshot: ComponentStateSnapshot
  ): InternalComponentStateSnapshot {
    return {
      componentId,
      version: snapshot.version,
      state: cloneRecord(snapshot.state),
      vectorClock: new VectorClock(snapshot.vectorClock),
      lastUpdatedBy: snapshot.lastUpdatedBy,
      updatedAt: snapshot.updatedAt,
    };
  }

  private getOrCreateSnapshot(componentId: string): InternalComponentStateSnapshot {
    const existing = this.componentSnapshots.get(componentId);
    if (existing) {
      return {
        componentId: existing.componentId,
        version: existing.version,
        state: cloneRecord(existing.state),
        vectorClock: existing.vectorClock.clone(),
        lastUpdatedBy: existing.lastUpdatedBy,
        updatedAt: existing.updatedAt,
      };
    }

    const snapshot = createEmptySnapshot(componentId);
    this.storeSnapshot(snapshot);
    return this.getOrCreateSnapshot(componentId);
  }

  private getSnapshotAtVersion(componentId: string, version: number): InternalComponentStateSnapshot | undefined {
    const history = this.snapshotHistory.get(componentId);
    const snapshot = history?.get(version);
    if (!snapshot) {
      return undefined;
    }

    return {
      componentId: snapshot.componentId,
      version: snapshot.version,
      state: cloneRecord(snapshot.state),
      vectorClock: snapshot.vectorClock.clone(),
      lastUpdatedBy: snapshot.lastUpdatedBy,
      updatedAt: snapshot.updatedAt,
    };
  }

  private storeSnapshot(snapshot: InternalComponentStateSnapshot): void {
    const clonedSnapshot: InternalComponentStateSnapshot = {
      componentId: snapshot.componentId,
      version: snapshot.version,
      state: cloneRecord(snapshot.state),
      vectorClock: snapshot.vectorClock.clone(),
      lastUpdatedBy: snapshot.lastUpdatedBy,
      updatedAt: snapshot.updatedAt,
    };

    this.componentSnapshots.set(snapshot.componentId, clonedSnapshot);

    const history = this.snapshotHistory.get(snapshot.componentId) ?? new Map<number, InternalComponentStateSnapshot>();
    history.set(snapshot.version, clonedSnapshot);
    const limit = this.config?.snapshotHistoryLimit ?? 25;

    if (history.size > limit) {
      const versions = Array.from(history.keys()).sort((left, right) => left - right);
      while (versions.length > limit) {
        const version = versions.shift();
        if (version !== undefined) {
          history.delete(version);
        }
      }
    }

    this.snapshotHistory.set(snapshot.componentId, history);
  }

  /**
   * Get next color for participant.
   */
  private getNextColor(): string {
    const color = this.userColors[this.colorIndex % this.userColors.length];
    this.colorIndex++;
    return color;
  }

  /**
   * Emit participants list.
   */
  private emitParticipants(): void {
    this.participantsSubject.next(Array.from(this.participantsMap.values()));
  }

  /**
   * Emit cursors list.
   */
  private emitCursors(): void {
    this.cursorsSubject.next(Array.from(this.cursorsMap.values()));
  }

  /**
   * Generate unique ID.
   */
  private generateId(): string {
    return crypto.randomUUID();
  }

  ngOnDestroy(): void {
    this.leaveRoom();
    this.heartbeatStop$.next();
    this.heartbeatStop$.complete();
    this.destroy$.next();
    this.destroy$.complete();
    this.participantsSubject.complete();
    this.cursorsSubject.complete();
    this.stateChangesSubject.complete();
    this.connectionStateSubject.complete();
  }
}

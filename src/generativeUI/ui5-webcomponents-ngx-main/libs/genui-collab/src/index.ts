// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * @ui5/genui-collab - Public API
 */

// Module
export { GenUiCollabModule } from './lib/genui-collab.module';

// CRDT primitives
export {
  VectorClock,
  GCounter,
  PNCounter,
  ORSet,
  LWWMap,
  mergeCrdtValues,
  serializeCrdtValue,
  deserializeCrdtValue,
  compareSerializableValues,
} from './lib/crdt';
export type {
  SerializedVectorClock,
  SerializedGCounter,
  SerializedPNCounter,
  SerializedORSet,
  SerializedLWWMap,
  SerializedLWWMapEntry,
  SerializedCRDTValue,
  VectorClockLike,
} from './lib/crdt';

// Service
export {
  CollaborationService,
  COLLAB_CONFIG,
} from './lib/services/collaboration.service';
export type {
  CollabConfig,
  BroadcastStateChangeInput,
  ComponentStateSnapshot,
  ConflictResolutionContext,
  ConflictResolutionDecision,
  ConflictResolver,
  ConflictResolutionStrategy,
  Participant,
  CursorPosition,
  StateChange,
  StateChangeType,
  ConnectionState,
} from './lib/services/collaboration.service';
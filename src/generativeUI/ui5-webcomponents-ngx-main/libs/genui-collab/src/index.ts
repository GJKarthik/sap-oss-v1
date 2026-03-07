// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * @ui5/genui-collab - Public API
 */

// Module
export { GenUiCollabModule } from './lib/genui-collab.module';

// Service
export {
  CollaborationService,
  COLLAB_CONFIG,
  CollabConfig,
  Participant,
  CursorPosition,
  StateChange,
  ConnectionState,
} from './lib/services/collaboration.service';
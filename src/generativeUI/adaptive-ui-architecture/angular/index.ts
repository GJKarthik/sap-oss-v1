/**
 * Adaptive UI Architecture — Angular Exports
 *
 * Import from this file to get all Angular-specific exports:
 *
 * @example
 * ```typescript
 * import {
 *   AdaptiveUiModule,
 *   AdaptationService,
 *   AdaptiveChatCaptureDirective,
 * } from '@adaptive-ui/angular';
 * ```
 */

// Module
export { AdaptiveUiModule, type AdaptiveUiConfig } from './adaptive-ui.module';

// Services (re-exported from core)
export { AdaptationService } from '../core/adaptation/angular/adaptation.service';
export { contextProvider } from '../core/context/context-provider';
export { captureService } from '../core/capture/capture-service';
export { modelingService, autoModeler } from '../core/modeling';
export { adaptationCoordinator } from '../core/adaptation/coordinator';
export { feedbackService } from '../core/feedback';

// Directives
// Note: Core directives are not re-exported to avoid Angular compilation issues
// in monorepo setup. Import AdaptiveChatCaptureDirective from this module.
export { AdaptiveChatCaptureDirective, type ChatCaptureConfig } from './adaptive-chat.directive';

// Types (re-exported from core)
export type {
  AdaptationDecision,
  LayoutAdaptation,
  ContentAdaptation,
  InteractionAdaptation,
} from '../core/adaptation/types';

export type {
  AdaptiveContext,
  UserContext,
  DeviceContext,
  TaskContext,
  UserRole,
} from '../core/context/types';

export type {
  UserModel,
  ExpertiseModel,
  FilterPreferences,
  TablePreferences,
  LayoutPreferences,
} from '../core/modeling/types';

export type {
  InteractionEvent,
  InteractionType,
  CaptureConfig,
} from '../core/capture/types';


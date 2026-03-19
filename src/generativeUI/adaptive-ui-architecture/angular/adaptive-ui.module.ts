/**
 * Adaptive UI Architecture — Angular Module
 *
 * Unified module for integrating adaptive UI capabilities into Angular applications.
 * Import this module to get access to:
 * - AdaptationService (layout, content, interaction adaptations)
 * - CaptureDirectives (interaction tracking)
 * - ContextService (user, device, task context)
 * - FeedbackComponents (user feedback collection)
 */

import { NgModule, ModuleWithProviders } from '@angular/core';
import { CommonModule } from '@angular/common';

// Services
import { AdaptationService } from '../core/adaptation/angular/adaptation.service';
import { contextProvider } from '../core/context/context-provider';
import { captureService } from '../core/capture/capture-service';
import { modelingService, autoModeler } from '../core/modeling';
import { adaptationCoordinator } from '../core/adaptation/coordinator';
import { feedbackService } from '../core/feedback';

// Directives - Only import the chat directive we created
// Note: Core directives (AdaptiveCaptureDirective, etc.) should be imported
// directly by consumers if needed, once this package is properly linked
import { AdaptiveChatCaptureDirective } from './adaptive-chat.directive';

// Configuration
export interface AdaptiveUiConfig {
  /** Privacy level for capture (default: 'medium') */
  privacyLevel?: 'none' | 'low' | 'medium' | 'high';
  /** Anonymize captured events (default: true) */
  anonymize?: boolean;
  /** Fields to exclude from capture */
  excludeFields?: string[];
  /** Auto-start the adaptation coordinator (default: true) */
  autoStart?: boolean;
  /** Minimum confidence to apply adaptations (default: 0.3) */
  minConfidence?: number;
  /** CSS variable prefix (default: '--adaptive') */
  cssVariablePrefix?: string;
  /** Enable debug logging (default: false) */
  debug?: boolean;
}

const DEFAULT_CONFIG: AdaptiveUiConfig = {
  privacyLevel: 'medium',
  anonymize: true,
  excludeFields: ['content', 'password', 'token'],
  autoStart: true,
  minConfidence: 0.3,
  cssVariablePrefix: '--adaptive',
  debug: false,
};

/**
 * Factory function to configure adaptive UI services
 */
function configureAdaptiveServices(config: AdaptiveUiConfig): void {
  // Configure capture service
  const anonymizationLevel = config.privacyLevel === 'high' ? 'full'
    : config.privacyLevel === 'low' ? 'none'
    : 'partial';

  captureService.configure({
    enabled: config.privacyLevel !== 'none',
    anonymizationLevel,
    excludedComponents: config.excludeFields || [],
  });

  // Start auto-modeler (bridges capture → user model)
  if (config.autoStart) {
    autoModeler.start();
  }

  if (config.debug) {
    console.log('[AdaptiveUI] Services configured:', config);
  }
}

@NgModule({
  imports: [
    CommonModule,
    // Standalone directives
    AdaptiveChatCaptureDirective,
  ],
  exports: [
    // Re-export directives for use in templates
    AdaptiveChatCaptureDirective,
  ],
  providers: [
    AdaptationService,
  ],
})
export class AdaptiveUiModule {
  /**
   * Configure the adaptive UI module for the root application.
   * Call this once in your root AppModule.
   *
   * @example
   * ```typescript
   * @NgModule({
   *   imports: [
   *     AdaptiveUiModule.forRoot({
   *       privacyLevel: 'high',
   *       anonymize: true,
   *     }),
   *   ],
   * })
   * export class AppModule {}
   * ```
   */
  static forRoot(config: AdaptiveUiConfig = {}): ModuleWithProviders<AdaptiveUiModule> {
    const mergedConfig = { ...DEFAULT_CONFIG, ...config };
    configureAdaptiveServices(mergedConfig);

    return {
      ngModule: AdaptiveUiModule,
      providers: [
        AdaptationService,
        { provide: 'ADAPTIVE_UI_CONFIG', useValue: mergedConfig },
      ],
    };
  }

  /**
   * Import in feature modules (no configuration needed).
   */
  static forChild(): ModuleWithProviders<AdaptiveUiModule> {
    return {
      ngModule: AdaptiveUiModule,
      providers: [],
    };
  }
}

// Re-export services for direct import
export { AdaptationService } from '../core/adaptation/angular/adaptation.service';
export { contextProvider, captureService, modelingService, autoModeler };
export { adaptationCoordinator } from '../core/adaptation/coordinator';
export { feedbackService } from '../core/feedback';

// Re-export directives
// Note: Core directives are not re-exported to avoid Angular compilation issues
// in monorepo setup. Import AdaptiveChatCaptureDirective from this module.
export { AdaptiveChatCaptureDirective, type ChatCaptureConfig } from './adaptive-chat.directive';

// Re-export types
export type { AdaptationDecision, LayoutAdaptation, ContentAdaptation, InteractionAdaptation } from '../core/adaptation/types';
export type { AdaptiveContext, UserContext, DeviceContext, TaskContext } from '../core/context/types';
export type { UserModel } from '../core/modeling/types';
export type { InteractionEvent, InteractionType, CaptureConfig } from '../core/capture/types';


/**
 * Adaptive UI Architecture — Adaptation Layer Exports
 */

// Types
export * from './types';

// Engine
export { AdaptationEngineImpl, adaptationEngine } from './engine';

// Coordinator
export { AdaptationCoordinator, adaptationCoordinator } from './coordinator';
export type { CoordinatorConfig, AdaptationListener } from './coordinator';

// Rules
export * from './rules';


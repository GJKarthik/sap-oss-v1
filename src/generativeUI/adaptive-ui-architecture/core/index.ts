/**
 * Adaptive UI Architecture — Core Exports
 *
 * Phase 1: Context & Capture ✅
 * Phase 2: User Modeling ✅
 * Phase 3: Adaptation (types + basic engine)
 */

// Layer 0: Context
export * from './context';

// Layer 1: Capture
export * from './capture';

// Layer 2: Modeling
export * from './modeling';

// Layer 3: Adaptation
export * from './adaptation/types';
export { AdaptationEngineImpl, adaptationEngine } from './adaptation/engine';


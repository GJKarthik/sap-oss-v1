/**
 * Adaptive UI Architecture — Capture Layer Exports
 */

export * from './types';
export { CaptureServiceImpl, captureService } from './capture-service';
export { createCaptureHooks, createHoverTracker, createFocusTracker } from './capture-hooks';
export type { CaptureOptions, CaptureHooks } from './capture-hooks';


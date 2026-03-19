/**
 * Adaptive UI Architecture — Auto Modeler
 * 
 * Automatically connects the Capture Service to the Modeling Service.
 * Periodically batches captured events and updates user models.
 */

import { captureService } from '../capture/capture-service';
import { contextProvider } from '../context/context-provider';
import { modelingService } from './modeling-service';
import type { InteractionEvent } from '../capture/types';

// ============================================================================
// CONFIGURATION
// ============================================================================

export interface AutoModelerConfig {
  /** How often to batch and process events (ms) */
  batchIntervalMs: number;
  /** Minimum events before triggering an update */
  minEventsForUpdate: number;
  /** Maximum events to process in one batch */
  maxBatchSize: number;
  /** Whether to auto-start on creation */
  autoStart: boolean;
}

const DEFAULT_CONFIG: AutoModelerConfig = {
  batchIntervalMs: 30000, // 30 seconds
  minEventsForUpdate: 5,
  maxBatchSize: 100,
  autoStart: true,
};

// ============================================================================
// AUTO MODELER
// ============================================================================

export class AutoModeler {
  private config: AutoModelerConfig;
  private intervalId: ReturnType<typeof setInterval> | null = null;
  private pendingEvents: InteractionEvent[] = [];
  private unsubscribeCapture: (() => void) | null = null;
  private isRunning = false;
  
  constructor(config: Partial<AutoModelerConfig> = {}) {
    this.config = { ...DEFAULT_CONFIG, ...config };
    
    if (this.config.autoStart) {
      this.start();
    }
  }
  
  /** Start automatic model updates */
  start(): void {
    if (this.isRunning) return;
    
    this.isRunning = true;
    
    // Subscribe to new capture events
    this.unsubscribeCapture = captureService.subscribe((event) => {
      this.pendingEvents.push(event);
      
      // If we have enough events, process immediately
      if (this.pendingEvents.length >= this.config.maxBatchSize) {
        this.processBatch();
      }
    });
    
    // Set up periodic processing
    this.intervalId = setInterval(() => {
      this.processBatch();
    }, this.config.batchIntervalMs);
  }
  
  /** Stop automatic model updates */
  stop(): void {
    if (!this.isRunning) return;
    
    this.isRunning = false;
    
    if (this.unsubscribeCapture) {
      this.unsubscribeCapture();
      this.unsubscribeCapture = null;
    }
    
    if (this.intervalId) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
    
    // Process any remaining events
    this.processBatch();
  }
  
  /** Process pending events */
  private processBatch(): void {
    if (this.pendingEvents.length < this.config.minEventsForUpdate) {
      return;
    }
    
    // Get the current user
    const context = contextProvider.getContext();
    const userId = context.user.userId;
    
    if (userId === 'anonymous') {
      // Don't model anonymous users
      this.pendingEvents = [];
      return;
    }
    
    // Take a batch of events
    const batch = this.pendingEvents.splice(0, this.config.maxBatchSize);
    
    // Update the model
    try {
      modelingService.updateModel(userId, batch);
    } catch (e) {
      console.error('[AutoModeler] Failed to update model:', e);
      // Re-add events on failure (will retry next batch)
      this.pendingEvents.unshift(...batch);
    }
  }
  
  /** Force an immediate model update */
  flush(): void {
    const saved = this.config.minEventsForUpdate;
    this.config.minEventsForUpdate = 1;
    this.processBatch();
    this.config.minEventsForUpdate = saved;
  }
  
  /** Get current pending event count */
  getPendingCount(): number {
    return this.pendingEvents.length;
  }
  
  /** Check if auto-modeler is running */
  isActive(): boolean {
    return this.isRunning;
  }
  
  /** Update configuration */
  configure(config: Partial<AutoModelerConfig>): void {
    const wasRunning = this.isRunning;
    
    if (wasRunning) {
      this.stop();
    }
    
    this.config = { ...this.config, ...config };
    
    if (wasRunning) {
      this.start();
    }
  }
}

// Singleton instance (auto-starts by default)
export const autoModeler = new AutoModeler();


/**
 * SAC Allocation Service
 *
 * Service for executing SAC allocation operations.
 * Derived from mangle/sac_planning.mg allocation_type, service_method "Allocation" facts.
 */

import { Injectable } from '@angular/core';

import { SacApiService } from '@sap-oss/sac-ngx-core';

export enum AllocationType {
  TopDown = 'top_down',
  BottomUp = 'bottom_up',
  Distribute = 'distribute',
  WeightBased = 'weight_based',
  Reference = 'reference',
}

export interface Allocation {
  id: string;
  name: string;
  type: AllocationType;
  sourceDimension: string;
  targetDimension: string;
  measure: string;
}

export interface AllocationParameter {
  sourceMember: string;
  targetMembers: string[];
  amount?: number;
  weights?: Record<string, number>;
  referenceDimension?: string;
}

export interface AllocationResult {
  success: boolean;
  rowsAffected: number;
  sourceValue: number;
  targetValues: Record<string, number>;
  message?: string;
}

@Injectable({ providedIn: 'root' })
export class SacAllocationService {
  constructor(private readonly api: SacApiService) {}

  /**
   * Execute allocation.
   * Implements: service_method("Allocation", "execute", "AllocationResult", "async")
   */
  async execute(allocation: Allocation, params: AllocationParameter): Promise<AllocationResult> {
    return this.api.post<AllocationResult>('/api/v1/planning/allocations/execute', {
      allocation,
      params,
    });
  }

  /**
   * Preview allocation (without committing).
   * Implements: service_method("Allocation", "preview", "AllocationResult", "async")
   */
  async preview(allocation: Allocation, params: AllocationParameter): Promise<AllocationResult> {
    return this.api.post<AllocationResult>('/api/v1/planning/allocations/preview', {
      allocation,
      params,
    });
  }

  /**
   * Validate allocation configuration.
   * Implements: service_method("Allocation", "validate", "ValidationResult", "sync")
   */
  validate(allocation: Allocation, params: AllocationParameter): { valid: boolean; errors: string[] } {
    const errors: string[] = [];

    if (!params.sourceMember) {
      errors.push('Source member is required');
    }

    if (!params.targetMembers || params.targetMembers.length === 0) {
      errors.push('At least one target member is required');
    }

    if (allocation.type === AllocationType.WeightBased && !params.weights) {
      errors.push('Weights are required for weight-based allocation');
    }

    if (allocation.type === AllocationType.Reference && !params.referenceDimension) {
      errors.push('Reference dimension is required for reference-based allocation');
    }

    return { valid: errors.length === 0, errors };
  }

  /**
   * Calculate weights for equal distribution.
   */
  calculateEqualWeights(targetMembers: string[]): Record<string, number> {
    const weight = 1 / targetMembers.length;
    return targetMembers.reduce((acc, member) => {
      acc[member] = weight;
      return acc;
    }, {} as Record<string, number>);
  }

  /**
   * Calculate weights based on proportional values.
   */
  calculateProportionalWeights(values: Record<string, number>): Record<string, number> {
    const total = Object.values(values).reduce((sum, value) => sum + value, 0);
    if (total === 0) return {};

    return Object.entries(values).reduce((acc, [key, value]) => {
      acc[key] = value / total;
      return acc;
    }, {} as Record<string, number>);
  }
}

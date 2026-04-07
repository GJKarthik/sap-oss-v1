/**
 * Allocation Types
 * Derived from mangle/sac_planning.mg
 */

export interface Allocation {
  id: string;
  name: string;
  type: string;
  sourceDimension: string;
  targetDimension: string;
  measure: string;
}

export interface AllocationParameter {
  id: string;
  name: string;
  type: string;
  value?: unknown;
  required: boolean;
}

export interface AllocationResult {
  allocationId: string;
  status: string;
  affectedCells: number;
  duration: number;
  message?: string;
}

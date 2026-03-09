/**
 * Data Action Types
 * Derived from mangle/sac_planning.mg
 */

export interface DataAction {
  id: string;
  name: string;
  description?: string;
  parameters: DataActionParameter[];
}

export interface DataActionParameter {
  id: string;
  name: string;
  type: string;
  required: boolean;
  defaultValue?: unknown;
}

export interface DataActionResult {
  actionId: string;
  executionId: string;
  status: string;
  startTime: string;
  endTime?: string;
  message?: string;
}

export interface DataActionTrigger {
  actionId: string;
  event: string;
  condition?: string;
  enabled: boolean;
}

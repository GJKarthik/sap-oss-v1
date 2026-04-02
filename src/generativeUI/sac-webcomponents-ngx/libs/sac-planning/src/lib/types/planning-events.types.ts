/**
 * Planning event types — from sap-sac-webcomponents-ts/src/planning
 */

export interface PlanningEvents {
  onDataActionExecuted?: (event: DataActionExecutedEvent) => void;
  onVersionChanged?: (event: VersionChangedEvent) => void;
  onDataLocked?: (event: DataLockedEvent) => void;
}

export interface DataActionExecutedEvent {
  actionId: string;
  status: string;
  duration: number;
}

export interface VersionChangedEvent {
  versionId: string;
  versionType: string;
  previousVersionId?: string;
}

export interface DataLockedEvent {
  scope: string;
  lockedBy: string;
  timestamp: string;
}

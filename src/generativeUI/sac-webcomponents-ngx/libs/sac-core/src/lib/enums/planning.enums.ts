/**
 * Planning Enums
 *
 * Re-exports shared enums from the package SDK bundle (single source of truth).
 * PlanningVersionType, PlanningAreaStatus, DataLockingScope, AllocationType,
 * PrivatePublishConflict, PublicPublishConflict, BPCPlanningSequenceStatus
 * are NGX-only extras — kept below.
 */
export {
  PlanningCategory,
  PlanningCopyOption,
  DataLockingState,
  DataActionParameterValueType,
  DataActionExecutionStatus,
} from '@sap-oss/sac-sdk';

/** Planning version type */
export enum PlanningVersionType {
  Public = 'Public',
  Private = 'Private',
  Actual = 'Actual',
}

/** Planning area status */
export enum PlanningAreaStatus {
  Open = 'Open',
  Closed = 'Closed',
  Locked = 'Locked',
  Published = 'Published',
}

/** Data locking scope */
export enum DataLockingScope {
  All = 'All',
  Selected = 'Selected',
  FilteredData = 'FilteredData',
}

/** Allocation type */
export enum AllocationType {
  Equal = 'Equal',
  Proportional = 'Proportional',
  WeightBased = 'WeightBased',
  Reference = 'Reference',
}

/** Publish conflict type - private version */
export enum PrivatePublishConflict {
  None = 'None',
  DataChanged = 'DataChanged',
  StructureChanged = 'StructureChanged',
  Deleted = 'Deleted',
}

/** Publish conflict type - public version */
export enum PublicPublishConflict {
  None = 'None',
  NewerVersionExists = 'NewerVersionExists',
  VersionLocked = 'VersionLocked',
  InsufficientPermissions = 'InsufficientPermissions',
}

/** BPC planning sequence status */
export enum BPCPlanningSequenceStatus {
  NotStarted = 'NotStarted',
  InProgress = 'InProgress',
  Completed = 'Completed',
  Failed = 'Failed',
  Cancelled = 'Cancelled',
}

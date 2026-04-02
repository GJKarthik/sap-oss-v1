/**
 * @sap-oss/sac-webcomponents-ngx/sdk — PlanningModel, DataAction, BPCPlanningSequence,
 *   Version, Allocation, PlanningPanel, DataLocking
 *
 * Maps to: sac_widgets.mg category "Planning"
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/planning/ (26 handlers)
 */

import type { SACRestAPIClient } from '../client';
import type {
  OperationResult, DataLockingState, PlanningCategory, PlanningCopyOption,
  DataActionExecutionStatus, DataActionParameterValueType,
} from '../types';

// ---------------------------------------------------------------------------
// Enums from specs
// ---------------------------------------------------------------------------

export enum DataLockingScope {
  Cell = 'cell',
  Row = 'row',
  Column = 'column',
  Region = 'region',
  Version = 'version',
}

export enum PlanningVersionType {
  Private = 'private',
  Public = 'public',
}

export enum PlanningAreaStatus {
  Active = 'active',
  Inactive = 'inactive',
  Locked = 'locked',
  Archived = 'archived',
}

export enum PrivatePublishConflict {
  Overwrite = 'overwrite',
  Skip = 'skip',
  Merge = 'merge',
  Abort = 'abort',
}

export enum PublicPublishConflict {
  Overwrite = 'overwrite',
  Merge = 'merge',
  Append = 'append',
}

// ---------------------------------------------------------------------------
// Planning types
// ---------------------------------------------------------------------------

export interface PlanningSession {
  id: string;
  modelId: string;
  status: string;
  createdAt?: string;
}

export interface LockInfo {
  id?: string;
  state: DataLockingState;
  lockedBy?: string;
  lockedAt?: string;
  scope?: DataLockingScope;
  context?: Record<string, string>;
}

export interface VersionInfo {
  id: string;
  name?: string;
  description?: string;
  status: string;
  category?: PlanningCategory;
  versionType?: PlanningVersionType;
  isPublic?: boolean;
  isEditable?: boolean;
  createdAt?: string;
  createdBy?: string;
  modifiedAt?: string;
}

export interface PlanningAreaInfo {
  id: string;
  name: string;
  description?: string;
  modelId: string;
  dimensions: string[];
  measures: string[];
  status: PlanningAreaStatus;
}

export interface PlanningAreaFilter {
  dimensionId: string;
  members: string[];
  include: boolean;
}

export interface PlanningAreaMemberInfo {
  id: string;
  name: string;
  description?: string;
  level?: number;
  parentId?: string;
  isLeaf?: boolean;
  properties?: Record<string, unknown>;
}

export interface PrivateVersionPublishOptions {
  targetVersion?: string;
  conflictResolution?: PrivatePublishConflict;
  includeComments?: boolean;
  notify?: string[];
}

export interface PublicVersionPublishOptions {
  targetVersion?: string;
  conflictResolution?: PublicPublishConflict;
}

export interface DataActionParameter {
  id: string;
  description?: string;
  valueType: DataActionParameterValueType;
  value?: string;
  availableValues?: string[];
}

export interface DataActionResult {
  status: DataActionExecutionStatus;
  message?: string;
  details?: string;
  affectedRecords?: number;
}

export interface AllocationParameter {
  id: string;
  value: string;
}

export interface BPCVariableInfo {
  id: string;
  description?: string;
  value?: string;
  availableValues?: string[];
}

export interface BPCExecutionResponse {
  status: string;
  message?: string;
  details?: string;
  success: boolean;
  errorCode?: string;
}

// ---------------------------------------------------------------------------
// PlanningModel
// ---------------------------------------------------------------------------

export class PlanningModel {
  constructor(
    private readonly client: SACRestAPIClient,
    public readonly id: string,
  ) {}

  async submitData(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/submit`);
  }

  async revertData(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/revert`);
  }

  async publish(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/publish`);
  }

  async getDataSource(): Promise<string> {
    return this.client.get<string>(`/planning/${e(this.id)}/datasource`);
  }

  async setDataSource(dsName: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/planning/${e(this.id)}/datasource`, { name: dsName });
  }

  async getEditMode(): Promise<string> {
    return this.client.get<string>(`/planning/${e(this.id)}/editMode`);
  }

  async setEditMode(mode: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/planning/${e(this.id)}/editMode`, { mode });
  }

  async isDataChanged(): Promise<boolean> {
    return this.client.get<boolean>(`/planning/${e(this.id)}/dataChanged`);
  }

  async validate(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/validate`);
  }

  // -- Locking ---------------------------------------------------------------

  async lock(scope?: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/lock`, { scope });
  }

  async unlock(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/unlock`);
  }

  async isLocked(): Promise<boolean> {
    return this.client.get<boolean>(`/planning/${e(this.id)}/locked`);
  }

  async getLockInfo(): Promise<LockInfo> {
    return this.client.get<LockInfo>(`/planning/${e(this.id)}/lockInfo`);
  }

  // -- Versions --------------------------------------------------------------

  async getVersion(): Promise<VersionInfo> {
    return this.client.get<VersionInfo>(`/planning/${e(this.id)}/version`);
  }

  async createVersion(description?: string, category?: PlanningCategory): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/version`, { description, category });
  }

  async deleteVersion(versionId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/planning/${e(this.id)}/version/${e(versionId)}`);
  }

  async copyVersion(sourceId: string, targetId: string, option?: PlanningCopyOption): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/version/copy`, { sourceId, targetId, option });
  }

  async getVersions(): Promise<VersionInfo[]> {
    return this.client.get<VersionInfo[]>(`/planning/${e(this.id)}/versions`);
  }

  async getPrivateVersions(): Promise<VersionInfo[]> {
    return this.client.get<VersionInfo[]>(`/planning/${e(this.id)}/versions?type=private`);
  }

  async getPublicVersions(): Promise<VersionInfo[]> {
    return this.client.get<VersionInfo[]>(`/planning/${e(this.id)}/versions?type=public`);
  }

  async createPrivateVersion(name: string, baseVersion?: string): Promise<VersionInfo> {
    return this.client.post<VersionInfo>(`/planning/${e(this.id)}/version/private`, { name, baseVersion });
  }

  async publishPrivateVersion(
    versionId: string, options?: PrivateVersionPublishOptions,
  ): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/planning/${e(this.id)}/version/${e(versionId)}/publish`, options ?? {},
    );
  }

  // -- Planning areas --------------------------------------------------------

  async getPlanningAreas(): Promise<PlanningAreaInfo[]> {
    return this.client.get<PlanningAreaInfo[]>(`/planning/${e(this.id)}/areas`);
  }

  async getPlanningArea(areaId: string): Promise<PlanningAreaInfo> {
    return this.client.get<PlanningAreaInfo>(`/planning/${e(this.id)}/areas/${e(areaId)}`);
  }

  async getAreaMembers(areaId: string, dimensionId: string): Promise<PlanningAreaMemberInfo[]> {
    return this.client.get<PlanningAreaMemberInfo[]>(
      `/planning/${e(this.id)}/areas/${e(areaId)}/dimensions/${e(dimensionId)}/members`,
    );
  }

  // -- Data locking (spec-aligned) -------------------------------------------

  async lockData(
    scope?: DataLockingScope, context?: Record<string, string>,
  ): Promise<LockInfo> {
    return this.client.post<LockInfo>(
      `/planning/${e(this.id)}/lock`, { scope: scope ?? DataLockingScope.Cell, context },
    );
  }

  async unlockData(lockId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planning/${e(this.id)}/unlock/${e(lockId)}`);
  }

  async getLockState(context?: Record<string, string>): Promise<LockInfo> {
    return this.client.post<LockInfo>(`/planning/${e(this.id)}/lockState`, { context });
  }

  // -- Factory ---------------------------------------------------------------

  static async getPlanningModel(client: SACRestAPIClient, id: string): Promise<PlanningModel> {
    return new PlanningModel(client, id);
  }
}

// ---------------------------------------------------------------------------
// DataAction
// ---------------------------------------------------------------------------

export class DataAction {
  constructor(
    private readonly client: SACRestAPIClient,
    public readonly id: string,
  ) {}

  async execute(): Promise<DataActionResult> {
    return this.client.post<DataActionResult>(`/dataaction/${e(this.id)}/execute`);
  }

  async getParameters(): Promise<DataActionParameter[]> {
    return this.client.get<DataActionParameter[]>(`/dataaction/${e(this.id)}/parameters`);
  }

  async setParameter(parameterId: string, value: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/dataaction/${e(this.id)}/parameters/${e(parameterId)}`, { value });
  }

  async getStatus(): Promise<DataActionExecutionStatus> {
    return this.client.get<DataActionExecutionStatus>(`/dataaction/${e(this.id)}/status`);
  }

  async cancel(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/dataaction/${e(this.id)}/cancel`);
  }

  async isRunning(): Promise<boolean> {
    return this.client.get<boolean>(`/dataaction/${e(this.id)}/running`);
  }

  static async getDataAction(client: SACRestAPIClient, id: string): Promise<DataAction> {
    return new DataAction(client, id);
  }
}

// ---------------------------------------------------------------------------
// BPCPlanningSequence
// ---------------------------------------------------------------------------

export class BPCPlanningSequence {
  constructor(
    private readonly client: SACRestAPIClient,
    public readonly id: string,
  ) {}

  async execute(): Promise<BPCExecutionResponse> {
    return this.client.post<BPCExecutionResponse>(`/bpc/${e(this.id)}/execute`);
  }

  async getVariables(): Promise<BPCVariableInfo[]> {
    return this.client.get<BPCVariableInfo[]>(`/bpc/${e(this.id)}/variables`);
  }

  async setVariableValue(variableId: string, value: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/bpc/${e(this.id)}/variables/${e(variableId)}`, { value });
  }

  async getExecutionResponse(): Promise<BPCExecutionResponse> {
    return this.client.get<BPCExecutionResponse>(`/bpc/${e(this.id)}/executionResponse`);
  }

  async cancel(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/bpc/${e(this.id)}/cancel`);
  }

  async isRunning(): Promise<boolean> {
    return this.client.get<boolean>(`/bpc/${e(this.id)}/running`);
  }

  async getStatus(): Promise<string> {
    return this.client.get<string>(`/bpc/${e(this.id)}/status`);
  }
}

// ---------------------------------------------------------------------------
// Allocation
// ---------------------------------------------------------------------------

export class Allocation {
  constructor(
    private readonly client: SACRestAPIClient,
    public readonly id: string,
  ) {}

  async execute(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/allocation/${e(this.id)}/execute`);
  }

  async getParameters(): Promise<AllocationParameter[]> {
    return this.client.get<AllocationParameter[]>(`/allocation/${e(this.id)}/parameters`);
  }

  async setParameter(parameterId: string, value: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/allocation/${e(this.id)}/parameters/${e(parameterId)}`, { value });
  }

  async preview(): Promise<unknown> {
    return this.client.post(`/allocation/${e(this.id)}/preview`);
  }

  async getStatus(): Promise<string> {
    return this.client.get<string>(`/allocation/${e(this.id)}/status`);
  }
}

// ---------------------------------------------------------------------------
// PlanningPanel (simpler container for planning data entry)
// ---------------------------------------------------------------------------

export class PlanningPanel {
  constructor(
    private readonly client: SACRestAPIClient,
    public readonly id: string,
  ) {}

  async setEditMode(mode: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/planningpanel/${e(this.id)}/editMode`, { mode });
  }

  async getEditMode(): Promise<string> {
    return this.client.get<string>(`/planningpanel/${e(this.id)}/editMode`);
  }

  async submit(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planningpanel/${e(this.id)}/submit`);
  }

  async revert(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planningpanel/${e(this.id)}/revert`);
  }

  async validate(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/planningpanel/${e(this.id)}/validate`);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }

// ---------------------------------------------------------------------------
// Re-exports
// ---------------------------------------------------------------------------

export type {
  DataLockingState, PlanningCategory, PlanningCopyOption,
  DataActionExecutionStatus, DataActionParameterValueType,
} from '../types';

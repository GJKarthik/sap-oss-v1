/**
 * Planning Model Types
 * Derived from mangle/sac_planning.mg
 */

export interface PlanningModel {
  id: string;
  name: string;
  description?: string;
  dimensions: string[];
  measures: string[];
  versions: string[];
  status: string;
}

export interface PlanningSession {
  id: string;
  modelId: string;
  userId: string;
  createdAt: string;
  active: boolean;
  versionId?: string;
}

export interface LockInfo {
  locked: boolean;
  lockedBy?: string;
  lockedAt?: string;
  scope?: string;
}

export interface VersionInfo {
  id: string;
  name: string;
  type: string;
  createdAt: Date;
  createdBy: string;
  isWorkingVersion: boolean;
}

export interface PlanningAreaInfo {
  id: string;
  name: string;
  description?: string;
  status: string;
  dimensions: string[];
  measures: string[];
}

export interface PlanningAreaFilter {
  dimensionId: string;
  members: string[];
  hierarchyId?: string;
}

export interface PlanningAreaMemberInfo {
  id: string;
  description?: string;
  parentId?: string;
  level: number;
  isLeaf: boolean;
}

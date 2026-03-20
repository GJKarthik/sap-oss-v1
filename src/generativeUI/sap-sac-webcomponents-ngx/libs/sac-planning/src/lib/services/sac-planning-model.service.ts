/**
 * SAC Planning Model Service
 *
 * Service for managing SAC planning model operations.
 * Derived from mangle/sac_planning.mg service_method facts.
 */

import { Injectable, inject } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import { DataLockingState, SacApiService } from '@sap-oss/sac-ngx-core';

export type PlanningVersionType = 'public' | 'private' | 'actual';
export type PlanningAreaStatus = 'active' | 'inactive' | 'locked';
export enum DataLockingScope {
  All = 'all',
  Dimension = 'dimension',
  Member = 'member',
}

export interface VersionInfo {
  id: string;
  name: string;
  type: PlanningVersionType;
  createdAt: Date;
  createdBy: string;
  isWorkingVersion: boolean;
}

export interface LockInfo {
  state: DataLockingState;
  lockedBy?: string;
  lockedAt?: Date;
  scope: DataLockingScope;
}

export interface PlanningSession {
  modelId: string;
  workingVersionId?: string;
  isDirty: boolean;
  lockInfo: LockInfo;
}

@Injectable({ providedIn: 'root' })
export class SacPlanningModelService {
  private readonly versions$ = new BehaviorSubject<VersionInfo[]>([]);
  private readonly lockStatus$ = new BehaviorSubject<LockInfo | null>(null);
  private readonly dirty$ = new BehaviorSubject<boolean>(false);
  private currentModelId: string | null = null;
  private readonly api = inject(SacApiService);

  /** Observable: all versions */
  get allVersions$(): Observable<VersionInfo[]> {
    return this.versions$.asObservable();
  }

  /** Observable: lock status */
  get currentLockStatus$(): Observable<LockInfo | null> {
    return this.lockStatus$.asObservable();
  }

  /** Observable: dirty state */
  get isDirty$(): Observable<boolean> {
    return this.dirty$.asObservable();
  }

  /**
   * Create a private version.
   * Implements: service_method("PlanningModel", "createPrivateVersion", "VersionInfo", "async")
   */
  async createPrivateVersion(name: string): Promise<VersionInfo> {
    const response = await this.api.post<VersionInfo>(
      this.buildPath('/versions'),
      { name, type: 'Private' },
    );
    await this.refreshVersions();
    return response;
  }

  /**
   * Publish private version.
   * Implements: service_method("PlanningModel", "publishPrivateVersion", "void", "async")
   */
  async publishPrivateVersion(versionId: string): Promise<void> {
    await this.api.post<void>(
      this.buildPath(`/versions/${encodeURIComponent(versionId)}/publish`),
      {},
    );
    await this.refreshVersions();
  }

  /**
   * Delete private version.
   * Implements: service_method("PlanningModel", "deletePrivateVersion", "void", "async")
   */
  async deletePrivateVersion(versionId: string): Promise<void> {
    await this.api.delete<void>(this.buildPath(`/versions/${encodeURIComponent(versionId)}`));
    await this.refreshVersions();
  }

  /**
   * Get all versions.
   * Implements: service_method("PlanningModel", "getVersions", "VersionInfo[]", "async")
   */
  async getVersions(): Promise<VersionInfo[]> {
    const versions = await this.api.get<VersionInfo[]>(this.buildPath('/versions'));
    this.versions$.next(versions);
    return versions;
  }

  /**
   * Set working version.
   * Implements: service_method("PlanningModel", "setWorkingVersion", "void", "sync")
   */
  setWorkingVersion(versionId: string): void {
    const versions = this.versions$.getValue().map((version) => ({
      ...version,
      isWorkingVersion: version.id === versionId,
    }));
    this.versions$.next(versions);
  }

  /**
   * Lock data.
   * Implements: service_method("PlanningModel", "lockData", "LockInfo", "async")
   */
  async lockData(scope: DataLockingScope = DataLockingScope.All): Promise<LockInfo> {
    const lockInfo = await this.api.post<LockInfo>(
      this.buildPath('/lock'),
      { scope },
    );
    this.lockStatus$.next(lockInfo);
    return lockInfo;
  }

  /**
   * Unlock data.
   * Implements: service_method("PlanningModel", "unlockData", "void", "async")
   */
  async unlockData(): Promise<void> {
    await this.api.delete<void>(this.buildPath('/lock'));
    this.lockStatus$.next(null);
  }

  /**
   * Get lock status.
   * Implements: service_method("PlanningModel", "getLockStatus", "LockInfo", "sync")
   */
  getLockStatus(): LockInfo | null {
    return this.lockStatus$.getValue();
  }

  /**
   * Save data.
   * Implements: service_method("PlanningModel", "saveData", "void", "async")
   */
  async saveData(): Promise<void> {
    await this.api.post<void>(this.buildPath('/data/save'), {});
    this.dirty$.next(false);
  }

  /**
   * Revert data.
   * Implements: service_method("PlanningModel", "revertData", "void", "async")
   */
  async revertData(): Promise<void> {
    await this.api.post<void>(this.buildPath('/data/revert'), {});
    this.dirty$.next(false);
  }

  /**
   * Initialize with a model.
   */
  initialize(modelId: string): void {
    this.currentModelId = modelId.trim();
    void this.refreshVersions();
    void this.refreshLockStatus();
  }

  private async refreshVersions(): Promise<void> {
    if (!this.currentModelId) return;
    await this.getVersions();
  }

  private async refreshLockStatus(): Promise<void> {
    if (!this.currentModelId) return;

    try {
      const status = await this.api.get<LockInfo>(this.buildPath('/lock/status'));
      this.lockStatus$.next(status);
    } catch {
      this.lockStatus$.next(null);
    }
  }

  private buildPath(endpoint: string): string {
    const modelId = this.requireModelId();
    const suffix = endpoint.startsWith('/') ? endpoint : `/${endpoint}`;
    return `/api/v1/planning/models/${encodeURIComponent(modelId)}${suffix}`;
  }

  private requireModelId(): string {
    if (!this.currentModelId) {
      throw new Error('Planning model has not been initialized');
    }

    return this.currentModelId;
  }
}

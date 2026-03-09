/**
 * SAC Data Action Service
 *
 * Service for executing SAC data actions.
 * Derived from mangle/sac_planning.mg service_method "DataAction" facts.
 */

import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import { SacApiService } from '@sap-oss/sac-ngx-core';

export enum DataActionStatus {
  Pending = 'pending',
  Running = 'running',
  Completed = 'completed',
  Failed = 'failed',
  Cancelled = 'cancelled',
}

export interface DataAction {
  id: string;
  name: string;
  description?: string;
  parameters: DataActionParameter[];
}

export interface DataActionParameter {
  id: string;
  name: string;
  type: 'Member' | 'Number' | 'String' | 'Date' | 'DateTime';
  required: boolean;
  defaultValue?: unknown;
  currentValue?: unknown;
}

export interface DataActionResult {
  executionId: string;
  status: DataActionStatus;
  startTime: Date;
  endTime?: Date;
  rowsAffected?: number;
  message?: string;
}

@Injectable({ providedIn: 'root' })
export class SacDataActionService {
  private readonly executionStatus$ = new BehaviorSubject<DataActionStatus>(DataActionStatus.Pending);
  private readonly lastResult$ = new BehaviorSubject<DataActionResult | null>(null);
  private currentParameters = new Map<string, unknown>();

  constructor(private readonly api: SacApiService) {}

  /** Observable: execution status */
  get status$(): Observable<DataActionStatus> {
    return this.executionStatus$.asObservable();
  }

  /** Observable: last result */
  get result$(): Observable<DataActionResult | null> {
    return this.lastResult$.asObservable();
  }

  /**
   * Execute data action.
   * Implements: service_method("DataAction", "execute", "DataActionResult", "async")
   */
  async execute(dataActionId: string, parameters?: Record<string, unknown>): Promise<DataActionResult> {
    this.executionStatus$.next(DataActionStatus.Running);

    try {
      const result = await this.api.post<DataActionResult>(
        this.buildPath(`${encodeURIComponent(dataActionId)}/execute`),
        { parameters: parameters ?? {} },
      );

      this.executionStatus$.next(result.status);
      this.lastResult$.next(result);
      return result;
    } catch (error) {
      this.executionStatus$.next(DataActionStatus.Failed);
      throw this.toError(error, 'Failed to execute data action');
    }
  }

  /**
   * Execute in background.
   * Implements: service_method("DataAction", "executeBackground", "string", "async")
   */
  async executeBackground(dataActionId: string, parameters?: Record<string, unknown>): Promise<string> {
    const response = await this.api.post<{ executionId: string }>(
      `${this.buildPath(`${encodeURIComponent(dataActionId)}/execute`)}?async=true`,
      { parameters: parameters ?? {} },
    );
    return response.executionId;
  }

  /**
   * Get execution status.
   * Implements: service_method("DataAction", "getStatus", "DataActionStatus", "async")
   */
  async getStatus(dataActionId: string, executionId: string): Promise<DataActionResult> {
    const result = await this.api.get<DataActionResult>(
      this.buildPath(`${encodeURIComponent(dataActionId)}/status/${encodeURIComponent(executionId)}`),
    );
    this.executionStatus$.next(result.status);
    this.lastResult$.next(result);
    return result;
  }

  /**
   * Cancel execution.
   * Implements: service_method("DataAction", "cancel", "void", "async")
   */
  async cancel(dataActionId: string, executionId: string): Promise<void> {
    await this.api.post<void>(
      this.buildPath(`${encodeURIComponent(dataActionId)}/cancel/${encodeURIComponent(executionId)}`),
      {},
    );
    this.executionStatus$.next(DataActionStatus.Cancelled);
  }

  getParameters(dataAction: DataAction): DataActionParameter[] {
    return dataAction.parameters.map((parameter) => ({
      ...parameter,
      currentValue: this.currentParameters.get(parameter.id) ?? parameter.defaultValue,
    }));
  }

  setParameter(parameterId: string, value: unknown): void {
    this.currentParameters.set(parameterId, value);
  }

  validateParameters(dataAction: DataAction): { valid: boolean; errors: string[] } {
    const errors: string[] = [];

    for (const param of dataAction.parameters) {
      if (param.required && !this.currentParameters.has(param.id)) {
        errors.push(`Required parameter "${param.name}" is missing`);
      }
    }

    return { valid: errors.length === 0, errors };
  }

  clearParameters(): void {
    this.currentParameters.clear();
  }

  private buildPath(suffix: string): string {
    return `/api/v1/dataactions/${suffix}`;
  }

  private toError(error: unknown, fallbackMessage: string): Error {
    if (error instanceof Error) {
      return error;
    }

    return new Error(fallbackMessage);
  }
}

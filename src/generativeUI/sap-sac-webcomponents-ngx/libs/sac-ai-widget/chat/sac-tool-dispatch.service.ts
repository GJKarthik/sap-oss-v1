// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SacToolDispatchService
 *
 * Executes frontend-only SAC tool calls dispatched by the LLM via AG-UI.
 * Each tool method maps to a SAC API call via the injected SacDataSource /
 * SacChart services from the local widget runtime.
 *
 * The SacAiDataWidgetComponent registers itself as the active widget target
 * so tool results can mutate its @Input() state reactively.
 */

import { Injectable, inject } from '@angular/core';
import {
  SacDataActionService,
  SacPlanningModelService,
  type LockInfo,
  type VersionInfo,
} from '@sap-oss/sac-webcomponents-ngx/planning';
import {
  VALID_WIDGET_TYPES,
  validateWidgetType,
} from '../types/sac-widget-schema';
import type {
  SacWidgetSchema,
  SacDimensionFilter,
  SacLayoutConfig,
  SacGridConfig,
  SacSliderConfig,
  SacTextConfig,
} from '../types/sac-widget-schema';

export interface ToolResult {
  success: boolean;
  data?: unknown;
  error?: string;
}

export interface WidgetBindingInfo {
  modelId: string;
  dimensions: string[];
  measures: string[];
  filters: SacDimensionFilter[];
  chartType?: string;
  widgetType: SacWidgetSchema['widgetType'];
  topK?: number;
}

export type WidgetStateTarget = {
  applySchema(schema: Partial<SacWidgetSchema>): void;
  getBindingInfo?(): Promise<WidgetBindingInfo>;
  refreshData?(): Promise<void>;
};

export type ToolReviewRiskLevel = 'medium' | 'high';

export interface ToolRollbackPreview {
  strategy: 'revertData' | 'manualReview';
  label: string;
  warnings: string[];
}

export interface ToolExecutionReview {
  toolName: string;
  title: string;
  summary: string;
  confirmationLabel: string;
  riskLevel: ToolReviewRiskLevel;
  actionId?: string;
  modelId?: string;
  binding?: WidgetBindingInfo;
  normalizedArgs: Record<string, unknown>;
  affectedScope: string[];
  rollbackPreview: ToolRollbackPreview;
}

@Injectable({ providedIn: 'root' })
export class SacToolDispatchService {
  private target: WidgetStateTarget | null = null;
  private readonly dataActionService: SacDataActionService;
  private readonly planningModelService: SacPlanningModelService;

  constructor(
    dataActionService?: SacDataActionService,
    planningModelService?: SacPlanningModelService,
  ) {
    this.dataActionService = dataActionService ?? inject(SacDataActionService);
    this.planningModelService = planningModelService ?? inject(SacPlanningModelService);
  }

  /** Called by SacAiDataWidgetComponent to register as the current render target. */
  registerTarget(target: WidgetStateTarget): void {
    this.target = target;
  }

  unregisterTarget(): void {
    this.target = null;
  }

  async getConfirmationReview(
    toolName: string,
    args: Record<string, unknown>,
  ): Promise<ToolExecutionReview | null> {
    switch (toolName) {
      case 'run_data_action':
        return this.buildDataActionReview(args);
      default:
        return null;
    }
  }

  async execute(toolName: string, args: Record<string, unknown>): Promise<ToolResult> {
    switch (toolName) {
      case 'set_datasource_filter':
        return this.setDatasourceFilter(args);
      case 'set_chart_type':
        return this.setChartType(args);
      case 'run_data_action':
        return this.runDataAction(args);
      case 'get_model_dimensions':
        return this.getModelDimensions(args);
      case 'generate_sac_widget':
        return this.generateSacWidget(args);
      default:
        return { success: false, error: `Unknown tool: ${toolName}` };
    }
  }

  private async setDatasourceFilter(args: Record<string, unknown>): Promise<ToolResult> {
    const dimension = this.readStringArg(args, 'dimension');
    if (!dimension) {
      return { success: false, error: 'set_datasource_filter: dimension is required' };
    }

    if (!this.target) return { success: false, error: 'No widget target registered' };

    const filterType = this.normalizeFilterType(args['filterType']);
    const value = this.normalizeFilterValue(args['value'], filterType);
    if (filterType === 'RangeValue' && (!value || Array.isArray(value) || typeof value === 'string')) {
      return { success: false, error: 'set_datasource_filter: RangeValue filters require {"low","high"}' };
    }

    const filter: SacDimensionFilter = {
      dimension,
      value,
      filterType,
    };

    this.target.applySchema({ filters: [filter] });
    await this.refreshActiveTarget();
    return {
      success: true,
      data: {
        applied: filter,
        binding: await this.readActiveBindingInfo(),
      },
    };
  }

  private async setChartType(args: Record<string, unknown>): Promise<ToolResult> {
    const chartType = this.readStringArg(args, 'chartType');
    if (!chartType) {
      return { success: false, error: 'set_chart_type: chartType is required' };
    }

    if (!this.target) return { success: false, error: 'No widget target registered' };
    this.target.applySchema({ chartType });
    await this.refreshActiveTarget();
    return {
      success: true,
      data: {
        chartType,
        binding: await this.readActiveBindingInfo(),
      },
    };
  }

  private async runDataAction(args: Record<string, unknown>): Promise<ToolResult> {
    const actionId = this.readStringArg(args, 'actionId');
    if (!actionId) {
      return { success: false, error: 'run_data_action: actionId is required' };
    }

    const modelId = await this.resolveModelId(args);
    if (!modelId) {
      return { success: false, error: 'run_data_action: modelId is required or the active widget must be bound' };
    }

    let parameters: Record<string, unknown>;
    try {
      parameters = this.parseRecordArg(args['params'], 'run_data_action: params must be valid JSON or an object');
    } catch (error) {
      return { success: false, error: error instanceof Error ? error.message : 'run_data_action: invalid params' };
    }

    const executionMode = this.readStringArg(args, 'mode')?.toLowerCase();
    const runInBackground = executionMode === 'background' || args['async'] === true;

    try {
      this.planningModelService.initialize(modelId);

      if (runInBackground) {
        const executionId = await this.dataActionService.executeBackground(actionId, parameters);
        return {
          success: true,
          data: {
            modelId,
            actionId,
            parameters,
            mode: 'background',
            executionId,
          },
        };
      }

      const result = await this.dataActionService.execute(actionId, parameters);
      await this.refreshActiveTarget(modelId);
      return {
        success: true,
        data: {
          modelId,
          actionId,
          parameters,
          result,
          binding: await this.readActiveBindingInfo(),
        },
      };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'run_data_action: execution failed',
      };
    }
  }

  private async buildDataActionReview(args: Record<string, unknown>): Promise<ToolExecutionReview | null> {
    const actionId = this.readStringArg(args, 'actionId');
    if (!actionId) {
      return null;
    }

    const modelId = await this.resolveModelId(args);
    if (!modelId) {
      return null;
    }

    let parameters: Record<string, unknown>;
    try {
      parameters = this.parseRecordArg(args['params'], 'run_data_action: params must be valid JSON or an object');
    } catch {
      return null;
    }

    const executionMode = this.readStringArg(args, 'mode')?.toLowerCase();
    const runInBackground = executionMode === 'background' || args['async'] === true;

    this.planningModelService.initialize(modelId);
    const binding = await this.readActiveBindingInfo();
    const versions = await this.readPlanningVersions();
    const workingVersion = versions.find((version) => version.isWorkingVersion);
    const lockInfo = this.planningModelService.getLockStatus();
    const affectedScope = this.describePlanningScope(binding, parameters, modelId);

    return {
      toolName: 'run_data_action',
      title: `Review planning action ${actionId}`,
      summary: runInBackground
        ? `Run data action ${actionId} in the background for model ${modelId}.`
        : `Run data action ${actionId} now against planning model ${modelId}.`,
      confirmationLabel: runInBackground ? 'Run in background' : 'Run action',
      riskLevel: runInBackground ? 'high' : 'high',
      actionId,
      modelId,
      binding,
      normalizedArgs: {
        ...args,
        modelId,
        params: parameters,
      },
      affectedScope,
      rollbackPreview: this.buildRollbackPreview(modelId, runInBackground, workingVersion, lockInfo),
    };
  }

  private async getModelDimensions(args: Record<string, unknown>): Promise<ToolResult> {
    const requestedModelId = this.readStringArg(args, 'modelId');
    const binding = await this.readActiveBindingInfo();
    if (binding) {
      if (requestedModelId && binding.modelId !== requestedModelId) {
        return {
          success: false,
          error: `Requested model ${requestedModelId} is not the active widget model (${binding.modelId})`,
        };
      }

      return {
        success: true,
        data: binding,
      };
    }

    return {
      success: false,
      error: requestedModelId
        ? `No active widget binding metadata is available for model ${requestedModelId}`
        : 'No active widget binding metadata is available',
    };
  }

  private async generateSacWidget(args: Record<string, unknown>): Promise<ToolResult> {
    if (!this.target) return { success: false, error: 'No widget target registered' };

    const rawWidgetType = args['widgetType'];
    if (!validateWidgetType(rawWidgetType)) {
      return {
        success: false,
        error: `generate_sac_widget: invalid widgetType '${String(rawWidgetType)}'. Valid types: ${Array.from(VALID_WIDGET_TYPES).join(', ')}`,
      };
    }

    const widgetType = rawWidgetType;
    const rawModelId = args['modelId'];
    if (
      (widgetType === 'chart' || widgetType === 'table' || widgetType === 'kpi')
      && (!rawModelId || typeof rawModelId !== 'string' || !rawModelId.trim())
    ) {
      return {
        success: false,
        error: `generate_sac_widget: modelId is required for data widget type '${widgetType}'`,
      };
    }

    const schema = {
      widgetType,
      chartType: args['chartType'] as string | undefined,
      modelId: args['modelId'] as string,
      dimensions: this.parseStringList(args['dimensions']),
      measures: this.parseStringList(args['measures']),
      title: args['title'] as string | undefined,
      subtitle: args['subtitle'] as string | undefined,
      topK: args['topK'] != null ? Number(args['topK']) : undefined,
      filters: this.parseWidgetFilters(args['filters']),
      layout: this.parseObjectArg<SacLayoutConfig | SacGridConfig>(args['layout']),
      slider: this.parseObjectArg<SacSliderConfig>(args['slider']),
      text: this.parseObjectArg<SacTextConfig>(args['text']),
      children: this.parseWidgetChildren(args['children']),
      ariaLabel: this.readStringArg(args, 'ariaLabel') ?? undefined,
      ariaDescription: this.readStringArg(args, 'ariaDescription') ?? undefined,
    } satisfies Partial<SacWidgetSchema>;

    this.target.applySchema(schema);
    await this.refreshActiveTarget();
    return {
      success: true,
      data: {
        schema,
        binding: await this.readActiveBindingInfo(),
      },
    };
  }

  private parseStringList(value: unknown): string[] {
    if (Array.isArray(value)) {
      return value
        .map((item) => String(item).trim())
        .filter(Boolean);
    }

    return String(value ?? '')
      .split(',')
      .map((item) => item.trim())
      .filter(Boolean);
  }

  private normalizeFilterType(value: unknown): SacDimensionFilter['filterType'] {
    const normalized = typeof value === 'string' ? value.trim() : '';
    switch (normalized) {
      case 'AllValue':
      case 'ExcludeValue':
      case 'MultipleValue':
      case 'RangeValue':
      case 'SingleValue':
        return normalized;
      default:
        return 'SingleValue';
    }
  }

  private normalizeFilterValue(
    value: unknown,
    filterType: SacDimensionFilter['filterType'],
  ): SacDimensionFilter['value'] | undefined {
    if (value == null || value === '') {
      return filterType === 'AllValue' ? undefined : '';
    }

    if (typeof value === 'string') {
      const trimmed = value.trim();
      if ((filterType === 'MultipleValue' || filterType === 'ExcludeValue' || filterType === 'RangeValue')
        && this.looksLikeJson(trimmed)) {
        try {
          return JSON.parse(trimmed) as SacDimensionFilter['value'];
        } catch {
          return trimmed;
        }
      }

      if (filterType === 'MultipleValue' || filterType === 'ExcludeValue') {
        return trimmed.split(',').map((item) => item.trim()).filter(Boolean);
      }

      return trimmed;
    }

    if (Array.isArray(value)) {
      return value.map((item) => String(item));
    }

    if (typeof value === 'object') {
      return value as SacDimensionFilter['value'];
    }

    return String(value);
  }

  private parseRecordArg(value: unknown, errorMessage: string): Record<string, unknown> {
    if (value == null || value === '') {
      return {};
    }

    if (typeof value === 'string') {
      const parsed = JSON.parse(value) as unknown;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error(errorMessage);
      }

      return parsed as Record<string, unknown>;
    }

    if (typeof value === 'object' && !Array.isArray(value)) {
      return { ...(value as Record<string, unknown>) };
    }

    throw new Error(errorMessage);
  }

  private parseObjectArg<T extends object>(value: unknown): T | undefined {
    if (value == null || value === '') {
      return undefined;
    }

    try {
      return this.parseRecordArg(value, 'Invalid object argument') as T;
    } catch {
      return undefined;
    }
  }

  private parseWidgetChildren(value: unknown): SacWidgetSchema[] | undefined {
    if (value == null || value === '') {
      return undefined;
    }

    const parsedValue = this.parseArrayArg(value);
    if (!parsedValue) {
      return undefined;
    }

    return parsedValue.filter(
      (item): item is SacWidgetSchema =>
        Boolean(item) && typeof item === 'object' && 'widgetType' in item,
    ) as SacWidgetSchema[];
  }

  private parseWidgetFilters(value: unknown): SacDimensionFilter[] | undefined {
    const parsedValue = this.parseArrayArg(value);
    if (!parsedValue) {
      return undefined;
    }

    return parsedValue
      .filter((item): item is SacDimensionFilter => Boolean(item) && typeof item === 'object' && 'dimension' in item)
      .map((filter) => ({
        ...filter,
        dimension: String(filter.dimension),
      }));
  }

  private parseArrayArg(value: unknown): unknown[] | undefined {
    if (value == null || value === '') {
      return undefined;
    }

    if (Array.isArray(value)) {
      return value;
    }

    if (typeof value === 'string') {
      try {
        const parsed = JSON.parse(value) as unknown;
        return Array.isArray(parsed) ? parsed : undefined;
      } catch {
        return undefined;
      }
    }

    return undefined;
  }

  private async readPlanningVersions(): Promise<VersionInfo[]> {
    try {
      return await this.planningModelService.getVersions();
    } catch {
      return [];
    }
  }

  private describePlanningScope(
    binding: WidgetBindingInfo | undefined,
    parameters: Record<string, unknown>,
    modelId: string,
  ): string[] {
    const scope = [`Model ${modelId}`];
    if (binding?.widgetType) {
      scope.push(`Widget ${binding.widgetType}`);
    }
    if (binding?.chartType) {
      scope.push(`Chart ${binding.chartType}`);
    }
    if (binding?.filters?.length) {
      const filterSummary = binding.filters
        .map((filter) => `${filter.dimension}=${this.formatScopeValue(filter.value)}`)
        .join(', ');
      scope.push(`Filters ${filterSummary}`);
    }

    const parameterKeys = Object.keys(parameters);
    if (parameterKeys.length) {
      scope.push(`Parameters ${parameterKeys.join(', ')}`);
    } else {
      scope.push('Parameters none');
    }

    return scope;
  }

  private buildRollbackPreview(
    modelId: string,
    runInBackground: boolean,
    workingVersion: VersionInfo | undefined,
    lockInfo: LockInfo | null,
  ): ToolRollbackPreview {
    const warnings: string[] = [];
    if (workingVersion) {
      warnings.push(`Working version: ${workingVersion.name} (${workingVersion.id})`);
    } else {
      warnings.push('Working version could not be resolved during review.');
    }

    if (lockInfo) {
      warnings.push(`Current lock state: ${lockInfo.state}`);
    } else {
      warnings.push('Current lock state is unavailable.');
    }

    if (runInBackground) {
      warnings.push('Background execution can continue after this panel closes; inspect the job result before reverting.');
      return {
        strategy: 'manualReview',
        label: `Rollback is manual: after the background job finishes, review changes on model ${modelId} and use revertData() before saving if the action wrote planning data.`,
        warnings,
      };
    }

    warnings.push('Rollback is only available before the working version is saved or published.');
    return {
      strategy: 'revertData',
      label: `If this action changes planning data, revert unsaved changes on model ${modelId} with revertData() before save or publish.`,
      warnings,
    };
  }

  private formatScopeValue(value: SacDimensionFilter['value'] | undefined): string {
    if (value == null || value === '') {
      return 'all';
    }

    if (Array.isArray(value)) {
      return value.join('|');
    }

    if (typeof value === 'object') {
      const range = value as { low?: unknown; high?: unknown };
      return `${range.low ?? '*'}..${range.high ?? '*'}`;
    }

    return String(value);
  }

  private readStringArg(args: Record<string, unknown>, key: string): string | null {
    const value = args[key];
    if (typeof value !== 'string') {
      return null;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : null;
  }

  private looksLikeJson(value: string): boolean {
    return value.startsWith('{') || value.startsWith('[');
  }

  private async resolveModelId(args: Record<string, unknown>): Promise<string | null> {
    const explicitModelId = this.readStringArg(args, 'modelId');
    if (explicitModelId) {
      return explicitModelId;
    }

    const binding = await this.readActiveBindingInfo();
    return binding?.modelId ?? null;
  }

  private async readActiveBindingInfo(): Promise<WidgetBindingInfo | null> {
    if (!this.target?.getBindingInfo) {
      return null;
    }

    return this.target.getBindingInfo();
  }

  private async refreshActiveTarget(expectedModelId?: string): Promise<void> {
    if (!this.target?.refreshData) {
      return;
    }

    if (expectedModelId && this.target.getBindingInfo) {
      const binding = await this.target.getBindingInfo();
      if (binding.modelId !== expectedModelId) {
        return;
      }
    }

    await this.target.refreshData();
  }
}

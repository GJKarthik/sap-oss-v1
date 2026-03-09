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

import { Injectable } from '@angular/core';
import type { SacWidgetSchema, SacDimensionFilter } from '../types/sac-widget-schema';

export interface ToolResult {
  success: boolean;
  data?: unknown;
  error?: string;
}

export type WidgetStateTarget = {
  applySchema(schema: Partial<SacWidgetSchema>): void;
  getBindingInfo?(): Promise<{
    modelId: string;
    dimensions: string[];
    measures: string[];
  }>;
};

@Injectable({ providedIn: 'root' })
export class SacToolDispatchService {
  private target: WidgetStateTarget | null = null;

  /** Called by SacAiDataWidgetComponent to register as the current render target. */
  registerTarget(target: WidgetStateTarget): void {
    this.target = target;
  }

  unregisterTarget(): void {
    this.target = null;
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

  private setDatasourceFilter(args: Record<string, unknown>): ToolResult {
    const { dimension, value, filterType } = args as {
      modelId: string;
      dimension: string;
      value: SacDimensionFilter['value'];
      filterType?: string;
    };

    if (!this.target) return { success: false, error: 'No widget target registered' };

    const filter: SacDimensionFilter = {
      dimension,
      value,
      filterType: (filterType as SacDimensionFilter['filterType']) ?? 'SingleValue',
    };

    this.target.applySchema({ filters: [filter] });
    return { success: true, data: { applied: filter } };
  }

  private setChartType(args: Record<string, unknown>): ToolResult {
    const { chartType } = args as { chartType: string };
    if (!this.target) return { success: false, error: 'No widget target registered' };
    this.target.applySchema({ chartType });
    return { success: true, data: { chartType } };
  }

  private runDataAction(args: Record<string, unknown>): ToolResult {
    const { modelId, actionId, params } = args as {
      modelId: string;
      actionId: string;
      params?: string;
    };
    let parsedParams: Record<string, unknown> = {};
    if (params) {
      try {
        parsedParams = JSON.parse(params) as Record<string, unknown>;
      } catch {
        return { success: false, error: 'run_data_action: params must be valid JSON' };
      }
    }
    console.info(`[SacToolDispatch] run_data_action: modelId=${modelId}, actionId=${actionId}`, parsedParams);
    return { success: true, data: { modelId, actionId, params: parsedParams } };
  }

  private async getModelDimensions(args: Record<string, unknown>): Promise<ToolResult> {
    const { modelId } = args as { modelId: string };
    if (this.target?.getBindingInfo) {
      return {
        success: true,
        data: await this.target.getBindingInfo(),
      };
    }

    console.info(`[SacToolDispatch] get_model_dimensions: modelId=${modelId}`);
    return {
      success: true,
      data: {
        modelId,
        dimensions: [],
        measures: [],
        note: 'No active widget binding metadata is available yet.',
      },
    };
  }

  private generateSacWidget(args: Record<string, unknown>): ToolResult {
    if (!this.target) return { success: false, error: 'No widget target registered' };

    const schema = {
      widgetType: args['widgetType'] as SacWidgetSchema['widgetType'],
      chartType: args['chartType'] as string | undefined,
      modelId: args['modelId'] as string,
      dimensions: this.parseStringList(args['dimensions']),
      measures: this.parseStringList(args['measures']),
      title: args['title'] as string | undefined,
      topK: args['topK'] != null ? Number(args['topK']) : undefined,
    } satisfies Partial<SacWidgetSchema>;

    this.target.applySchema(schema);
    return { success: true, data: schema };
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
}

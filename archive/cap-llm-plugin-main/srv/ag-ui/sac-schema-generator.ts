// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Widget Schema Generator
 *
 * Extends the AG-UI schema generation layer with SAP Analytics Cloud
 * widget schemas. The LLM uses GENERATE_SAC_WIDGET_FUNCTION to express
 * its intent as a typed SacWidgetSchema, which the Angular widget then
 * applies to drive SAC chart/table/KPI state.
 */

import type { ToolDefinition } from './tool-handler';

// =============================================================================
// SAC Widget Schema Types
// =============================================================================

/** Filter entry for a SAC datasource dimension */
export interface SacDimensionFilter {
  dimension: string;
  value: string;
  filterType?: 'SingleValue' | 'MultipleValue' | 'RangeValue' | 'ExcludeValue';
}

/**
 * Schema emitted by the LLM (via generate_sac_widget tool call) that
 * describes how a SAC chart, table, or KPI should be configured.
 */
export interface SacWidgetSchema {
  widgetType: 'chart' | 'table' | 'kpi';
  chartType?: string;
  modelId: string;
  dimensions: string[];
  measures: string[];
  filters?: SacDimensionFilter[];
  title?: string;
  topK?: number;
}

// =============================================================================
// Allowed SAC widget types for LLM schema generation
// =============================================================================

export const SAC_CHART_TYPES = [
  'bar', 'column', 'line', 'area', 'pie', 'donut',
  'bubble', 'scatter', 'waterfall', 'treemap', 'heatmap',
  'bullet', 'combo', 'stacked_bar', 'stacked_column', 'variance',
] as const;

export const SAC_FILTER_TYPES = [
  'SingleValue', 'MultipleValue', 'RangeValue', 'ExcludeValue',
] as const;

// =============================================================================
// LLM Function Definition for SAC Widget Generation
// =============================================================================

/**
 * OpenAI function definition for generating a SacWidgetSchema.
 * Register this alongside GENERATE_UI_FUNCTION in AgentService when
 * serviceId === 'sac-ai-widget'.
 */
export const GENERATE_SAC_WIDGET_FUNCTION: ToolDefinition = {
  name: 'generate_sac_widget',
  description: `Generate a SAP Analytics Cloud widget configuration (SacWidgetSchema) based on
the user's analytics request. Use this when the user wants to see data from a SAC model
as a chart, table, or KPI tile. Always specify modelId, at least one dimension and one measure.`,
  parameters: {
    type: 'object',
    properties: {
      widgetType: {
        type: 'string',
        description: 'Type of SAC widget to render',
        enum: ['chart', 'table', 'kpi'],
      },
      chartType: {
        type: 'string',
        description: 'Chart subtype — required when widgetType is "chart"',
        enum: SAC_CHART_TYPES as unknown as string[],
      },
      modelId: {
        type: 'string',
        description: 'SAC datasource model ID (e.g. "BestRunJuice_SalesActual")',
      },
      dimensions: {
        type: 'string',
        description: 'Comma-separated list of dimension IDs to show on category/row axis',
      },
      measures: {
        type: 'string',
        description: 'Comma-separated list of measure IDs to show on value axis',
      },
      filters: {
        type: 'string',
        description:
          'JSON array of {dimension, value, filterType} objects to apply. ' +
          'filterType is one of: SingleValue, MultipleValue, RangeValue, ExcludeValue',
      },
      title: {
        type: 'string',
        description: 'Optional widget title shown above the chart/table',
      },
      topK: {
        type: 'string',
        description: 'Limit result rows/members (default 20)',
      },
    },
    required: ['widgetType', 'modelId', 'dimensions', 'measures'],
  },
};

// =============================================================================
// Parser: raw LLM tool-call args → typed SacWidgetSchema
// =============================================================================

/**
 * Parse the raw string arguments from an LLM generate_sac_widget tool call
 * into a validated SacWidgetSchema. Throws on invalid input.
 */
export function parseSacWidgetArgs(
  args: Record<string, unknown>,
): SacWidgetSchema {
  const widgetType = args['widgetType'] as string;
  if (!['chart', 'table', 'kpi'].includes(widgetType)) {
    throw new Error(`generate_sac_widget: invalid widgetType "${widgetType}"`);
  }

  const modelId = (args['modelId'] as string | undefined)?.trim();
  if (!modelId) {
    throw new Error('generate_sac_widget: modelId is required');
  }

  const dimensions = splitCsv(args['dimensions'] as string | undefined);
  const measures = splitCsv(args['measures'] as string | undefined);

  if (dimensions.length === 0) {
    throw new Error('generate_sac_widget: at least one dimension is required');
  }
  if (measures.length === 0) {
    throw new Error('generate_sac_widget: at least one measure is required');
  }

  let filters: SacDimensionFilter[] | undefined;
  if (args['filters']) {
    try {
      filters = JSON.parse(args['filters'] as string) as SacDimensionFilter[];
    } catch {
      throw new Error('generate_sac_widget: filters must be valid JSON array');
    }
  }

  const chartType = widgetType === 'chart'
    ? ((args['chartType'] as string | undefined) ?? 'bar')
    : undefined;

  return {
    widgetType: widgetType as SacWidgetSchema['widgetType'],
    chartType,
    modelId,
    dimensions,
    measures,
    filters,
    title: (args['title'] as string | undefined) ?? undefined,
    topK: args['topK'] != null ? Number(args['topK']) : undefined,
  };
}

function splitCsv(raw: string | undefined): string[] {
  if (!raw) return [];
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

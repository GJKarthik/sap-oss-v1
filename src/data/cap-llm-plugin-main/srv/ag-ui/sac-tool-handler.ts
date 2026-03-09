// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Tool Handler
 *
 * Defines the four LLM function-calling tools that let the agent drive
 * SAP Analytics Cloud widget state from natural language.
 *
 * All tools are marked frontendOnly: true — the AG-UI TOOL_CALL_START
 * event is forwarded to the Angular SacAgUiService, which executes them
 * locally against the SacDataSourceService / SacChartComponent.
 */

import type { ToolDefinition } from './tool-handler';
import { SAC_CHART_TYPES, SAC_FILTER_TYPES } from './sac-schema-generator';

// =============================================================================
// Tool: set_datasource_filter
// =============================================================================

/**
 * Instructs the widget to set a dimension filter on the active datasource.
 * Executed by SacAgUiService on the frontend.
 */
export const SET_DATASOURCE_FILTER_TOOL: ToolDefinition = {
  name: 'set_datasource_filter',
  description:
    'Set or update a dimension filter on the SAC datasource currently displayed in the widget. ' +
    'Use this to narrow down data based on user queries like "show only Europe" or "filter to Q1 2024".',
  parameters: {
    type: 'object',
    properties: {
      modelId: {
        type: 'string',
        description: 'SAC datasource model ID',
      },
      dimension: {
        type: 'string',
        description: 'Dimension ID to filter on (e.g. "Location", "Version", "Date")',
      },
      value: {
        type: 'string',
        description: 'Member value or comma-separated list of values',
      },
      filterType: {
        type: 'string',
        description: 'Filter type',
        enum: SAC_FILTER_TYPES as unknown as string[],
      },
    },
    required: ['modelId', 'dimension', 'value'],
  },
  frontendOnly: true,
};

// =============================================================================
// Tool: set_chart_type
// =============================================================================

/**
 * Instructs the widget to switch the active chart to a different visualization type.
 * Executed by SacAgUiService on the frontend.
 */
export const SET_CHART_TYPE_TOOL: ToolDefinition = {
  name: 'set_chart_type',
  description:
    'Change the chart visualization type for the currently displayed SAC chart widget. ' +
    'Use this when the user asks to see data as a bar chart, line chart, pie chart, etc.',
  parameters: {
    type: 'object',
    properties: {
      chartType: {
        type: 'string',
        description: 'New chart type to apply',
        enum: SAC_CHART_TYPES as unknown as string[],
      },
    },
    required: ['chartType'],
  },
  frontendOnly: true,
};

// =============================================================================
// Tool: run_data_action
// =============================================================================

/**
 * Instructs the widget to execute a SAC planning data action.
 * Executed by SacAgUiService on the frontend via SacDataSourceService.
 */
export const RUN_DATA_ACTION_TOOL: ToolDefinition = {
  name: 'run_data_action',
  description:
    'Execute a SAP Analytics Cloud planning data action on the active model. ' +
    'Use this when the user wants to trigger a calculation, allocation, or planning sequence.',
  parameters: {
    type: 'object',
    properties: {
      modelId: {
        type: 'string',
        description: 'SAC planning model ID',
      },
      actionId: {
        type: 'string',
        description: 'Data action ID to execute',
      },
      params: {
        type: 'string',
        description:
          'JSON object of parameter key/value pairs to pass to the data action. ' +
          'Keys and values must match the data action parameter definitions.',
      },
    },
    required: ['modelId', 'actionId'],
  },
  frontendOnly: true,
};

// =============================================================================
// Tool: get_model_dimensions
// =============================================================================

/**
 * Returns dimension metadata for a SAC model so the LLM can reason
 * about what dimensions/measures are available before suggesting filters.
 * Executed by SacAgUiService on the frontend.
 */
export const GET_MODEL_DIMENSIONS_TOOL: ToolDefinition = {
  name: 'get_model_dimensions',
  description:
    'Retrieve the list of available dimensions and measures for a SAC datasource model. ' +
    'Call this before set_datasource_filter or generate_sac_widget if you are unsure which ' +
    'dimensions exist in the model.',
  parameters: {
    type: 'object',
    properties: {
      modelId: {
        type: 'string',
        description: 'SAC datasource model ID',
      },
    },
    required: ['modelId'],
  },
  frontendOnly: true,
};

// =============================================================================
// Exported registry of all SAC tools
// =============================================================================

export const SAC_TOOLS: ToolDefinition[] = [
  SET_DATASOURCE_FILTER_TOOL,
  SET_CHART_TYPE_TOOL,
  RUN_DATA_ACTION_TOOL,
  GET_MODEL_DIMENSIONS_TOOL,
];

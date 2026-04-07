import { describe, expect, it } from 'vitest';

import {
  validateWidgetType,
  VALID_WIDGET_TYPES,
  MAX_CHILDREN_DEPTH,
  DEFAULT_SAC_WIDGET_SCHEMA,
} from '../libs/sac-ai-widget/types/sac-widget-schema';

describe('validateWidgetType', () => {
  it('returns true for all 13 valid widget types', () => {
    const types = [
      'chart', 'table', 'kpi',
      'filter-dropdown', 'filter-checkbox', 'filter-date-range',
      'slider', 'range-slider',
      'text-block', 'heading', 'divider',
      'grid-container', 'flex-container',
    ];

    for (const type of types) {
      expect(validateWidgetType(type)).toBe(true);
    }
  });

  it('returns false for unknown string', () => {
    expect(validateWidgetType('sparkline')).toBe(false);
    expect(validateWidgetType('treemap')).toBe(false);
    expect(validateWidgetType('CHART')).toBe(false);
  });

  it('returns false for null and undefined', () => {
    expect(validateWidgetType(null)).toBe(false);
    expect(validateWidgetType(undefined)).toBe(false);
  });

  it('returns false for number', () => {
    expect(validateWidgetType(42)).toBe(false);
  });

  it('returns false for empty string', () => {
    expect(validateWidgetType('')).toBe(false);
  });
});

describe('VALID_WIDGET_TYPES', () => {
  it('contains exactly 13 types', () => {
    expect(VALID_WIDGET_TYPES.size).toBe(13);
  });

  it('includes all core types', () => {
    expect(VALID_WIDGET_TYPES.has('chart')).toBe(true);
    expect(VALID_WIDGET_TYPES.has('table')).toBe(true);
    expect(VALID_WIDGET_TYPES.has('kpi')).toBe(true);
  });

  it('includes all filter types', () => {
    expect(VALID_WIDGET_TYPES.has('filter-dropdown')).toBe(true);
    expect(VALID_WIDGET_TYPES.has('filter-checkbox')).toBe(true);
    expect(VALID_WIDGET_TYPES.has('filter-date-range')).toBe(true);
  });

  it('includes all slider types', () => {
    expect(VALID_WIDGET_TYPES.has('slider')).toBe(true);
    expect(VALID_WIDGET_TYPES.has('range-slider')).toBe(true);
  });

  it('includes all text types', () => {
    expect(VALID_WIDGET_TYPES.has('text-block')).toBe(true);
    expect(VALID_WIDGET_TYPES.has('heading')).toBe(true);
    expect(VALID_WIDGET_TYPES.has('divider')).toBe(true);
  });

  it('includes all layout types', () => {
    expect(VALID_WIDGET_TYPES.has('grid-container')).toBe(true);
    expect(VALID_WIDGET_TYPES.has('flex-container')).toBe(true);
  });
});

describe('MAX_CHILDREN_DEPTH', () => {
  it('equals 8', () => {
    expect(MAX_CHILDREN_DEPTH).toBe(8);
  });
});

describe('DEFAULT_SAC_WIDGET_SCHEMA', () => {
  it('defaults to chart widget type', () => {
    expect(DEFAULT_SAC_WIDGET_SCHEMA.widgetType).toBe('chart');
  });

  it('has empty modelId', () => {
    expect(DEFAULT_SAC_WIDGET_SCHEMA.modelId).toBe('');
  });

  it('has empty dimensions and measures', () => {
    expect(DEFAULT_SAC_WIDGET_SCHEMA.dimensions).toEqual([]);
    expect(DEFAULT_SAC_WIDGET_SCHEMA.measures).toEqual([]);
  });
});

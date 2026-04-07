import '@angular/compiler';

import { ChangeDetectorRef, Injector, runInInjectionContext } from '@angular/core';
import { EMPTY, Subject } from 'rxjs';
import { describe, expect, it, vi, beforeEach } from 'vitest';

import { SacAgUiService, AgUiEvent } from '../libs/sac-ai-widget/ag-ui/sac-ag-ui.service';
import { SacToolDispatchService } from '../libs/sac-ai-widget/chat/sac-tool-dispatch.service';
import { SacAiSessionService } from '../libs/sac-ai-widget/session/sac-ai-session.service';
import { SacDataSourceService } from '../libs/sac-datasource/src/index';
import { SacAiDataWidgetComponent } from '../libs/sac-ai-widget/data-widget/sac-ai-data-widget.component';
import { MAX_CHILDREN_DEPTH } from '../libs/sac-ai-widget/types/sac-widget-schema';

function createSessionStub() {
  return {
    getThreadId: vi.fn().mockReturnValue('thread-data'),
    recordAudit: vi.fn(),
    getAuditEntries: vi.fn().mockReturnValue([]),
    clearAudit: vi.fn(),
    recordReplay: vi.fn(),
    getReplayEntries: vi.fn().mockReturnValue([]),
    clearReplay: vi.fn(),
  };
}

function createDataSourceStub() {
  return {
    create: vi.fn().mockReturnValue({
      modelId: 'MODEL_1',
      id: 'ds-1',
      pause: vi.fn(),
      resume: vi.fn(),
      clearFilters: vi.fn().mockResolvedValue(undefined),
      setFilter: vi.fn().mockResolvedValue(undefined),
      getData: vi.fn().mockResolvedValue({ dimensions: [], measures: [], data: [] }),
    }),
    destroy: vi.fn(),
  };
}

function createComponent() {
  const cdr = { markForCheck: vi.fn(), detectChanges: vi.fn() } as unknown as ChangeDetectorRef;
  const agUi = { run: vi.fn().mockReturnValue(EMPTY), dispatchToolResult: vi.fn() };
  const dsService = createDataSourceStub();
  const session = createSessionStub();
  const toolDispatch = { registerTarget: vi.fn(), unregisterTarget: vi.fn() };

  const injector = Injector.create({
    providers: [
      { provide: ChangeDetectorRef, useValue: cdr },
      { provide: SacAgUiService, useValue: agUi },
      { provide: SacDataSourceService, useValue: dsService },
      { provide: SacAiSessionService, useValue: session },
      { provide: SacToolDispatchService, useValue: toolDispatch },
    ],
  });

  const component = runInInjectionContext(injector, () => new SacAiDataWidgetComponent());
  return { component, cdr, agUi, dsService, session, toolDispatch };
}

describe('SacAiDataWidgetComponent', () => {
  describe('showRenderableContent', () => {
    it('returns true for text widgets without modelId', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'heading', modelId: '' };
      expect(component.showRenderableContent).toBe(true);
    });

    it('returns true for container widgets without modelId', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'flex-container', modelId: '' };
      expect(component.showRenderableContent).toBe(true);
    });

    it('returns true for slider widgets without modelId', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'slider', modelId: '' };
      expect(component.showRenderableContent).toBe(true);
    });

    it('returns true for filter widgets without modelId', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'filter-dropdown', modelId: '' };
      expect(component.showRenderableContent).toBe(true);
    });

    it('requires modelId and bindings for chart widgets', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'chart', modelId: '', dimensions: [], measures: [] };
      expect(component.showRenderableContent).toBe(false);

      component.schema = { ...component.schema, modelId: 'M1', dimensions: ['Region'], measures: ['Rev'] };
      expect(component.showRenderableContent).toBe(true);
    });

    it('requires modelId and bindings for table widgets', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'table', modelId: '' };
      expect(component.showRenderableContent).toBe(false);
    });

    it('requires modelId and bindings for kpi widgets', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'kpi', modelId: '' };
      expect(component.showRenderableContent).toBe(false);
    });
  });

  describe('applySchema', () => {
    it('merges incoming filters with existing filters by dimension', () => {
      const { component, cdr } = createComponent();
      component.schema = {
        ...component.schema,
        modelId: 'M1',
        filters: [{ dimension: 'Region', value: 'EMEA' }],
      };

      component.applySchema({
        filters: [{ dimension: 'Year', value: '2024' }],
      });

      expect(component.schema.filters).toEqual([
        { dimension: 'Region', value: 'EMEA' },
        { dimension: 'Year', value: '2024' },
      ]);
    });

    it('overwrites same-dimension filters', () => {
      const { component } = createComponent();
      component.schema = {
        ...component.schema,
        modelId: 'M1',
        filters: [{ dimension: 'Region', value: 'EMEA' }],
      };

      component.applySchema({
        filters: [{ dimension: 'Region', value: 'APJ' }],
      });

      expect(component.schema.filters).toEqual([
        { dimension: 'Region', value: 'APJ' },
      ]);
    });

    it('triggers change detection', () => {
      const { component, cdr } = createComponent();
      component.applySchema({ title: 'New Title' });
      expect(cdr.markForCheck).toHaveBeenCalled();
    });
  });

  describe('handleFilterChange', () => {
    it('applies a filter schema patch', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, modelId: 'M1' };

      component.handleFilterChange({
        dimension: 'Region',
        value: 'EMEA',
        filterType: 'SingleValue',
      });

      expect(component.schema.filters).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ dimension: 'Region', value: 'EMEA' }),
        ]),
      );
    });
  });

  describe('handleSliderChange', () => {
    it('applies slider value and filter', () => {
      const { component } = createComponent();
      component.schema = {
        ...component.schema,
        modelId: 'M1',
        slider: { min: 0, max: 100 },
      };

      component.handleSliderChange({ dimension: 'Amount', value: 50 });

      expect(component.schema.filters).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ dimension: 'Amount', value: '50', filterType: 'SingleValue' }),
        ]),
      );
      expect(component.schema.slider?.value).toBe(50);
    });
  });

  describe('handleRangeSliderChange', () => {
    it('ensures low <= high', () => {
      const { component } = createComponent();
      component.schema = {
        ...component.schema,
        modelId: 'M1',
        slider: { min: 0, max: 100, rangeValue: { low: 20, high: 80 } },
      };

      component.handleRangeSliderChange('low', { dimension: 'Amount', value: 90 });

      expect(component.schema.slider?.rangeValue?.low).toBeLessThanOrEqual(
        component.schema.slider?.rangeValue?.high ?? Infinity,
      );
    });
  });

  describe('buildChildSchema', () => {
    it('inherits modelId from parent when child has none', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, modelId: 'PARENT_MODEL' };

      const child = component.buildChildSchema({
        widgetType: 'chart',
        modelId: '',
        dimensions: ['Region'],
        measures: ['Revenue'],
      });

      expect(child.modelId).toBe('PARENT_MODEL');
    });

    it('inherits filters from parent when child has none', () => {
      const { component } = createComponent();
      component.schema = {
        ...component.schema,
        modelId: 'M1',
        filters: [{ dimension: 'Region', value: 'EMEA' }],
      };

      const child = component.buildChildSchema({
        widgetType: 'chart',
        modelId: 'M1',
        dimensions: ['Region'],
        measures: ['Revenue'],
      });

      expect(child.filters).toEqual([{ dimension: 'Region', value: 'EMEA' }]);
    });
  });

  describe('depth limit enforcement', () => {
    it('truncates children beyond MAX_CHILDREN_DEPTH levels', () => {
      const { component } = createComponent();

      // Build a schema nested deeper than MAX_CHILDREN_DEPTH
      let deepSchema: any = {
        widgetType: 'heading',
        modelId: '',
        dimensions: [],
        measures: [],
        text: { content: 'leaf' },
      };

      for (let i = 0; i < MAX_CHILDREN_DEPTH + 3; i++) {
        deepSchema = {
          widgetType: 'flex-container',
          modelId: '',
          dimensions: [],
          measures: [],
          children: [deepSchema],
        };
      }

      component.applySchema(deepSchema);

      // Walk down to verify truncation
      let current = component.schema;
      let depth = 0;
      while (current.children?.length) {
        depth++;
        current = current.children[0];
      }

      expect(depth).toBeLessThanOrEqual(MAX_CHILDREN_DEPTH);
    });
  });

  describe('getBindingInfo', () => {
    it('returns current schema binding info', async () => {
      const { component } = createComponent();
      component.schema = {
        ...component.schema,
        widgetType: 'chart',
        modelId: 'M1',
        dimensions: ['Region'],
        measures: ['Revenue'],
        chartType: 'bar',
      };

      const info = await component.getBindingInfo();

      expect(info).toEqual({
        modelId: 'M1',
        dimensions: ['Region'],
        measures: ['Revenue'],
        filters: [],
        chartType: 'bar',
        widgetType: 'chart',
        topK: undefined,
      });
    });
  });

  describe('formatFilterValue', () => {
    it('formats array filter values as comma-separated', () => {
      const { component } = createComponent();
      expect(component.formatFilterValue({
        dimension: 'Region',
        value: ['EMEA', 'APJ'],
      })).toBe('EMEA, APJ');
    });

    it('formats range values with dash separator', () => {
      const { component } = createComponent();
      expect(component.formatFilterValue({
        dimension: 'Date',
        value: { low: '2024-01', high: '2024-12' },
      })).toBe('2024-01 - 2024-12');
    });

    it('formats single values as string', () => {
      const { component } = createComponent();
      expect(component.formatFilterValue({
        dimension: 'Region',
        value: 'EMEA',
      })).toBe('EMEA');
    });

    it('shows All for undefined value', () => {
      const { component } = createComponent();
      expect(component.formatFilterValue({
        dimension: 'Region',
      })).toBe('All');
    });
  });

  describe('resolved getters', () => {
    it('resolvedTextContent falls back to title when text.content is empty', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'heading', title: 'My Title' };
      expect(component.resolvedTextContent).toBe('My Title');
    });

    it('resolvedHeadingLevel defaults to 2', () => {
      const { component } = createComponent();
      expect(component.resolvedHeadingLevel).toBe(2);
    });

    it('resolvedFlexDirection defaults to row', () => {
      const { component } = createComponent();
      expect(component.resolvedFlexDirection).toBe('row');
    });

    it('resolvedLayoutGap clamps to minimum 1', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, layout: { gap: 0 } };
      expect(component.resolvedLayoutGap).toBe(1);
    });

    it('resolvedGridColumns defaults to children count or 2', () => {
      const { component } = createComponent();
      component.schema = { ...component.schema, widgetType: 'grid-container' };
      expect(component.resolvedGridColumns).toBe(2);
    });
  });
});

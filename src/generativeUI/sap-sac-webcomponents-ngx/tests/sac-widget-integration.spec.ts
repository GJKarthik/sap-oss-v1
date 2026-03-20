import '@angular/compiler';

import { ChangeDetectorRef, Injector, SimpleChange, runInInjectionContext } from '@angular/core';
import { EMPTY, Subject } from 'rxjs';
import { describe, expect, it, vi } from 'vitest';

import { ChartType, Feed, FilterValueType } from '@sap-oss/sac-ngx-core';
import { AgUiEvent, SacAgUiService } from '../libs/sac-ai-widget/ag-ui/sac-ag-ui.service';
import { SacToolDispatchService } from '../libs/sac-ai-widget/chat/sac-tool-dispatch.service';
import { SacAiDataWidgetComponent } from '../libs/sac-ai-widget/data-widget/sac-ai-data-widget.component';
import { SacAiSessionService } from '../libs/sac-ai-widget/session/sac-ai-session.service';
import { SacChartComponent } from '../libs/sac-chart/src/lib/components/sac-chart.component';
import { SacChartService } from '../libs/sac-chart/src/lib/services/sac-chart.service';
import { SacDataSourceService } from '../libs/sac-datasource/src/lib/services/sac-datasource.service';
import { SacDataActionService, SacPlanningModelService } from '../libs/sac-planning/src/index';

type WidgetDataSource = {
  id: string;
  modelId: string;
  pause: ReturnType<typeof vi.fn>;
  resume: ReturnType<typeof vi.fn>;
  clearFilters: ReturnType<typeof vi.fn>;
  setFilter: ReturnType<typeof vi.fn>;
  getData: ReturnType<typeof vi.fn>;
};

function createResultSet() {
  return {
    dimensions: ['Region'],
    measures: ['Revenue'],
    data: [
      [{ value: 'North', formatted: 'North' }, { value: 120, formatted: '120' }],
      [{ value: 'South', formatted: 'South' }, { value: 200, formatted: '200' }],
    ],
  };
}

function createWidgetDataSource(modelId: string): WidgetDataSource {
  return {
    id: `ds-${modelId}`,
    modelId,
    pause: vi.fn(),
    resume: vi.fn(),
    clearFilters: vi.fn().mockResolvedValue(undefined),
    setFilter: vi.fn().mockResolvedValue(undefined),
    getData: vi.fn().mockResolvedValue(createResultSet()),
  };
}

function createContainer(width = 640, height = 360): HTMLDivElement {
  return {
    innerHTML: '',
    clientWidth: width,
    clientHeight: height,
    getBoundingClientRect: () => ({
      left: 0,
      top: 0,
      right: width,
      bottom: height,
      width,
      height,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    }),
  } as unknown as HTMLDivElement;
}

async function flushAsync(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));
}

function createToolDispatch() {
  const injector = Injector.create({
    providers: [
      {
        provide: SacDataActionService,
        useValue: {
          execute: vi.fn().mockResolvedValue({
            executionId: 'exec-1',
            status: 'completed',
            startTime: new Date('2026-03-20T00:00:00.000Z'),
          }),
          executeBackground: vi.fn().mockResolvedValue('exec-bg-1'),
        } satisfies Partial<SacDataActionService>,
      },
      {
        provide: SacPlanningModelService,
        useValue: {
          initialize: vi.fn(),
          getLockStatus: vi.fn().mockReturnValue(null),
          getVersions: vi.fn().mockResolvedValue([]),
        } satisfies Partial<SacPlanningModelService>,
      },
    ],
  });

  return runInInjectionContext(injector, () => new SacToolDispatchService());
}

describe('widget and chart integration', () => {
  it('applies tool-dispatch schema updates, configures datasource filters, and reuses the AG-UI thread on resync', async () => {
    const cdr = { markForCheck: vi.fn(), detectChanges: vi.fn() } as ChangeDetectorRef;
    const toolDispatch = createToolDispatch();
    const agUi = {
      run: vi.fn().mockReturnValue(EMPTY),
    };
    const session = {
      getThreadId: vi.fn().mockReturnValue('thread-fixed'),
    };
    const createdDataSources: WidgetDataSource[] = [];
    const dataSources = {
      create: vi.fn((modelId: string) => {
        const instance = createWidgetDataSource(modelId);
        createdDataSources.push(instance);
        return instance;
      }),
      destroy: vi.fn(),
    };

    const injector = Injector.create({
      providers: [
        { provide: ChangeDetectorRef, useValue: cdr },
        { provide: SacToolDispatchService, useValue: toolDispatch },
        { provide: SacAgUiService, useValue: agUi },
        { provide: SacAiSessionService, useValue: session },
        { provide: SacDataSourceService, useValue: dataSources },
      ],
    });

    const component = runInInjectionContext(injector, () => new SacAiDataWidgetComponent());
    component.widgetType = 'chart';
    component.modelId = 'MODEL_1';
    component.ngOnInit();
    await flushAsync();

    expect(agUi.run).toHaveBeenCalledWith({
      message: '__state_sync__',
      modelId: 'MODEL_1',
      threadId: 'thread-fixed',
    });

    await toolDispatch.execute('generate_sac_widget', {
      widgetType: 'chart',
      modelId: 'MODEL_1',
      dimensions: ['Region'],
      measures: ['Revenue'],
      title: 'Revenue by Region',
    });
    await flushAsync();

    await toolDispatch.execute('set_datasource_filter', {
      dimension: 'Region',
      value: 'EMEA',
    });
    await flushAsync();

    expect(component.schema.title).toBe('Revenue by Region');
    expect(component.chartFeeds.get(Feed.CategoryAxis)).toEqual(['Region']);
    expect(component.chartFeeds.get(Feed.ValueAxis)).toEqual(['Revenue']);
    expect(component.formatFilterValue(component.schema.filters?.[0] ?? { dimension: 'Region' })).toBe('EMEA');
    expect(component.dataSource?.modelId).toBe('MODEL_1');
    expect(createdDataSources).toHaveLength(1);
    expect(createdDataSources[0].pause).toHaveBeenCalled();
    expect(createdDataSources[0].clearFilters).toHaveBeenCalled();
    expect(createdDataSources[0].setFilter).toHaveBeenCalledWith('Region', {
      type: FilterValueType.SingleValue,
      dimension: 'Region',
      value: 'EMEA',
    });
    expect(cdr.markForCheck).toHaveBeenCalled();

    component.modelId = 'MODEL_2';
    component.ngOnChanges({
      modelId: new SimpleChange('MODEL_1', 'MODEL_2', false),
    });
    await flushAsync();

    expect(agUi.run).toHaveBeenLastCalledWith({
      message: '__state_sync__',
      modelId: 'MODEL_2',
      threadId: 'thread-fixed',
    });
    expect(dataSources.destroy).toHaveBeenCalledWith('ds-MODEL_1');
    expect(createdDataSources).toHaveLength(2);
    expect(component.dataSource?.modelId).toBe('MODEL_2');

    component.ngOnDestroy();
    expect(dataSources.destroy).toHaveBeenLastCalledWith('ds-MODEL_2');
  });

  it('renders chart output from the widget datasource and emits interaction events through the chart component surface', async () => {
    const chartService = new SacChartService();
    const cdr = { markForCheck: vi.fn() } as ChangeDetectorRef;
    const component = new SacChartComponent(chartService, cdr);
    const dataSource = createWidgetDataSource('MODEL_1');
    const canvas = createContainer();

    component.chartType = ChartType.Column;
    component.dataSource = dataSource;
    component.feeds = new Map([
      [Feed.CategoryAxis, ['Region']],
      [Feed.ValueAxis, ['Revenue']],
    ]);
    component.canvasContainer = { nativeElement: canvas };

    const legendEvents: unknown[] = [];
    const pointEvents: unknown[] = [];
    const selectionEvents: unknown[] = [];
    component.onLegendClick.subscribe((event) => legendEvents.push(event));
    component.onDataPointClick.subscribe((event) => pointEvents.push(event));
    component.onSelectionChange.subscribe((event) => selectionEvents.push(event));

    component.ngAfterViewInit();
    await flushAsync();

    expect(canvas.innerHTML).toContain('<svg');
    expect(component.legendItems).toEqual([
      {
        label: 'Revenue',
        color: '#0a6ed1',
        isVisible: true,
      },
    ]);
    expect(dataSource.getData).toHaveBeenCalled();

    component.handleLegendItemClick(component.legendItems[0], 0, {
      stopPropagation: vi.fn(),
    } as unknown as MouseEvent);

    expect(legendEvents).toEqual([
      expect.objectContaining({
        legendItem: 'Revenue',
        isVisible: false,
      }),
    ]);
    expect(component.legendItems[0]?.isVisible).toBe(false);
    expect(canvas.innerHTML).toContain('All chart series are hidden.');

    vi.spyOn(chartService, 'getDataPointAt').mockReturnValue({
      dimension: 'Region',
      member: 'North',
      measure: 'Revenue',
      value: 120,
      formattedValue: '120',
    });

    component.handleCanvasClick({
      clientX: 96,
      clientY: 180,
    } as MouseEvent);

    expect(pointEvents).toEqual([
      expect.objectContaining({
        dataPoint: expect.objectContaining({
          member: 'North',
          measure: 'Revenue',
        }),
        chartType: ChartType.Column,
      }),
    ]);
    expect(selectionEvents).toEqual([
      expect.objectContaining({
        selectedPoints: [
          expect.objectContaining({
            member: 'North',
          }),
        ],
        source: 'click',
      }),
    ]);

    component.ngOnDestroy();
  });

  it('builds table columns and rows from widget datasource result sets in table mode', async () => {
    const cdr = { markForCheck: vi.fn() } as ChangeDetectorRef;
    const toolDispatch = createToolDispatch();
    const agUi = {
      run: vi.fn().mockReturnValue(EMPTY),
    };
    const session = {
      getThreadId: vi.fn().mockReturnValue('thread-fixed'),
    };
    const dataSources = {
      create: vi.fn((modelId: string) => createWidgetDataSource(modelId)),
      destroy: vi.fn(),
    };

    const injector = Injector.create({
      providers: [
        { provide: ChangeDetectorRef, useValue: cdr },
        { provide: SacToolDispatchService, useValue: toolDispatch },
        { provide: SacAgUiService, useValue: agUi },
        { provide: SacAiSessionService, useValue: session },
        { provide: SacDataSourceService, useValue: dataSources },
      ],
    });

    const component = runInInjectionContext(injector, () => new SacAiDataWidgetComponent());
    component.widgetType = 'table';
    component.modelId = 'MODEL_1';
    component.ngOnInit();
    await flushAsync();

    await toolDispatch.execute('generate_sac_widget', {
      widgetType: 'table',
      modelId: 'MODEL_1',
      dimensions: ['Region'],
      measures: ['Revenue'],
      topK: 1,
    });
    await flushAsync();

    expect(component.tableColumns).toEqual([
      { id: 'Region', label: 'Region', sortable: true, align: 'left' },
      { id: 'Revenue', label: 'Revenue', sortable: true, align: 'right' },
    ]);
    expect(component.tableRows).toEqual([
      { id: 'row-1', Region: 'North', Revenue: '120' },
    ]);

    component.ngOnDestroy();
  });

  it('accepts expanded workspace schemas with layout, text, filter, and child widget surfaces', async () => {
    const cdr = { markForCheck: vi.fn() } as ChangeDetectorRef;
    const toolDispatch = createToolDispatch();
    const agUi = {
      run: vi.fn().mockReturnValue(EMPTY),
    };
    const session = {
      getThreadId: vi.fn().mockReturnValue('thread-fixed'),
    };
    const dataSources = {
      create: vi.fn((modelId: string) => createWidgetDataSource(modelId)),
      destroy: vi.fn(),
    };

    const injector = Injector.create({
      providers: [
        { provide: ChangeDetectorRef, useValue: cdr },
        { provide: SacToolDispatchService, useValue: toolDispatch },
        { provide: SacAgUiService, useValue: agUi },
        { provide: SacAiSessionService, useValue: session },
        { provide: SacDataSourceService, useValue: dataSources },
      ],
    });

    const component = runInInjectionContext(injector, () => new SacAiDataWidgetComponent());
    component.widgetType = 'flex-container';
    component.modelId = 'MODEL_1';
    component.ngOnInit();
    await flushAsync();

    component.applySchema({
      widgetType: 'flex-container',
      title: 'Regional analysis workspace',
      layout: {
        direction: 'row',
        gap: 3,
        wrap: true,
      },
      filters: [
        {
          dimension: 'Region',
          value: ['EMEA'],
          filterType: 'MultipleValue',
        },
      ],
      children: [
        {
          id: 'workspace-heading',
          widgetType: 'heading',
          modelId: '',
          dimensions: [],
          measures: [],
          text: { content: 'Revenue overview', level: 2 },
        },
        {
          id: 'workspace-filter',
          widgetType: 'filter-dropdown',
          modelId: '',
          dimensions: ['Region'],
          measures: [],
          title: 'Region',
        },
        {
          id: 'workspace-chart',
          widgetType: 'chart',
          modelId: '',
          dimensions: ['Region'],
          measures: ['Revenue'],
          chartType: 'column',
        },
      ],
    });
    await flushAsync();

    expect(component.showRenderableContent).toBe(true);
    expect(component.resolvedChildren.map((child) => child.widgetType)).toEqual([
      'heading',
      'filter-dropdown',
      'chart',
    ]);
    expect(component.resolvedFlexDirection).toBe('row');
    expect(component.resolvedLayoutGap).toBe(3);
    expect(component.filterOptions).toEqual([
      { value: 'EMEA', label: 'EMEA', selected: true },
    ]);
    expect(component.buildChildSchema(component.resolvedChildren[2]!)).toEqual(
      expect.objectContaining({
        modelId: 'MODEL_1',
        filters: [
          {
            dimension: 'Region',
            value: ['EMEA'],
            filterType: 'MultipleValue',
          },
        ],
      }),
    );

    component.ngOnDestroy();
  });

  it('reconciles state sync snapshots against the live widget binding to prevent drift', async () => {
    const cdr = { markForCheck: vi.fn(), detectChanges: vi.fn() } as ChangeDetectorRef;
    const toolDispatch = createToolDispatch();
    const stateSyncEvents$ = new Subject<AgUiEvent>();
    const agUi = {
      run: vi.fn().mockReturnValue(stateSyncEvents$.asObservable()),
    };
    const session = {
      getThreadId: vi.fn().mockReturnValue('thread-fixed'),
    };
    const dataSources = {
      create: vi.fn((modelId: string) => createWidgetDataSource(modelId)),
      destroy: vi.fn(),
    };

    const injector = Injector.create({
      providers: [
        { provide: ChangeDetectorRef, useValue: cdr },
        { provide: SacToolDispatchService, useValue: toolDispatch },
        { provide: SacAgUiService, useValue: agUi },
        { provide: SacAiSessionService, useValue: session },
        { provide: SacDataSourceService, useValue: dataSources },
      ],
    });

    const component = runInInjectionContext(injector, () => new SacAiDataWidgetComponent());
    component.widgetType = 'table';
    component.modelId = 'MODEL_1';
    component.ngOnInit();
    await flushAsync();

    component.applySchema({
      widgetType: 'table',
      title: 'Live workspace',
      dimensions: ['Region'],
      measures: ['Revenue'],
      filters: [
        {
          dimension: 'Region',
          value: ['EMEA'],
          filterType: 'MultipleValue',
        },
      ],
    });
    await flushAsync();

    stateSyncEvents$.next({
      type: 'CUSTOM',
      timestamp: 1,
      threadId: 'thread-fixed',
      name: 'UI_SCHEMA_SNAPSHOT',
      value: {
        title: 'Stale agent title',
        subtitle: 'Synced subtitle',
        widgetType: 'chart',
        chartType: 'line',
        modelId: 'MODEL_STALE',
        dimensions: ['Country'],
        measures: ['Margin'],
        filters: [
          {
            dimension: 'Region',
            value: 'APJ',
            filterType: 'SingleValue',
          },
        ],
      },
    });
    await flushAsync();

    expect(component.schema.modelId).toBe('MODEL_1');
    expect(component.schema.widgetType).toBe('table');
    expect(component.schema.chartType).toBeUndefined();
    expect(component.schema.dimensions).toEqual(['Region']);
    expect(component.schema.measures).toEqual(['Revenue']);
    expect(component.schema.filters).toEqual([
      {
        dimension: 'Region',
        value: ['EMEA'],
        filterType: 'MultipleValue',
      },
    ]);
    expect(component.schema.title).toBe('Live workspace');
    expect(component.schema.subtitle).toBe('Synced subtitle');
    expect(cdr.detectChanges).toHaveBeenCalled();

    component.ngOnDestroy();
  });
});

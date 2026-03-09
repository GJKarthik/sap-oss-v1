import '@angular/compiler';
import { describe, expect, it, vi } from 'vitest';

vi.mock('@sap-oss/sac-ngx-core', () => ({
  ChartType: {
    Bar: 'bar',
    Column: 'column',
    Line: 'line',
    Area: 'area',
    Pie: 'pie',
    Donut: 'donut',
    StackedBar: 'stacked_bar',
    StackedColumn: 'stacked_column',
  },
  Feed: {
    CategoryAxis: 'categoryAxis',
    Color: 'color',
    ValueAxis: 'valueAxis',
  },
  ChartLegendPosition: {
    Top: 'TOP',
    Bottom: 'BOTTOM',
    Left: 'LEFT',
    Right: 'RIGHT',
    None: 'NONE',
  },
  ForecastType: {
    Automatic: 'Automatic',
  },
}));

import { ChartType, Feed } from '@sap-oss/sac-ngx-core';
import { SacChartService } from '../libs/sac-chart/src/lib/services/sac-chart.service';

function createContainer(width = 640, height = 360): HTMLElement {
  return {
    innerHTML: '',
    clientWidth: width,
    clientHeight: height,
  } as unknown as HTMLElement;
}

describe('SacChartService', () => {
  it('renders an SVG chart from a datasource-backed result set', async () => {
    const service = new SacChartService();
    const container = createContainer();
    const dataSource = {
      getData: vi.fn().mockResolvedValue({
        dimensions: ['Region'],
        measures: ['Revenue'],
        data: [
          [{ value: 'North', formatted: 'North' }, { value: 120, formatted: '120' }],
          [{ value: 'South', formatted: 'South' }, { value: 200, formatted: '200' }],
        ],
      }),
    };

    service.initialize(container, {
      chartType: ChartType.Column,
      dataSource,
      feeds: new Map([
        [Feed.CategoryAxis, ['Region']],
        [Feed.ValueAxis, ['Revenue']],
      ]),
    });

    await service.refreshData();

    expect(container.innerHTML).toContain('<svg');
    expect(container.innerHTML).toContain('North');
    expect(service.getLegendItems()).toEqual([
      {
        label: 'Revenue',
        color: '#0a6ed1',
        isVisible: true,
      },
    ]);

    const hit = service.getDataPointAt(80, 150);
    expect(hit).toMatchObject({
      member: 'North',
      measure: 'Revenue',
      value: 120,
    });

    const exported = await service.exportChart('svg');
    await expect(exported.text()).resolves.toContain('South');
  });

  it('keeps cartesian legend items available when series are hidden', async () => {
    const service = new SacChartService();
    const container = createContainer();
    const dataSource = {
      getData: vi.fn().mockResolvedValue({
        dimensions: ['Region'],
        measures: ['Revenue', 'Cost'],
        data: [
          [
            { value: 'North', formatted: 'North' },
            { value: 120, formatted: '120' },
            { value: 70, formatted: '70' },
          ],
          [
            { value: 'South', formatted: 'South' },
            { value: 200, formatted: '200' },
            { value: 90, formatted: '90' },
          ],
        ],
      }),
    };

    service.initialize(container, {
      chartType: ChartType.Column,
      dataSource,
      feeds: new Map([
        [Feed.CategoryAxis, ['Region']],
        [Feed.ValueAxis, ['Revenue', 'Cost']],
      ]),
    });

    await service.refreshData();
    service.toggleLegendItem('Revenue');
    service.toggleLegendItem('Cost');

    expect(container.innerHTML).toContain('All chart series are hidden.');
    expect(service.getLegendItems()).toEqual([
      {
        label: 'Revenue',
        color: '#0a6ed1',
        isVisible: false,
      },
      {
        label: 'Cost',
        color: '#f58b00',
        isVisible: false,
      },
    ]);
  });

  it('keeps pie legend items visible for re-enable after a slice is hidden', async () => {
    const service = new SacChartService();
    const container = createContainer();
    const dataSource = {
      getData: vi.fn().mockResolvedValue({
        dimensions: ['Region'],
        measures: ['Revenue'],
        data: [
          [{ value: 'North', formatted: 'North' }, { value: 120, formatted: '120' }],
          [{ value: 'South', formatted: 'South' }, { value: 200, formatted: '200' }],
        ],
      }),
    };

    service.initialize(container, {
      chartType: ChartType.Pie,
      dataSource,
      feeds: new Map([
        [Feed.CategoryAxis, ['Region']],
        [Feed.ValueAxis, ['Revenue']],
      ]),
    });

    await service.refreshData();
    service.toggleLegendItem('North');

    expect(container.innerHTML).toContain('<svg');
    expect(service.getLegendItems()).toEqual([
      {
        label: 'North',
        color: '#0a6ed1',
        isVisible: false,
      },
      {
        label: 'South',
        color: '#f58b00',
        isVisible: true,
      },
    ]);
  });
});

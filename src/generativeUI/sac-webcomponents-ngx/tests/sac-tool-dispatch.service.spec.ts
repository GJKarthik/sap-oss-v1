import { describe, expect, it, vi } from 'vitest';

import { SacToolDispatchService, WidgetStateTarget } from '../libs/sac-ai-widget/chat/sac-tool-dispatch.service';
import { SacDataActionService, SacPlanningModelService } from '../libs/sac-planning/src/index';

function createTarget(overrides: Partial<WidgetStateTarget> = {}): WidgetStateTarget {
  return {
    applySchema: vi.fn(),
    getBindingInfo: vi.fn().mockResolvedValue({
      modelId: 'MODEL_1',
      dimensions: ['Region'],
      measures: ['Revenue'],
      filters: [],
      chartType: 'bar',
      widgetType: 'chart',
      topK: 5,
    }),
    refreshData: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  };
}

describe('SacToolDispatchService', () => {
  it('builds a confirmation review with rollback guidance for risky planning actions', async () => {
    const service = new SacToolDispatchService(
      {
        execute: vi.fn(),
        executeBackground: vi.fn(),
      } as unknown as SacDataActionService,
      {
        initialize: vi.fn(),
        getVersions: vi.fn().mockResolvedValue([
          {
            id: 'public.actuals',
            name: 'Actuals',
            isWorkingVersion: false,
          },
          {
            id: 'private.me',
            name: 'My Private Version',
            isWorkingVersion: true,
          },
        ]),
        getLockStatus: vi.fn().mockReturnValue({ state: 'locked' }),
      } as unknown as SacPlanningModelService,
    );
    service.registerTarget(createTarget());

    const review = await service.getConfirmationReview('run_data_action', {
      actionId: 'ALLOCATE_BUDGET',
      params: '{"region":"EMEA","amount":1200}',
    });

    expect(review).toEqual({
      toolName: 'run_data_action',
      title: 'Review planning action ALLOCATE_BUDGET',
      summary: 'Run data action ALLOCATE_BUDGET now against planning model MODEL_1.',
      confirmationLabel: 'Run action',
      riskLevel: 'high',
      actionId: 'ALLOCATE_BUDGET',
      modelId: 'MODEL_1',
      binding: expect.objectContaining({
        modelId: 'MODEL_1',
        widgetType: 'chart',
      }),
      normalizedArgs: {
        actionId: 'ALLOCATE_BUDGET',
        modelId: 'MODEL_1',
        params: {
          region: 'EMEA',
          amount: 1200,
        },
      },
      affectedScope: [
        'Model MODEL_1',
        'Widget chart',
        'Chart bar',
        'Parameters region, amount',
      ],
      rollbackPreview: {
        strategy: 'revertData',
        label: 'If this action changes planning data, revert unsaved changes on model MODEL_1 with revertData() before save or publish.',
        warnings: [
          'Working version: My Private Version (private.me)',
          'Current lock state: locked',
          'Rollback is only available before the working version is saved or published.',
        ],
      },
    });
  });

  it('executes run_data_action through the real planning services and refreshes the bound widget', async () => {
    const dataActionService = {
      execute: vi.fn().mockResolvedValue({
        executionId: 'exec-42',
        status: 'completed',
        startTime: new Date('2026-03-20T00:00:00.000Z'),
        rowsAffected: 12,
      }),
      executeBackground: vi.fn(),
    };
    const planningModelService = {
      initialize: vi.fn(),
    };
    const target = createTarget();
    const service = new SacToolDispatchService(
      dataActionService as unknown as SacDataActionService,
      planningModelService as unknown as SacPlanningModelService,
    );

    service.registerTarget(target);

    const result = await service.execute('run_data_action', {
      actionId: 'ALLOCATE_BUDGET',
      params: '{"region":"EMEA","amount":1200}',
    });

    expect(planningModelService.initialize).toHaveBeenCalledWith('MODEL_1');
    expect(dataActionService.execute).toHaveBeenCalledWith('ALLOCATE_BUDGET', {
      region: 'EMEA',
      amount: 1200,
    });
    expect(target.refreshData).toHaveBeenCalledTimes(1);
    expect(result).toEqual({
      success: true,
      data: expect.objectContaining({
        modelId: 'MODEL_1',
        actionId: 'ALLOCATE_BUDGET',
        parameters: {
          region: 'EMEA',
          amount: 1200,
        },
        binding: expect.objectContaining({
          modelId: 'MODEL_1',
          widgetType: 'chart',
        }),
      }),
    });
  });

  it('returns enriched binding metadata and rejects mismatched requested models', async () => {
    const service = new SacToolDispatchService(
      {
        execute: vi.fn(),
        executeBackground: vi.fn(),
      } as unknown as SacDataActionService,
      {
        initialize: vi.fn(),
      } as unknown as SacPlanningModelService,
    );
    service.registerTarget(createTarget());

    const activeBinding = await service.execute('get_model_dimensions', {});
    expect(activeBinding).toEqual({
      success: true,
      data: expect.objectContaining({
        modelId: 'MODEL_1',
        dimensions: ['Region'],
        measures: ['Revenue'],
        widgetType: 'chart',
      }),
    });

    const mismatchedBinding = await service.execute('get_model_dimensions', { modelId: 'MODEL_2' });
    expect(mismatchedBinding).toEqual({
      success: false,
      error: 'Requested model MODEL_2 is not the active widget model (MODEL_1)',
    });
  });

  it('applies parsed filter updates and refreshes the current widget target', async () => {
    const target = createTarget();
    const service = new SacToolDispatchService(
      {
        execute: vi.fn(),
        executeBackground: vi.fn(),
      } as unknown as SacDataActionService,
      {
        initialize: vi.fn(),
      } as unknown as SacPlanningModelService,
    );
    service.registerTarget(target);

    const result = await service.execute('set_datasource_filter', {
      dimension: 'Region',
      value: '["EMEA","APJ"]',
      filterType: 'MultipleValue',
    });

    expect(target.applySchema).toHaveBeenCalledWith({
      filters: [
        {
          dimension: 'Region',
          value: ['EMEA', 'APJ'],
          filterType: 'MultipleValue',
        },
      ],
    });
    expect(target.refreshData).toHaveBeenCalledTimes(1);
    expect(result).toEqual({
      success: true,
      data: expect.objectContaining({
        applied: {
          dimension: 'Region',
          value: ['EMEA', 'APJ'],
          filterType: 'MultipleValue',
        },
      }),
    });
  });

  it('preserves expanded generated surface fields when generating SAC widgets', async () => {
    const target = createTarget();
    const service = new SacToolDispatchService(
      {
        execute: vi.fn(),
        executeBackground: vi.fn(),
      } as unknown as SacDataActionService,
      {
        initialize: vi.fn(),
      } as unknown as SacPlanningModelService,
    );
    service.registerTarget(target);

    const result = await service.execute('generate_sac_widget', {
      widgetType: 'flex-container',
      modelId: 'MODEL_1',
      title: 'Regional analysis workspace',
      subtitle: 'Generated from agent request',
      layout: {
        direction: 'row',
        gap: 3,
        wrap: true,
      },
      text: {
        content: 'Compare revenue and margin by region.',
        markdown: true,
      },
      children: [
        {
          id: 'workspace-heading',
          widgetType: 'heading',
          text: { content: 'Regional performance', level: 2 },
          modelId: '',
          dimensions: [],
          measures: [],
        },
        {
          id: 'workspace-chart',
          widgetType: 'chart',
          modelId: 'MODEL_1',
          dimensions: ['Region'],
          measures: ['Revenue'],
        },
      ],
      filters: [
        {
          dimension: 'Region',
          value: ['EMEA', 'APJ'],
          filterType: 'MultipleValue',
        },
      ],
    });

    expect(target.applySchema).toHaveBeenCalledWith({
      widgetType: 'flex-container',
      modelId: 'MODEL_1',
      dimensions: [],
      measures: [],
      title: 'Regional analysis workspace',
      subtitle: 'Generated from agent request',
      topK: undefined,
      filters: [
        {
          dimension: 'Region',
          value: ['EMEA', 'APJ'],
          filterType: 'MultipleValue',
        },
      ],
      layout: {
        direction: 'row',
        gap: 3,
        wrap: true,
      },
      slider: undefined,
      text: {
        content: 'Compare revenue and margin by region.',
        markdown: true,
      },
      children: [
        expect.objectContaining({
          id: 'workspace-heading',
          widgetType: 'heading',
        }),
        expect.objectContaining({
          id: 'workspace-chart',
          widgetType: 'chart',
        }),
      ],
      chartType: undefined,
      ariaLabel: undefined,
      ariaDescription: undefined,
    });
    expect(result).toEqual({
      success: true,
      data: expect.objectContaining({
        schema: expect.objectContaining({
          widgetType: 'flex-container',
          children: expect.arrayContaining([
            expect.objectContaining({ widgetType: 'heading' }),
            expect.objectContaining({ widgetType: 'chart' }),
          ]),
        }),
      }),
    });
  });
});

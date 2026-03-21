import '@angular/compiler';

import { ChangeDetectorRef, Injector, runInInjectionContext } from '@angular/core';
import { Subject } from 'rxjs';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { AgUiEvent, SacAgUiService } from '../libs/sac-ai-widget/ag-ui/sac-ag-ui.service';
import { SacAiChatPanelComponent } from '../libs/sac-ai-widget/chat/sac-ai-chat-panel.component';
import { SacToolDispatchService } from '../libs/sac-ai-widget/chat/sac-tool-dispatch.service';
import { SacAiSessionService } from '../libs/sac-ai-widget/session/sac-ai-session.service';

async function flushAsync(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));
}

function createSessionStub() {
  const auditEntries: Array<{
    id: string;
    timestamp: string;
    eventType: string;
    status: 'processing' | 'approved' | 'rejected' | 'completed' | 'error';
    detail: string;
  }> = [];
  const replayEntries: Array<{
    id: string;
    sequence: number;
    timestamp: string;
    kind:
      | 'request.sent'
      | 'stream.chunk'
      | 'stream.complete'
      | 'stream.error'
      | 'tool.requested'
      | 'tool.result'
      | 'tool.error'
      | 'approval.required'
      | 'approval.queued'
      | 'approval.approved'
      | 'approval.rejected';
    detail: string;
  }> = [];

  return {
    getThreadId: vi.fn().mockReturnValue('thread-chat'),
    recordAudit: vi.fn((eventType: string, status: 'processing' | 'approved' | 'rejected' | 'completed' | 'error', detail: string) => {
      const entry = {
        id: `audit-${auditEntries.length + 1}`,
        timestamp: new Date().toISOString(),
        eventType,
        status,
        detail,
      };
      auditEntries.unshift(entry);
      return entry;
    }),
    getAuditEntries: vi.fn(() => [...auditEntries]),
    clearAudit: vi.fn(() => {
      auditEntries.length = 0;
    }),
    recordReplay: vi.fn((kind: typeof replayEntries[number]['kind'], detail: string) => {
      const entry = {
        id: `replay-${replayEntries.length + 1}`,
        sequence: replayEntries.length + 1,
        timestamp: new Date().toISOString(),
        kind,
        detail,
      };
      replayEntries.unshift(entry);
      return entry;
    }),
    getReplayEntries: vi.fn(() => [...replayEntries]),
    clearReplay: vi.fn(() => {
      replayEntries.length = 0;
    }),
  };
}

describe('SacAiChatPanelComponent', () => {
  afterEach(() => {
    vi.clearAllTimers();
  });

  it('executes only correlated tool-call sequences and posts the correlated result', async () => {
    const events$ = new Subject<AgUiEvent>();
    const agUi = {
      run: vi.fn().mockReturnValue(events$.asObservable()),
      dispatchToolResult: vi.fn(),
    };
    const toolDispatch = {
      getConfirmationReview: vi.fn().mockResolvedValue(null),
      execute: vi.fn().mockResolvedValue({ success: true, data: { chartType: 'line' } }),
    };
    const session = createSessionStub();
    const cdr = { markForCheck: vi.fn() } as ChangeDetectorRef;

    const injector = Injector.create({
      providers: [
        { provide: ChangeDetectorRef, useValue: cdr },
        { provide: SacAgUiService, useValue: agUi },
        { provide: SacToolDispatchService, useValue: toolDispatch },
        { provide: SacAiSessionService, useValue: session },
      ],
    });

    const component = runInInjectionContext(injector, () => new SacAiChatPanelComponent());
    component.inputText = 'Switch the chart to line';
    component.send();

    events$.next({
      type: 'TOOL_CALL_ARGS',
      timestamp: 1,
      toolCallId: 'orphan-tool',
      delta: '{"chartType":"bar"}',
      threadId: 'thread-chat',
    });
    events$.next({
      type: 'TOOL_CALL_END',
      timestamp: 2,
      toolCallId: 'orphan-tool',
      toolName: 'set_chart_type',
      threadId: 'thread-chat',
    });
    events$.next({
      type: 'TOOL_CALL_START',
      timestamp: 3,
      toolCallId: 'tool-1',
      toolName: 'set_chart_type',
      threadId: 'thread-chat',
    });
    events$.next({
      type: 'TOOL_CALL_ARGS',
      timestamp: 4,
      toolCallId: 'tool-1',
      delta: '{"chartType":"line"}',
      threadId: 'thread-chat',
    });
    events$.next({
      type: 'TOOL_CALL_END',
      timestamp: 5,
      toolCallId: 'tool-1',
      toolName: 'set_chart_type',
      threadId: 'thread-chat',
    });
    events$.complete();

    await flushAsync();

    expect(agUi.run).toHaveBeenCalledWith({
      message: 'Switch the chart to line',
      modelId: undefined,
      threadId: 'thread-chat',
    });
    expect(toolDispatch.execute).toHaveBeenCalledTimes(1);
    expect(toolDispatch.execute).toHaveBeenCalledWith('set_chart_type', { chartType: 'line' });
    expect(agUi.dispatchToolResult).toHaveBeenCalledWith('tool-1', {
      success: true,
      data: { chartType: 'line' },
    });
    expect(component.auditEntries.some((entry) => entry.eventType === 'tool.executed' && entry.status === 'completed')).toBe(true);
    expect(component.replayEntries.some((entry) => entry.kind === 'request.sent')).toBe(true);
    expect(component.replayEntries.some((entry) => entry.kind === 'tool.result')).toBe(true);
    expect(component.replayEntries.some((entry) => entry.kind === 'stream.complete')).toBe(true);

    component.ngOnDestroy();
  });

  it('requires confirmation before executing risky planning actions and dispatches the approved result', async () => {
    const events$ = new Subject<AgUiEvent>();
    const agUi = {
      run: vi.fn().mockReturnValue(events$.asObservable()),
      dispatchToolResult: vi.fn(),
    };
    const toolDispatch = {
      getConfirmationReview: vi.fn().mockResolvedValue({
        toolName: 'run_data_action',
        title: 'Review planning action ALLOCATE_BUDGET',
        summary: 'Run data action ALLOCATE_BUDGET now against planning model MODEL_1.',
        confirmationLabel: 'Run action',
        riskLevel: 'high',
        actionId: 'ALLOCATE_BUDGET',
        modelId: 'MODEL_1',
        normalizedArgs: {
          actionId: 'ALLOCATE_BUDGET',
          modelId: 'MODEL_1',
          params: { region: 'EMEA', amount: 1200 },
        },
        affectedScope: ['Model MODEL_1', 'Parameters region, amount'],
        rollbackPreview: {
          strategy: 'revertData',
          label: 'Revert unsaved changes before save.',
          warnings: ['Working version: My Private Version (private.me)'],
        },
      }),
      execute: vi.fn().mockResolvedValue({
        success: true,
        data: { executionId: 'exec-42' },
      }),
    };
    const session = createSessionStub();
    const cdr = { markForCheck: vi.fn() } as ChangeDetectorRef;

    const injector = Injector.create({
      providers: [
        { provide: ChangeDetectorRef, useValue: cdr },
        { provide: SacAgUiService, useValue: agUi },
        { provide: SacToolDispatchService, useValue: toolDispatch },
        { provide: SacAiSessionService, useValue: session },
      ],
    });

    const component = runInInjectionContext(injector, () => new SacAiChatPanelComponent());
    component.inputText = 'Allocate budget to EMEA';
    component.send();

    events$.next({
      type: 'TOOL_CALL_START',
      timestamp: 1,
      toolCallId: 'tool-approve',
      toolName: 'run_data_action',
      threadId: 'thread-chat',
    });
    events$.next({
      type: 'TOOL_CALL_ARGS',
      timestamp: 2,
      toolCallId: 'tool-approve',
      delta: '{"actionId":"ALLOCATE_BUDGET","params":{"region":"EMEA","amount":1200}}',
      threadId: 'thread-chat',
    });
    events$.next({
      type: 'TOOL_CALL_END',
      timestamp: 3,
      toolCallId: 'tool-approve',
      toolName: 'run_data_action',
      threadId: 'thread-chat',
    });

    await flushAsync();

    expect(toolDispatch.getConfirmationReview).toHaveBeenCalledWith('run_data_action', {
      actionId: 'ALLOCATE_BUDGET',
      params: {
        region: 'EMEA',
        amount: 1200,
      },
    });
    expect(toolDispatch.execute).not.toHaveBeenCalled();
    expect(component.activeConfirmation?.review.rollbackPreview.label).toBe('Revert unsaved changes before save.');
    expect(component.auditEntries.some((entry) => entry.eventType === 'approval.required')).toBe(true);

    await component.approveActiveConfirmation();

    expect(toolDispatch.execute).toHaveBeenCalledWith('run_data_action', {
      actionId: 'ALLOCATE_BUDGET',
      modelId: 'MODEL_1',
      params: {
        region: 'EMEA',
        amount: 1200,
      },
    });
    expect(agUi.dispatchToolResult).toHaveBeenCalledWith('tool-approve', {
      success: true,
      data: { executionId: 'exec-42' },
    });
    expect(component.activeConfirmation).toBeNull();
    expect(component.auditEntries.some((entry) => entry.eventType === 'approval.approved')).toBe(true);
    expect(component.replayEntries.some((entry) => entry.kind === 'approval.required')).toBe(true);
    expect(component.replayEntries.some((entry) => entry.kind === 'approval.approved')).toBe(true);

    component.ngOnDestroy();
  });

  it('lets the user reject risky planning actions before execution', async () => {
    const events$ = new Subject<AgUiEvent>();
    const agUi = {
      run: vi.fn().mockReturnValue(events$.asObservable()),
      dispatchToolResult: vi.fn(),
    };
    const toolDispatch = {
      getConfirmationReview: vi.fn().mockResolvedValue({
        toolName: 'run_data_action',
        title: 'Review planning action FREEZE_PLAN',
        summary: 'Run data action FREEZE_PLAN now against planning model MODEL_1.',
        confirmationLabel: 'Run action',
        riskLevel: 'high',
        actionId: 'FREEZE_PLAN',
        modelId: 'MODEL_1',
        normalizedArgs: {
          actionId: 'FREEZE_PLAN',
          modelId: 'MODEL_1',
          params: {},
        },
        affectedScope: ['Model MODEL_1'],
        rollbackPreview: {
          strategy: 'revertData',
          label: 'Revert unsaved changes before save.',
          warnings: ['Working version: My Private Version (private.me)'],
        },
      }),
      execute: vi.fn(),
    };
    const session = createSessionStub();
    const cdr = { markForCheck: vi.fn() } as ChangeDetectorRef;

    const injector = Injector.create({
      providers: [
        { provide: ChangeDetectorRef, useValue: cdr },
        { provide: SacAgUiService, useValue: agUi },
        { provide: SacToolDispatchService, useValue: toolDispatch },
        { provide: SacAiSessionService, useValue: session },
      ],
    });

    const component = runInInjectionContext(injector, () => new SacAiChatPanelComponent());
    component.inputText = 'Freeze the plan';
    component.send();

    events$.next({
      type: 'TOOL_CALL_START',
      timestamp: 1,
      toolCallId: 'tool-reject',
      toolName: 'run_data_action',
      threadId: 'thread-chat',
    });
    events$.next({
      type: 'TOOL_CALL_ARGS',
      timestamp: 2,
      toolCallId: 'tool-reject',
      delta: '{"actionId":"FREEZE_PLAN","params":{}}',
      threadId: 'thread-chat',
    });
    events$.next({
      type: 'TOOL_CALL_END',
      timestamp: 3,
      toolCallId: 'tool-reject',
      toolName: 'run_data_action',
      threadId: 'thread-chat',
    });

    await flushAsync();
    component.rejectActiveConfirmation();

    expect(toolDispatch.execute).not.toHaveBeenCalled();
    expect(agUi.dispatchToolResult).toHaveBeenCalledWith('tool-reject', {
      success: false,
      error: 'Rejected by user before executing planning action',
      data: {
        code: 'USER_REJECTED',
        toolName: 'run_data_action',
        actionId: 'FREEZE_PLAN',
        modelId: 'MODEL_1',
      },
    });
    expect(component.activeConfirmation).toBeNull();
    expect(component.auditEntries.some((entry) => entry.eventType === 'approval.rejected')).toBe(true);
    expect(component.replayEntries.some((entry) => entry.kind === 'approval.rejected')).toBe(true);

    component.ngOnDestroy();
  });
});

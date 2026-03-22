import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  AgUiEvent,
  AgUiToolCallEndEvent,
  SacAgUiService,
} from '../libs/sac-ai-widget/ag-ui/sac-ag-ui.service';
import { SacAiSessionService } from '../libs/sac-ai-widget/session/sac-ai-session.service';

function createSseResponse(...frames: string[]): Response {
  const encoder = new TextEncoder();

  return new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      for (const frame of frames) {
        controller.enqueue(encoder.encode(frame));
      }
      controller.close();
    },
  }), {
    status: 200,
    headers: { 'Content-Type': 'text/event-stream' },
  });
}

function collectEvents(observable: { subscribe: (observer: {
  next: (event: AgUiEvent) => void;
  error: (error: Error) => void;
  complete: () => void;
}) => unknown }): Promise<AgUiEvent[]> {
  return new Promise<AgUiEvent[]>((resolve, reject) => {
    const events: AgUiEvent[] = [];

    observable.subscribe({
      next: (event: AgUiEvent) => events.push(event),
      error: (error: Error) => reject(error),
      complete: () => resolve(events),
    });
  });
}

async function flushAsync(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));
}

describe('SacAgUiService', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('drops malformed or uncorrelated SSE events and preserves validated tool-call metadata', async () => {
    const fetchMock = vi.fn().mockResolvedValue(createSseResponse(
      'data: {"type":"TOOL_CALL_ARGS","timestamp":1,"toolCallId":"tool-1","delta":"{\\"chartType\\":\\"line\\"}","threadId":"thread-1","runId":"run-1"}\n\n',
      'data: {"type":"RUN_STARTED","timestamp":2,"runId":"run-1","threadId":"thread-1"}\n\n',
      'data: {"type":"TOOL_CALL_START","timestamp":3,"toolCallId":"tool-1","toolName":"set_chart_type","threadId":"thread-1","runId":"run-1"}\n\n',
      'data: {"type":"TOOL_CALL_ARGS","timestamp":4,"toolCallId":"tool-1","delta":"{\\"chartType\\":\\"line\\"}","threadId":"thread-1","runId":"run-1"}\n\n',
      'data: {"type":"TOOL_CALL_END","timestamp":5,"toolCallId":"tool-1","threadId":"thread-1","runId":"run-1"}\n\n',
      'data: {"type":"TEXT_MESSAGE_CONTENT","timestamp":6,"delta":"ignore me","messageId":"msg-1","threadId":"wrong-thread","runId":"run-1"}\n\n',
      'data: {"type":"RUN_FINISHED","timestamp":7,"runId":"run-1","threadId":"thread-1"}\n\n',
    ));
    vi.stubGlobal('fetch', fetchMock);

    const service = new SacAgUiService(
      { getToken: () => 'token-1' } as never,
      'https://backend.example',
      new SacAiSessionService(),
    );

    const events = await collectEvents(service.run({
      message: 'show revenue by region',
      modelId: 'MODEL_1',
      threadId: 'thread-1',
    }));

    expect(events.map((event) => event.type)).toEqual([
      'RUN_STARTED',
      'TOOL_CALL_START',
      'TOOL_CALL_ARGS',
      'TOOL_CALL_END',
      'RUN_FINISHED',
    ]);
    expect((events[3] as AgUiToolCallEndEvent).toolName).toBe('set_chart_type');
    expect(events.every((event) => event.threadId === 'thread-1')).toBe(true);
  });

  it('includes tool-call correlation metadata when posting a tool result and ignores unknown ids', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(createSseResponse(
        'data: {"type":"RUN_STARTED","timestamp":1,"runId":"run-22","threadId":"thread-22"}\n\n',
        'data: {"type":"TOOL_CALL_START","timestamp":2,"toolCallId":"tool-22","toolName":"generate_sac_widget","threadId":"thread-22","runId":"run-22"}\n\n',
        'data: {"type":"TOOL_CALL_END","timestamp":3,"toolCallId":"tool-22","threadId":"thread-22","runId":"run-22"}\n\n',
        'data: {"type":"RUN_FINISHED","timestamp":4,"runId":"run-22","threadId":"thread-22"}\n\n',
      ))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);

    const service = new SacAgUiService(
      { getToken: () => 'token-2' } as never,
      'https://backend.example',
      new SacAiSessionService(),
    );

    await collectEvents(service.run({
      message: 'build me a widget',
      modelId: 'MODEL_2',
      threadId: 'thread-22',
    }));

    service.dispatchToolResult('tool-22', { success: true, data: { widgetType: 'chart' } });
    service.dispatchToolResult('missing-tool', { success: true });
    await flushAsync();

    expect(fetchMock).toHaveBeenCalledTimes(2);

    const [, init] = fetchMock.mock.calls[1] as [string, RequestInit];
    expect(fetchMock.mock.calls[1]?.[0]).toBe('https://backend.example/ag-ui/tool-result');
    expect(JSON.parse(String(init.body))).toEqual({
      toolCallId: 'tool-22',
      toolName: 'generate_sac_widget',
      runId: 'run-22',
      threadId: 'thread-22',
      result: { success: true, data: { widgetType: 'chart' } },
    });
  });

  it('fails the stream when an SSE frame exceeds the configured size limit', async () => {
    const oversizedPayload = 'x'.repeat(70 * 1024);
    const fetchMock = vi.fn().mockResolvedValue(createSseResponse(
      `data: {"type":"CUSTOM","timestamp":1,"name":"OVERSIZED","value":"${oversizedPayload}","threadId":"thread-99"}\n\n`,
    ));
    vi.stubGlobal('fetch', fetchMock);

    const service = new SacAgUiService(
      { getToken: () => null } as never,
      'https://backend.example',
      new SacAiSessionService(),
    );

    await expect(collectEvents(service.run({
      message: 'oversized',
      threadId: 'thread-99',
    }))).rejects.toThrow('AG-UI: SSE frame exceeded size limit');
  });
});

(function attachHarness(global) {
  const state = {
    errors: [],
    runRequests: [],
    toolResults: [],
    dataRequests: [],
    lifecycle: [],
  };

  const baseRows = [
    { Region: 'EMEA', Revenue: 420000 },
    { Region: 'APJ', Revenue: 310000 },
    { Region: 'AMER', Revenue: 530000 },
  ];

  function now() {
    return Date.now();
  }

  function recordError(type, message) {
    state.errors.push({ type, message: String(message) });
  }

  function buildJsonResponse(body, init) {
    return new Response(JSON.stringify(body), {
      status: 200,
      ...init,
      headers: {
        'Content-Type': 'application/json',
        ...(init?.headers ?? {}),
      },
    });
  }

  function buildSseResponse(events) {
    const encoder = new TextEncoder();

    return new Response(new ReadableStream({
      start(controller) {
        for (const event of events) {
          const chunk = `data: ${JSON.stringify(event)}\n\n`;
          controller.enqueue(encoder.encode(chunk));
        }
        controller.close();
      },
    }), {
      status: 200,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
      },
    });
  }

  function buildResultSet(modelId, filters) {
    const regionFilter = filters?.Region;
    const rows = typeof regionFilter === 'string'
      ? baseRows.filter((row) => row.Region === regionFilter)
      : baseRows;

    return {
      data: rows.map((row) => [
        {
          value: row.Region,
          formatted: row.Region,
          status: 'normal',
        },
        {
          value: row.Revenue,
          formatted: row.Revenue.toLocaleString('en-US'),
          currency: 'USD',
          status: 'normal',
        },
      ]),
      dimensions: ['Region'],
      measures: ['Revenue'],
      rowCount: rows.length,
      columnCount: 2,
      metadata: {
        modelId,
        executionTime: 12,
        totalRowCount: rows.length,
        truncated: false,
        dimensionHeaders: [
          { id: 'Region', name: 'Region', index: 0 },
        ],
        measureHeaders: [
          { id: 'Revenue', name: 'Revenue', index: 1, currency: 'USD' },
        ],
      },
    };
  }

  function buildStateSyncEvents(payload, requestPath) {
    const reconnected = requestPath.includes('mock-cap-v2');

    return [
      {
        type: 'RUN_STARTED',
        timestamp: now(),
        runId: `state-${payload.threadId}`,
        threadId: payload.threadId,
      },
      {
        type: 'CUSTOM',
        timestamp: now(),
        runId: `state-${payload.threadId}`,
        threadId: payload.threadId,
        name: 'UI_SCHEMA_SNAPSHOT',
        value: {
          title: reconnected ? 'Regional Revenue (Reconnected)' : 'Regional Revenue',
          widgetType: 'chart',
          chartType: 'bar',
          modelId: payload.modelId,
          dimensions: ['Region'],
          measures: ['Revenue'],
          subtitle: reconnected ? 'Recovered after backend reconnect' : undefined,
        },
      },
      {
        type: 'RUN_FINISHED',
        timestamp: now(),
        runId: `state-${payload.threadId}`,
        threadId: payload.threadId,
      },
    ];
  }

  function splitArgs(json) {
    const pivot = Math.ceil(json.length / 2);
    return [json.slice(0, pivot), json.slice(pivot)];
  }

  function resolveChatScenario(payload, requestPath) {
    const message = String(payload.messages?.[0]?.content ?? '');
    const normalized = message.toLowerCase();
    const region = normalized.includes('apj')
      ? 'APJ'
      : normalized.includes('amer')
        ? 'AMER'
        : 'EMEA';
    const chartType = normalized.includes('column')
      ? 'column'
      : normalized.includes('bar')
        ? 'bar'
        : 'line';
    const loopId = requestPath.includes('mock-cap-v2') ? 'v2' : 'v1';

    return {
      region,
      chartType,
      loopId,
      message: requestPath.includes('mock-cap-v2')
        ? 'Updating the widget after reconnect.'
        : 'Updating the widget.',
    };
  }

  function buildChatEvents(payload, requestPath) {
    const scenario = resolveChatScenario(payload, requestPath);
    const filterArgs = splitArgs(JSON.stringify({
      dimension: 'Region',
      value: scenario.region,
      filterType: 'SingleValue',
    }));
    const chartArgs = splitArgs(JSON.stringify({ chartType: scenario.chartType }));
    const filterToolCallId = `${scenario.loopId}-${scenario.region.toLowerCase()}-filter`;
    const chartToolCallId = `${scenario.loopId}-${scenario.chartType}-chart`;

    return [
      {
        type: 'RUN_STARTED',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
      },
      {
        type: 'TEXT_MESSAGE_CONTENT',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        messageId: 'assistant-1',
        delta: scenario.message,
      },
      {
        type: 'TOOL_CALL_START',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        toolCallId: filterToolCallId,
        toolName: 'set_datasource_filter',
      },
      {
        type: 'TOOL_CALL_ARGS',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        toolCallId: filterToolCallId,
        delta: filterArgs[0],
      },
      {
        type: 'TOOL_CALL_ARGS',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        toolCallId: filterToolCallId,
        delta: filterArgs[1],
      },
      {
        type: 'TOOL_CALL_END',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        toolCallId: filterToolCallId,
        toolName: 'set_datasource_filter',
      },
      {
        type: 'TOOL_CALL_START',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        toolCallId: chartToolCallId,
        toolName: 'set_chart_type',
      },
      {
        type: 'TOOL_CALL_ARGS',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        toolCallId: chartToolCallId,
        delta: chartArgs[0],
      },
      {
        type: 'TOOL_CALL_ARGS',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        toolCallId: chartToolCallId,
        delta: chartArgs[1],
      },
      {
        type: 'TOOL_CALL_END',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
        toolCallId: chartToolCallId,
        toolName: 'set_chart_type',
      },
      {
        type: 'RUN_FINISHED',
        timestamp: now(),
        runId: `chat-${scenario.loopId}-${payload.threadId}-${scenario.region.toLowerCase()}-${scenario.chartType}`,
        threadId: payload.threadId,
      },
    ];
  }

  const realFetch = global.fetch.bind(global);

  global.__widgetHarness = state;

  global.addEventListener('error', (event) => {
    recordError('error', event.error?.message ?? event.message ?? 'Unknown error');
  });

  global.addEventListener('unhandledrejection', (event) => {
    recordError('unhandledrejection', event.reason?.message ?? event.reason ?? 'Unhandled rejection');
  });

  global.fetch = async function mockedFetch(input, init) {
    const request = input instanceof Request ? input : new Request(input, init);
    const url = new URL(request.url, global.location.href);
    const bodyText = request.method === 'GET' || request.method === 'HEAD'
      ? ''
      : await request.clone().text();
    const authHeader = request.headers.get('authorization');

    if (/\/mock-cap(?:-v2)?\/ag-ui\/run$/.test(url.pathname)) {
      const payload = bodyText ? JSON.parse(bodyText) : {};
      state.runRequests.push({
        url: url.pathname,
        authHeader,
        payload,
      });

      const message = payload.messages?.[0]?.content;
      return buildSseResponse(
        message === '__state_sync__'
          ? buildStateSyncEvents(payload, url.pathname)
          : buildChatEvents(payload, url.pathname),
      );
    }

    if (/\/mock-cap(?:-v2)?\/ag-ui\/tool-result$/.test(url.pathname)) {
      state.toolResults.push({
        url: url.pathname,
        authHeader,
        payload: bodyText ? JSON.parse(bodyText) : {},
      });

      return new Response(null, { status: 204 });
    }

    if (/\/mock-sac(?:-v2)?\/api\/v1\/datasources\/.+\/data$/.test(url.pathname)) {
      const payload = bodyText ? JSON.parse(bodyText) : {};
      const modelId = decodeURIComponent(url.pathname.split('/').slice(-2, -1)[0] ?? '');
      state.dataRequests.push({
        url: url.pathname,
        authHeader,
        payload,
      });

      return buildJsonResponse(buildResultSet(modelId, payload.filters ?? {}));
    }

    return realFetch(request);
  };

  state.lifecycle.push({ step: 'ready', timestamp: now() });
})(globalThis);

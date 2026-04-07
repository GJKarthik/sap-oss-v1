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

      const shell = global.document.querySelector('.harness-shell');
      if (shell) shell.classList.add('harness-loading');

      const message = payload.messages?.[0]?.content;
      const response = buildSseResponse(
        message === '__state_sync__'
          ? buildStateSyncEvents(payload, url.pathname)
          : buildChatEvents(payload, url.pathname),
      );

      return response;
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

  // ---------------------------------------------------------------------------
  // Harness controls wiring
  // ---------------------------------------------------------------------------

  const statusDot = global.document.getElementById('connectionStatus');
  let activityTimer = null;

  function flashActivity() {
    if (statusDot) {
      statusDot.classList.add('active');
      statusDot.title = 'Mock API active';
      clearTimeout(activityTimer);
      activityTimer = setTimeout(() => {
        statusDot.classList.remove('active');
        statusDot.title = 'Mock API idle';
      }, 1500);
    }
  }

  // Patch state tracking to flash status on activity
  const origPush = state.runRequests.push.bind(state.runRequests);
  state.runRequests.push = function () {
    flashActivity();
    return origPush.apply(this, arguments);
  };

  // Debounce-remove loading when tool results arrive (signals stream completion)
  let toolResultTimer = null;
  const origToolResultPush = state.toolResults.push.bind(state.toolResults);
  state.toolResults.push = function () {
    const result = origToolResultPush.apply(this, arguments);
    clearTimeout(toolResultTimer);
    toolResultTimer = setTimeout(() => {
      const shell = global.document.querySelector('.harness-shell');
      if (shell) shell.classList.remove('harness-loading');
    }, 150);
    return result;
  };

  // Scenario selector
  const scenarioSelect = global.document.getElementById('scenarioSelect');
  if (scenarioSelect) {
    scenarioSelect.addEventListener('change', () => {
      const widget = global.document.getElementById('widget');
      const value = scenarioSelect.value;
      if (!widget || !value) return;

      const prompt = value === 'apj' ? 'Show APJ revenue'
        : value === 'amer' ? 'Show AMER revenue'
        : value === 'bar' ? 'Show revenue as bar chart'
        : value === 'column' ? 'Show revenue as column chart'
        : '';

      if (prompt && typeof widget.dispatchEvent === 'function') {
        widget.dispatchEvent(new CustomEvent('harness-prompt', { detail: { prompt } }));
      }
    });
  }

  // Reset button
  const resetBtn = global.document.getElementById('resetBtn');
  function resetHarness() {
    state.errors.length = 0;
    state.runRequests.length = 0;
    state.toolResults.length = 0;
    state.dataRequests.length = 0;
    if (scenarioSelect) scenarioSelect.value = '';
    const shell = global.document.querySelector('.harness-shell');
    if (shell) shell.classList.remove('harness-loading');
    clearTimeout(toolResultTimer);
    state.lifecycle.push({ step: 'reset', timestamp: now() });
  }

  if (resetBtn) {
    resetBtn.addEventListener('click', resetHarness);
  }

  // Keyboard shortcuts: 1-5 select scenarios, R resets
  const scenarioKeys = ['1', '2', '3', '4', '5'];
  global.document.addEventListener('keydown', (event) => {
    const tag = (event.target && event.target.tagName) || '';
    if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return;

    if (event.key.toLowerCase() === 'r' && !event.metaKey && !event.ctrlKey) {
      event.preventDefault();
      resetHarness();
      return;
    }

    const idx = scenarioKeys.indexOf(event.key);
    if (idx !== -1 && scenarioSelect) {
      const options = scenarioSelect.options;
      if (idx < options.length) {
        scenarioSelect.value = options[idx].value;
        scenarioSelect.dispatchEvent(new Event('change'));
      }
    }
  });
})(globalThis);

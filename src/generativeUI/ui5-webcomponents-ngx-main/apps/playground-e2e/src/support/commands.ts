// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

/**
 * Intercept AG-UI SSE stream and replay a scripted sequence of events.
 * This allows E2E tests to run without a live agent backend.
 *
 * Usage:
 *   cy.interceptAgUi('run_started,text_delta,run_finished')
 */
Cypress.Commands.add(
  'interceptAgUi',
  (scenario: 'text' | 'schema' | 'error' = 'text') => {
    const runId = 'e2e-run-1';
    let seq = 0;
    const evt = (type: string, extra: object = {}) => {
      seq++;
      return (
        'data: ' +
        JSON.stringify({
          type,
          id: `e2e-${seq}`,
          runId,
          timestamp: new Date().toISOString(),
          seq,
          ...extra,
        }) +
        '\n\n'
      );
    };

    const streams: Record<string, string> = {
      text: [
        evt('lifecycle.run_started', { threadId: 'e2e-thread' }),
        evt('text.message_start', { messageId: 'msg-1' }),
        evt('text.message_delta', { messageId: 'msg-1', delta: 'Hello from Joule!' }),
        evt('text.message_end', { messageId: 'msg-1' }),
        evt('lifecycle.run_finished'),
      ].join(''),

      schema: [
        evt('lifecycle.run_started', { threadId: 'e2e-thread' }),
        evt('custom', {
          name: 'ui_schema_snapshot',
          payload: {
            component: 'ui5-button',
            schemaVersion: '1',
            props: { text: 'Generated Button', design: 'Emphasized' },
          },
        }),
        evt('lifecycle.run_finished'),
      ].join(''),

      error: [
        evt('lifecycle.run_started', { threadId: 'e2e-thread' }),
        evt('lifecycle.run_error', { message: 'Agent backend unavailable' }),
      ].join(''),
    };

    cy.intercept('POST', '/ag-ui/run', {
      statusCode: 200,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Accel-Buffering': 'no',
      },
      body: streams[scenario],
    }).as('agUiRun');
  },
);

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Cypress {
    interface Chainable {
      interceptAgUi(scenario?: 'text' | 'schema' | 'error'): void;
    }
  }
}

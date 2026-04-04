// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { MCPServer } from './server';

describe('MCPServer CPN + mangle_query', () => {
  it('orchestration_run executes built-in odps_close_process and populates petri_stage facts', async () => {
    const server = new MCPServer();
    const res = await server.handleRequest({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'orchestration_run',
        arguments: {
          scenario: 'odps_close_process',
          input: JSON.stringify({ appId: 'compliance-demo-app' }),
        },
      },
    });
    expect(res.error).toBeUndefined();
    const text = (res.result as { content: Array<{ text: string }> }).content[0]!.text;
    const body = JSON.parse(text) as {
      status: string;
      engine: string;
      trace: unknown[];
    };
    expect(body.engine).toBe('cpn');
    expect(body.status).toBe('completed');
    expect(body.trace).toHaveLength(2);

    const mq = await server.handleRequest({
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: {
        name: 'mangle_query',
        arguments: {
          predicate: 'petri_stage',
          args: JSON.stringify(['compliance-demo-app', 'S02']),
        },
      },
    });
    const mqText = (mq.result as { content: Array<{ text: string }> }).content[0]!.text;
    const mqBody = JSON.parse(mqText) as { results: Array<{ app: string; stage: string }> };
    expect(mqBody.results).toHaveLength(1);
    expect(mqBody.results[0]).toEqual({ app: 'compliance-demo-app', stage: 'S02' });
  });

  it('mangle_query petri_stage without args returns all rows', async () => {
    const server = new MCPServer();
    await server.handleRequest({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'cpn_reset',
        arguments: { scenario: 'odps_close_process', appId: 'x1' },
      },
    });
    await server.handleRequest({
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: { name: 'cpn_step', arguments: {} },
    });
    const mq = await server.handleRequest({
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/call',
      params: {
        name: 'mangle_query',
        arguments: { predicate: 'petri_stage', args: '[]' },
      },
    });
    const mqText = (mq.result as { content: Array<{ text: string }> }).content[0]!.text;
    const mqBody = JSON.parse(mqText) as { results: Array<{ app: string; stage: string }> };
    expect(mqBody.results.some((r) => r.app === 'x1' && r.stage === 'S01')).toBe(true);
    expect(mqBody.results.some((r) => r.app === 'x1' && r.stage === 'S02')).toBe(true);
  });
});

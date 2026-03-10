// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { AgUiToolRegistry, FrontendTool } from './tool-registry.service';
import { AgUiClient } from './ag-ui-client.service';
import { Subject } from 'rxjs';

// ---------------------------------------------------------------------------
// Stub AgUiClient — only the parts ToolRegistry subscribes to
// ---------------------------------------------------------------------------

function makeClient(): AgUiClient {
  return {
    tool$: new Subject(),
    events$: new Subject(),
  } as unknown as AgUiClient;
}

function makeTool(name = 'test-tool'): FrontendTool {
  return {
    name,
    description: 'A test tool',
    parameters: { type: 'object', properties: {}, required: [] },
    handler: jest.fn().mockResolvedValue({ ok: true }),
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('AgUiToolRegistry', () => {
  let client: AgUiClient;
  let registry: AgUiToolRegistry;

  beforeEach(() => {
    client = makeClient();
    registry = new AgUiToolRegistry(client);
  });

  afterEach(() => {
    registry.ngOnDestroy();
  });

  it('registers a tool and retrieves it by name', () => {
    const tool = makeTool('my-tool');
    registry.register(tool);

    expect(registry.has('my-tool')).toBe(true);
    expect(registry.get('my-tool')).toBe(tool);
  });

  it('getAll() returns all registered tools', () => {
    registry.register(makeTool('tool-a'));
    registry.register(makeTool('tool-b'));

    const names = registry.getAll().map(t => t.name);
    expect(names).toContain('tool-a');
    expect(names).toContain('tool-b');
  });

  it('unregister() removes the tool', () => {
    registry.register(makeTool('remove-me'));
    expect(registry.has('remove-me')).toBe(true);

    const removed = registry.unregister('remove-me');

    expect(removed).toBe(true);
    expect(registry.has('remove-me')).toBe(false);
  });

  it('getToolDefinitions() returns name, description, parameters for each tool', () => {
    registry.register(makeTool('def-tool'));

    const defs = registry.getToolDefinitions();

    expect(defs).toHaveLength(1);
    expect(defs[0].name).toBe('def-tool');
    expect(defs[0].description).toBe('A test tool');
    expect(defs[0].parameters).toBeDefined();
  });
});

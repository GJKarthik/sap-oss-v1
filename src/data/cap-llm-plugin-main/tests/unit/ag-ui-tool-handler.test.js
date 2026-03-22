// SPDX-License-Identifier: Apache-2.0
"use strict";

const {
  ToolRegistry,
  ToolCallTracker,
  ToolHandler,
  BUILTIN_TOOLS,
  NAVIGATE_TOOL,
  CONFIRM_ACTION_TOOL,
  FETCH_DATA_TOOL,
  createToolHandler,
} = require("../../srv/ag-ui/tool-handler");

// =============================================================================
// ToolRegistry
// =============================================================================

describe("ToolRegistry", () => {
  it("loads builtin tools by default", () => {
    const registry = new ToolRegistry();
    expect(registry.has("navigate")).toBe(true);
    expect(registry.has("confirm_action")).toBe(true);
    expect(registry.has("fetch_data")).toBe(true);
    expect(registry.has("execute_action")).toBe(true);
    expect(registry.has("show_notification")).toBe(true);
    expect(registry.has("open_dialog")).toBe(true);
  });

  it("can skip builtins", () => {
    const registry = new ToolRegistry(false);
    expect(registry.getAll()).toHaveLength(0);
  });

  it("registers and retrieves a custom tool", () => {
    const registry = new ToolRegistry(false);
    registry.register({ name: "my_tool", description: "test", parameters: { type: "object", properties: {} } });
    expect(registry.has("my_tool")).toBe(true);
    expect(registry.get("my_tool").name).toBe("my_tool");
  });

  it("unregisters a tool", () => {
    const registry = new ToolRegistry();
    registry.unregister("navigate");
    expect(registry.has("navigate")).toBe(false);
  });

  it("getAll returns all registered tools", () => {
    const registry = new ToolRegistry();
    expect(registry.getAll().length).toBe(BUILTIN_TOOLS.length);
  });

  it("getAsOpenAIFunctions returns name/description/parameters only", () => {
    const registry = new ToolRegistry();
    const fns = registry.getAsOpenAIFunctions();
    for (const fn of fns) {
      expect(fn).toHaveProperty("name");
      expect(fn).toHaveProperty("description");
      expect(fn).toHaveProperty("parameters");
      expect(fn).not.toHaveProperty("handler");
      expect(fn).not.toHaveProperty("frontendOnly");
    }
  });

  it("getFrontendTools returns only frontend-only tools", () => {
    const registry = new ToolRegistry();
    const frontendTools = registry.getFrontendTools();
    for (const t of frontendTools) {
      expect(t.frontendOnly).toBe(true);
    }
  });

  it("getServerTools returns tools without frontendOnly", () => {
    const registry = new ToolRegistry();
    const serverTools = registry.getServerTools();
    for (const t of serverTools) {
      expect(t.frontendOnly).toBeFalsy();
    }
  });
});

// =============================================================================
// ToolCallTracker
// =============================================================================

describe("ToolCallTracker", () => {
  it("creates and retrieves a pending tool call", () => {
    const tracker = new ToolCallTracker();
    const call = tracker.create("tc-1", "navigate", { route: "/home" });

    expect(call.toolCallId).toBe("tc-1");
    expect(call.status).toBe("pending");
    expect(tracker.get("tc-1")).toBe(call);
  });

  it("marks a call as executing", () => {
    const tracker = new ToolCallTracker();
    tracker.create("tc-1", "navigate", {});
    tracker.markExecuting("tc-1");
    expect(tracker.get("tc-1").status).toBe("executing");
  });

  it("completes a tool call with success", () => {
    const tracker = new ToolCallTracker();
    tracker.create("tc-1", "navigate", {});
    tracker.complete("tc-1", { success: true, data: "ok" });
    const call = tracker.get("tc-1");
    expect(call.status).toBe("completed");
    expect(call.result.success).toBe(true);
    expect(call.completedAt).toBeDefined();
  });

  it("marks failed tool call", () => {
    const tracker = new ToolCallTracker();
    tracker.create("tc-1", "navigate", {});
    tracker.complete("tc-1", { success: false, error: "fail" });
    expect(tracker.get("tc-1").status).toBe("failed");
  });

  it("getPending returns only pending calls", () => {
    const tracker = new ToolCallTracker();
    tracker.create("tc-1", "a", {});
    tracker.create("tc-2", "b", {});
    tracker.markExecuting("tc-2");
    expect(tracker.getPending()).toHaveLength(1);
    expect(tracker.getPending()[0].toolCallId).toBe("tc-1");
  });

  it("cleanup removes expired calls", async () => {
    const tracker = new ToolCallTracker(1); // 1ms timeout
    tracker.create("tc-1", "a", {});
    await new Promise((r) => setTimeout(r, 5)); // wait for expiry
    tracker.cleanup();
    expect(tracker.get("tc-1")).toBeUndefined();
  });

  it("clear removes all calls", () => {
    const tracker = new ToolCallTracker();
    tracker.create("tc-1", "a", {});
    tracker.create("tc-2", "b", {});
    tracker.clear();
    expect(tracker.get("tc-1")).toBeUndefined();
    expect(tracker.get("tc-2")).toBeUndefined();
  });
});

// =============================================================================
// ToolHandler
// =============================================================================

describe("ToolHandler", () => {
  it("createToolHandler returns a handler with builtins", () => {
    const handler = createToolHandler();
    expect(handler.getRegistry().has("navigate")).toBe(true);
  });

  it("startToolCall creates a pending entry in the tracker", () => {
    const handler = new ToolHandler();
    const call = handler.startToolCall("tc-1", "navigate", { route: "/" });
    expect(call.status).toBe("pending");
    expect(handler.getTracker().get("tc-1")).toBeDefined();
  });

  it("processToolResult parses JSON result", async () => {
    const handler = new ToolHandler();
    handler.startToolCall("tc-1", "navigate", {});
    const result = await handler.processToolResult({
      toolCallId: "tc-1",
      result: JSON.stringify({ success: true, data: { ok: true } }),
      threadId: "t1",
      runId: "r1",
    });
    expect(result.success).toBe(true);
    expect(result.data.ok).toBe(true);
  });

  it("processToolResult treats non-JSON as raw data", async () => {
    const handler = new ToolHandler();
    handler.startToolCall("tc-1", "navigate", {});
    const result = await handler.processToolResult({
      toolCallId: "tc-1",
      result: "raw text result",
      threadId: "t1",
      runId: "r1",
    });
    expect(result.success).toBe(true);
    expect(result.data).toBe("raw text result");
  });

  it("processToolResult returns error for unknown tool call", async () => {
    const handler = new ToolHandler();
    const result = await handler.processToolResult({
      toolCallId: "unknown-tc",
      result: "{}",
      threadId: "t1",
      runId: "r1",
    });
    expect(result.success).toBe(false);
    expect(result.error).toMatch(/not found/);
  });

  it("isFrontendTool correctly identifies frontend tools", () => {
    const handler = new ToolHandler();
    expect(handler.isFrontendTool("navigate")).toBe(true);
    expect(handler.isFrontendTool("fetch_data")).toBe(false);
  });

  it("requiresConfirmation checks tool flag", () => {
    const handler = new ToolHandler();
    expect(handler.requiresConfirmation("confirm_action")).toBe(true);
    expect(handler.requiresConfirmation("navigate")).toBe(false);
  });

  it("executeServerTool returns error for unknown tool", async () => {
    const handler = new ToolHandler();
    const result = await handler.executeServerTool("nonexistent", {}, { runId: "r", threadId: "t" });
    expect(result.success).toBe(false);
    expect(result.error).toMatch(/Unknown tool/);
  });

  it("executeServerTool returns error for frontend-only tool", async () => {
    const handler = new ToolHandler();
    const result = await handler.executeServerTool("navigate", {}, { runId: "r", threadId: "t" });
    expect(result.success).toBe(false);
    expect(result.error).toMatch(/frontend-only/);
  });

  it("executeServerTool returns error for tool with no handler", async () => {
    const handler = new ToolHandler();
    const result = await handler.executeServerTool("fetch_data", {}, { runId: "r", threadId: "t" });
    expect(result.success).toBe(false);
    expect(result.error).toMatch(/no handler/);
  });

  it("executeServerTool invokes handler and returns result", async () => {
    const registry = new ToolRegistry(false);
    registry.register({
      name: "greet",
      description: "say hi",
      parameters: { type: "object", properties: {} },
      handler: async (args) => ({ success: true, data: `hi ${args.name}` }),
    });
    const handler = new ToolHandler(registry);
    const result = await handler.executeServerTool("greet", { name: "SAP" }, { runId: "r", threadId: "t" });
    expect(result.success).toBe(true);
    expect(result.data).toBe("hi SAP");
  });
});

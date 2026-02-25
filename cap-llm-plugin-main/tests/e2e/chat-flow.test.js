/**
 * E2E Test — Chat Completion Flow
 *
 * Tests the full chat completion pipeline through real HTTP:
 *   Client POST → Express → Plugin.getChatCompletionWithConfig → Mocked SDK → HTTP response
 *
 * Validates request handling, response structure, multi-turn conversations,
 * and different chat configurations.
 */

const { setupPlugin } = require("./helpers/setup-plugin");
const { createApp, startServer } = require("./server");

let BASE;

describe("E2E Chat Completion Flow", () => {
  let server;

  beforeAll(async () => {
    const { plugin } = setupPlugin();
    const app = createApp(plugin);
    server = await startServer(app, 0);
    BASE = "http://localhost:" + server.address().port;
  });

  afterAll((done) => {
    server.close(done);
  });

  async function post(path, body) {
    const res = await fetch(BASE + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    return { status: res.status, data };
  }

  const chatConfig = { modelName: "gpt-4o", resourceGroup: "default" };

  // ── Single-turn chat ────────────────────────────────────────────────

  test("single user message returns assistant response", async () => {
    const { status, data } = await post("/api/chat", {
      config: chatConfig,
      payload: { messages: [{ role: "user", content: "What is SAP CAP?" }] },
    });

    expect(status).toBe(200);
    const choice = data.result.orchestration_result.choices[0];
    expect(choice.message.role).toBe("assistant");
    expect(choice.message.content).toBe("This is a mock AI response.");
    expect(choice.finish_reason).toBe("stop");
  });

  test("response includes token usage metadata", async () => {
    const { status, data } = await post("/api/chat", {
      config: chatConfig,
      payload: { messages: [{ role: "user", content: "Hello" }] },
    });

    expect(status).toBe(200);
    const usage = data.result.orchestration_result.usage;
    expect(usage).toBeDefined();
    expect(usage.completion_tokens).toBe(42);
    expect(usage.prompt_tokens).toBe(100);
    expect(usage.total_tokens).toBe(142);
  });

  // ── Multi-turn chat ─────────────────────────────────────────────────

  test("multi-turn conversation with system + user + assistant history", async () => {
    const messages = [
      { role: "system", content: "You are a helpful assistant." },
      { role: "user", content: "What is CDS?" },
      { role: "assistant", content: "CDS stands for Core Data Services." },
      { role: "user", content: "Can you explain more?" },
    ];

    const { status, data } = await post("/api/chat", {
      config: chatConfig,
      payload: { messages },
    });

    expect(status).toBe(200);
    expect(data.result.orchestration_result.choices).toHaveLength(1);
    expect(data.result.orchestration_result.choices[0].message.role).toBe("assistant");
  });

  // ── Config variations ───────────────────────────────────────────────

  test("accepts optional destinationName and deploymentUrl", async () => {
    const { status } = await post("/api/chat", {
      config: {
        modelName: "gpt-4o",
        resourceGroup: "default",
        destinationName: "my-aicore-dest",
        deploymentUrl: "/v2/inference/deployments/abc123",
      },
      payload: { messages: [{ role: "user", content: "test" }] },
    });

    expect(status).toBe(200);
  });

  // ── Error scenarios ─────────────────────────────────────────────────

  test("missing config returns 400 with LLMErrorResponse", async () => {
    const { status, data } = await post("/api/chat", {
      payload: { messages: [{ role: "user", content: "Hello" }] },
    });

    expect(status).toBe(400);
    expect(data.error).toBeDefined();
    expect(data.error.code).toBe("CHAT_CONFIG_INVALID");
    expect(data.error.message).toBeDefined();
    expect(data.error.details).toBeDefined();
  });

  test("missing messages still reaches SDK (plugin does not validate)", async () => {
    const { status } = await post("/api/chat", {
      config: chatConfig,
      payload: {},
    });

    // Plugin passes through to SDK which handles validation
    expect([200, 500]).toContain(status);
  });

  test("empty messages array still reaches SDK (plugin does not validate)", async () => {
    const { status } = await post("/api/chat", {
      config: chatConfig,
      payload: { messages: [] },
    });

    // Plugin passes through to SDK which handles validation
    expect([200, 500]).toContain(status);
  });
});

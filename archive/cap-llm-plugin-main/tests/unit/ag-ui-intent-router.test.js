// SPDX-License-Identifier: Apache-2.0
"use strict";

const { IntentRouter } = require("../../srv/ag-ui/intent-router");

describe("IntentRouter", () => {
  let router;

  beforeEach(() => {
    router = new IntentRouter({
      vllmEndpoint: "http://vllm:9180",
      palEndpoint: "http://pal:9170",
      mcpEndpoint: "http://mcp:9190",
    });
  });

  // ---------------------------------------------------------------------------
  // 1. Forced backend
  // ---------------------------------------------------------------------------

  it("respects forceBackend override", () => {
    const result = router.classify("hello", { forceBackend: "vllm" });
    expect(result.backend).toBe("vllm");
    expect(result.reason).toMatch(/Forced routing/);
    expect(result.endpoint).toBe("http://vllm:9180");
  });

  it("returns blocked when forceBackend is 'blocked'", () => {
    const result = router.classify("hello", { forceBackend: "blocked" });
    expect(result.backend).toBe("blocked");
  });

  // ---------------------------------------------------------------------------
  // 2. Service-ID policy
  // ---------------------------------------------------------------------------

  it("routes data-cleaning-copilot to vllm", () => {
    const result = router.classify("clean data", { serviceId: "data-cleaning-copilot" });
    expect(result.backend).toBe("vllm");
    expect(result.reason).toMatch(/Service policy/);
  });

  it("routes sac-ai-widget to aicore-streaming", () => {
    const result = router.classify("show chart", { serviceId: "sac-ai-widget" });
    expect(result.backend).toBe("aicore-streaming");
  });

  it("routes ai-core-pal to pal", () => {
    const result = router.classify("run analysis", { serviceId: "ai-core-pal" });
    expect(result.backend).toBe("pal");
  });

  // ---------------------------------------------------------------------------
  // 3. Security class
  // ---------------------------------------------------------------------------

  it("routes confidential to vllm", () => {
    const result = router.classify("hello", { securityClass: "confidential" });
    expect(result.backend).toBe("vllm");
  });

  it("routes public to aicore-streaming", () => {
    const result = router.classify("hello", { securityClass: "public" });
    expect(result.backend).toBe("aicore-streaming");
  });

  it("blocks restricted security class", () => {
    const result = router.classify("hello", { securityClass: "restricted" });
    expect(result.backend).toBe("blocked");
  });

  // ---------------------------------------------------------------------------
  // 4. Model alias
  // ---------------------------------------------------------------------------

  it("routes confidential model alias to vllm", () => {
    const result = router.classify("hello", { model: "qwen3.5-confidential" });
    expect(result.backend).toBe("vllm");
    expect(result.reason).toMatch(/Model alias/);
  });

  // ---------------------------------------------------------------------------
  // 5. Model name → backend
  // ---------------------------------------------------------------------------

  it("routes Qwen3.5 models to vllm", () => {
    const result = router.classify("hello", { model: "Qwen/Qwen3.5-0.8B" });
    expect(result.backend).toBe("vllm");
  });

  // ---------------------------------------------------------------------------
  // 6. Content keyword analysis
  // ---------------------------------------------------------------------------

  it("detects restricted keywords and blocks", () => {
    const result = router.classify("this is classified information");
    expect(result.backend).toBe("blocked");
    expect(result.reason).toMatch(/Restricted keywords/);
  });

  it("detects confidential keywords and routes to vllm", () => {
    const result = router.classify("analyze customer payment data");
    expect(result.backend).toBe("vllm");
    expect(result.reason).toMatch(/Confidential keywords/);
  });

  it("detects PAL analytics keywords and routes to pal", () => {
    const result = router.classify("run a time series forecast");
    expect(result.backend).toBe("pal");
    expect(result.reason).toMatch(/PAL keywords/);
  });

  // ---------------------------------------------------------------------------
  // 6d. RAG
  // ---------------------------------------------------------------------------

  it("routes to rag when enableRag is true and no other match", () => {
    const result = router.classify("what is the meaning of life", { enableRag: true });
    expect(result.backend).toBe("rag");
  });

  // ---------------------------------------------------------------------------
  // 7. Default
  // ---------------------------------------------------------------------------

  it("defaults to aicore-streaming for generic messages", () => {
    const result = router.classify("hello world");
    expect(result.backend).toBe("aicore-streaming");
    expect(result.endpoint).toBe("http://mcp:9190");
  });

  // ---------------------------------------------------------------------------
  // Priority order
  // ---------------------------------------------------------------------------

  it("forceBackend takes precedence over serviceId", () => {
    const result = router.classify("hello", {
      forceBackend: "pal",
      serviceId: "data-cleaning-copilot",
    });
    expect(result.backend).toBe("pal");
  });

  it("securityClass overrides serviceId when both provided", () => {
    const result = router.classify("hello", {
      serviceId: "sac-ai-widget",
      securityClass: "confidential",
    });
    // Security class takes higher priority than service policy
    expect(result.backend).toBe("vllm");
    expect(result.reason).toMatch(/Security class/);
  });
});

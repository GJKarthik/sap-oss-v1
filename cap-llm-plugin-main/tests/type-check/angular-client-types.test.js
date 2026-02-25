/**
 * Type-safety verification: Angular client models ↔ Backend types.
 *
 * This test ensures that the Angular client interface shapes match
 * the backend TypeScript interfaces. It validates structural alignment
 * without requiring Angular dependencies.
 */

const fs = require("fs");
const path = require("path");

describe("Angular Client Type Alignment", () => {
  const modelsPath = path.join(
    __dirname,
    "../../generated/angular-client/models.ts",
  );
  const servicePath = path.join(
    __dirname,
    "../../generated/angular-client/cap-llm-plugin.service.ts",
  );
  const indexPath = path.join(
    __dirname,
    "../../generated/angular-client/index.ts",
  );
  const backendPath = path.join(__dirname, "../../srv/cap-llm-plugin.ts");
  const openapiPath = path.join(__dirname, "../../docs/api/openapi.yaml");

  let modelsContent;
  let serviceContent;
  let indexContent;
  let backendContent;
  let openapiContent;

  beforeAll(() => {
    modelsContent = fs.readFileSync(modelsPath, "utf-8");
    serviceContent = fs.readFileSync(servicePath, "utf-8");
    indexContent = fs.readFileSync(indexPath, "utf-8");
    backendContent = fs.readFileSync(backendPath, "utf-8");
    openapiContent = fs.readFileSync(openapiPath, "utf-8");
  });

  // ── Model interfaces exist ──────────────────────────────────────────

  const requiredSchemas = [
    "EmbeddingConfig",
    "ChatConfig",
    "ChatMessage",
    "SimilaritySearchResult",
    "RagResponse",
    "ErrorDetail",
    "ErrorResponse",
  ];

  test.each(requiredSchemas)(
    "Angular models exports interface: %s",
    (name) => {
      expect(modelsContent).toContain(`export interface ${name}`);
    },
  );

  // ── Request body interfaces exist ───────────────────────────────────

  const requiredRequestBodies = [
    "GetEmbeddingRequest",
    "GetChatCompletionRequest",
    "GetRagResponseRequest",
    "SimilaritySearchRequest",
    "GetAnonymizedDataRequest",
    "GetHarmonizedChatCompletionRequest",
    "GetContentFiltersRequest",
  ];

  test.each(requiredRequestBodies)(
    "Angular models exports request body: %s",
    (name) => {
      expect(modelsContent).toContain(`export interface ${name}`);
    },
  );

  // ── Service methods exist ───────────────────────────────────────────

  const requiredMethods = [
    "getEmbeddingWithConfig",
    "getChatCompletionWithConfig",
    "getRagResponse",
    "similaritySearch",
    "getAnonymizedData",
    "getHarmonizedChatCompletion",
    "getContentFilters",
  ];

  test.each(requiredMethods)(
    "Angular service has method: %s",
    (method) => {
      expect(serviceContent).toContain(`${method}(`);
    },
  );

  // ── Backend has matching methods ────────────────────────────────────

  test.each(requiredMethods)(
    "Backend has matching method: %s",
    (method) => {
      expect(backendContent).toContain(`async ${method}(`);
    },
  );

  // ── OpenAPI has matching paths ──────────────────────────────────────

  test.each(requiredMethods)(
    "OpenAPI spec has path for: %s",
    (method) => {
      expect(openapiContent).toContain(`/${method}:`);
    },
  );

  // ── Barrel export completeness ──────────────────────────────────────

  test("index.ts exports CAPLLMPluginService", () => {
    expect(indexContent).toContain("CAPLLMPluginService");
  });

  test.each([...requiredSchemas, ...requiredRequestBodies])(
    "index.ts exports type: %s",
    (name) => {
      expect(indexContent).toContain(name);
    },
  );

  // ── Structural field alignment ──────────────────────────────────────

  test("EmbeddingConfig has required fields: modelName, resourceGroup", () => {
    // Angular client
    expect(modelsContent).toMatch(/interface EmbeddingConfig[\s\S]*?modelName:\s*string/);
    expect(modelsContent).toMatch(/interface EmbeddingConfig[\s\S]*?resourceGroup:\s*string/);
    // Backend
    expect(backendContent).toMatch(/interface EmbeddingConfig[\s\S]*?modelName:\s*string/);
    expect(backendContent).toMatch(/interface EmbeddingConfig[\s\S]*?resourceGroup:\s*string/);
  });

  test("ChatConfig has required fields: modelName, resourceGroup", () => {
    expect(modelsContent).toMatch(/interface ChatConfig[\s\S]*?modelName:\s*string/);
    expect(modelsContent).toMatch(/interface ChatConfig[\s\S]*?resourceGroup:\s*string/);
    expect(backendContent).toMatch(/interface ChatConfig[\s\S]*?modelName:\s*string/);
    expect(backendContent).toMatch(/interface ChatConfig[\s\S]*?resourceGroup:\s*string/);
  });

  test("ChatMessage has required fields: role, content", () => {
    expect(modelsContent).toMatch(/interface ChatMessage[\s\S]*?role:\s*string/);
    expect(modelsContent).toMatch(/interface ChatMessage[\s\S]*?content:\s*string/);
    expect(backendContent).toMatch(/interface ChatMessage[\s\S]*?role:\s*string/);
    expect(backendContent).toMatch(/interface ChatMessage[\s\S]*?content:\s*string/);
  });

  test("SimilaritySearchResult has fields: PAGE_CONTENT, SCORE", () => {
    expect(modelsContent).toMatch(/interface SimilaritySearchResult[\s\S]*?PAGE_CONTENT/);
    expect(modelsContent).toMatch(/interface SimilaritySearchResult[\s\S]*?SCORE/);
    expect(backendContent).toMatch(/interface SimilaritySearchResult[\s\S]*?PAGE_CONTENT/);
    expect(backendContent).toMatch(/interface SimilaritySearchResult[\s\S]*?SCORE/);
  });

  test("RagResponse has fields: completion, additionalContents", () => {
    expect(modelsContent).toMatch(/interface RagResponse[\s\S]*?completion/);
    expect(modelsContent).toMatch(/interface RagResponse[\s\S]*?additionalContents/);
    expect(backendContent).toMatch(/interface RagResponse[\s\S]*?completion/);
    expect(backendContent).toMatch(/interface RagResponse[\s\S]*?additionalContents/);
  });

  // ── Service uses correct HTTP method and base path ──────────────────

  test("Service uses POST for all actions", () => {
    const postCalls = (serviceContent.match(/this\.http\.post/g) || []).length;
    expect(postCalls).toBe(7);
  });

  test("Service uses correct OData base path", () => {
    expect(serviceContent).toContain("/odata/v4/cap-llm-plugin");
  });
});

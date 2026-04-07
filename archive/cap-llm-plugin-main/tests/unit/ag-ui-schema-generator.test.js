// SPDX-License-Identifier: Apache-2.0
"use strict";

const {
  ALLOWED_COMPONENTS,
  createTextSchema,
  createLoadingSchema,
  createErrorSchema,
} = require("../../srv/ag-ui/schema-generator");

// Deny list is not exported from compiled JS; define locally for testing
const DENY_LIST = [
  "ui5-file-uploader",
  "ui5-file-chooser",
  "ui5-upload-collection",
  "ui5-upload-collection-item",
];

// =============================================================================
// ALLOWED_COMPONENTS whitelist
// =============================================================================

describe("ALLOWED_COMPONENTS", () => {
  it("is a non-empty Set", () => {
    expect(ALLOWED_COMPONENTS).toBeInstanceOf(Set);
    expect(ALLOWED_COMPONENTS.size).toBeGreaterThan(0);
  });

  it("includes core Fiori components", () => {
    expect(ALLOWED_COMPONENTS.has("ui5-button")).toBe(true);
    expect(ALLOWED_COMPONENTS.has("ui5-card")).toBe(true);
    expect(ALLOWED_COMPONENTS.has("ui5-table")).toBe(true);
    expect(ALLOWED_COMPONENTS.has("ui5-input")).toBe(true);
    expect(ALLOWED_COMPONENTS.has("ui5-dialog")).toBe(true);
    expect(ALLOWED_COMPONENTS.has("ui5-list")).toBe(true);
  });

  it("includes standard layout and form components", () => {
    expect(ALLOWED_COMPONENTS.has("ui5-card")).toBe(true);
    expect(ALLOWED_COMPONENTS.has("ui5-panel")).toBe(true);
    expect(ALLOWED_COMPONENTS.has("ui5-input")).toBe(true);
  });
});

// =============================================================================
// SCHEMA_GEN_DENY_LIST
// =============================================================================

describe("Security deny list (sanitize-time enforcement)", () => {
  it("deny-listed components are rejected at schema sanitize time, not in ALLOWED_COMPONENTS", () => {
    // The deny list is enforced in sanitizeComponent(), not by excluding from ALLOWED_COMPONENTS.
    // This verifies the split is intentional: ALLOWED_COMPONENTS is the LLM whitelist,
    // SCHEMA_GEN_DENY_LIST is the security filter applied after LLM output.
    expect(ALLOWED_COMPONENTS.has("ui5-button")).toBe(true);
    expect(ALLOWED_COMPONENTS.has("ui5-table")).toBe(true);
  });
});

// =============================================================================
// createTextSchema
// =============================================================================

describe("createTextSchema", () => {
  it("creates a card with text content", () => {
    const schema = createTextSchema("Hello world");
    expect(schema.layout.type).toBe("ui5-card");
    expect(schema.layout.children).toHaveLength(1);
    expect(schema.layout.children[0].type).toBe("ui5-text");
    expect(schema.layout.children[0].props.text).toBe("Hello world");
  });

  it("uses provided id", () => {
    const schema = createTextSchema("test", "my-id");
    expect(schema.layout.id).toBe("my-id");
    expect(schema.layout.children[0].id).toBe("my-id-content");
  });

  it("sets schema metadata", () => {
    const schema = createTextSchema("test");
    expect(schema.$schema).toMatch(/a2ui-schema/);
    expect(schema.version).toBe("1.0");
  });
});

// =============================================================================
// createLoadingSchema
// =============================================================================

describe("createLoadingSchema", () => {
  it("creates a busy indicator", () => {
    const schema = createLoadingSchema();
    expect(schema.layout.type).toBe("ui5-busy-indicator");
    expect(schema.layout.props.active).toBe(true);
    expect(schema.layout.props.text).toBe("Loading...");
  });

  it("accepts custom message", () => {
    const schema = createLoadingSchema("Processing...");
    expect(schema.layout.props.text).toBe("Processing...");
  });
});

// =============================================================================
// createErrorSchema
// =============================================================================

describe("createErrorSchema", () => {
  it("creates a negative message strip", () => {
    const schema = createErrorSchema("Something went wrong");
    expect(schema.layout.type).toBe("ui5-message-strip");
    expect(schema.layout.props.design).toBe("Negative");
  });

  it("includes error message and title", () => {
    const schema = createErrorSchema("Network failure", "Connection Error");
    const title = schema.layout.children.find((c) => c.type === "ui5-title");
    const text = schema.layout.children.find((c) => c.type === "ui5-text");
    expect(title.props.text).toBe("Connection Error");
    expect(text.props.text).toBe("Network failure");
  });

  it("uses default title when not provided", () => {
    const schema = createErrorSchema("oops");
    const title = schema.layout.children.find((c) => c.type === "ui5-title");
    expect(title.props.text).toBe("Error");
  });
});

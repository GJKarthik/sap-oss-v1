// SPDX-License-Identifier: Apache-2.0
"use strict";

const {
  AgUiEventType,
  createEvent,
  serializeEvent,
  createErrorFrame,
  createDoneSentinel,
  GenUiEventNames,
} = require("../../srv/ag-ui/event-types");

describe("AG-UI event-types", () => {
  // ---------------------------------------------------------------------------
  // AgUiEventType enum
  // ---------------------------------------------------------------------------

  it("defines all expected lifecycle event types", () => {
    expect(AgUiEventType.RUN_STARTED).toBe("RUN_STARTED");
    expect(AgUiEventType.RUN_FINISHED).toBe("RUN_FINISHED");
    expect(AgUiEventType.RUN_ERROR).toBe("RUN_ERROR");
    expect(AgUiEventType.STEP_STARTED).toBe("STEP_STARTED");
    expect(AgUiEventType.STEP_FINISHED).toBe("STEP_FINISHED");
  });

  it("defines text message event types", () => {
    expect(AgUiEventType.TEXT_MESSAGE_START).toBe("TEXT_MESSAGE_START");
    expect(AgUiEventType.TEXT_MESSAGE_CONTENT).toBe("TEXT_MESSAGE_CONTENT");
    expect(AgUiEventType.TEXT_MESSAGE_END).toBe("TEXT_MESSAGE_END");
  });

  it("defines tool call event types", () => {
    expect(AgUiEventType.TOOL_CALL_START).toBe("TOOL_CALL_START");
    expect(AgUiEventType.TOOL_CALL_ARGS).toBe("TOOL_CALL_ARGS");
    expect(AgUiEventType.TOOL_CALL_END).toBe("TOOL_CALL_END");
    expect(AgUiEventType.TOOL_CALL_RESULT).toBe("TOOL_CALL_RESULT");
  });

  it("defines CUSTOM and RAW event types", () => {
    expect(AgUiEventType.CUSTOM).toBe("CUSTOM");
    expect(AgUiEventType.RAW).toBe("RAW");
  });

  // ---------------------------------------------------------------------------
  // AgUiEventType enum completeness
  // ---------------------------------------------------------------------------

  it("has at least 16 event types", () => {
    const values = Object.values(AgUiEventType);
    expect(values.length).toBeGreaterThanOrEqual(16);
  });

  // ---------------------------------------------------------------------------
  // createEvent()
  // ---------------------------------------------------------------------------

  it("adds a numeric timestamp to the event", () => {
    const event = createEvent({ type: AgUiEventType.RUN_STARTED, runId: "r1", threadId: "t1" });
    expect(typeof event.timestamp).toBe("number");
    expect(event.type).toBe("RUN_STARTED");
    expect(event.runId).toBe("r1");
  });

  // ---------------------------------------------------------------------------
  // serializeEvent()
  // ---------------------------------------------------------------------------

  it("serializes to SSE data frame", () => {
    const event = createEvent({ type: AgUiEventType.RUN_FINISHED, runId: "r1", threadId: "t1" });
    const sse = serializeEvent(event);

    expect(sse).toMatch(/^data: /);
    expect(sse).toMatch(/\n\n$/);

    const payload = JSON.parse(sse.replace("data: ", "").trim());
    expect(payload.runId).toBe("r1");
    expect(payload.threadId).toBe("t1");
    expect(typeof payload.timestamp).toBe("number");
  });

  // ---------------------------------------------------------------------------
  // createErrorFrame()
  // ---------------------------------------------------------------------------

  it("creates an SSE error event frame", () => {
    const frame = createErrorFrame("AUTH_ERROR", "Token expired");
    expect(frame).toMatch(/^event: error\n/);
    expect(frame).toMatch(/\n\n$/);

    const dataLine = frame.split("\n").find((l) => l.startsWith("data: "));
    const payload = JSON.parse(dataLine.replace("data: ", ""));
    expect(payload.code).toBe("AUTH_ERROR");
    expect(payload.message).toBe("Token expired");
  });

  // ---------------------------------------------------------------------------
  // createDoneSentinel()
  // ---------------------------------------------------------------------------

  it("returns the [DONE] sentinel", () => {
    expect(createDoneSentinel()).toBe("data: [DONE]\n\n");
  });

  // ---------------------------------------------------------------------------
  // GenUiEventNames
  // ---------------------------------------------------------------------------

  it("exposes expected custom event names", () => {
    expect(GenUiEventNames.UI_SCHEMA_SNAPSHOT).toBe("ui_schema_snapshot");
    expect(GenUiEventNames.UI_SCHEMA_DELTA).toBe("ui_schema_delta");
    expect(GenUiEventNames.COMPONENT_ADDED).toBe("component_added");
  });
});

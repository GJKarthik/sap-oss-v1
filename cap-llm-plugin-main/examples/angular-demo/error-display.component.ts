/**
 * ErrorDisplayComponent
 *
 * Renders a UI5 MessageStrip for any `LLMErrorDetail` error.
 *
 * Usage in a parent template:
 *
 *   <app-llm-error-display [error]="currentError" (dismissed)="currentError = null" />
 *
 * The component:
 *   - Shows nothing when `error` is null/undefined
 *   - Renders a UI5 MessageStrip with the error code as title and message as body
 *   - Maps error codes to MessageStrip types (Error / Warning / Information)
 *   - Emits `(dismissed)` when the strip's close button is clicked
 *
 * UI5 web component note:
 *   Uses @ui5/webcomponents MessageStrip via CUSTOM_ELEMENTS_SCHEMA.
 *   Add the following import to your component or AppModule:
 *     import "@ui5/webcomponents/dist/MessageStrip.js";
 */

import { Component, Input, Output, EventEmitter, OnChanges } from "@angular/core";

import type { LLMErrorDetail } from "../../generated/angular-client";

/** UI5 MessageStrip design variants. */
export type MessageStripDesign = "Negative" | "Critical" | "Positive" | "Information";

/** User-friendly error category derived from the error code. */
export interface ErrorDisplayState {
  design: MessageStripDesign;
  title: string;
  body: string;
  visible: boolean;
}

/** Maps structured error codes to display properties. */
const CODE_TO_DESIGN: Record<string, MessageStripDesign> = {
  // Config / validation → Critical (amber)
  EMBEDDING_CONFIG_INVALID: "Critical",
  CHAT_CONFIG_INVALID: "Critical",
  INVALID_SEQUENCE_ID: "Critical",
  INVALID_ALGO_NAME: "Critical",
  UNSUPPORTED_FILTER_TYPE: "Critical",

  // Not found → Information (blue)
  ENTITY_NOT_FOUND: "Information",
  SEQUENCE_COLUMN_NOT_FOUND: "Information",

  // Network / unknown → Critical
  NETWORK_ERROR: "Critical",
  HTTP_401: "Critical",
  HTTP_403: "Critical",

  // All others default to Negative (red) — upstream/SDK failures
};

function getDesign(code: string): MessageStripDesign {
  return CODE_TO_DESIGN[code] ?? "Negative";
}

function formatTitle(code: string): string {
  return code
    .split("_")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(" ");
}

@Component({
  selector: "app-llm-error-display",
  template: `
    <ui5-message-strip
      *ngIf="state.visible"
      [attr.design]="state.design"
      (close)="onDismiss()"
    >
      <strong>{{ state.title }}</strong> — {{ state.body }}
    </ui5-message-strip>
  `,
})
export class ErrorDisplayComponent implements OnChanges {
  /** The LLMErrorDetail to display, or null to hide. */
  @Input() error: LLMErrorDetail | null = null;

  /** Emitted when the user dismisses (closes) the message strip. */
  @Output() dismissed = new EventEmitter<void>();

  state: ErrorDisplayState = {
    design: "Negative",
    title: "",
    body: "",
    visible: false,
  };

  ngOnChanges(): void {
    if (!this.error) {
      this.state = { design: "Negative", title: "", body: "", visible: false };
      return;
    }

    this.state = {
      design: getDesign(this.error.code),
      title: formatTitle(this.error.code),
      body: this.error.message,
      visible: true,
    };
  }

  onDismiss(): void {
    this.state = { ...this.state, visible: false };
    this.dismissed.emit();
  }
}

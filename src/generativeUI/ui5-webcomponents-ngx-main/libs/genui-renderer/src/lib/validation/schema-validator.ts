// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * A2UI Schema Validator
 *
 * Validates A2UI schemas for security and correctness before rendering.
 * Implements sanitization and allowlist checks.
 */

import { Injectable } from '@angular/core';
import { ComponentRegistry } from '../registry/component-registry';
import { A2UiSchema, A2UI_SCHEMA_VERSION } from '../renderer/types';

/** Known/supported schema versions. Schemas with other versions produce a warning. */
const KNOWN_SCHEMA_VERSIONS: Set<string> = new Set([A2UI_SCHEMA_VERSION]);

// =============================================================================
// Types
// =============================================================================

/** Validation error */
export interface ValidationError {
  /** Path to the error in the schema */
  path: string;
  /** Error message */
  message: string;
  /** Error code */
  code: ValidationErrorCode;
  /** Severity */
  severity: 'error' | 'warning';
}

/** Validation error codes */
export type ValidationErrorCode =
  | 'UNKNOWN_COMPONENT'
  | 'DENIED_COMPONENT'
  | 'INVALID_PROP'
  | 'INVALID_SLOT'
  | 'INVALID_EVENT'
  | 'INVALID_BINDING'
  | 'INVALID_SCHEMA'
  | 'XSS_DETECTED'
  | 'CIRCULAR_REFERENCE'
  | 'MAX_DEPTH_EXCEEDED';

/** Validation result */
export interface ValidationResult {
  /** Whether the schema is valid */
  valid: boolean;
  /** Validation errors */
  errors: ValidationError[];
  /** Validation warnings */
  warnings: ValidationError[];
  /** Sanitized schema (if sanitization was applied) */
  sanitizedSchema?: A2UiSchema;
}

/** Validator configuration */
export interface ValidatorConfig {
  /** Maximum nesting depth */
  maxDepth?: number;
  /** Enable HTML sanitization */
  sanitize?: boolean;
  /** Allow unknown components (not recommended) */
  allowUnknown?: boolean;
  /** Strict mode - treat warnings as errors */
  strict?: boolean;
}

// =============================================================================
// Default Configuration
// =============================================================================

const DEFAULT_CONFIG: ValidatorConfig = {
  maxDepth: 20,
  sanitize: true,
  allowUnknown: false,
  strict: true,
};

// =============================================================================
// XSS Patterns
// =============================================================================

const XSS_PATTERNS = [
  /<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi,
  /javascript:/gi,
  /on\w+\s*=/gi,
  /data:\s*text\/html/gi,
  /<iframe/gi,
  /<object/gi,
  /<embed/gi,
];

const ALLOWED_BINDING_TRANSFORMS = new Set([
  'uppercase',
  'lowercase',
  'number',
  'string',
  'boolean',
  'json',
]);

const FORBIDDEN_BINDING_PATH_SEGMENTS = new Set([
  '__proto__',
  'prototype',
  'constructor',
  '__defineGetter__',
  '__defineSetter__',
  '__lookupGetter__',
  '__lookupSetter__',
]);

// =============================================================================
// Schema Validator Service
// =============================================================================

@Injectable()
export class SchemaValidator {
  private config: ValidatorConfig = DEFAULT_CONFIG;

  constructor(private registry: ComponentRegistry) {}

  /**
   * Configure the validator
   */
  configure(config: Partial<ValidatorConfig>): void {
    this.config = { ...DEFAULT_CONFIG, ...config };
  }

  /**
   * Validate an A2UI schema
   */
  validate(schema: A2UiSchema, config?: Partial<ValidatorConfig>): ValidationResult {
    const cfg = { ...this.config, ...config };
    const errors: ValidationError[] = [];
    const warnings: ValidationError[] = [];

    // Schema version check — warn on unknown, never reject (backward-compatible)
    if (schema.schemaVersion !== undefined && !KNOWN_SCHEMA_VERSIONS.has(schema.schemaVersion)) {
      warnings.push({
        path: 'schemaVersion',
        message: `Unknown schema version '${schema.schemaVersion}'. Known versions: ${[...KNOWN_SCHEMA_VERSIONS].join(', ')}. Schema will still be rendered.`,
        code: 'INVALID_SCHEMA',
        severity: 'warning',
      });
    }

    // Validate recursively
    this.validateNode(schema, '', 0, cfg, errors, warnings, new Set());

    // Sanitize if enabled
    let sanitizedSchema: A2UiSchema | undefined;
    if (cfg.sanitize) {
      sanitizedSchema = this.sanitizeSchema(schema);
    }

    const valid = cfg.strict
      ? errors.length === 0 && warnings.length === 0
      : errors.length === 0;

    return {
      valid,
      errors,
      warnings,
      sanitizedSchema,
    };
  }

  /**
   * Quick check if a schema is valid (no detailed errors)
   */
  isValid(schema: A2UiSchema): boolean {
    const result = this.validate(schema);
    return result.valid;
  }

  /**
   * Validate a single node in the schema tree
   */
  private validateNode(
    node: A2UiSchema,
    path: string,
    depth: number,
    config: ValidatorConfig,
    errors: ValidationError[],
    warnings: ValidationError[],
    seenIds: Set<string>
  ): void {
    // Check max depth
    if (depth > (config.maxDepth || 20)) {
      errors.push({
        path,
        message: `Maximum nesting depth (${config.maxDepth}) exceeded`,
        code: 'MAX_DEPTH_EXCEEDED',
        severity: 'error',
      });
      return;
    }

    // Validate component name
    if (!node.component || typeof node.component !== 'string') {
      errors.push({
        path: `${path}.component`,
        message: 'Component name is required and must be a string',
        code: 'INVALID_SCHEMA',
        severity: 'error',
      });
      return;
    }

    // Check if component is allowed
    if (!this.registry.isAllowed(node.component)) {
      if (config.allowUnknown) {
        warnings.push({
          path: `${path}.component`,
          message: `Component '${node.component}' is not in the allowlist`,
          code: 'UNKNOWN_COMPONENT',
          severity: 'warning',
        });
      } else {
        errors.push({
          path: `${path}.component`,
          message: `Component '${node.component}' is not allowed`,
          code: 'DENIED_COMPONENT',
          severity: 'error',
        });
      }
    }

    // Check for duplicate IDs
    if (node.id) {
      if (seenIds.has(node.id)) {
        errors.push({
          path: `${path}.id`,
          message: `Duplicate ID '${node.id}'`,
          code: 'INVALID_SCHEMA',
          severity: 'error',
        });
      }
      seenIds.add(node.id);
    }

    // Validate props
    if (node.props) {
      this.validateProps(node.props, `${path}.props`, config, errors, warnings);
    }

    // Validate events
    if (node.events) {
      this.validateEvents(node, `${path}.events`, errors, warnings);
    }

    // Validate slots
    if (node.slots) {
      const allowedSlots = this.registry.getSlots(node.component);
      for (const [slotName, slotContent] of Object.entries(node.slots)) {
        if (!allowedSlots.includes(slotName) && slotName !== 'default') {
          warnings.push({
            path: `${path}.slots.${slotName}`,
            message: `Slot '${slotName}' is not defined for component '${node.component}'`,
            code: 'INVALID_SLOT',
            severity: 'warning',
          });
        }

        // Validate slot content
        const contents = Array.isArray(slotContent) ? slotContent : [slotContent];
        contents.forEach((content, index) => {
          this.validateNode(
            content,
            `${path}.slots.${slotName}[${index}]`,
            depth + 1,
            config,
            errors,
            warnings,
            seenIds
          );
        });
      }
    }

    // Validate children
    if (node.children) {
      if (!this.registry.isContainer(node.component)) {
        warnings.push({
          path: `${path}.children`,
          message: `Component '${node.component}' may not support children`,
          code: 'INVALID_SCHEMA',
          severity: 'warning',
        });
      }

      node.children.forEach((child, index) => {
        this.validateNode(
          child,
          `${path}.children[${index}]`,
          depth + 1,
          config,
          errors,
          warnings,
          seenIds
        );
      });
    }

    // Validate bindings
    if (node.bindings) {
      this.validateBindings(node.bindings, `${path}.bindings`, errors, warnings);
    }
  }

  /**
   * Validate props for XSS and type correctness
   */
  private validateProps(
    props: Record<string, unknown>,
    path: string,
    config: ValidatorConfig,
    errors: ValidationError[],
    warnings: ValidationError[]
  ): void {
    for (const [key, value] of Object.entries(props)) {
      // Check for XSS in string values
      if (typeof value === 'string' && config.sanitize) {
        if (this.detectXss(value)) {
          errors.push({
            path: `${path}.${key}`,
            message: `Potential XSS detected in prop '${key}'`,
            code: 'XSS_DETECTED',
            severity: 'error',
          });
        }
      }

      // Check for dangerous prop names
      if (key.toLowerCase().startsWith('on')) {
        errors.push({
          path: `${path}.${key}`,
          message: `Event handlers must be defined in 'events', not props`,
          code: 'INVALID_PROP',
          severity: 'error',
        });
      }
    }
  }

  /**
   * Validate event handlers
   */
  private validateEvents(
    node: A2UiSchema,
    path: string,
    errors: ValidationError[],
    warnings: ValidationError[]
  ): void {
    if (!node.events) return;

    const allowedEvents = this.registry.getEvents(node.component);

    for (const [eventName, handler] of Object.entries(node.events)) {
      // Check if event is allowed
      if (allowedEvents.length > 0 && !allowedEvents.includes(eventName)) {
        warnings.push({
          path: `${path}.${eventName}`,
          message: `Event '${eventName}' may not be valid for component '${node.component}'`,
          code: 'INVALID_EVENT',
          severity: 'warning',
        });
      }

      // Validate handler structure
      if (!handler.toolName && !handler.callback) {
        errors.push({
          path: `${path}.${eventName}`,
          message: `Event handler must have either 'toolName' or 'callback'`,
          code: 'INVALID_EVENT',
          severity: 'error',
        });
      }
    }
  }

  /**
   * Validate data bindings
   */
  private validateBindings(
    bindings: Record<string, unknown>,
    path: string,
    errors: ValidationError[],
    warnings: ValidationError[]
  ): void {
    for (const [prop, binding] of Object.entries(bindings)) {
      if (prop.toLowerCase().startsWith('on')) {
        errors.push({
          path: `${path}.${prop}`,
          message: `Binding target '${prop}' is not allowed`,
          code: 'INVALID_BINDING',
          severity: 'error',
        });
        continue;
      }

      if (!binding || typeof binding !== 'object') {
        errors.push({
          path: `${path}.${prop}`,
          message: `Binding must be an object with 'source' and 'path'`,
          code: 'INVALID_BINDING',
          severity: 'error',
        });
        continue;
      }

      const b = binding as Record<string, unknown>;
      if (!b['source'] || !b['path']) {
        errors.push({
          path: `${path}.${prop}`,
          message: `Binding requires 'source' and 'path' properties`,
          code: 'INVALID_BINDING',
          severity: 'error',
        });
        continue;
      }

      if (typeof b['source'] !== 'string' || typeof b['path'] !== 'string') {
        errors.push({
          path: `${path}.${prop}`,
          message: `Binding 'source' and 'path' must be strings`,
          code: 'INVALID_BINDING',
          severity: 'error',
        });
        continue;
      }

      const segments = `${b['source']}.${b['path']}`.split('.');
      if (segments.some(segment => FORBIDDEN_BINDING_PATH_SEGMENTS.has(segment))) {
        errors.push({
          path: `${path}.${prop}`,
          message: `Binding path contains a forbidden object traversal segment`,
          code: 'INVALID_BINDING',
          severity: 'error',
        });
      }

      if (b['transform'] !== undefined && !ALLOWED_BINDING_TRANSFORMS.has(String(b['transform']))) {
        errors.push({
          path: `${path}.${prop}.transform`,
          message: `Binding transform '${String(b['transform'])}' is not supported`,
          code: 'INVALID_BINDING',
          severity: 'error',
        });
      }
    }
  }

  /**
   * Detect potential XSS in a string
   */
  private detectXss(value: string): boolean {
    return XSS_PATTERNS.some(pattern => pattern.test(value));
  }

  /**
   * Sanitize a schema by removing dangerous content
   */
  private sanitizeSchema(schema: A2UiSchema): A2UiSchema {
    const sanitized: A2UiSchema = {
      ...schema,
      props: schema.props ? this.sanitizeProps(schema.props) : undefined,
      children: schema.children?.map(child => this.sanitizeSchema(child)),
      slots: schema.slots
        ? Object.fromEntries(
            Object.entries(schema.slots).map(([key, value]) => [
              key,
              Array.isArray(value)
                ? value.map(v => this.sanitizeSchema(v))
                : this.sanitizeSchema(value),
            ])
          )
        : undefined,
    };

    return sanitized;
  }

  /**
   * Sanitize props
   */
  private sanitizeProps(props: Record<string, unknown>): Record<string, unknown> {
    const sanitized: Record<string, unknown> = {};

    for (const [key, value] of Object.entries(props)) {
      // Skip dangerous props
      if (key.toLowerCase().startsWith('on')) continue;

      // Sanitize string values
      if (typeof value === 'string') {
        sanitized[key] = this.sanitizeString(value);
      } else {
        sanitized[key] = value;
      }
    }

    return sanitized;
  }

  /**
   * Sanitize a string value
   */
  private sanitizeString(value: string): string {
    // Remove script tags and dangerous patterns
    let sanitized = value;
    XSS_PATTERNS.forEach(pattern => {
      sanitized = sanitized.replace(pattern, '');
    });
    return sanitized;
  }
}

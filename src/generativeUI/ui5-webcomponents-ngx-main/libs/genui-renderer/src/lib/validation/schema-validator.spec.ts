// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * SchemaValidator unit tests
 *
 * Covers:
 * - Schema version field: known, unknown, absent
 * - Security deny list integration (file I/O components)
 * - XSS detection in props
 * - Max depth enforcement
 * - Valid Fiori floorplan schemas (snapshot)
 */

import { SchemaValidator } from './schema-validator';
import { ComponentRegistry } from '../registry/component-registry';
import { A2UiSchema, A2UI_SCHEMA_VERSION } from '../renderer/types';

function makeValidator(): SchemaValidator {
  const registry = new ComponentRegistry();
  return new SchemaValidator(registry);
}

// ---------------------------------------------------------------------------
// Schema version
// ---------------------------------------------------------------------------

describe('SchemaValidator — schemaVersion', () => {
  let validator: SchemaValidator;

  beforeEach(() => { validator = makeValidator(); });

  it('accepts a schema without schemaVersion (backward compat)', () => {
    const schema: A2UiSchema = { component: 'ui5-button', props: { text: 'OK' } };
    const result = validator.validate(schema);
    expect(result.valid).toBe(true);
    const versionWarnings = result.warnings.filter(w => w.path === 'schemaVersion');
    expect(versionWarnings).toHaveLength(0);
  });

  it('accepts the current known schema version without warning', () => {
    const schema: A2UiSchema = {
      component: 'ui5-button',
      schemaVersion: A2UI_SCHEMA_VERSION,
      props: { text: 'OK' },
    };
    const result = validator.validate(schema);
    expect(result.valid).toBe(true);
    const versionWarnings = result.warnings.filter(w => w.path === 'schemaVersion');
    expect(versionWarnings).toHaveLength(0);
  });

  it('rejects an unknown schema version in default strict mode', () => {
    const schema: A2UiSchema = {
      component: 'ui5-button',
      schemaVersion: '99',
      props: { text: 'OK' },
    };
    const result = validator.validate(schema);
    expect(result.valid).toBe(false);
    const versionWarnings = result.warnings.filter(w => w.path === 'schemaVersion');
    expect(versionWarnings).toHaveLength(1);
    expect(versionWarnings[0].code).toBe('INVALID_SCHEMA');
    expect(versionWarnings[0].severity).toBe('warning');
  });

  it('allows unknown schema version as warning-only when strict is off', () => {
    const schema: A2UiSchema = {
      component: 'ui5-button',
      schemaVersion: '99',
      props: { text: 'OK' },
    };
    const result = validator.validate(schema, { strict: false });
    expect(result.valid).toBe(true);
    const versionWarnings = result.warnings.filter(w => w.path === 'schemaVersion');
    expect(versionWarnings).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------
// Security: file I/O deny list
// ---------------------------------------------------------------------------

describe('SchemaValidator — security deny list', () => {
  let validator: SchemaValidator;

  beforeEach(() => { validator = makeValidator(); });

  const deniedComponents = [
    'ui5-file-uploader',
    'ui5-file-chooser',
    'ui5-upload-collection',
    'ui5-upload-collection-item',
  ];

  deniedComponents.forEach(tag => {
    it(`rejects schema containing denied component '${tag}'`, () => {
      const schema: A2UiSchema = { component: tag };
      const result = validator.validate(schema);
      expect(result.valid).toBe(false);
      expect(result.errors.some(e => e.code === 'DENIED_COMPONENT')).toBe(true);
    });
  });

  it('rejects denied component nested inside a valid parent', () => {
    const schema: A2UiSchema = {
      component: 'ui5-dialog',
      children: [{ component: 'ui5-file-uploader' }],
    };
    const result = validator.validate(schema);
    expect(result.valid).toBe(false);
    expect(result.errors.some(e => e.code === 'DENIED_COMPONENT')).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// XSS detection
// ---------------------------------------------------------------------------

describe('SchemaValidator — XSS detection', () => {
  let validator: SchemaValidator;

  beforeEach(() => { validator = makeValidator(); });

  it('detects <script> tag in props', () => {
    const schema: A2UiSchema = {
      component: 'ui5-button',
      props: { text: '<script>alert(1)</script>' },
    };
    const result = validator.validate(schema);
    expect(result.valid).toBe(false);
    expect(result.errors.some(e => e.code === 'XSS_DETECTED')).toBe(true);
  });

  it('detects javascript: URI in props', () => {
    const schema: A2UiSchema = {
      component: 'ui5-button',
      props: { href: 'javascript:void(0)' },
    };
    const result = validator.validate(schema);
    expect(result.valid).toBe(false);
    expect(result.errors.some(e => e.code === 'XSS_DETECTED')).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Red-team binding validation
// ---------------------------------------------------------------------------

describe('SchemaValidator — hostile binding payloads', () => {
  let validator: SchemaValidator;

  beforeEach(() => { validator = makeValidator(); });

  it('rejects bindings targeting handler-like props', () => {
    const schema: A2UiSchema = {
      component: 'ui5-button',
      bindings: {
        onclick: {
          source: 'ctx',
          path: 'payload',
        },
      },
    };

    const result = validator.validate(schema);
    expect(result.valid).toBe(false);
    expect(result.errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'INVALID_BINDING',
          path: '.bindings.onclick',
        }),
      ])
    );
  });

  it('rejects prototype-polluting binding paths', () => {
    const schema: A2UiSchema = {
      component: 'ui5-text',
      bindings: {
        text: {
          source: 'ctx',
          path: '__proto__.polluted',
        },
      },
    };

    const result = validator.validate(schema);
    expect(result.valid).toBe(false);
    expect(result.errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'INVALID_BINDING',
          path: '.bindings.text',
        }),
      ])
    );
  });

  it('rejects unsupported binding transforms', () => {
    const schema: A2UiSchema = {
      component: 'ui5-text',
      bindings: {
        text: {
          source: 'ctx',
          path: 'value',
          transform: 'constructor',
        },
      },
    };

    const result = validator.validate(schema);
    expect(result.valid).toBe(false);
    expect(result.errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'INVALID_BINDING',
          path: '.bindings.text.transform',
        }),
      ])
    );
  });
});

// ---------------------------------------------------------------------------
// Max depth
// ---------------------------------------------------------------------------

describe('SchemaValidator — max depth', () => {
  let validator: SchemaValidator;

  beforeEach(() => { validator = makeValidator(); });

  it('rejects schemas exceeding maxDepth', () => {
    let deepSchema: A2UiSchema = { component: 'ui5-panel' };
    for (let i = 0; i < 25; i++) {
      deepSchema = { component: 'ui5-panel', children: [deepSchema] };
    }
    const result = validator.validate(deepSchema, { maxDepth: 5 });
    expect(result.valid).toBe(false);
    expect(result.errors.some(e => e.code === 'MAX_DEPTH_EXCEEDED')).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Snapshot: valid Fiori floorplan schemas
// ---------------------------------------------------------------------------

describe('SchemaValidator — Fiori floorplan snapshots', () => {
  let validator: SchemaValidator;

  beforeEach(() => { validator = makeValidator(); });

  it('validates a list-detail floorplan schema (snapshot)', () => {
    const schema: A2UiSchema = {
      component: 'ui5-flexible-column-layout',
      schemaVersion: A2UI_SCHEMA_VERSION,
      props: { layout: 'TwoColumnsMidExpanded' },
      slots: {
        startColumn: {
          component: 'ui5-list',
          props: { headerText: 'Items' },
          children: [
            { component: 'ui5-li', props: { text: 'Item 1' } },
            { component: 'ui5-li', props: { text: 'Item 2' } },
          ],
        },
        midColumn: {
          component: 'ui5-panel',
          props: { headerText: 'Details' },
          children: [
            { component: 'ui5-label', props: { text: 'Name' } },
          ],
        },
      },
    };
    const result = validator.validate(schema);
    expect(result).toMatchSnapshot();
  });

  it('validates a form floorplan schema (snapshot)', () => {
    const schema: A2UiSchema = {
      component: 'ui5-form',
      schemaVersion: A2UI_SCHEMA_VERSION,
      props: { headerText: 'New Employee' },
      children: [
        {
          component: 'ui5-form-group',
          props: { headerText: 'Personal Data' },
          children: [
            { component: 'ui5-form-item', children: [
              { component: 'ui5-label', props: { text: 'First Name', required: true } },
              { component: 'ui5-input', props: { placeholder: 'Enter first name' } },
            ]},
            { component: 'ui5-form-item', children: [
              { component: 'ui5-label', props: { text: 'Last Name', required: true } },
              { component: 'ui5-input', props: { placeholder: 'Enter last name' } },
            ]},
          ],
        },
      ],
    };
    const result = validator.validate(schema);
    expect(result).toMatchSnapshot();
  });
});

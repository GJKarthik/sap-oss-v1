// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * ComponentRegistry unit tests
 *
 * Covers:
 * - Security deny list enforcement (file I/O components)
 * - allow() / register() cannot bypass deny list
 * - Fiori standard allowlist is correct on init
 * - Custom allow / deny lifecycle
 */

import { ComponentRegistry, SECURITY_DENY_LIST } from './component-registry';

describe('ComponentRegistry', () => {
  let registry: ComponentRegistry;

  beforeEach(() => {
    registry = new ComponentRegistry();
  });

  // ---------------------------------------------------------------------------
  // Security Deny List
  // ---------------------------------------------------------------------------

  describe('SECURITY_DENY_LIST', () => {
    it('denies all file I/O components by default', () => {
      const fileIoComponents = [
        'ui5-file-uploader',
        'ui5-file-chooser',
        'ui5-upload-collection',
        'ui5-upload-collection-item',
      ];

      fileIoComponents.forEach(tag => {
        expect(SECURITY_DENY_LIST.has(tag)).toBe(true);
        expect(registry.isAllowed(tag)).toBe(false);
        expect(registry.get(tag)).toBeUndefined();
      });
    });

    it('throws ComponentNotAllowedException when allow() is called for a denied component', () => {
      expect(() => registry.allow('ui5-file-uploader')).toThrow(
        "Component 'ui5-file-uploader' is in the security deny list and cannot be allowed."
      );
    });

    it('throws ComponentNotAllowedException when register() is called for a denied component', () => {
      expect(() =>
        registry.register({ tagName: 'ui5-file-chooser', category: 'form' })
      ).toThrow(
        "Component 'ui5-file-chooser' is in the security deny list and cannot be registered."
      );
    });

    it('keeps security-denied components denied even after reset()', () => {
      registry.reset();
      SECURITY_DENY_LIST.forEach(tag => {
        expect(registry.isAllowed(tag)).toBe(false);
      });
    });

    it('keeps security-denied components denied even after loadFioriStandard()', () => {
      registry.loadFioriStandard();
      SECURITY_DENY_LIST.forEach(tag => {
        expect(registry.isAllowed(tag)).toBe(false);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Fiori Standard Allowlist
  // ---------------------------------------------------------------------------

  describe('Fiori standard components', () => {
    it('allows ui5-button on init', () => {
      expect(registry.isAllowed('ui5-button')).toBe(true);
    });

    it('allows ui5-table on init', () => {
      expect(registry.isAllowed('ui5-table')).toBe(true);
    });

    it('allows ui5-dialog on init', () => {
      expect(registry.isAllowed('ui5-dialog')).toBe(true);
    });

    it('does not allow arbitrary unknown components', () => {
      expect(registry.isAllowed('my-custom-widget')).toBe(false);
    });
  });

  // ---------------------------------------------------------------------------
  // Custom allow / deny lifecycle
  // ---------------------------------------------------------------------------

  describe('allow() and deny()', () => {
    it('allows a non-denied custom component', () => {
      registry.allow('my-safe-chart');
      expect(registry.isAllowed('my-safe-chart')).toBe(true);
    });

    it('can explicitly deny a previously allowed component', () => {
      expect(registry.isAllowed('ui5-button')).toBe(true);
      registry.deny('ui5-button');
      expect(registry.isAllowed('ui5-button')).toBe(false);
      expect(registry.get('ui5-button')).toBeUndefined();
    });

    it('getAll() excludes denied components', () => {
      registry.deny('ui5-label');
      const all = registry.getAll();
      expect(all.find(m => m.tagName === 'ui5-label')).toBeUndefined();
    });
  });

  // ---------------------------------------------------------------------------
  // Metadata accessors
  // ---------------------------------------------------------------------------

  describe('metadata accessors', () => {
    it('isContainer returns true for ui5-table', () => {
      expect(registry.isContainer('ui5-table')).toBe(true);
    });

    it('isContainer returns false for ui5-button', () => {
      expect(registry.isContainer('ui5-button')).toBe(false);
    });

    it('getSlots returns column slots for ui5-table', () => {
      const slots = registry.getSlots('ui5-table');
      expect(slots).toContain('columns');
    });

    it('getEvents returns click for ui5-button', () => {
      const events = registry.getEvents('ui5-button');
      expect(events).toContain('click');
    });
  });
});

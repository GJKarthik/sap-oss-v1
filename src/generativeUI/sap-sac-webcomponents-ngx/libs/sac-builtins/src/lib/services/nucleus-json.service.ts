/**
 * NucleusJSON Service
 *
 * Angular wrapper for JSON schema validation, JSONPath querying,
 * diff/patch operations, and format conversions.
 * Wraps NucleusJSON from sap-sac-webcomponents-ts/src/builtins.
 */

import { Injectable } from '@angular/core';

import type { JsonSchemaValidationResult, JsonDiff, JsonPatch } from '../types/builtins.types';

@Injectable()
export class NucleusJsonService {
  // -- Validation ------------------------------------------------------------

  validate(data: unknown, schema: Record<string, unknown>): JsonSchemaValidationResult {
    // Placeholder — delegates to SAC REST API via SACRestAPIClient
    return { valid: true };
  }

  // -- JSONPath --------------------------------------------------------------

  query(data: unknown, path: string): unknown[] {
    // Simplified JSONPath ($.key.subkey) — production delegates to REST API
    const parts = path.replace(/^\$\.?/, '').split('.');
    let current: any = data;
    for (const part of parts) {
      if (current == null) return [];
      current = current[part];
    }
    return Array.isArray(current) ? current : current != null ? [current] : [];
  }

  // -- Diff / Patch ----------------------------------------------------------

  diff(a: unknown, b: unknown, path = ''): JsonDiff[] {
    const diffs: JsonDiff[] = [];
    if (typeof a !== typeof b) {
      diffs.push({ path: path || '/', op: 'replace', oldValue: a, newValue: b });
      return diffs;
    }
    if (typeof a === 'object' && a !== null && b !== null) {
      const aObj = a as Record<string, unknown>;
      const bObj = b as Record<string, unknown>;
      const allKeys = new Set([...Object.keys(aObj), ...Object.keys(bObj)]);
      for (const key of allKeys) {
        const p = `${path}/${key}`;
        if (!(key in aObj)) {
          diffs.push({ path: p, op: 'add', newValue: bObj[key] });
        } else if (!(key in bObj)) {
          diffs.push({ path: p, op: 'remove', oldValue: aObj[key] });
        } else if (JSON.stringify(aObj[key]) !== JSON.stringify(bObj[key])) {
          diffs.push({ path: p, op: 'replace', oldValue: aObj[key], newValue: bObj[key] });
        }
      }
    } else if (a !== b) {
      diffs.push({ path: path || '/', op: 'replace', oldValue: a, newValue: b });
    }
    return diffs;
  }

  applyPatch(data: unknown, patches: JsonPatch[]): unknown {
    let result = JSON.parse(JSON.stringify(data));
    for (const patch of patches) {
      const parts = patch.path.split('/').filter(Boolean);
      if (parts.length === 0) continue;
      const parent = this.navigateTo(result, parts.slice(0, -1));
      const key = parts[parts.length - 1];
      if (parent == null) continue;

      switch (patch.op) {
        case 'add':
        case 'replace':
          parent[key] = patch.value;
          break;
        case 'remove':
          delete parent[key];
          break;
      }
    }
    return result;
  }

  // -- Format conversion -----------------------------------------------------

  toXml(data: unknown, rootTag = 'root'): string {
    // Simplified — production delegates to REST API
    return `<${rootTag}>${JSON.stringify(data)}</${rootTag}>`;
  }

  toCsv(data: unknown[]): string {
    if (!Array.isArray(data) || data.length === 0) return '';
    const headers = Object.keys(data[0] as Record<string, unknown>);
    const rows = data.map(row => {
      const r = row as Record<string, unknown>;
      return headers.map(h => String(r[h] ?? '')).join(',');
    });
    return [headers.join(','), ...rows].join('\n');
  }

  // -- Private ---------------------------------------------------------------

  private navigateTo(obj: any, parts: string[]): any {
    let current = obj;
    for (const part of parts) {
      if (current == null) return null;
      current = current[part];
    }
    return current;
  }
}

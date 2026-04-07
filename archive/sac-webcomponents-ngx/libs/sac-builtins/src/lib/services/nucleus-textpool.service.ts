/**
 * NucleusTextPool Service
 *
 * Angular wrapper for centralized text resources / i18n.
 * Wraps TextPool from sap-sac-webcomponents-ts/src/builtins.
 */

import { Injectable } from '@angular/core';

import type { TextPoolEntry } from '../types/builtins.types';

@Injectable()
export class NucleusTextPoolService {
  private entries = new Map<string, TextPoolEntry>();
  private language = 'en';

  /**
   * Set the active language.
   */
  setLanguage(lang: string): void {
    this.language = lang;
  }

  /**
   * Get the active language.
   */
  getLanguage(): string {
    return this.language;
  }

  /**
   * Register a text pool entry.
   */
  set(key: string, value: string, language?: string): void {
    this.entries.set(`${language || this.language}:${key}`, { key, value, language: language || this.language });
  }

  /**
   * Get a text by key for the current (or specified) language.
   */
  get(key: string, language?: string): string {
    const lang = language || this.language;
    return this.entries.get(`${lang}:${key}`)?.value ?? key;
  }

  /**
   * Load a batch of entries.
   */
  loadEntries(entries: TextPoolEntry[]): void {
    for (const entry of entries) {
      this.set(entry.key, entry.value, entry.language);
    }
  }

  /**
   * Get all entries for the current language.
   */
  getAll(language?: string): TextPoolEntry[] {
    const lang = language || this.language;
    return [...this.entries.values()].filter(e => e.language === lang);
  }

  /**
   * Clear all entries.
   */
  clear(): void {
    this.entries.clear();
  }
}

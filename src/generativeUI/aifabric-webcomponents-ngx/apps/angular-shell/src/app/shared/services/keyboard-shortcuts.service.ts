/**
 * Keyboard Shortcuts Service
 * 
 * Provides centralized keyboard shortcut management for power users.
 * Supports customizable shortcuts, context-aware bindings, and help documentation.
 */

import { Injectable, NgZone, OnDestroy, inject } from '@angular/core';
import { Router } from '@angular/router';
import { BehaviorSubject, Subject } from 'rxjs';

export interface KeyboardShortcut {
  id: string;
  keys: string[];
  description: string;
  category: ShortcutCategory;
  action: () => void;
  enabled?: boolean;
  context?: string; // Optional context where shortcut is active
}

export type ShortcutCategory = 'navigation' | 'actions' | 'view' | 'help';

export interface ShortcutGroup {
  category: ShortcutCategory;
  label: string;
  shortcuts: KeyboardShortcut[];
}

@Injectable({
  providedIn: 'root'
})
export class KeyboardShortcutsService implements OnDestroy {
  private readonly shortcuts = new Map<string, KeyboardShortcut>();
  private readonly shortcutsSubject = new BehaviorSubject<KeyboardShortcut[]>([]);
  private readonly helpDialogSubject = new Subject<boolean>();
  private readonly destroy$ = new Subject<void>();
  private enabled = true;
  private currentContext = 'global';

  readonly shortcuts$ = this.shortcutsSubject.asObservable();
  readonly helpDialogOpen$ = this.helpDialogSubject.asObservable();
  private readonly router = inject(Router);
  private readonly ngZone = inject(NgZone);

  constructor() {
    this.setupDefaultShortcuts();
    this.setupKeyboardListener();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  /**
   * Register a new keyboard shortcut
   */
  register(shortcut: KeyboardShortcut): void {
    const key = this.normalizeKeys(shortcut.keys);
    this.shortcuts.set(key, { ...shortcut, enabled: shortcut.enabled ?? true });
    this.updateShortcutsList();
  }

  /**
   * Unregister a keyboard shortcut
   */
  unregister(keys: string[]): void {
    const key = this.normalizeKeys(keys);
    this.shortcuts.delete(key);
    this.updateShortcutsList();
  }

  /**
   * Enable or disable all shortcuts
   */
  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
  }

  /**
   * Set the current context for context-aware shortcuts
   */
  setContext(context: string): void {
    this.currentContext = context;
  }

  /**
   * Show the keyboard shortcuts help dialog
   */
  showHelp(): void {
    this.helpDialogSubject.next(true);
  }

  /**
   * Hide the keyboard shortcuts help dialog
   */
  hideHelp(): void {
    this.helpDialogSubject.next(false);
  }

  /**
   * Get shortcuts grouped by category
   */
  getGroupedShortcuts(): ShortcutGroup[] {
    const categories: Record<ShortcutCategory, string> = {
      navigation: 'Navigation',
      actions: 'Actions',
      view: 'View',
      help: 'Help'
    };

    const groups: ShortcutGroup[] = [];
    
    for (const [category, label] of Object.entries(categories)) {
      const categoryShortcuts = Array.from(this.shortcuts.values())
        .filter(s => s.category === category && s.enabled);
      
      if (categoryShortcuts.length > 0) {
        groups.push({
          category: category as ShortcutCategory,
          label,
          shortcuts: categoryShortcuts
        });
      }
    }

    return groups;
  }

  /**
   * Format keys for display (e.g., "Ctrl+K" -> "⌘K" on Mac)
   */
  formatKeysForDisplay(keys: string[]): string {
    const isMac = navigator.platform.toUpperCase().indexOf('MAC') >= 0;
    
    return keys.map(key => {
      let formatted = key;
      if (isMac) {
        formatted = formatted.replace('Ctrl', '⌘');
        formatted = formatted.replace('Alt', '⌥');
        formatted = formatted.replace('Shift', '⇧');
      }
      return formatted;
    }).join(' + ');
  }

  private setupDefaultShortcuts(): void {
    // Navigation shortcuts
    this.register({
      id: 'nav-dashboard',
      keys: ['g', 'd'],
      description: 'Go to Dashboard',
      category: 'navigation',
      action: () => this.navigate('/dashboard')
    });

    this.register({
      id: 'nav-deployments',
      keys: ['g', 'p'],
      description: 'Go to Deployments',
      category: 'navigation',
      action: () => this.navigate('/deployments')
    });

    this.register({
      id: 'nav-streaming',
      keys: ['g', 's'],
      description: 'Go to Search Ops',
      category: 'navigation',
      action: () => this.navigate('/streaming')
    });

    this.register({
      id: 'nav-rag',
      keys: ['g', 'r'],
      description: 'Go to Search Studio',
      category: 'navigation',
      action: () => this.navigate('/rag')
    });

    this.register({
      id: 'nav-data',
      keys: ['g', 'e'],
      description: 'Go to Data Explorer',
      category: 'navigation',
      action: () => this.navigate('/data')
    });

    this.register({
      id: 'nav-playground',
      keys: ['g', 'l'],
      description: 'Go to PAL Workbench',
      category: 'navigation',
      action: () => this.navigate('/playground')
    });

    this.register({
      id: 'nav-governance',
      keys: ['g', 'v'],
      description: 'Go to Governance',
      category: 'navigation',
      action: () => this.navigate('/governance')
    });

    this.register({
      id: 'nav-lineage',
      keys: ['g', 'i'],
      description: 'Go to Lineage',
      category: 'navigation',
      action: () => this.navigate('/lineage')
    });

    // Action shortcuts
    this.register({
      id: 'action-refresh',
      keys: ['Ctrl', 'r'],
      description: 'Refresh current page',
      category: 'actions',
      action: () => this.triggerRefresh()
    });

    this.register({
      id: 'action-search',
      keys: ['Ctrl', 'k'],
      description: 'Focus search / Quick actions',
      category: 'actions',
      action: () => this.triggerSearch()
    });

    // View shortcuts
    this.register({
      id: 'view-toggle-nav',
      keys: ['['],
      description: 'Toggle navigation panel',
      category: 'view',
      action: () => this.toggleNavigation()
    });

    // Help shortcuts
    this.register({
      id: 'help-shortcuts',
      keys: ['?'],
      description: 'Show keyboard shortcuts',
      category: 'help',
      action: () => this.showHelp()
    });

    this.register({
      id: 'help-close',
      keys: ['Escape'],
      description: 'Close dialogs / Cancel',
      category: 'help',
      action: () => this.hideHelp()
    });
  }

  private setupKeyboardListener(): void {
    const keySequence: string[] = [];
    let sequenceTimeout: ReturnType<typeof setTimeout> | null = null;

    document.addEventListener('keydown', (event: KeyboardEvent) => {
      // Skip if disabled or if user is typing in an input
      if (!this.enabled || this.isInputFocused(event)) {
        return;
      }

      // Build key combination
      const keys: string[] = [];
      if (event.ctrlKey || event.metaKey) keys.push('Ctrl');
      if (event.altKey) keys.push('Alt');
      if (event.shiftKey) keys.push('Shift');
      
      // Add the actual key
      const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
      if (!['Control', 'Alt', 'Shift', 'Meta'].includes(event.key)) {
        keys.push(key);
      }

      // Check for single key shortcuts first
      const singleKeyNormalized = this.normalizeKeys(keys);
      const singleKeyShortcut = this.shortcuts.get(singleKeyNormalized);
      
      if (singleKeyShortcut?.enabled && this.isContextValid(singleKeyShortcut)) {
        event.preventDefault();
        this.ngZone.run(() => singleKeyShortcut.action());
        return;
      }

      // Handle key sequences (e.g., g then d)
      if (keys.length === 1 && keys[0].length === 1) {
        keySequence.push(keys[0]);
        
        // Clear sequence after timeout
        if (sequenceTimeout) {
          clearTimeout(sequenceTimeout);
        }
        sequenceTimeout = setTimeout(() => {
          keySequence.length = 0;
        }, 500);

        // Check for sequence match
        const sequenceNormalized = this.normalizeKeys(keySequence);
        const sequenceShortcut = this.shortcuts.get(sequenceNormalized);
        
        if (sequenceShortcut?.enabled && this.isContextValid(sequenceShortcut)) {
          event.preventDefault();
          keySequence.length = 0;
          if (sequenceTimeout) {
            clearTimeout(sequenceTimeout);
          }
          this.ngZone.run(() => sequenceShortcut.action());
        }
      }
    });
  }

  private normalizeKeys(keys: string[]): string {
    return keys.map(k => k.toLowerCase()).sort().join('+');
  }

  private isInputFocused(event: KeyboardEvent): boolean {
    const target = event.target as HTMLElement;
    const tagName = target.tagName.toLowerCase();
    const isContentEditable = target.isContentEditable;
    
    // Allow shortcuts in inputs only for specific keys
    if (['input', 'textarea', 'select'].includes(tagName) || isContentEditable) {
      // Allow Escape and some Ctrl shortcuts even in inputs
      if (event.key === 'Escape') {
        return false;
      }
      return true;
    }
    
    return false;
  }

  private isContextValid(shortcut: KeyboardShortcut): boolean {
    if (!shortcut.context) {
      return true; // Global shortcut
    }
    return shortcut.context === this.currentContext;
  }

  private updateShortcutsList(): void {
    this.shortcutsSubject.next(Array.from(this.shortcuts.values()));
  }

  private navigate(route: string): void {
    void this.router.navigate([route]);
  }

  private triggerRefresh(): void {
    // Dispatch a custom event that pages can listen to
    window.dispatchEvent(new CustomEvent('app-refresh'));
  }

  private triggerSearch(): void {
    // Dispatch a custom event for search/quick actions
    window.dispatchEvent(new CustomEvent('app-search'));
  }

  private toggleNavigation(): void {
    // Dispatch a custom event for toggling navigation
    window.dispatchEvent(new CustomEvent('app-toggle-nav'));
  }
}

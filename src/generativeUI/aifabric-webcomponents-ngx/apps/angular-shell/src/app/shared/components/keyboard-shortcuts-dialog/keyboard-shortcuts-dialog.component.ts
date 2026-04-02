/**
 * Keyboard Shortcuts Dialog Component
 * 
 * Displays available keyboard shortcuts organized by category.
 * Accessible via the '?' key shortcut.
 */

import { Component, DestroyRef, OnInit, ViewChild, ElementRef, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { KeyboardShortcutsService, ShortcutGroup } from '../../services/keyboard-shortcuts.service';

@Component({
  selector: 'app-keyboard-shortcuts-dialog',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  template: `
    <ui5-dialog
      #dialog
      header-text="Keyboard Shortcuts"
      [open]="isOpen"
      (after-close)="onClose()"
      accessible-name="Keyboard shortcuts help"
      class="shortcuts-dialog">
      
      <div class="shortcuts-content">
        <p class="shortcuts-intro">
          Use these keyboard shortcuts to navigate quickly through the application.
        </p>
        
        <div class="shortcut-groups">
          <div *ngFor="let group of shortcutGroups" class="shortcut-group">
            <h4 class="group-title">{{ group.label }}</h4>
            
            <div class="shortcuts-list">
              <div 
                *ngFor="let shortcut of group.shortcuts" 
                class="shortcut-item"
                [attr.aria-label]="shortcut.description + ': ' + formatKeys(shortcut.keys)">
                <span class="shortcut-description">{{ shortcut.description }}</span>
                <span class="shortcut-keys">
                  <kbd *ngFor="let key of shortcut.keys; let last = last">
                    {{ formatKey(key) }}
                  </kbd>
                  <span *ngIf="shortcut.keys.length > 1 && isSequence(shortcut.keys)" class="sequence-hint">
                    (press in sequence)
                  </span>
                </span>
              </div>
            </div>
          </div>
        </div>
        
        <div class="shortcuts-footer">
          <ui5-icon name="hint" aria-hidden="true"></ui5-icon>
          <span>Press <kbd>?</kbd> anytime to show this dialog</span>
        </div>
      </div>
      
      <div slot="footer" class="dialog-footer">
        <ui5-button design="Emphasized" (click)="close()">
          Close
        </ui5-button>
      </div>
    </ui5-dialog>
  `,
  styles: [`
    .shortcuts-dialog {
      --_ui5_popup_content_padding: 0;
    }
    
    .shortcuts-content {
      padding: 1rem 1.5rem;
      max-width: 600px;
      max-height: 70vh;
      overflow-y: auto;
    }
    
    .shortcuts-intro {
      margin: 0 0 1.5rem 0;
      color: var(--sapContent_LabelColor);
      line-height: 1.5;
    }
    
    .shortcut-groups {
      display: flex;
      flex-direction: column;
      gap: 1.5rem;
    }
    
    .shortcut-group {
      background: var(--sapList_Background);
      border-radius: 8px;
      padding: 1rem;
    }
    
    .group-title {
      margin: 0 0 0.75rem 0;
      font-size: var(--sapFontSize);
      font-weight: 600;
      color: var(--sapBrandColor);
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    
    .shortcuts-list {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }
    
    .shortcut-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.5rem 0;
      border-bottom: 1px solid var(--sapList_BorderColor);
    }
    
    .shortcut-item:last-child {
      border-bottom: none;
    }
    
    .shortcut-description {
      color: var(--sapTextColor);
      flex: 1;
      padding-right: 1rem;
    }
    
    .shortcut-keys {
      display: flex;
      align-items: center;
      gap: 0.25rem;
      flex-shrink: 0;
    }
    
    kbd {
      display: inline-block;
      padding: 0.25rem 0.5rem;
      font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
      font-size: var(--sapFontSmallSize);
      color: var(--sapTextColor);
      background: var(--sapBackgroundColor);
      border: 1px solid var(--sapList_BorderColor);
      border-radius: 4px;
      box-shadow: 0 1px 1px rgba(0, 0, 0, 0.1);
      min-width: 24px;
      text-align: center;
    }
    
    .sequence-hint {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
      font-style: italic;
      margin-left: 0.5rem;
    }
    
    .shortcuts-footer {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-top: 1.5rem;
      padding-top: 1rem;
      border-top: 1px solid var(--sapList_BorderColor);
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }
    
    .shortcuts-footer ui5-icon {
      font-size: 1rem;
    }
    
    .shortcuts-footer kbd {
      padding: 0.125rem 0.375rem;
    }
    
    .dialog-footer {
      display: flex;
      justify-content: flex-end;
      padding: 0.5rem 1rem;
      border-top: 1px solid var(--sapList_BorderColor);
    }
    
    @media (max-width: 600px) {
      .shortcuts-content {
        padding: 1rem;
      }
      
      .shortcut-item {
        flex-direction: column;
        align-items: flex-start;
        gap: 0.5rem;
      }
      
      .shortcut-description {
        padding-right: 0;
      }
    }
  `]
})
export class KeyboardShortcutsDialogComponent implements OnInit {
  @ViewChild('dialog') dialogRef!: ElementRef;
  
  private readonly keyboardService = inject(KeyboardShortcutsService);
  private readonly destroyRef = inject(DestroyRef);
  
  isOpen = false;
  shortcutGroups: ShortcutGroup[] = [];

  ngOnInit(): void {
    // Subscribe to help dialog state
    this.keyboardService.helpDialogOpen$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(open => {
        this.isOpen = open;
        if (open) {
          this.shortcutGroups = this.keyboardService.getGroupedShortcuts();
        }
      });
  }

  close(): void {
    this.keyboardService.hideHelp();
  }

  onClose(): void {
    this.isOpen = false;
  }

  formatKeys(keys: string[]): string {
    return this.keyboardService.formatKeysForDisplay(keys);
  }

  formatKey(key: string): string {
    const isMac = navigator.platform.toUpperCase().indexOf('MAC') >= 0;
    
    if (isMac) {
      if (key === 'Ctrl') return '⌘';
      if (key === 'Alt') return '⌥';
      if (key === 'Shift') return '⇧';
    }
    
    // Format special keys
    if (key === 'Escape') return 'Esc';
    if (key === ' ') return 'Space';
    
    // Uppercase single letters
    if (key.length === 1) {
      return key.toUpperCase();
    }
    
    return key;
  }

  isSequence(keys: string[]): boolean {
    // A sequence is when all keys are single characters and there's more than one
    return keys.length > 1 && keys.every(k => k.length === 1);
  }
}
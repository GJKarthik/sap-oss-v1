/**
 * Theme Switcher Component
 * 
 * Allows users to manually toggle between light and dark themes,
 * or use the system preference.
 */

import { Component, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { ThemeService, ThemeMode } from '../../services/theme.service';

@Component({
  selector: 'app-theme-switcher',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  template: `
    <div class="theme-switcher" role="group" aria-label="Theme selection">
      <ui5-segmented-button 
        accessible-name="Select theme mode"
        (selection-change)="onThemeChange($event)">
        <ui5-segmented-button-item 
          [selected]="currentTheme === 'light'"
          icon="lightbulb"
          accessible-name="Light theme"
          data-theme="light">
        </ui5-segmented-button-item>
        <ui5-segmented-button-item 
          [selected]="currentTheme === 'system'"
          icon="settings"
          accessible-name="System theme"
          data-theme="system">
        </ui5-segmented-button-item>
        <ui5-segmented-button-item 
          [selected]="currentTheme === 'dark'"
          icon="show"
          accessible-name="Dark theme"
          data-theme="dark">
        </ui5-segmented-button-item>
      </ui5-segmented-button>
      
      <span class="theme-label" *ngIf="showLabel">
        {{ getThemeLabel() }}
      </span>
    </div>
  `,
  styles: [`
    .theme-switcher {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    
    .theme-label {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }
  `]
})
export class ThemeSwitcherComponent implements OnInit {
  private readonly themeService = inject(ThemeService);
  
  currentTheme: ThemeMode = 'system';
  showLabel = false;

  ngOnInit(): void {
    this.currentTheme = this.themeService.getCurrentTheme();
  }

  onThemeChange(event: Event): void {
    const customEvent = event as CustomEvent;
    const selectedItem = customEvent.detail?.selectedItem;
    const theme = selectedItem?.dataset?.theme as ThemeMode;
    
    if (theme) {
      this.currentTheme = theme;
      this.themeService.setTheme(theme);
    }
  }

  getThemeLabel(): string {
    switch (this.currentTheme) {
      case 'light': return 'Light';
      case 'dark': return 'Dark';
      case 'system': return 'System';
      default: return '';
    }
  }
}
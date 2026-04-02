/**
 * Theme Service
 * 
 * Manages application theme (light/dark/system) with persistence
 * and system preference detection.
 */

import { Injectable, OnDestroy } from '@angular/core';
import { BehaviorSubject, Subject } from 'rxjs';

export type ThemeMode = 'light' | 'dark' | 'system';

export interface ThemeState {
  mode: ThemeMode;
  activeTheme: 'light' | 'dark';
}

@Injectable({
  providedIn: 'root'
})
export class ThemeService implements OnDestroy {
  private readonly STORAGE_KEY = 'sap-ai-fabric-theme';
  private readonly themeSubject = new BehaviorSubject<ThemeState>({
    mode: 'system',
    activeTheme: 'light'
  });
  private readonly destroy$ = new Subject<void>();
  private mediaQuery: MediaQueryList | null = null;

  readonly theme$ = this.themeSubject.asObservable();

  constructor() {
    this.initialize();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
    this.removeMediaQueryListener();
  }

  /**
   * Get the current theme mode (light/dark/system)
   */
  getCurrentTheme(): ThemeMode {
    return this.themeSubject.value.mode;
  }

  /**
   * Get the active theme (resolved light or dark)
   */
  getActiveTheme(): 'light' | 'dark' {
    return this.themeSubject.value.activeTheme;
  }

  /**
   * Set the theme mode
   */
  setTheme(mode: ThemeMode): void {
    const activeTheme = this.resolveTheme(mode);
    
    // Save preference
    localStorage.setItem(this.STORAGE_KEY, mode);
    
    // Apply theme
    this.applyTheme(activeTheme);
    
    // Update state
    this.themeSubject.next({ mode, activeTheme });
    
    // Set up or remove media query listener
    if (mode === 'system') {
      this.setupMediaQueryListener();
    } else {
      this.removeMediaQueryListener();
    }
  }

  /**
   * Toggle between light and dark (ignores system preference)
   */
  toggleTheme(): void {
    const current = this.getActiveTheme();
    const newTheme = current === 'light' ? 'dark' : 'light';
    this.setTheme(newTheme);
  }

  private initialize(): void {
    // Load saved preference or default to system
    const savedTheme = localStorage.getItem(this.STORAGE_KEY) as ThemeMode | null;
    const mode = savedTheme || 'system';
    
    // Resolve and apply initial theme
    const activeTheme = this.resolveTheme(mode);
    this.applyTheme(activeTheme);
    
    // Update state
    this.themeSubject.next({ mode, activeTheme });
    
    // Set up media query listener if using system preference
    if (mode === 'system') {
      this.setupMediaQueryListener();
    }
  }

  private resolveTheme(mode: ThemeMode): 'light' | 'dark' {
    if (mode === 'system') {
      return this.getSystemPreference();
    }
    return mode;
  }

  private getSystemPreference(): 'light' | 'dark' {
    if (typeof window !== 'undefined' && window.matchMedia) {
      return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }
    return 'light';
  }

  private applyTheme(theme: 'light' | 'dark'): void {
    const root = document.documentElement;
    
    if (theme === 'dark') {
      root.setAttribute('data-theme', 'dark');
      root.classList.add('dark-theme');
      root.classList.remove('light-theme');
      
      // Apply dark theme CSS variables
      root.style.setProperty('--sapBackgroundColor', '#1c2228');
      root.style.setProperty('--sapList_Background', '#29313a');
      root.style.setProperty('--sapList_BorderColor', '#3d4751');
      root.style.setProperty('--sapTextColor', '#ffffff');
      root.style.setProperty('--sapContent_LabelColor', '#a3b2c2');
      root.style.setProperty('--sapShellColor', '#1a2129');
    } else {
      root.setAttribute('data-theme', 'light');
      root.classList.add('light-theme');
      root.classList.remove('dark-theme');
      
      // Apply light theme CSS variables
      root.style.setProperty('--sapBackgroundColor', '#f7f7f7');
      root.style.setProperty('--sapList_Background', '#ffffff');
      root.style.setProperty('--sapList_BorderColor', '#e5e5e5');
      root.style.setProperty('--sapTextColor', '#32363a');
      root.style.setProperty('--sapContent_LabelColor', '#556b82');
      root.style.setProperty('--sapShellColor', '#354a5f');
    }
    
    // Update meta theme-color for mobile browsers
    const metaThemeColor = document.querySelector('meta[name="theme-color"]');
    if (metaThemeColor) {
      metaThemeColor.setAttribute('content', theme === 'dark' ? '#1c2228' : '#0a6ed1');
    }
  }

  private setupMediaQueryListener(): void {
    if (typeof window === 'undefined' || !window.matchMedia) {
      return;
    }

    this.removeMediaQueryListener();
    
    this.mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
    this.mediaQuery.addEventListener('change', this.handleMediaQueryChange);
  }

  private removeMediaQueryListener(): void {
    if (this.mediaQuery) {
      this.mediaQuery.removeEventListener('change', this.handleMediaQueryChange);
      this.mediaQuery = null;
    }
  }

  private handleMediaQueryChange = (event: MediaQueryListEvent): void => {
    const currentMode = this.themeSubject.value.mode;
    
    // Only react if we're in system mode
    if (currentMode === 'system') {
      const activeTheme = event.matches ? 'dark' : 'light';
      this.applyTheme(activeTheme);
      this.themeSubject.next({ mode: 'system', activeTheme });
    }
  };
}
/**
 * Shared Module Exports
 * 
 * Central export point for all shared components, pipes, directives, and services.
 */

// Components
export { ConfirmationDialogComponent, ConfirmationDialogData } from './components/confirmation-dialog/confirmation-dialog.component';
export { EmptyStateComponent } from './components/empty-state/empty-state.component';
export { PaginationComponent, PaginationState } from './components/pagination/pagination.component';
export { ErrorBoundaryComponent, ErrorInfo, GlobalErrorHandler } from './components/error-boundary/error-boundary.component';
export { KeyboardShortcutsDialogComponent } from './components/keyboard-shortcuts-dialog/keyboard-shortcuts-dialog.component';
export { ThemeSwitcherComponent } from './components/theme-switcher/theme-switcher.component';
export { CrossAppLinkComponent } from './cross-app-link.component';

// Pipes
export { DateFormatPipe, DateFormatStyle } from './pipes/date-format.pipe';

// Services
export { 
  KeyboardShortcutsService, 
  KeyboardShortcut, 
  ShortcutCategory, 
  ShortcutGroup 
} from './services/keyboard-shortcuts.service';
export { ThemeService, ThemeMode, ThemeState } from './services/theme.service';
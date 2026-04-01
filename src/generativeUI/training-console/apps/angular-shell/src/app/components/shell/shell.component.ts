import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, HostListener, signal, computed, ElementRef, ViewChild } from '@angular/core';
import { RouterOutlet, RouterLink, RouterLinkActive, Router } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { AuthService } from '../../services/auth.service';
import { UserSettingsService } from '../../services/user-settings.service';
import { AppStore } from '../../store/app.store';

interface NavItem {
  label: string;
  icon: string;
  route: string;
}

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [RouterOutlet, RouterLink, RouterLinkActive, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="shell-layout">
      @if (showSearch()) {
        <div class="search-overlay" (click)="closeSearch()">
          <div class="search-modal" (click)="$event.stopPropagation()">
            <div class="search-header-container">
              <span class="search-icon">🔍</span>
              <input #searchInput type="text" class="search-input"
                [ngModel]="searchQuery()" (ngModelChange)="searchQuery.set($event)"
                placeholder="Search pages... (e.g. Pipeline, Chat)"
                (keydown.enter)="navigateToSelected()"
                (keydown.escape)="closeSearch()"
                (keydown.arrowDown)="moveSelection(1); $event.preventDefault()"
                (keydown.arrowUp)="moveSelection(-1); $event.preventDefault()" />
              <kbd class="search-kbd">ESC</kbd>
            </div>
            <div class="search-results-list">
              @for (res of searchResults(); track res.route; let i = $index) {
                <div class="search-item" [class.selected]="i === selectedIndex()"
                  (click)="navigateFromSearch(res.route)"
                  (mouseenter)="selectedIndex.set(i)">
                  <span class="nav-icon" aria-hidden="true">{{ res.icon }}</span>
                  <span class="nav-label">{{ res.label }}</span>
                  <span class="search-shortcut">↵</span>
                </div>
              }
              @if (searchResults().length === 0) {
                <div class="search-empty">No results found matching "{{searchQuery()}}"</div>
              }
            </div>
          </div>
        </div>
      }

      <header class="shell-header">
        <div class="header-left">
          <button class="hamburger-btn" (click)="sidebarOpen.set(!sidebarOpen())" aria-label="Toggle navigation">
            <span class="hamburger-line"></span>
            <span class="hamburger-line"></span>
            <span class="hamburger-line"></span>
          </button>
          <div class="header-brand">
            <span class="brand-icon">◆</span>
            <span class="brand-name">Training Console</span>
            <span class="brand-version">v{{ version }}</span>
          </div>
          @if (store.wsState() === 'connected') {
            <span class="ws-badge connected">Live</span>
          } @else if (store.wsState() === 'reconnecting' || store.wsState() === 'connecting') {
            <span class="ws-badge warning">Reconnecting...</span>
          } @else {
            <span class="ws-badge error">Offline</span>
          }
        </div>
        <div class="header-actions">
          <button class="header-btn search-trigger" (click)="toggleSearch()" title="Search (⌘K)">
            <span>🔍</span><kbd>⌘K</kbd>
          </button>
          <select class="mode-select" [ngModel]="userSettings.mode()" (ngModelChange)="userSettings.setMode($event)">
            <option value="novice">Novice</option>
            <option value="intermediate">Intermediate</option>
            <option value="expert">Expert</option>
          </select>
          <div class="avatar-wrapper" (click)="avatarMenuOpen.set(!avatarMenuOpen())">
            <div class="user-avatar">TC</div>
            @if (avatarMenuOpen()) {
              <div class="avatar-menu">
                <div class="avatar-menu-item" (click)="logout()">Sign out</div>
              </div>
            }
          </div>
        </div>
      </header>

      <div class="shell-body">
        <nav class="side-nav" [class.side-nav--open]="sidebarOpen()">
          <ul class="nav-list">
            @for (item of navItems; track item.route) {
              <li>
                <a [routerLink]="item.route" routerLinkActive="nav-link--active"
                  class="nav-link" [attr.aria-label]="item.label">
                  <span class="nav-icon" aria-hidden="true">{{ item.icon }}</span>
                  <span class="nav-label">{{ item.label }}</span>
                </a>
              </li>
            }
          </ul>
          <div class="nav-footer">
            <div class="api-key-row">
              <input type="password" class="api-key-input" [(ngModel)]="apiKeyDraft"
                placeholder="API key (optional)" (keydown.enter)="saveApiKey()" />
              <button class="api-key-save" (click)="saveApiKey()">Save</button>
            </div>
          </div>
        </nav>
        @if (sidebarOpen()) {
          <div class="sidebar-backdrop" (click)="sidebarOpen.set(false)"></div>
        }
        <main class="shell-content" id="main-content">
          <router-outlet />
        </main>
      </div>
    </div>
  `,
  styles: [`
    .shell-layout {
      display: flex; flex-direction: column; height: 100vh;
      overflow: hidden; background: var(--sapBackgroundColor, #f5f5f5);
    }

    /* Search overlay */
    .search-overlay {
      position: fixed; inset: 0;
      background: rgba(0,0,0,0.45); backdrop-filter: blur(4px);
      z-index: 1000; display: flex; justify-content: center;
      align-items: flex-start; padding-top: 10vh;
      animation: fadeIn 0.15s ease-out;
    }
    .search-modal {
      width: 100%; max-width: 560px;
      background: var(--sapBaseColor, #fff); border-radius: 0.75rem;
      box-shadow: 0 16px 48px rgba(0,0,0,0.24); overflow: hidden;
      display: flex; flex-direction: column;
      animation: slideUp 0.2s ease-out;
    }
    .search-header-container {
      display: flex; align-items: center;
      padding: 0.875rem 1.25rem;
      border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
    }
    .search-icon { font-size: 1.1rem; margin-right: 0.75rem; opacity: 0.6; }
    .search-input {
      flex: 1; border: none; outline: none;
      font-size: 1rem; background: transparent;
      color: var(--sapTextColor, #32363a);
    }
    .search-kbd {
      background: var(--sapGroup_TitleBorderColor, #d9d9d9);
      border: none; padding: 0.2rem 0.5rem; border-radius: 0.25rem;
      font-size: 0.6875rem; color: var(--sapTextColor, #32363a);
      font-weight: 600; font-family: inherit;
    }
    .search-results-list { max-height: 360px; overflow-y: auto; padding: 0.375rem 0; }
    .search-item {
      display: flex; align-items: center;
      padding: 0.625rem 1.25rem; cursor: pointer;
      border-radius: 0.375rem; margin: 0 0.375rem;
      transition: background 0.1s;
    }
    .search-item:hover, .search-item.selected {
      background: var(--sapList_SelectionBackgroundColor, #e8f2ff);
    }
    .search-item.selected { color: var(--sapBrandColor, #0854a0); }
    .search-item .nav-icon { margin-right: 0.75rem; font-size: 1.125rem; }
    .search-shortcut {
      margin-left: auto; color: var(--sapContent_LabelColor, #6a6d70);
      font-size: 0.875rem; opacity: 0;
    }
    .search-item.selected .search-shortcut,
    .search-item:hover .search-shortcut { opacity: 1; }
    .search-empty {
      padding: 2rem 1.25rem; text-align: center;
      color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.875rem;
    }

    /* Header */
    .shell-header {
      display: flex; align-items: center; justify-content: space-between;
      padding: 0 1.25rem; height: 2.75rem;
      background: linear-gradient(135deg, var(--sapShellColor, #354a5e), #2c3e50);
      color: #fff; flex-shrink: 0;
      box-shadow: 0 1px 3px rgba(0,0,0,0.18), 0 1px 2px rgba(0,0,0,0.12);
    }
    .header-left { display: flex; align-items: center; gap: 0.75rem; }
    .hamburger-btn {
      display: none; flex-direction: column; gap: 3px;
      background: none; border: none; cursor: pointer; padding: 0.25rem;
    }
    .hamburger-line {
      display: block; width: 18px; height: 2px;
      background: #fff; border-radius: 1px;
      transition: transform 0.2s;
    }
    .header-brand {
      display: flex; align-items: center; gap: 0.5rem;
      font-weight: 600; font-size: 0.9375rem; letter-spacing: 0.01em;
    }
    .brand-icon {
      font-size: 1.125rem; color: #6fb3f2;
    }
    .brand-name { color: #fff; }
    .brand-version {
      font-size: 0.625rem; color: rgba(255,255,255,0.5);
      font-weight: 400; margin-top: 0.05rem;
    }
    .ws-badge {
      font-size: 0.5625rem; padding: 0.125rem 0.375rem;
      border-radius: 0.75rem; text-transform: uppercase;
      font-weight: 700; letter-spacing: 0.04em;
    }
    .ws-badge.connected { background: rgba(46,125,50,0.85); }
    .ws-badge.warning { background: rgba(245,124,0,0.85); }
    .ws-badge.error { background: rgba(198,40,40,0.85); }
    .header-actions { display: flex; align-items: center; gap: 0.625rem; }
    .header-btn {
      background: transparent; border: 1px solid rgba(255,255,255,0.25);
      color: #fff; padding: 0.25rem 0.625rem; border-radius: 0.25rem;
      cursor: pointer; font-size: 0.75rem;
      transition: background 0.15s, border-color 0.15s;
      display: flex; align-items: center; gap: 0.375rem;
    }
    .header-btn:hover { background: rgba(255,255,255,0.1); border-color: rgba(255,255,255,0.4); }
    .search-trigger kbd {
      font-size: 0.5625rem; opacity: 0.6; font-family: inherit;
      background: rgba(255,255,255,0.15); padding: 0.1rem 0.3rem;
      border-radius: 0.15rem;
    }
    .mode-select {
      background: transparent; color: #fff;
      border: 1px solid rgba(255,255,255,0.25); border-radius: 0.25rem;
      padding: 0.25rem 0.5rem; font-size: 0.75rem;
      outline: none; cursor: pointer;
      option { background: var(--sapShellColor, #354a5e); color: #fff; }
    }

    /* Avatar */
    .avatar-wrapper { position: relative; cursor: pointer; }
    .user-avatar {
      width: 1.75rem; height: 1.75rem; border-radius: 50%;
      background: rgba(255,255,255,0.2); display: flex;
      align-items: center; justify-content: center;
      font-size: 0.6875rem; font-weight: 700; color: #fff;
      border: 1.5px solid rgba(255,255,255,0.35);
      transition: background 0.15s;
    }
    .avatar-wrapper:hover .user-avatar { background: rgba(255,255,255,0.3); }
    .avatar-menu {
      position: absolute; top: calc(100% + 0.5rem); right: 0;
      background: var(--sapBaseColor, #fff); border-radius: 0.375rem;
      box-shadow: 0 4px 16px rgba(0,0,0,0.15);
      min-width: 140px; overflow: hidden; z-index: 100;
      animation: slideUp 0.15s ease-out;
    }
    .avatar-menu-item {
      padding: 0.5rem 0.875rem; font-size: 0.8125rem;
      color: var(--sapTextColor, #32363a); cursor: pointer;
      transition: background 0.1s;
    }
    .avatar-menu-item:hover { background: var(--sapList_Hover_Background, #f5f5f5); }

    /* Layout */
    .shell-body { display: flex; flex: 1; overflow: hidden; position: relative; }
    .side-nav {
      width: 220px; background: var(--sapBaseColor, #fff);
      border-right: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      display: flex; flex-direction: column;
      flex-shrink: 0; overflow-y: auto;
      transition: transform 0.25s ease;
    }
    .nav-list { list-style: none; padding: 0.5rem 0; margin: 0; flex: 1; }
    .nav-link {
      display: flex; align-items: center; gap: 0.625rem;
      padding: 0.5rem 1rem; margin: 0.125rem 0.5rem;
      color: var(--sapTextColor, #32363a); text-decoration: none;
      font-size: 0.8125rem; border-radius: 0.375rem;
      border-left: 3px solid transparent;
      transition: background 0.15s ease, border-color 0.2s ease, color 0.15s ease;
    }
    .nav-link:hover {
      background: var(--sapList_Hover_Background, #f5f5f5);
    }
    .nav-link.nav-link--active {
      background: var(--sapList_SelectionBackgroundColor, #e8f2ff);
      border-left-color: var(--sapBrandColor, #0854a0);
      color: var(--sapBrandColor, #0854a0); font-weight: 600;
    }
    .nav-icon { font-size: 1.125rem; width: 1.25rem; text-align: center; }
    .nav-footer {
      padding: 0.75rem;
      border-top: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
    }
    .api-key-row { display: flex; gap: 0.375rem; }
    .api-key-input {
      flex: 1; padding: 0.3rem 0.5rem; font-size: 0.75rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem; background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a); min-width: 0;
    }
    .api-key-save {
      padding: 0.3rem 0.6rem; font-size: 0.75rem;
      background: var(--sapBrandColor, #0854a0); color: #fff;
      border: none; border-radius: 0.25rem; cursor: pointer;
      white-space: nowrap;
      &:hover { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }
    .shell-content { flex: 1; overflow-y: auto; }
    .sidebar-backdrop { display: none; }

    /* Animations */
    @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
    @keyframes slideUp {
      from { transform: translateY(0.5rem); opacity: 0; }
      to   { transform: translateY(0); opacity: 1; }
    }

    /* Responsive */
    @media (max-width: 768px) {
      .hamburger-btn { display: flex; }
      .side-nav {
        position: absolute; top: 0; bottom: 0; left: 0; z-index: 50;
        transform: translateX(-100%);
        box-shadow: 4px 0 16px rgba(0,0,0,0.1);
      }
      .side-nav--open { transform: translateX(0); }
      .sidebar-backdrop {
        display: block; position: absolute; inset: 0; z-index: 40;
        background: rgba(0,0,0,0.3);
      }
      .search-trigger kbd { display: none; }
    }
  `],
})
export class ShellComponent {
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);
  readonly userSettings = inject(UserSettingsService);
  readonly store = inject(AppStore);

  readonly navItems: NavItem[] = [
    { label: 'Dashboard', icon: '📊', route: '/dashboard' },
    { label: 'Pipeline', icon: '🔄', route: '/pipeline' },
    { label: 'Data Explorer', icon: '📂', route: '/data-explorer' },
    { label: 'Data Cleaning', icon: '🧹', route: '/data-cleaning' },
    { label: 'Model Optimizer', icon: '🤖', route: '/model-optimizer' },
    { label: 'Registry', icon: '🏷️', route: '/registry' },
    { label: 'HippoCPP', icon: '🕸', route: '/hippocpp' },
    { label: 'Chat', icon: '💬', route: '/chat' },
    { label: 'A/B Compare', icon: '⚖️', route: '/compare' },
  ];

  readonly version = '1.0.0';
  apiKeyDraft = this.auth.token() ?? '';

  // --- UI State ---
  showSearch = signal(false);
  searchQuery = signal('');
  selectedIndex = signal(0);
  sidebarOpen = signal(false);
  avatarMenuOpen = signal(false);

  @ViewChild('searchInput') searchInput!: ElementRef<HTMLInputElement>;

  searchResults = computed(() => {
    const q = this.searchQuery().toLowerCase().trim();
    if (!q) return this.navItems;
    return this.navItems.filter(i =>
      i.label.toLowerCase().includes(q) ||
      i.route.toLowerCase().includes(q)
    );
  });

  @HostListener('window:keydown', ['$event'])
  handleKeyboardEvent(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) && event.key === 'k') {
      event.preventDefault();
      this.toggleSearch();
    } else if (event.key === 'Escape' && this.showSearch()) {
      this.closeSearch();
    }
  }

  toggleSearch() {
    this.showSearch.set(!this.showSearch());
    if (this.showSearch()) {
      this.selectedIndex.set(0);
      setTimeout(() => this.searchInput?.nativeElement?.focus(), 50);
    } else {
      this.searchQuery.set('');
    }
  }

  closeSearch() {
    this.showSearch.set(false);
    this.searchQuery.set('');
    this.selectedIndex.set(0);
  }

  moveSelection(delta: number) {
    const len = this.searchResults().length;
    if (!len) return;
    this.selectedIndex.set((this.selectedIndex() + delta + len) % len);
  }

  navigateToSelected() {
    const results = this.searchResults();
    const idx = this.selectedIndex();
    if (results.length > 0 && idx < results.length) {
      this.navigateFromSearch(results[idx].route);
    }
  }

  navigateFromSearch(route: string) {
    this.router.navigate([route]);
    this.closeSearch();
  }

  saveApiKey(): void {
    if (this.apiKeyDraft.trim()) {
      this.auth.setToken(this.apiKeyDraft.trim());
    } else {
      this.auth.clearToken();
    }
  }

  logout(): void {
    this.auth.clearToken();
    this.router.navigate(['/login']);
  }
}

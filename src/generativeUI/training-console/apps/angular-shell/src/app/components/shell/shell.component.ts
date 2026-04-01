import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, HostListener, signal, computed, ElementRef, ViewChild } from '@angular/core';
import { RouterOutlet, Router, NavigationEnd } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
import { AuthService } from '../../services/auth.service';
import { UserSettingsService } from '../../services/user-settings.service';
import { AppStore } from '../../store/app.store';
import { filter } from 'rxjs/operators';
import { toSignal } from '@angular/core/rxjs-interop';

interface NavItem {
  label: string;
  icon: string;
  route: string;
}

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [RouterOutlet, FormsModule, Ui5WebcomponentsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <!-- Search Dialog -->
    @if (showSearch()) {
      <div class="search-overlay" (click)="closeSearch()">
        <div class="search-modal" (click)="$event.stopPropagation()">
          <div class="search-header-container">
            <ui5-icon name="search" class="search-icon"></ui5-icon>
            <input #searchInput type="text" class="search-input"
              [ngModel]="searchQuery()" (ngModelChange)="searchQuery.set($event)"
              placeholder="Search pages... (e.g. Pipeline, Chat)"
              (keydown.enter)="navigateToSelected()"
              (keydown.escape)="closeSearch()"
              (keydown.arrowDown)="moveSelection(1); $event.preventDefault()"
              (keydown.arrowUp)="moveSelection(-1); $event.preventDefault()" />
            <ui5-tag design="Set2" color-scheme="6">ESC</ui5-tag>
          </div>
          <ui5-list class="search-results-list">
            @for (res of searchResults(); track res.route; let i = $index) {
              <ui5-list-item-standard
                icon="{{ res.icon }}"
                [attr.selected]="i === selectedIndex() ? true : null"
                (click)="navigateFromSearch(res.route)"
                (mouseenter)="selectedIndex.set(i)">
                {{ res.label }}
              </ui5-list-item-standard>
            }
          </ui5-list>
          @if (searchResults().length === 0) {
            <div class="search-empty">No results found matching "{{ searchQuery() }}"</div>
          }
        </div>
      </div>
    }

    <!-- Shellbar -->
    <ui5-shellbar
      primary-title="Training Console"
      secondary-title="v{{ version }}"
      show-search-field="false">

      <!-- WS Status badge -->
      @if (store.wsState() === 'connected') {
        <ui5-tag slot="startButton" design="Positive">Live</ui5-tag>
      } @else if (store.wsState() === 'reconnecting' || store.wsState() === 'connecting') {
        <ui5-tag slot="startButton" design="Critical">Reconnecting...</ui5-tag>
      } @else {
        <ui5-tag slot="startButton" design="Negative">Offline</ui5-tag>
      }

      <!-- Search button -->
      <ui5-shellbar-item
        icon="search"
        text="Search (⌘K)"
        (item-click)="toggleSearch()">
      </ui5-shellbar-item>

      <!-- Mode selector in profile slot area -->
      <ui5-select slot="profile" style="min-width:130px"
        (change)="onModeChange($event)">
        <ui5-option value="novice" [attr.selected]="userSettings.mode() === 'novice' ? true : null">Novice</ui5-option>
        <ui5-option value="intermediate" [attr.selected]="userSettings.mode() === 'intermediate' ? true : null">Intermediate</ui5-option>
        <ui5-option value="expert" [attr.selected]="userSettings.mode() === 'expert' ? true : null">Expert</ui5-option>
      </ui5-select>

      <!-- Avatar with menu -->
      <ui5-avatar slot="profile" initials="TC" size="XS" interactive
        (click)="avatarMenuOpen.set(!avatarMenuOpen())">
      </ui5-avatar>
    </ui5-shellbar>

    @if (avatarMenuOpen()) {
      <div class="avatar-menu-backdrop" (click)="avatarMenuOpen.set(false)">
        <div class="avatar-menu" (click)="$event.stopPropagation()">
          <ui5-list>
            <ui5-list-item-standard icon="log" (click)="logout()">Sign out</ui5-list-item-standard>
          </ui5-list>
        </div>
      </div>
    }

    <!-- Navigation Layout with Side Navigation -->
    <div class="shell-body">
      <ui5-side-navigation class="side-nav" [class.side-nav--open]="sidebarOpen()">
        @for (item of navItems; track item.route) {
          <ui5-side-navigation-item
            text="{{ item.label }}"
            icon="{{ item.icon }}"
            [attr.selected]="isActiveRoute(item.route) ? true : null"
            (click)="navigateTo(item.route)">
          </ui5-side-navigation-item>
        }
        <ui5-side-navigation-item slot="fixedItems" text="API Key" icon="key">
        </ui5-side-navigation-item>
      </ui5-side-navigation>

      @if (sidebarOpen()) {
        <div class="sidebar-backdrop" (click)="sidebarOpen.set(false)"></div>
      }

      <main class="shell-content" id="main-content">
        <router-outlet />
      </main>
    </div>
  `,
  styles: [`
    :host {
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
    .search-icon { margin-right: 0.75rem; opacity: 0.6; }
    .search-input {
      flex: 1; border: none; outline: none;
      font-size: 1rem; background: transparent;
      color: var(--sapTextColor, #32363a);
    }
    .search-results-list { max-height: 360px; overflow-y: auto; }
    .search-empty {
      padding: 2rem 1.25rem; text-align: center;
      color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.875rem;
    }

    /* Avatar menu */
    .avatar-menu-backdrop {
      position: fixed; inset: 0; z-index: 500;
    }
    .avatar-menu {
      position: fixed; top: 2.75rem; right: 0.5rem;
      background: var(--sapBaseColor, #fff); border-radius: 0.375rem;
      box-shadow: 0 4px 16px rgba(0,0,0,0.15);
      min-width: 160px; overflow: hidden; z-index: 501;
      animation: slideUp 0.15s ease-out;
    }

    /* Layout */
    .shell-body { display: flex; flex: 1; overflow: hidden; position: relative; }
    .side-nav { flex-shrink: 0; }
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
    }
  `],
})
export class ShellComponent {
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);
  readonly userSettings = inject(UserSettingsService);
  readonly store = inject(AppStore);

  readonly navItems: NavItem[] = [
    { label: 'Dashboard', icon: 'home', route: '/dashboard' },
    { label: 'Pipeline', icon: 'process', route: '/pipeline' },
    { label: 'Data Explorer', icon: 'database', route: '/data-explorer' },
    { label: 'Data Cleaning', icon: 'refresh', route: '/data-cleaning' },
    { label: 'Model Optimizer', icon: 'ai', route: '/model-optimizer' },
    { label: 'Registry', icon: 'shipping-status', route: '/registry' },
    { label: 'HippoCPP', icon: 'chain-link', route: '/hippocpp' },
    { label: 'Chat', icon: 'message-popup', route: '/chat' },
    { label: 'A/B Compare', icon: 'compare', route: '/compare' },
  ];

  readonly version = '1.0.0';
  apiKeyDraft = this.auth.token() ?? '';

  // Track current URL for active route highlighting
  private readonly currentUrl = toSignal(
    this.router.events.pipe(
      filter((e): e is NavigationEnd => e instanceof NavigationEnd)
    ),
    { initialValue: null }
  );

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

  isActiveRoute(route: string): boolean {
    return this.router.url === route || this.router.url.startsWith(route + '/');
  }

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

  navigateTo(route: string) {
    this.router.navigate([route]);
  }

  onModeChange(event: Event) {
    const select = event.target as HTMLElement;
    const selectedOption = (select as any).selectedOption;
    if (selectedOption) {
      this.userSettings.setMode(selectedOption.value);
    }
  }

  saveApiKey(): void {
    if (this.apiKeyDraft.trim()) {
      this.auth.setToken(this.apiKeyDraft.trim());
    } else {
      this.auth.clearToken();
    }
  }

  logout(): void {
    this.avatarMenuOpen.set(false);
    this.auth.clearToken();
    this.router.navigate(['/login']);
  }
}

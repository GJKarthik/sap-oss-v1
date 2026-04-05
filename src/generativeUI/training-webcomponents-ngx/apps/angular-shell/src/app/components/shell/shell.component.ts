import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, HostListener, signal, computed, ElementRef, ViewChild, OnInit, OnDestroy } from '@angular/core';
import { RouterOutlet, Router } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { UserSettingsService } from '../../services/user-settings.service';
import { AppStore } from '../../store/app.store';
import { DiagnosticsService } from '../../services/diagnostics.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { ApiService } from '../../services/api.service';
import '@ui5/webcomponents-fiori/dist/ShellBar.js';
import '@ui5/webcomponents-fiori/dist/ShellBarItem.js';
import '@ui5/webcomponents/dist/Tag.js';
import '@ui5/webcomponents/dist/Popover.js';
import '@ui5/webcomponents/dist/List.js';
import '@ui5/webcomponents/dist/ListItemStandard.js';

interface NavItem {
  label: string;
  icon: string;
  route: string;
}

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [RouterOutlet, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="shell-layout" [class.rtl]="i18n.isRtl()">
      @if (showSearch()) {
        <div class="search-overlay" (click)="closeSearch()">
          <div class="search-modal" (click)="$event.stopPropagation()">
            <div class="search-header-container">
              <ui5-icon class="search-icon" name="search"></ui5-icon>
              <input #searchInput type="text" class="search-input" [ngModel]="searchQuery()" (ngModelChange)="searchQuery.set($event)" [placeholder]="i18n.t('app.search.placeholder')" (keydown.enter)="selectFirstResult()" (keydown.escape)="closeSearch()" />
              <button class="search-close-btn" (click)="closeSearch()">{{ i18n.t('app.search.esc') }}</button>
            </div>
            <div class="search-results-list">
              @for (res of searchResults(); track res.route) {
                <div class="search-item" (click)="navigateFromSearch(res.route)">
                  <span class="nav-icon" aria-hidden="true">{{ res.icon }}</span>
                  <span class="nav-label">{{ res.label }}</span>
                  <span class="search-shortcut">{{ i18n.t('app.search.enter') }}</span>
                </div>
              }
              @if (searchResults().length === 0) {
                <div class="search-empty">{{ i18n.t('app.search.noResults') }} "{{searchQuery()}}"</div>
              }
            </div>
          </div>
        </div>
      }

      <ui5-shellbar
        [attr.primary-title]="i18n.t('app.title')"
        [attr.secondary-title]="i18n.t('app.subtitle')"
        show-notifications
        notifications-count="3"
        show-product-switch
        (logo-click)="navigateTo('/dashboard')"
        (notifications-click)="openNotifications()"
        (product-switch-click)="openProducts($event)"
      >
        @for (item of navItems; track item.route) {
          <ui5-shellbar-item
            [attr.icon]="item.icon"
            [attr.text]="item.label"
            count=""
            (item-click)="navigateTo(item.route)"
          ></ui5-shellbar-item>
        }
      </ui5-shellbar>

      <ui5-popover #productPopover [attr.header-text]="i18n.t('product.switcher')" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
        <ui5-list (item-click)="onProductSelect($event)">
          <ui5-li icon="home" data-url="/aifabric/">{{ i18n.t('product.aiFabric') }}</ui5-li>
          <ui5-li icon="process" data-url="/training/" selected>{{ i18n.t('product.training') }}</ui5-li>
          <ui5-li icon="BusinessSuiteInAppSymbols/product-switch" data-url="/sac/">{{ i18n.t('product.sac') }}</ui5-li>
          <ui5-li icon="grid" data-url="/ui5/">{{ i18n.t('product.joule') }}</ui5-li>
        </ui5-list>
      </ui5-popover>

      <nav class="app-nav" role="navigation" aria-label="Training navigation">
        @for (item of navItems; track item.route) {
          <button
            class="app-nav__item"
            [class.app-nav__item--active]="isActive(item.route)"
            (click)="navigateTo(item.route)">
            {{ item.label }}
          </button>
        }

        <div class="app-nav__spacer"></div>

        <ui5-tag [design]="wsTagDesign()">{{ wsLabel() }}</ui5-tag>
        <span class="model-status-indicator" [class.model-online]="arabicModelOnline()" [class.model-offline]="!arabicModelOnline()" [title]="arabicModelOnline() ? i18n.t('chat.modelOnline') : i18n.t('chat.modelOffline')">{{ arabicModelOnline() ? '🟢' : '🔴' }} {{ i18n.t('chat.arabicFinanceModel') }}</span>
        <button class="header-btn lang-toggle" (click)="i18n.toggleLanguage()">{{ i18n.t('app.language') }}</button>
        <button class="header-btn" (click)="showDiagnostics.set(!showDiagnostics())" [title]="i18n.t('app.diagnostics')">
          {{ i18n.t('app.diagnostics') }}
        </button>
        <select class="mode-select" [ngModel]="userSettings.mode()" (ngModelChange)="userSettings.setMode($event)">
          <option value="novice">{{ i18n.t('mode.novice') }}</option>
          <option value="intermediate">{{ i18n.t('mode.intermediate') }}</option>
          <option value="expert">{{ i18n.t('mode.expert') }}</option>
        </select>

        @if (i18n.currentLang() === 'ar') {
          <select class="mode-select" [ngModel]="userSettings.calendar()" (ngModelChange)="userSettings.setCalendar($event)">
            <option value="gregorian">{{ i18n.t('gregorianLabel') }}</option>
            <option value="hijri">{{ i18n.t('hijriLabel') }}</option>
          </select>
          <select class="mode-select" [ngModel]="userSettings.numbering()" (ngModelChange)="userSettings.setNumbering($event)">
            <option value="latn">123</option>
            <option value="arab">١٢٣</option>
          </select>
        }

        <button class="header-btn" (click)="logout()" [title]="i18n.t('app.signOut')">{{ i18n.t('app.signOut') }}</button>
      </nav>

      @if (showDiagnostics()) {
        <aside class="diagnostics-drawer" [attr.aria-label]="i18n.t('diagnostics.title')">
          <div class="diagnostics-header">
            <strong>{{ i18n.t('diagnostics.title') }}</strong>
            <button class="header-btn" (click)="showDiagnostics.set(false)">{{ i18n.t('diagnostics.close') }}</button>
          </div>
          <div class="diagnostics-list">
            @for (entry of diagnostics.entries(); track entry.route) {
              <div class="diagnostics-row">
                <div class="route">{{ entry.route }}</div>
                <div class="meta">{{ entry.method }} · {{ entry.status }}</div>
                <div class="meta">{{ i18n.t('diagnostics.latency') }}: {{ entry.latencyMs }}ms</div>
                <div class="meta">{{ i18n.t('diagnostics.correlation') }}: {{ entry.correlationId }}</div>
                @if (entry.lastError !== '-') {
                  <div class="error">{{ i18n.t('diagnostics.error') }}: {{ entry.lastError }}</div>
                }
              </div>
            }
            @if (!diagnostics.entries().length) {
              <div class="search-empty">{{ i18n.t('diagnostics.noRequests') }}</div>
            }
          </div>
        </aside>
      }

      <main class="shell-content" id="main-content">
        <router-outlet />
      </main>
    </div>
  `,
  styles: [
    `
      .shell-layout {
        display: flex;
        flex-direction: column;
        height: 100vh;
        overflow: hidden;
        background: var(--sapBackgroundColor, #f5f6f7);
      }

      .search-overlay {
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        background: rgba(0, 0, 0, 0.4);
        backdrop-filter: blur(2px);
        z-index: 1000;
        display: flex;
        justify-content: center;
        align-items: flex-start;
        padding-top: 10vh;
      }
      .search-modal {
        width: 100%;
        max-width: 600px;
        background: var(--sapBaseColor, #fff);
        border-radius: 0.5rem;
        box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2);
        overflow: hidden;
        display: flex;
        flex-direction: column;
      }
      .search-header-container {
        display: flex;
        align-items: center;
        padding: 0.75rem 1.25rem;
        border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      }
      .search-icon { font-size: 1.2rem; margin-inline-end: 0.75rem; }
      .search-input {
        flex: 1;
        border: none;
        outline: none;
        font-size: 1.125rem;
        background: transparent;
        color: var(--sapTextColor, #32363a);
      }
      .search-close-btn {
        background: var(--sapGroup_TitleBorderColor, #d9d9d9); 
        border: none; padding: 0.25rem 0.5rem; border-radius: 0.25rem;
        font-size: 0.75rem; color: var(--sapTextColor, #32363a); cursor: pointer; font-weight: 600;
      }
      .search-results-list {
        max-height: 400px;
        overflow-y: auto;
        padding: 0.5rem 0;
      }
      .search-item {
        display: flex;
        align-items: center;
        padding: 0.75rem 1.25rem;
        cursor: pointer;
        transition: background 0.1s;
      }
      .search-item:hover, .search-item.active {
        background: var(--sapList_Hover_Background, #f5f5f5);
      }
      .search-item .nav-icon { margin-inline-end: 0.75rem; }
      .search-shortcut {
        margin-inline-start: auto;
        color: var(--sapGroup_TitleBorderColor, #d9d9d9);
        font-size: 1.1rem;
        opacity: 0;
      }
      .search-item:hover .search-shortcut { opacity: 1; }
      .search-empty {
        padding: 1.5rem;
        text-align: center;
        color: var(--sapField_BorderColor, #89919a);
      }

      .header-btn {
        background: #fff;
        border: 1px solid var(--sapField_BorderColor, #89919a);
        color: var(--sapTextColor, #32363a);
        padding: 0.25rem 0.75rem;
        border-radius: 0.25rem;
        cursor: pointer;
        font-size: 0.8125rem;
        transition: background 0.15s;

        &:hover {
          background: var(--sapList_Hover_Background, #f5f5f5);
        }
      }

      .app-nav {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        padding: 0.5rem 1rem;
        background: #fff;
        border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      }

      .app-nav__item {
        border: none;
        background: transparent;
        color: var(--sapTextColor, #32363a);
        padding: 0.375rem 0.625rem;
        border-radius: 0.375rem;
        font-size: 0.8125rem;
        cursor: pointer;
      }

      .app-nav__item:hover {
        background: var(--sapList_Hover_Background, #f5f5f5);
      }

      .app-nav__item--active {
        background: var(--sapList_SelectionBackgroundColor, #e8f2ff);
        color: var(--sapBrandColor, #0854a0);
        font-weight: 600;
      }

      .app-nav__spacer {
        flex: 1;
      }

      .mode-select {
        background: #fff;
        color: var(--sapTextColor, #32363a);
        border: 1px solid var(--sapField_BorderColor, #89919a);
        border-radius: 0.25rem;
        padding: 0.25rem 0.5rem;
        font-size: 0.8125rem;
        outline: none;
        cursor: pointer;

        option {
          background: #fff;
          color: var(--sapTextColor, #32363a);
        }
      }

      .shell-content {
        flex: 1;
        overflow-y: auto;
      }

      .diagnostics-drawer {
        border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
        background: #fff;
        padding: 0.75rem 1rem;
      }

      .diagnostics-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        margin-bottom: 0.5rem;
      }

      .diagnostics-list {
        max-height: 180px;
        overflow-y: auto;
        display: grid;
        gap: 0.5rem;
      }

      .diagnostics-row {
        border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
        border-radius: 0.375rem;
        padding: 0.5rem 0.625rem;
        background: var(--sapTile_Background, #fff);
      }

      .route {
        font-size: 0.8125rem;
        font-weight: 600;
        color: var(--sapTextColor, #32363a);
      }

      .meta {
        font-size: 0.75rem;
        color: var(--sapContent_LabelColor, #6a6d70);
      }

      .error {
        margin-top: 0.2rem;
        font-size: 0.75rem;
        color: var(--sapNegativeColor, #b00);
      }

      .model-status-indicator {
        font-size: 0.75rem;
        font-weight: 500;
        padding: 0.2rem 0.5rem;
        border-radius: 0.25rem;
        white-space: nowrap;
      }

      .model-online {
        color: var(--sapPositiveColor, #107e3e);
      }

      .model-offline {
        color: var(--sapNegativeColor, #b00);
        opacity: 0.8;
      }

      .lang-toggle {
        font-weight: 600;
        min-width: 5rem;
        text-align: center;
      }

      :host-context([dir='rtl']) .app-nav,
      .rtl .app-nav {
        flex-direction: row-reverse;
      }

      :host-context([dir='rtl']) .app-nav__spacer ~ *,
      .rtl .app-nav__spacer ~ * {
        direction: rtl;
      }
    `,
  ],
})
export class ShellComponent implements OnInit, OnDestroy {
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);
  private readonly toast = inject(ToastService);
  private readonly api = inject(ApiService);
  readonly diagnostics = inject(DiagnosticsService);
  readonly userSettings = inject(UserSettingsService);
  readonly store = inject(AppStore);
  readonly i18n = inject(I18nService);
  private readonly destroy$ = new Subject<void>();
  readonly arabicModelOnline = signal(false);

  get navItems(): NavItem[] {
    return [
      { label: this.i18n.t('nav.dashboard'), icon: 'home', route: '/dashboard' },
      { label: this.i18n.t('nav.pipeline'), icon: 'process', route: '/pipeline' },
      { label: this.i18n.t('nav.dataExplorer'), icon: 'folder', route: '/data-explorer' },
      { label: this.i18n.t('nav.dataCleaning'), icon: 'edit', route: '/data-cleaning' },
      { label: this.i18n.t('nav.modelOptimizer'), icon: 'machine', route: '/model-optimizer' },
      { label: this.i18n.t('nav.registry'), icon: 'tags', route: '/registry' },
      { label: this.i18n.t('nav.hippocpp'), icon: 'chain-link', route: '/hippocpp' },
      { label: this.i18n.t('nav.chat'), icon: 'discussion-2', route: '/chat' },
      { label: this.i18n.t('nav.compare'), icon: 'compare', route: '/compare' },
      { label: this.i18n.t('nav.documentOcr'), icon: 'document', route: '/document-ocr' },
      { label: this.i18n.t('nav.semanticSearch'), icon: 'search', route: '/semantic-search' },
      { label: this.i18n.t('nav.analytics'), icon: 'lead', route: '/analytics' },
      { label: this.i18n.t('nav.arabicWizard'), icon: 'learning-assistant', route: '/arabic-wizard' },
      { label: this.i18n.t('nav.workflow'), icon: 'workflow-tasks', route: '/workflow' },
    ];
  }

  readonly version = '1.0.0';
  apiKeyDraft = this.auth.token() ?? '';

  ngOnInit(): void {
    this.checkArabicModelStatus();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  private checkArabicModelStatus(): void {
    this.api.getModelStatus()
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (resp) => this.arabicModelOnline.set(resp.status === 'ready' || resp.status === 'online'),
        error: () => this.arabicModelOnline.set(false),
      });
  }

  // --- Search State & Logic ---
  showSearch = signal(false);
  showDiagnostics = signal(false);
  searchQuery = signal('');
  
  @ViewChild('searchInput') searchInput!: ElementRef<HTMLInputElement>;
  @ViewChild('productPopover') productPopover!: ElementRef<any>;

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
      setTimeout(() => this.searchInput?.nativeElement?.focus(), 50);
    } else {
      this.searchQuery.set('');
    }
  }

  closeSearch() {
    this.showSearch.set(false);
    this.searchQuery.set('');
  }

  navigateFromSearch(route: string) {
    this.router.navigate([route]);
    this.closeSearch();
  }

  selectFirstResult() {
    const results = this.searchResults();
    if (results.length > 0) {
      this.navigateFromSearch(results[0].route);
    }
  }
  // -------------------------

  isActive(route: string): boolean {
    const url = this.router.url.split('?')[0];
    return url.startsWith(route);
  }

  navigateTo(route: string): void {
    this.router.navigate([route]);
  }

  wsLabel(): string {
    switch (this.store.wsState()) {
      case 'connected':
        return this.i18n.t('app.live');
      case 'reconnecting':
      case 'connecting':
        return this.i18n.t('app.reconnecting');
      default:
        return this.i18n.t('app.offline');
    }
  }

  wsTagDesign(): 'Positive' | 'Critical' | 'Negative' {
    switch (this.store.wsState()) {
      case 'connected':
        return 'Positive';
      case 'reconnecting':
      case 'connecting':
        return 'Critical';
      default:
        return 'Negative';
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
    this.auth.clearToken();
    this.router.navigate(['/login']);
  }

  openNotifications(): void {
    this.toast.info(this.i18n.t('app.noNotifications'));
  }

  openProducts(event: any): void {
    const popover = this.productPopover?.nativeElement;
    const target = event?.detail?.targetRef;
    if (popover && target) {
      if (typeof popover.showAt === 'function') {
        popover.showAt(target);
      } else {
        popover.opener = target;
        popover.open = true;
      }
    }
  }

  onProductSelect(event: any): void {
    const url = event.detail.item.getAttribute('data-url');
    if (url) {
      window.location.href = url;
    }
  }
}

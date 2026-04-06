import {
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  ElementRef,
  HostListener,
  OnDestroy,
  OnInit,
  ViewChild,
  computed,
  inject,
  signal,
} from '@angular/core';
import { NavigationEnd, Router, RouterOutlet } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Subject, filter, takeUntil } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { UserSettingsService } from '../../services/user-settings.service';
import { AppStore } from '../../store/app.store';
import { DiagnosticsService } from '../../services/diagnostics.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { ApiService } from '../../services/api.service';
import '@ui5/webcomponents-fiori/dist/ShellBar.js';
import '@ui5/webcomponents-fiori/dist/ShellBarItem.js';
import '@ui5/webcomponents/dist/Avatar.js';
import '@ui5/webcomponents/dist/Switch.js';
import '@ui5/webcomponents/dist/Tag.js';
import '@ui5/webcomponents/dist/Popover.js';
import '@ui5/webcomponents/dist/List.js';
import '@ui5/webcomponents/dist/ListItemStandard.js';
import '@ui5/webcomponents-icons-business-suite/dist/AllIcons.js';
import {
  TRAINING_NAV_GROUPS,
  TRAINING_ROUTE_LINKS,
  TRAINING_EXPERT_ROUTES,
  TrainingNavGroup,
  TrainingRouteGroupId,
  TrainingRouteLink,
  resolveTrainingGroup,
} from '../../app.navigation';

type Ui5PopoverElement = HTMLElement & {
  showAt?: (target: HTMLElement) => void;
  opener?: HTMLElement;
  open?: boolean;
};

type ShellbarClickEvent = Event & {
  detail?: {
    targetRef?: HTMLElement | null;
  };
};

type ProductSelectEvent = Event & {
  detail?: {
    item?: Element | null;
  };
};

interface TranslatedNavGroup extends TrainingNavGroup {
  label: string;
}

interface TranslatedRouteLink extends TrainingRouteLink {
  label: string;
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
          <div class="search-modal" (click)="$event.stopPropagation()" (keydown)="trapSearchFocus($event)">
            <div class="search-header-container">
              <ui5-icon class="search-icon" name="search"></ui5-icon>
              <input #searchInput type="text" class="search-input" name="shellSearch" [ngModel]="searchQuery()" (ngModelChange)="searchQuery.set($event)" [placeholder]="i18n.t('app.search.placeholder')" (keydown.enter)="selectFirstResult()" (keydown.escape)="closeSearch()" />
              <button class="search-close-btn" (click)="closeSearch()">{{ i18n.t('app.search.esc') }}</button>
            </div>
            <div class="search-results-list">
              @for (res of searchResults(); track res.path) {
                <div class="search-item" (click)="navigateFromSearch(res.path)">
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
        [attr.notifications-count]="notificationCount()"
        show-product-switch
        (logo-click)="navigateTo('/dashboard')"
        (notifications-click)="openNotifications()"
        (product-switch-click)="openProducts($event)"
        (profile-click)="openProfile($event)"
      >
        <ui5-avatar slot="profile" icon="employee"></ui5-avatar>
      </ui5-shellbar>

      <ui5-popover #profilePopover [attr.header-text]="i18n.t('app.profile')" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
        <div class="profile-panel">
          <div class="profile-panel__section">
            <div class="profile-panel__title">{{ i18n.t('app.workspaceSettings') }}</div>
            <label class="profile-panel__label" for="shellMode">{{ i18n.t('app.modeSelect') }}</label>
            <select
              id="shellMode"
              class="mode-select mode-select--block"
              name="shellMode"
              [ngModel]="userSettings.mode()"
              (ngModelChange)="userSettings.setMode($event)"
              [attr.aria-label]="i18n.t('app.modeSelect')">
              <option value="novice">{{ i18n.t('mode.novice') }}</option>
              <option value="intermediate">{{ i18n.t('mode.intermediate') }}</option>
              <option value="expert">{{ i18n.t('mode.expert') }}</option>
            </select>

            <label class="profile-panel__label" for="shellLang">{{ i18n.t('app.languageSelect') }}</label>
            <select
              id="shellLang"
              class="mode-select mode-select--block"
              name="shellLang"
              [ngModel]="i18n.currentLang()"
              (ngModelChange)="i18n.setLanguage($event)"
              [attr.aria-label]="i18n.t('app.languageSelect')">
              <option value="en">English</option>
              <option value="ar">العربية (Arabic)</option>
              <option value="fr">Français (French)</option>
            </select>
          </div>

          <div class="profile-panel__section">
            <div class="profile-panel__title">{{ i18n.t('app.systemStatus') }}</div>
            <div class="profile-status">
              <ui5-tag [design]="wsTagDesign()">{{ wsLabel() }}</ui5-tag>
              <span
                class="model-status-indicator"
                [class.model-online]="arabicModelOnline()"
                [class.model-offline]="!arabicModelOnline()"
                [title]="arabicModelOnline() ? i18n.t('chat.modelOnline') : i18n.t('chat.modelOffline')"
                role="status">
                <span class="model-status-dot" aria-hidden="true"></span>
                {{ i18n.t('chat.arabicFinanceModel') }}
              </span>
            </div>

            <button class="header-btn header-btn--block" (click)="toggleDiagnostics()">
              {{ i18n.t('app.diagnostics') }}
            </button>

            <ui5-button design="Transparent" icon="log" (click)="logout()" style="width: 100%;">
              {{ i18n.t('app.signOut') }}
            </ui5-button>
          </div>
        </div>
      </ui5-popover>

      <ui5-popover #productPopover [attr.header-text]="i18n.t('product.switcher')" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
        <ui5-list (item-click)="onProductSelect($event)">
          <ui5-li icon="home" data-url="/aifabric/">{{ i18n.t('product.aiFabric') }}</ui5-li>
          <ui5-li icon="process" data-url="/training/" selected>{{ i18n.t('product.training') }}</ui5-li>
          <ui5-li icon="product" data-url="/sac/">{{ i18n.t('product.sac') }}</ui5-li>
          <ui5-li icon="grid" data-url="/ui5/">{{ i18n.t('product.joule') }}</ui5-li>
        </ui5-list>
      </ui5-popover>

      <nav class="app-nav" role="navigation" [attr.aria-label]="i18n.t('app.navigation')">
        @for (group of navGroups(); track group.id) {
          <button
            class="app-nav__item"
            [class.app-nav__item--active]="isGroupActive(group.id)"
            (click)="navigateTo(group.defaultPath)">
            {{ group.label }}
          </button>
        }
        <button
          #moreBtn
          class="app-nav__item"
          [class.app-nav__item--active]="isGroupActive('expert')"
          (click)="openExpertPopover()">
          {{ i18n.t('navGroup.more') }} <span class="more-chevron" [class.more-chevron--open]="isGroupActive('expert')">▾</span>
        </button>
      </nav>

      <ui5-popover #expertPopover [attr.header-text]="i18n.t('navGroup.more')" placement-type="Bottom">
        <ui5-list>
          @for (route of expertRoutes(); track route.path) {
            <ui5-li [icon]="route.icon" (click)="navigateTo(route.path); closeExpertPopover()">
              {{ route.label }}
            </ui5-li>
          }
        </ui5-list>
      </ui5-popover>

      @if (activeGroupRoutes().length > 1) {
        <section class="section-nav" [attr.aria-label]="i18n.t('app.sectionRoutes')">
          <div class="section-nav__label">{{ activeGroup().label }}</div>
          <div class="section-nav__items">
            @for (route of activeGroupRoutes(); track route.path) {
              <button
                class="section-nav__item"
                [class.section-nav__item--active]="isRouteActive(route.path)"
                (click)="navigateTo(route.path)">
                {{ route.label }}
              </button>
            }
          </div>
        </section>
      }

      @if (showStatusNotice()) {
        <section class="status-banner" role="status" aria-live="polite">
          @if (store.wsState() !== 'connected') {
            <ui5-tag [design]="wsTagDesign()">{{ wsLabel() }}</ui5-tag>
          }
          @if (!arabicModelOnline()) {
            <span
              class="model-status-indicator model-offline"
              [title]="i18n.t('chat.modelOffline')"
              role="status">
              <span class="model-status-dot" aria-hidden="true"></span>
              {{ i18n.t('chat.arabicFinanceModel') }}
            </span>
          }
        </section>
      }

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
        display: inline-flex;
        align-items: center;
        justify-content: center;
        background: var(--sapBaseColor, #fff);
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

      .header-btn--block {
        width: 100%;
      }

      .profile-panel {
        min-width: 18rem;
        padding: 1rem;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .profile-panel__section {
        display: flex;
        flex-direction: column;
        gap: 0.625rem;
      }

      .profile-panel__title {
        font-size: 0.75rem;
        font-weight: 700;
        letter-spacing: 0.04em;
        text-transform: uppercase;
        color: var(--sapContent_LabelColor, #6a6d70);
      }

      .profile-panel__label {
        font-size: 0.8125rem;
        color: var(--sapTextColor, #32363a);
      }

      .profile-panel__toggle {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 1rem;
      }

      .profile-status {
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        gap: 0.5rem;
      }

      .app-nav {
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        gap: 0.5rem;
        padding: 0.5rem 1rem;
        background: var(--sapBaseColor, #fff);
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
        transition: background 0.15s, color 0.15s, box-shadow 0.2s;
      }

      .app-nav__item:hover {
        background: var(--sapList_Hover_Background, #f5f5f5);
      }

      .app-nav__item--active {
        background: var(--sapList_SelectionBackgroundColor, #e8f2ff);
        color: var(--sapBrandColor, #0854a0);
        font-weight: 600;
        box-shadow: inset 0 -2px 0 0 var(--sapBrandColor, #0854a0);
      }

      .section-nav {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        padding: 0.5rem 1rem;
        background: var(--sapList_Background, #f7f7f7);
        border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      }

      .section-nav__label {
        font-size: 0.75rem;
        font-weight: 700;
        letter-spacing: 0.04em;
        text-transform: uppercase;
        color: var(--sapContent_LabelColor, #6a6d70);
      }

      .section-nav__items {
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        gap: 0.5rem;
      }

      .section-nav__item {
        border: none;
        background: var(--sapButton_Lite_Background, transparent);
        color: var(--sapTextColor, #32363a);
        padding: 0.3rem 0.625rem;
        border-radius: 999px;
        font-size: 0.75rem;
        cursor: pointer;
        transition: background 0.15s, color 0.15s, box-shadow 0.2s;
      }

      .section-nav__item:hover {
        background: var(--sapList_Hover_Background, #f5f5f5);
      }

      .section-nav__item--active {
        background: var(--sapList_SelectionBackgroundColor, #e8f2ff);
        color: var(--sapBrandColor, #0854a0);
        font-weight: 600;
        box-shadow: inset 0 -2px 0 0 var(--sapBrandColor, #0854a0);
      }

      .status-banner {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        flex-wrap: wrap;
        padding: 0.5rem 1rem;
        background: var(--sapWarningBackground, #fff8d6);
        border-bottom: 1px solid var(--sapWarningBorderColor, #e6c96a);
      }

      .mode-select {
        background: var(--sapField_Background, #fff);
        color: var(--sapTextColor, #32363a);
        border: 1px solid var(--sapField_BorderColor, #89919a);
        border-radius: 0.25rem;
        padding: 0.25rem 0.5rem;
        font-size: 0.8125rem;
        outline: none;
        cursor: pointer;

        option {
          background: var(--sapField_Background, #fff);
          color: var(--sapTextColor, #32363a);
        }
      }

      .mode-select--block {
        width: 100%;
      }

      .shell-content {
        flex: 1;
        overflow-y: auto;
      }

      .diagnostics-drawer {
        border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
        background: var(--sapBaseColor, #fff);
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
      .model-online .model-status-dot::before {
        content: '';
        display: inline-block;
        width: 8px; height: 8px;
        border-radius: 50%;
        background: var(--sapPositiveColor, #107e3e);
        margin-inline-end: 4px;
        vertical-align: middle;
      }

      .model-offline {
        color: var(--sapNegativeColor, #b00);
        opacity: 0.8;
      }
      .model-offline .model-status-dot::before {
        content: '';
        display: inline-block;
        width: 8px; height: 8px;
        border-radius: 50%;
        background: var(--sapNegativeColor, #b00);
        margin-inline-end: 4px;
        vertical-align: middle;
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

      :host-context([dir='rtl']) .section-nav,
      .rtl .section-nav {
        flex-direction: row-reverse;
      }

      :host-context([dir='rtl']) .section-nav__items,
      .rtl .section-nav__items,
      :host-context([dir='rtl']) .profile-status,
      .rtl .profile-status {
        direction: rtl;
      }

      .more-chevron {
        display: inline-block;
        font-size: 0.75em;
        opacity: 0.6;
        transition: transform 0.2s, opacity 0.2s;
      }

      .more-chevron--open {
        transform: rotate(180deg);
        opacity: 1;
      }

      @media (max-width: 900px) {
        .section-nav {
          align-items: flex-start;
          flex-direction: column;
        }

        .profile-panel {
          min-width: 16rem;
        }
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
  readonly currentPath = signal('/dashboard');
  readonly routeLinks = computed<TranslatedRouteLink[]>(() =>
    TRAINING_ROUTE_LINKS.map((link) => ({
      ...link,
      label: this.i18n.t(link.labelKey),
    })),
  );
  readonly navGroups = computed<TranslatedNavGroup[]>(() =>
    TRAINING_NAV_GROUPS.map((group) => ({
      ...group,
      label: this.i18n.t(group.labelKey),
    })),
  );
  readonly activeGroupId = computed<TrainingRouteGroupId>(() =>
    resolveTrainingGroup(this.currentPath()),
  );
  readonly activeGroup = computed<TranslatedNavGroup>(() => {
    const groups = this.navGroups();
    const fallback = {
      ...TRAINING_NAV_GROUPS[0],
      label: this.i18n.t(TRAINING_NAV_GROUPS[0].labelKey),
    };
    return groups.find((group) => group.id === this.activeGroupId()) ?? groups[0] ?? fallback;
  });
  readonly activeGroupRoutes = computed<TranslatedRouteLink[]>(() =>
    this.routeLinks().filter((route) => route.group === this.activeGroupId()),
  );
  readonly showStatusNotice = computed(
    () => this.store.wsState() !== 'connected' || !this.arabicModelOnline(),
  );
  readonly notificationCount = signal(0);
  readonly expertRoutes = computed<TranslatedRouteLink[]>(() =>
    TRAINING_EXPERT_ROUTES.map((link) => ({
      ...link,
      label: this.i18n.t(link.labelKey),
    })),
  );

  ngOnInit(): void {
    this.currentPath.set(this.normalizePath(this.router.url));
    this.router.events
      .pipe(
        filter((event): event is NavigationEnd => event instanceof NavigationEnd),
        takeUntil(this.destroy$),
      )
      .subscribe((event) => {
        this.currentPath.set(this.normalizePath(event.urlAfterRedirects));
      });

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
  @ViewChild('productPopover') productPopover!: ElementRef<Ui5PopoverElement>;
  @ViewChild('profilePopover') profilePopover!: ElementRef<Ui5PopoverElement>;
  @ViewChild('expertPopover') expertPopover!: ElementRef<Ui5PopoverElement>;
  @ViewChild('moreBtn') moreBtn!: ElementRef<HTMLButtonElement>;

  searchResults = computed<TranslatedRouteLink[]>(() => {
    const q = this.searchQuery().toLowerCase().trim();
    const routes = this.routeLinks();
    if (!q) return routes;
    return routes.filter(
      (route) => route.label.toLowerCase().includes(q) || route.path.toLowerCase().includes(q),
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
      this.navigateFromSearch(results[0].path);
    }
  }

  trapSearchFocus(event: KeyboardEvent): void {
    if (event.key !== 'Tab') return;
    const modal = (event.currentTarget as HTMLElement);
    const focusable = modal.querySelectorAll<HTMLElement>(
      'input, button, [tabindex]:not([tabindex="-1"])',
    );
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }
  // -------------------------

  isGroupActive(groupId: TrainingRouteGroupId): boolean {
    return this.activeGroupId() === groupId;
  }

  isRouteActive(route: string): boolean {
    const currentPath = this.currentPath();
    return currentPath === route || currentPath.startsWith(`${route}/`);
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

  logout(): void {
    this.auth.clearToken();
    this.router.navigate(['/login']);
  }

  openNotifications(): void {
    this.toast.info(this.i18n.t('app.noNotifications'));
  }

  openProducts(event: ShellbarClickEvent): void {
    this.showPopover(this.productPopover?.nativeElement, event?.detail?.targetRef);
  }

  onProductSelect(event: ProductSelectEvent): void {
    const url = event.detail?.item?.getAttribute('data-url');
    if (url) {
      window.location.href = url;
    }
  }

  openProfile(event: ShellbarClickEvent): void {
    this.showPopover(this.profilePopover?.nativeElement, event?.detail?.targetRef);
  }

  toggleDiagnostics(): void {
    this.showDiagnostics.update((value) => !value);
    if (this.profilePopover?.nativeElement) {
      this.profilePopover.nativeElement.open = false;
    }
  }

  openExpertPopover(): void {
    this.showPopover(this.expertPopover?.nativeElement, this.moreBtn?.nativeElement);
  }

  closeExpertPopover(): void {
    if (this.expertPopover?.nativeElement) {
      this.expertPopover.nativeElement.open = false;
    }
  }

  private showPopover(popover?: Ui5PopoverElement, target?: HTMLElement | null): void {
    if (!popover || !target) {
      return;
    }

    if (typeof popover.showAt === 'function') {
      popover.showAt(target);
      return;
    }

    popover.opener = target;
    popover.open = true;
  }

  private normalizePath(url: string): string {
    const path = url.split('?')[0].split('#')[0];
    return path && path !== '/' ? path : '/dashboard';
  }
}

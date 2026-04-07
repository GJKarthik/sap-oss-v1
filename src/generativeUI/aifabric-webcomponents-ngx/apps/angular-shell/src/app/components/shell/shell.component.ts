/**
 * Shell Component - Angular/UI5 Version
 *
 * Main navigation shell using UI5 ShellBar following ui5-webcomponents-ngx standards
 * Enhanced with accessibility features and responsive mobile navigation
 */

import { Component, DestroyRef, HostListener, OnInit, inject, ElementRef, ViewChild, computed, signal } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Router, NavigationEnd } from '@angular/router';
import { filter, finalize } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { McpService } from '../../services/mcp.service';
import { CollaborationService, TeamMember, ConnectionState } from '../../services/collaboration.service';
import { TeamConfigService } from '../../services/team-config.service';
import { WorkspaceService } from '../../services/workspace.service';
import { UseCaseWorkspace, CrossAppFeature } from '../../services/workspace.types';
import { I18nService, TranslatePipe } from '../../shared/services/i18n.service';
import { environment } from '../../../environments/environment';
import {
  AI_FABRIC_NAV_ITEMS,
  AI_FABRIC_NAV_SECTIONS,
  AiFabricNavItem,
  AiFabricNavSection,
  AiFabricNavSectionId,
} from '../../app.navigation';

type PopoverElement = HTMLElement & {
  showAt?: (target: HTMLElement) => void;
  opener?: HTMLElement;
  open?: boolean;
};

type ProductSwitchEvent = CustomEvent<{
  targetRef?: HTMLElement;
}>;

type ProductSelectEvent = CustomEvent<{
  item?: Element | null;
}>;

@Component({
  selector: 'app-shell',
  standalone: false,
  template: `
    <!-- Skip to main content link for accessibility -->
    <a href="#main-content" class="skip-link" (click)="skipToMain($event)">
      {{ 'navigation.skipToMain' | translate }}
    </a>

    <!-- UI5 Shell Bar -->
    <ui5-shellbar
      [attr.primary-title]="i18n.t('shell.primaryTitle')"
      [attr.secondary-title]="i18n.t('shell.secondaryTitle')"
      [showNotifications]="false"
      showProductSwitch="true"
      (logo-click)="navigateTo('/dashboard')"
      (product-switch-click)="openProducts($event)"
      (profile-click)="openProfile($event)"
      role="banner">

      <!-- Menu Button for Mobile -->
      <ui5-button
        slot="startButton"
        icon="menu2"
        design="Transparent"
        [attr.aria-label]="getMenuButtonLabel()"
        [attr.aria-expanded]="isNavExpanded()"
        aria-controls="side-navigation"
        (click)="toggleSideNav()"
        class="menu-button">
      </ui5-button>

      <!-- Cmd+K hint -->
      <ui5-button
        slot="startButton"
        design="Transparent"
        class="kbd-hint"
        (click)="toggleSearch()"
        [attr.aria-label]="i18n.t('shell.openSearch')">
        ⌘K
      </ui5-button>

      <!-- Workspace Switcher -->
      <ui5-button
        slot="startButton"
        design="Transparent"
        class="ws-switcher-btn"
        [icon]="workspaceService.activeWorkspace() ? 'group' : 'add-folder'"
        (click)="openWorkspaceSwitcher($event)"
        [attr.aria-label]="i18n.t('shell.workspaceLabel', { name: workspaceService.activeWorkspace()?.useCase || 'None' })">
        {{ workspaceService.activeWorkspace()?.useCase || ('shell.selectWorkspace' | translate) }}
      </ui5-button>

      <!-- Logo -->
      <img slot="logo" src="assets/sap-logo.svg" alt="SAP Logo" />

      <!-- Team Presence Indicators -->
      <div slot="startButton" class="team-presence" *ngIf="teamMembers.length > 0" [attr.aria-label]="'shell.teamMembersOnline' | translate">
        <ng-container *ngFor="let member of teamMembers.slice(0, 5)">
          <ui5-avatar
            size="XS"
            [attr.initials]="getMemberInitials(member)"
            [attr.aria-label]="member.displayName + ' (' + member.status + ')'"
            [style.border]="'2px solid ' + member.color"
            [class.member-idle]="member.status === 'idle'"
            [class.member-away]="member.status === 'away'"
            interactive>
          </ui5-avatar>
          <span *ngIf="member.language" class="member-lang-badge" [title]="getLanguageName(member.language)">{{ member.language?.toUpperCase() }}</span>
        </ng-container>
        <span *ngIf="teamMembers.length > 5" class="team-overflow">+{{ teamMembers.length - 5 }}</span>
        <span class="collab-status" [class.collab-connected]="collabState === 'connected'" [class.collab-reconnecting]="collabState === 'reconnecting'">
          {{ collabState === 'connected' ? '●' : collabState === 'reconnecting' ? '◌' : '' }}
        </span>
      </div>

      <!-- Profile Menu -->
      <ui5-avatar
        slot="profile"
        [attr.initials]="getUserInitials()"
        color-scheme="Accent6"
        [attr.aria-label]="i18n.t('accessibility.userProfile') + ': ' + getSessionLabel()"
        interactive>
      </ui5-avatar>
    </ui5-shellbar>

    <!-- Workspace Switcher Popover -->
    <ui5-popover #workspacePopover [attr.header-text]="i18n.t('shell.useCaseWorkspaces')" placement-type="Bottom" horizontal-align="Left" style="min-width: 380px;">
      <div class="ws-popover-content">
        <div class="ws-list">
          <div class="ws-item" *ngFor="let ws of workspaceService.getAllWorkspaces()"
            [class.ws-item--active]="ws.id === workspaceService.activeWorkspace()?.id"
            (click)="switchWorkspace(ws.id)">
            <div class="ws-item-header">
              <strong>{{ ws.useCase }}</strong>
              <ui5-tag [design]="ws.id === workspaceService.activeWorkspace()?.id ? 'Positive' : 'Information'">{{ ws.team.teamName }}</ui5-tag>
            </div>
            <div class="ws-item-desc">{{ ws.description }}</div>
            <div class="ws-item-meta">
              <span>{{ ws.features.length }} features · {{ ws.team.members.length }} members · {{ ws.language }}</span>
            </div>
          </div>
        </div>
        <div class="ws-popover-actions" *ngIf="workspaceService.activeWorkspace()">
          <ui5-button design="Transparent" icon="cancel" (click)="switchWorkspace(null)">{{ 'shell.leaveWorkspace' | translate }}</ui5-button>
        </div>
      </div>
    </ui5-popover>

    <!-- Cross-App Feature Bar (when workspace is active) -->
    <div class="cross-app-bar" *ngIf="workspaceService.crossAppFeatures().length > 0">
      <span class="cross-app-label">{{ 'shell.otherApps' | translate }}</span>
      <ui5-button *ngFor="let f of workspaceService.crossAppFeatures()"
        design="Transparent"
        [icon]="f.icon"
        (click)="navigateCrossApp(f)"
        [attr.title]="f.label + ' (' + f.sourceApp + ')'">
        {{ f.label }}
      </ui5-button>
    </div>

    <ui5-popover #productPopover [attr.header-text]="i18n.t('shell.productSwitcher')" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
      <ui5-list (item-click)="onProductSelect($event)">
        <ui5-li icon="home" data-url="/aifabric/" selected>AI Fabric Console</ui5-li>
        <ui5-li icon="process" data-url="/training/">Training Console</ui5-li>
        <ui5-li icon="product" data-url="/sac/">SAC AI Integration</ui5-li>
        <ui5-li icon="grid" data-url="/ui5/">Joule AI Playground</ui5-li>
      </ui5-list>
    </ui5-popover>

    <ui5-popover #profilePopover [attr.header-text]="i18n.t('navigation.workspace')" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
      <div class="profile-panel">
        <div class="profile-panel__section">
          <div class="profile-panel__title">Session</div>
          <div class="profile-panel__identity">{{ getSessionLabel() }}</div>
          <div class="profile-panel__meta">v1.0.0</div>
        </div>
        <div class="profile-panel__section">
          <div class="profile-panel__title">Language</div>
          <select
            class="mode-select mode-select--block"
            [value]="currentLocale"
            (change)="onLocaleChange($event)"
            [attr.aria-label]="i18n.t('shell.language')">
            <option value="en">English</option>
            <option value="ar">العربية (Arabic)</option>
            <option value="fr">Français</option>
            <option value="de">Deutsch</option>
            <option value="ko">한국어</option>
            <option value="zh">中文</option>
            <option value="id">Bahasa Indonesia</option>
          </select>
        </div>
        <div class="profile-panel__section">
          <div class="profile-panel__title">System status</div>
          <div class="profile-panel__status">
            <ui5-icon
              [name]="getStatusIcon()"
              [attr.aria-hidden]="true"
              class="status-icon"
              [class.status-healthy]="overallHealth === 'healthy'"
              [class.status-degraded]="overallHealth === 'degraded'"
              [class.status-error]="overallHealth === 'error'">
            </ui5-icon>
            <span>{{ getStatusText() }}</span>
          </div>
          <div class="profile-panel__meta">{{ getCurrentPageLabel() }}</div>
        </div>
        <ui5-button design="Transparent" icon="log" (click)="logout()">Logout</ui5-button>
      </div>
    </ui5-popover>

    <section class="status-banner" *ngIf="showStatusBanner()" role="status" aria-live="polite">
      <ui5-icon
        [name]="getStatusIcon()"
        [attr.aria-hidden]="true"
        class="status-icon"
        [class.status-healthy]="overallHealth === 'healthy'"
        [class.status-degraded]="overallHealth === 'degraded'"
        [class.status-error]="overallHealth === 'error'">
      </ui5-icon>
      <span>{{ getStatusText() }}</span>
    </section>

    <!-- Side Navigation -->
    <div class="shell-layout">
      <nav
        id="side-navigation"
        class="side-nav-container"
        [class.collapsed]="sideNavCollapsed"
        [class.mobile-open]="mobileNavOpen"
        [attr.aria-label]="i18n.t('shell.mainNavigation')"
        role="navigation">

        <!-- Mobile overlay backdrop -->
        <div
          class="nav-backdrop"
          *ngIf="mobileNavOpen && isMobile"
          (click)="closeMobileNav()"
          aria-hidden="true">
        </div>

        <aside class="side-nav" [class.side-nav--compact]="isCompactNav()">
          <section class="side-nav__section" *ngFor="let section of navSections">
            <div class="side-nav__section-label" *ngIf="!isCompactNav()">
              {{ i18n.t(section.labelKey) }}
            </div>
            <button
              type="button"
              class="side-nav__item"
              *ngFor="let item of getItemsForSection(section.id)"
              [class.side-nav__item--active]="isActive(item.route)"
              [attr.aria-current]="isActive(item.route) ? 'page' : null"
              [attr.aria-label]="i18n.t(item.descriptionKey)"
              [title]="isCompactNav() ? i18n.t(item.textKey) : i18n.t(item.descriptionKey)"
              (click)="navigateTo(item.route); closeMobileNav()">
              <ui5-icon class="side-nav__item-icon" [name]="item.icon" [attr.aria-hidden]="true"></ui5-icon>
              <span class="side-nav__item-text" *ngIf="!isCompactNav()">{{ i18n.t(item.textKey) }}</span>
            </button>
          </section>
        </aside>
      </nav>

      <!-- Main Content Area -->
      <main
        id="main-content"
        class="main-content"
        role="main"
        [attr.aria-label]="getCurrentPageLabel()"
        tabindex="-1">
        <router-outlet></router-outlet>
      </main>
    </div>

    <!-- Search Overlay -->
    <div class="search-overlay" *ngIf="showSearch()" (click)="closeSearch()" (keydown.escape)="closeSearch()">
      <div class="search-modal" (click)="$event.stopPropagation()" role="dialog" [attr.aria-label]="i18n.t('shell.searchLabel')">
        <div class="search-modal__input-row">
          <ui5-icon name="search" aria-hidden="true"></ui5-icon>
          <input
            #searchInput
            type="text"
            class="search-modal__input"
            [placeholder]="i18n.t('shell.searchPlaceholder')"
            [value]="searchQuery()"
            (input)="searchQuery.set($any($event.target).value)"
            (keydown.enter)="selectFirstResult()"
            (keydown.escape)="closeSearch()"
            (keydown.tab)="trapSearchFocus($event)"
            [attr.aria-label]="i18n.t('shell.searchInputLabel')" />
          <kbd class="search-modal__kbd">esc</kbd>
        </div>
        <ul class="search-modal__results" role="listbox">
          <li
            *ngFor="let res of searchResults(); let i = index"
            class="search-modal__result"
            [class.search-modal__result--active]="i === 0"
            role="option"
            [attr.aria-selected]="i === 0"
            (click)="navigateFromSearch(res.route)">
            <ui5-icon [name]="res.icon" aria-hidden="true"></ui5-icon>
            <div class="search-modal__result-text">
              <span class="search-modal__result-title">{{ i18n.t(res.textKey) }}</span>
              <span class="search-modal__result-desc">{{ i18n.t(res.descriptionKey) }}</span>
            </div>
            <span class="search-modal__result-route">{{ res.route }}</span>
          </li>
        </ul>
        <div class="search-modal__footer" *ngIf="searchResults().length === 0 && searchQuery()">
          {{ i18n.t('common.noResults', { query: searchQuery() }) }}
        </div>
      </div>
    </div>

    <footer class="shell-footer">
      <span>v1.0.0</span>
      <span class="shell-footer__status">{{ getStatusText() }}</span>
    </footer>

  `,
  styles: [`
    .ws-switcher-btn { font-size: 0.8125rem; max-width: 200px; overflow: hidden; text-overflow: ellipsis; }
    .ws-popover-content { padding: 0.5rem; }
    .ws-list { display: flex; flex-direction: column; gap: 0.5rem; max-height: 400px; overflow-y: auto; }
    .ws-item { border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 0.75rem; cursor: pointer; transition: background 0.15s; }
    .ws-item:hover { background: var(--sapList_Hover_Background, #f5f5f5); }
    .ws-item--active { border-color: var(--sapBrandColor, #0854a0); background: var(--sapList_SelectionBackgroundColor, #e8f2ff); }
    .ws-item-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.25rem; }
    .ws-item-desc { font-size: 0.8125rem; color: var(--sapTextColor); margin-bottom: 0.25rem; }
    .ws-item-meta { font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .ws-popover-actions { margin-top: 0.5rem; border-top: 1px solid var(--sapGroup_TitleBorderColor); padding-top: 0.5rem; }
    .cross-app-bar { display: flex; align-items: center; gap: 0.5rem; padding: 0.25rem 1rem; background: var(--sapList_SelectionBackgroundColor, #e8f2ff); border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9); font-size: 0.8125rem; flex-wrap: wrap; }
    .cross-app-label { font-size: 0.75rem; color: var(--sapContent_LabelColor); font-weight: 500; }
    .team-presence {
      display: inline-flex;
      align-items: center;
      gap: 0.25rem;
      margin-inline-start: 0.5rem;
    }
    .team-presence ui5-avatar { cursor: default; }
    .team-presence .member-idle { opacity: 0.6; }
    .team-presence .member-away { opacity: 0.4; }
    .team-overflow {
      font-size: 0.75rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      padding: 0 0.25rem;
    }
    .collab-status {
      font-size: 0.5rem;
      margin-inline-start: 0.25rem;
    }
    .collab-connected { color: var(--sapPositiveColor, #107e3e); }
    .collab-reconnecting { color: var(--sapCriticalColor, #e9730c); }
    .member-lang-badge {
      font-size: 0.625rem;
      font-weight: 600;
      background: var(--sapInformationBackground, #e8f2ff);
      color: var(--sapInformativeColor, #0a6ed1);
      padding: 0.1rem 0.3rem;
      border-radius: 0.25rem;
      line-height: 1;
    }
  `]
})
export class ShellComponent implements OnInit {
  private readonly destroyRef = inject(DestroyRef);
  private readonly router = inject(Router);
  private readonly authService = inject(AuthService);
  private readonly mcpService = inject(McpService);
  private readonly collabService = inject(CollaborationService);
  private readonly teamConfigService = inject(TeamConfigService);
  readonly workspaceService = inject(WorkspaceService);
  readonly i18n = inject(I18nService);

  sideNavCollapsed = false;
  mobileNavOpen = false;
  isMobile = false;
  overallHealth: 'healthy' | 'degraded' | 'error' | 'unknown' = 'unknown';
  currentUser = this.authService.getUser();
  currentLocale = 'en';

  // Team collaboration state
  teamMembers: TeamMember[] = [];
  collabState: ConnectionState = 'disconnected';

  // Search overlay state
  showSearch = signal(false);
  searchQuery = signal('');
  searchResults = computed(() => {
    const query = this.searchQuery().toLowerCase().trim();
    if (!query) return this.navItems;
    return this.navItems.filter(item =>
      this.i18n.t(item.textKey).toLowerCase().includes(query) ||
      this.i18n.t(item.descriptionKey).toLowerCase().includes(query) ||
      item.route.toLowerCase().includes(query)
    );
  });

  @ViewChild('productPopover') productPopover!: ElementRef<PopoverElement>;
  @ViewChild('profilePopover') profilePopover!: ElementRef<PopoverElement>;
  @ViewChild('workspacePopover') workspacePopover!: ElementRef<PopoverElement>;
  @ViewChild('searchInput') searchInput?: ElementRef<HTMLInputElement>;

  get navItems(): AiFabricNavItem[] {
    return this.workspaceService.visibleNavItems();
  }
  readonly navSections: AiFabricNavSection[] = AI_FABRIC_NAV_SECTIONS;

  @HostListener('window:resize')
  onResize(): void {
    this.checkMobile();
  }

  @HostListener('window:keydown', ['$event'])
  onGlobalKeydown(event: KeyboardEvent): void {
    if ((event.metaKey || event.ctrlKey) && event.key === 'k') {
      event.preventDefault();
      this.toggleSearch();
    }
    if (event.key === 'Escape') {
      if (this.showSearch()) {
        this.closeSearch();
      } else if (this.mobileNavOpen) {
        this.closeMobileNav();
      }
    }
  }

  ngOnInit(): void {
    this.workspaceService.initialize();
    this.checkMobile();

    this.mcpService.health$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(health => {
        this.overallHealth = health.overall;
      });

    // Close mobile nav on route change
    this.router.events
      .pipe(
        filter(event => event instanceof NavigationEnd),
        takeUntilDestroyed(this.destroyRef)
      )
      .subscribe(() => {
        this.closeMobileNav();
      });

    // Initialize team collaboration
    this.initCollaboration();
    this.teamConfigService.loadTeamConfig();
  }

  private initCollaboration(): void {
    const userId = this.currentUser?.username || environment.collabUserId;
    const displayName = this.currentUser?.username || environment.collabDisplayName;

    this.collabService.configure({
      websocketUrl: environment.collabWsUrl,
      userId,
      displayName,
      language: this.currentLocale,
    });

    this.collabService.connectionState$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(state => {
        this.collabState = state;
      });

    this.collabService.members$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(members => {
        this.teamMembers = members;
      });

    // Auto-join the default workspace room
    this.collabService.joinRoom('aifabric-workspace-default').catch(() => {
      // Silent fail — will reconnect automatically
    });

    // Track page location for presence
    this.router.events
      .pipe(
        filter(event => event instanceof NavigationEnd),
        takeUntilDestroyed(this.destroyRef)
      )
      .subscribe((event) => {
        const navEnd = event as NavigationEnd;
        this.collabService.updatePresence('active', navEnd.urlAfterRedirects);
      });
  }

  getMemberInitials(member: TeamMember): string {
    const name = member.displayName?.trim();
    if (!name) return '??';
    const parts = name.split(/\s+/);
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    return name.slice(0, 2).toUpperCase();
  }

  // ─── Workspace Switcher ─────────────────────────────────────────
  openWorkspaceSwitcher(event: Event): void {
    const popover = this.workspacePopover?.nativeElement;
    const target = event.target as HTMLElement;
    if (popover && target) {
      if (typeof popover.showAt === 'function') { popover.showAt(target); }
      else { popover.opener = target; popover.open = true; }
    }
  }

  switchWorkspace(workspaceId: string | null): void {
    this.workspaceService.switchWorkspace(workspaceId);
    // Close popover
    const popover = this.workspacePopover?.nativeElement;
    if (typeof (popover as any)?.close === 'function') (popover as any).close();
    else if (popover) popover.open = false;
  }

  navigateCrossApp(feature: CrossAppFeature): void {
    this.workspaceService.navigateToFeature(feature);
  }

  private checkMobile(): void {
    this.isMobile = window.innerWidth <= 768;
    if (!this.isMobile) {
      this.mobileNavOpen = false;
    }
  }

  skipToMain(event: Event): void {
    event.preventDefault();
    const mainContent = document.getElementById('main-content');
    if (mainContent) {
      mainContent.focus();
      mainContent.scrollIntoView({ behavior: 'smooth' });
    }
  }

  navigateTo(route: string): void {
    void this.router.navigate([route]);
  }

  isActive(route: string): boolean {
    return this.router.url === route || this.router.url.startsWith(route + '/');
  }

  getUserInitials(): string {
    const username = this.currentUser?.username?.trim();
    if (!username) {
      return 'AI';
    }

    return username.slice(0, 2).toUpperCase();
  }

  getSessionLabel(): string {
    if (!this.currentUser) {
      return this.i18n.t('shell.guestSession');
    }

    return `${this.currentUser.username} (${this.currentUser.role})`;
  }

  getCurrentPageLabel(): string {
    const currentNav = this.navItems.find(item => this.isActive(item.route));
    return currentNav ? this.i18n.t(currentNav.descriptionKey) : this.i18n.t('accessibility.mainContent');
  }

  isNavExpanded(): boolean {
    return this.isMobile ? this.mobileNavOpen : !this.sideNavCollapsed;
  }

  getMenuButtonLabel(): string {
    return this.isNavExpanded() ? this.i18n.t('navigation.closeMenu') : this.i18n.t('navigation.openMenu');
  }

  showStatusBanner(): boolean {
    return this.overallHealth === 'degraded' || this.overallHealth === 'error';
  }

  isCompactNav(): boolean {
    return this.sideNavCollapsed && !this.isMobile;
  }

  getItemsForSection(sectionId: AiFabricNavSectionId): AiFabricNavItem[] {
    return this.navItems.filter(item => item.section === sectionId);
  }

  logout(): void {
    this.closeMobileNav();
    this.authService.logout()
      .pipe(
        finalize(() => {
          void this.router.navigate(['/login']);
        }),
        takeUntilDestroyed(this.destroyRef),
      )
      .subscribe();
  }

  getStatusText(): string {
    switch (this.overallHealth) {
      case 'healthy':
        return this.i18n.t('dashboard.allSystemsOperational');
      case 'degraded':
        return this.i18n.t('dashboard.someServicesDegraded');
      case 'error':
        return this.i18n.t('dashboard.servicesUnavailable');
      default:
        return this.i18n.t('dashboard.checkingStatus');
    }
  }

  getStatusIcon(): string {
    switch (this.overallHealth) {
      case 'healthy':
        return 'status-positive';
      case 'degraded':
        return 'status-critical';
      case 'error':
        return 'status-negative';
      default:
        return 'status-inactive';
    }
  }

  onLocaleChange(event: Event): void {
    const select = event.target as HTMLSelectElement;
    this.currentLocale = select.value;
    void this.i18n.setLocale(this.currentLocale as any);
    this.workspaceService.updateLanguage(this.currentLocale);
    this.collabService.updateLanguage(this.currentLocale);
  }

  private static readonly LANG_NAMES: Record<string, string> = {
    en: 'English', ar: 'العربية', fr: 'Français', de: 'Deutsch',
    ko: '한국어', zh: '中文', id: 'Bahasa Indonesia',
  };

  getLanguageName(code: string): string {
    return ShellComponent.LANG_NAMES[code] || code.toUpperCase();
  }

  toggleSideNav(): void {
    if (this.isMobile) {
      this.mobileNavOpen = !this.mobileNavOpen;
    } else {
      this.sideNavCollapsed = !this.sideNavCollapsed;
    }
  }

  closeMobileNav(): void {
    this.mobileNavOpen = false;
  }

  toggleSearch(): void {
    if (this.showSearch()) {
      this.closeSearch();
    } else {
      this.searchQuery.set('');
      this.showSearch.set(true);
      setTimeout(() => this.searchInput?.nativeElement.focus());
    }
  }

  closeSearch(): void {
    this.showSearch.set(false);
    this.searchQuery.set('');
  }

  navigateFromSearch(route: string): void {
    this.closeSearch();
    this.navigateTo(route);
  }

  selectFirstResult(): void {
    const results = this.searchResults();
    if (results.length > 0) {
      this.navigateFromSearch(results[0].route);
    }
  }

  trapSearchFocus(event: Event): void {
    event.preventDefault();
    this.searchInput?.nativeElement.focus();
  }

  openProducts(event: Event): void {
    const detail = (event as ProductSwitchEvent).detail;
    this.showPopover(this.productPopover.nativeElement, detail?.targetRef);
  }

  openProfile(event: Event): void {
    const detail = (event as ProductSwitchEvent).detail;
    this.showPopover(this.profilePopover.nativeElement, detail?.targetRef);
  }

  onProductSelect(event: Event): void {
    const detail = (event as ProductSelectEvent).detail;
    const url = detail?.item?.getAttribute('data-url');
    if (url) {
      window.location.href = url;
    }
  }

  private showPopover(popover: PopoverElement, target?: HTMLElement): void {
    if (!target) {
      return;
    }
    if (typeof popover.showAt === 'function') {
      popover.showAt(target);
      return;
    }
    popover.opener = target;
    popover.open = true;
  }
}

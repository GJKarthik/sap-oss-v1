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
      Skip to main content
    </a>

    <!-- UI5 Shell Bar -->
    <ui5-shellbar
      primary-title="SAP AI Fabric Console"
      secondary-title="Enterprise AI Platform"
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
        aria-label="Open search (Cmd+K)">
        ⌘K
      </ui5-button>
      
      <!-- Logo -->
      <img slot="logo" src="assets/sap-logo.svg" alt="SAP Logo" />

      <!-- Profile Menu -->
      <ui5-avatar 
        slot="profile" 
        [attr.initials]="getUserInitials()" 
        color-scheme="Accent6"
        [attr.aria-label]="'User profile: ' + getSessionLabel()"
        interactive>
      </ui5-avatar>
    </ui5-shellbar>

    <ui5-popover #productPopover header-text="Product Switcher" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
      <ui5-list (item-click)="onProductSelect($event)">
        <ui5-li icon="home" data-url="/aifabric/" selected>AI Fabric Console</ui5-li>
        <ui5-li icon="process" data-url="/training/">Training Console</ui5-li>
        <ui5-li icon="product" data-url="/sac/">SAC AI Integration</ui5-li>
        <ui5-li icon="grid" data-url="/ui5/">Joule AI Playground</ui5-li>
      </ui5-list>
    </ui5-popover>

    <ui5-popover #profilePopover header-text="Workspace" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
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
            aria-label="Select language">
            <option value="en">English</option>
            <option value="ar">العربية (Arabic)</option>
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
        [attr.aria-label]="'Main navigation'"
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
              {{ section.label }}
            </div>
            <button
              type="button"
              class="side-nav__item"
              *ngFor="let item of getItemsForSection(section.id)"
              [class.side-nav__item--active]="isActive(item.route)"
              [attr.aria-current]="isActive(item.route) ? 'page' : null"
              [attr.aria-label]="item.description"
              [title]="isCompactNav() ? item.text : item.description"
              (click)="navigateTo(item.route); closeMobileNav()">
              <ui5-icon class="side-nav__item-icon" [name]="item.icon" [attr.aria-hidden]="true"></ui5-icon>
              <span class="side-nav__item-text" *ngIf="!isCompactNav()">{{ item.text }}</span>
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
      <div class="search-modal" (click)="$event.stopPropagation()" role="dialog" aria-label="Quick navigation search">
        <div class="search-modal__input-row">
          <ui5-icon name="search" aria-hidden="true"></ui5-icon>
          <input
            #searchInput
            type="text"
            class="search-modal__input"
            placeholder="Search pages..."
            [value]="searchQuery()"
            (input)="searchQuery.set($any($event.target).value)"
            (keydown.enter)="selectFirstResult()"
            (keydown.escape)="closeSearch()"
            (keydown.tab)="trapSearchFocus($event)"
            aria-label="Search navigation pages" />
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
              <span class="search-modal__result-title">{{ res.text }}</span>
              <span class="search-modal__result-desc">{{ res.description }}</span>
            </div>
            <span class="search-modal__result-route">{{ res.route }}</span>
          </li>
        </ul>
        <div class="search-modal__footer" *ngIf="searchResults().length === 0 && searchQuery()">
          No results for "{{ searchQuery() }}"
        </div>
      </div>
    </div>

    <footer class="shell-footer">
      <span>SAP AI Fabric Console v1.0.0</span>
      <span class="shell-footer__status">{{ getStatusText() }}</span>
    </footer>

  `
})
export class ShellComponent implements OnInit {
  private readonly destroyRef = inject(DestroyRef);
  private readonly router = inject(Router);
  private readonly authService = inject(AuthService);
  private readonly mcpService = inject(McpService);

  sideNavCollapsed = false;
  mobileNavOpen = false;
  isMobile = false;
  overallHealth: 'healthy' | 'degraded' | 'error' | 'unknown' = 'unknown';
  currentUser = this.authService.getUser();
  currentLocale = 'en';

  // Search overlay state
  showSearch = signal(false);
  searchQuery = signal('');
  searchResults = computed(() => {
    const query = this.searchQuery().toLowerCase().trim();
    if (!query) return this.navItems;
    return this.navItems.filter(item =>
      item.text.toLowerCase().includes(query) ||
      item.description.toLowerCase().includes(query) ||
      item.route.toLowerCase().includes(query)
    );
  });

  @ViewChild('productPopover') productPopover!: ElementRef<PopoverElement>;
  @ViewChild('profilePopover') profilePopover!: ElementRef<PopoverElement>;
  @ViewChild('searchInput') searchInput?: ElementRef<HTMLInputElement>;
  
  readonly navItems: AiFabricNavItem[] = AI_FABRIC_NAV_ITEMS;
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
      return 'Guest session';
    }

    return `${this.currentUser.username} (${this.currentUser.role})`;
  }

  getCurrentPageLabel(): string {
    const currentNav = this.navItems.find(item => this.isActive(item.route));
    return currentNav ? currentNav.description : 'Main content area';
  }

  isNavExpanded(): boolean {
    return this.isMobile ? this.mobileNavOpen : !this.sideNavCollapsed;
  }

  getMenuButtonLabel(): string {
    return this.isNavExpanded() ? 'Close navigation menu' : 'Open navigation menu';
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
        return 'All systems operational';
      case 'degraded':
        return 'Some services degraded';
      case 'error':
        return 'Services unavailable';
      default:
        return 'Checking status...';
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
    document.documentElement.setAttribute('lang', this.currentLocale);
    document.documentElement.setAttribute('dir', this.currentLocale === 'ar' ? 'rtl' : 'ltr');
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

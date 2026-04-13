// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, OnDestroy, OnInit, ViewChild, ElementRef, effect, signal, computed, HostListener, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { Router, NavigationEnd, Event, RouterOutlet } from '@angular/router';
import { CommonModule } from '@angular/common';
import { filter, takeUntil } from 'rxjs/operators';
import { Subject } from 'rxjs';
import { LearnPathService } from './core/learn-path.service';
import { I18nPipe, I18nService } from '@ui5/webcomponents-ngx/i18n';
import { WorkspaceService } from './core/workspace.service';
import { ProductNavigationService, ProductAppId } from './core/product-navigation.service';
import { normalizeWorkspaceTheme } from './core/theme-utils';
import { QuickAccessService, NavLinkDatum } from './core/quick-access.service';
import { Ui5WorkspaceComponentsModule } from './shared/ui5-workspace-components.module';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, RouterOutlet, Ui5WorkspaceComponentsModule, I18nPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  templateUrl: './app.component.html',
  styleUrls: ['./app.component.scss'],
})
export class AppComponent implements OnInit, OnDestroy {
  readonly shellbarA11y = {
    logo: {
      role: 'link' as const,
      name: 'SAP Home',
    },
  };

  currentTheme = 'sap_horizon';
  currentLanguage = 'en';
  learnPathActive = false;
  learnPathDismissed = false;
  learnPathProgress = 0;
  learnPathStepLabel = '';

  readonly currentPath = signal('/');
  readonly searchQuery = signal('');
  readonly selectedSearchIndex = signal(0);
  readonly currentPagePinned = computed(() => this.quickAccess.isPinned(this.currentPath()));
  readonly canPinCurrentPage = computed(() => this.quickAccess.canPin(this.currentPath()));

  readonly pinnedQuickAccess = computed(() => this.quickAccess.pinnedEntries());
  readonly recentQuickAccess = computed(() => this.quickAccess.recentEntries());
  readonly suggestedQuickAccess = computed(() =>
    this.quickAccess.suggestedEntries().filter((entry) => entry.path !== this.currentPath()).slice(0, 5),
  );
  readonly searchQuickAccess = computed(() => this.quickAccess.search(this.searchQuery()));

  readonly effectiveSearchEntries = computed(() => {
    if (this.searchQuery().trim()) {
      return this.searchQuickAccess();
    }
    const pinned = this.pinnedQuickAccess();
    const recent = this.recentQuickAccess();
    const suggested = this.suggestedQuickAccess();
    
    const combined = [...pinned, ...recent, ...suggested];
    const seen = new Set<string>();
    return combined.filter(entry => {
      if (seen.has(entry.path)) return false;
      seen.add(entry.path);
      return true;
    }).slice(0, 10);
  });

  @ViewChild('productPopover', { read: ElementRef }) productPopover!: ElementRef<any>;
  @ViewChild('profilePopover', { read: ElementRef }) profilePopover!: ElementRef<any>;
  @ViewChild('notificationsPopover', { read: ElementRef }) notificationsPopover!: ElementRef<any>;
  @ViewChild('searchDialog', { read: ElementRef }) searchDialog!: ElementRef<any>;
  @ViewChild('searchInput', { read: ElementRef }) searchInput!: ElementRef<any>;

  private readonly destroy$ = new Subject<void>();

  constructor(
    private router: Router,
    private learnPath: LearnPathService,
    private i18nService: I18nService,
    private workspaceService: WorkspaceService,
    private productNavigation: ProductNavigationService,
    private quickAccess: QuickAccessService,
    ) {
    effect(() => {
      const settings = this.workspaceService.settings();
      const theme = normalizeWorkspaceTheme(settings.theme);
      if (theme !== this.currentTheme) {
        this.currentTheme = theme;
        this.applyTheme(theme);
        localStorage.setItem('ui5-theme', theme);
      }

      if (
        settings.language
        && this.SUPPORTED_LANGS.includes(settings.language)
        && settings.language !== this.currentLanguage
      ) {
        this.applyLanguage(settings.language);
        localStorage.setItem('ui5-language', settings.language);
      }
    });
  }

  get navLinks(): NavLinkDatum[] {
    return this.workspaceService.visibleNavLinks().filter((link) => link.showInShellbar && link.path !== '/workspace');
  }

  trackByPath(_index: number, link: NavLinkDatum): string {
    return link.path;
  }

  ngOnInit(): void {
    this.currentTheme = normalizeWorkspaceTheme(this.workspaceService.settings().theme);
    this.applyTheme(this.currentTheme);
    this.learnPathDismissed = localStorage.getItem('learn-path-dismissed') === 'true';
    this.currentPath.set(this.normalizePath(this.router.url));
    this.quickAccess.recordVisit(this.router.url);

    const savedLanguage = this.workspaceService.settings().language || localStorage.getItem('ui5-language');
    const language = savedLanguage && this.SUPPORTED_LANGS.includes(savedLanguage) ? savedLanguage : 'en';
    this.currentLanguage = language;
    this.applyLanguage(language);

    this.router.events
      .pipe(
        filter((event): event is NavigationEnd => event instanceof NavigationEnd),
        takeUntil(this.destroy$),
      )
      .subscribe((event) => {
        this.currentPath.set(this.normalizePath(event.urlAfterRedirects));
        this.quickAccess.recordVisit(event.urlAfterRedirects);
        this.learnPath.syncWithUrl(event.urlAfterRedirects);
        this.updateLearnPathBanner();
      });

    if (this.router.url === '/' && this.workspaceService.navConfig().defaultLandingPath !== '/') {
      this.openLanding();
      return;
    }

    this.updateLearnPathBanner();
  }

  skipToMain(event: globalThis.Event): void {
    event.preventDefault();
    const main = document.getElementById('main-content');
    if (main) {
      main.focus();
      main.scrollIntoView();
    }
  }

  isActive(path: string): boolean {
    const url = this.router.url.split('?')[0];
    return path === '/' ? url === '/' : url.startsWith(path);
  }

  navigateTo(path: string): void {
    this.router.navigate([path]);
  }

  onNavSelectionChange(event: any): void {
    const path = event.detail.item.getAttribute('data-path');
    if (path) {
      this.navigateTo(path);
    }
  }

  shouldShowViewportHeader(): boolean {
    return this.router.url !== '/';
  }

  toggleSearch(): void {
    const dialog = this.searchDialog.nativeElement;
    if (dialog.open) {
      this.closeSearchDialog();
      return;
    }

    this.searchQuery.set('');
    this.selectedSearchIndex.set(0);
    dialog.show();
    setTimeout(() => this.searchInput.nativeElement.focus(), 100);
  }

  onSearchInput(event: globalThis.Event): void {
    const input = event.target as HTMLInputElement | null;
    this.searchQuery.set(input?.value ?? '');
    this.selectedSearchIndex.set(0);
  }

  jumpTo(path: string): void {
    this.closeSearchDialog();
    void this.router.navigate([path]);
  }

  toggleCurrentPagePin(): void {
    this.quickAccess.togglePinned(this.currentPath());
  }

  togglePinned(path: string, event: globalThis.Event): void {
    event.stopPropagation();
    this.quickAccess.togglePinned(path);
  }

  isPinned(path: string): boolean {
    return this.quickAccess.isPinned(path);
  }

  openLanding(): void {
    this.productNavigation.navigateToLanding();
  }

  openProducts(event: any): void {
    this.productPopover.nativeElement.showAt(event.detail.targetRef);
  }

  openNotifications(event: any): void {
    this.notificationsPopover.nativeElement.showAt(event.detail.targetRef);
  }

  openProfile(event: any): void {
    this.profilePopover.nativeElement.showAt(event.detail.targetRef);
  }

  onProductSelect(event: any): void {
    const appId = event.detail.item.getAttribute('data-app') as ProductAppId | null;
    if (appId) {
      this.productNavigation.navigateToApp(appId);
    }
  }

  onSignOut(): void {
    console.log('Signing out...');
    this.closeProfile();
  }

  onThemeChange(event: globalThis.Event): void {
    const theme = normalizeWorkspaceTheme((event as CustomEvent).detail?.selectedOption?.value);
    if (theme) {
      this.currentTheme = theme;
      this.applyTheme(theme);
      localStorage.setItem('ui5-theme', theme);
      this.workspaceService.updateTheme(theme);
    }
  }

  private readonly SUPPORTED_LANGS = ['en', 'ar', 'fr', 'de', 'ko', 'zh', 'id'];
  private readonly UI5_LANGUAGE_MAP: Record<string, string> = {
    ar: 'ar',
    de: 'de',
    en: 'en',
    fr: 'fr',
    id: 'id',
    ko: 'ko',
    zh: 'zh_CN',
  };

  onLanguageChange(event: globalThis.Event): void {
    const language = (event as CustomEvent).detail?.selectedOption?.value;
    if (language && this.SUPPORTED_LANGS.includes(language)) {
      this.currentLanguage = language;
      this.applyLanguage(language);
      localStorage.setItem('ui5-language', language);
      this.workspaceService.updateLanguage(language);
    }
  }

  advanceLearnPath(): void {
    const next = this.learnPath.next();
    if (next) {
      this.router.navigate([next.route]);
      return;
    }
    this.router.navigate(['/readiness']);
  }

  endLearnPath(): void {
    this.learnPath.stop();
    localStorage.setItem('ui5-learn-path-dismissed', 'true');
    this.updateLearnPathBanner();
  }

  dismissLearnPath(): void {
    this.learnPathDismissed = true;
    localStorage.setItem('learn-path-dismissed', 'true');
    this.learnPath.stop();
    this.updateLearnPathBanner();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  @HostListener('window:keydown', ['$event'])
  handleKeyboardEvent(event: KeyboardEvent): void {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      this.toggleSearch();
      return;
    }

    if (this.searchDialog?.nativeElement?.open) {
      this.handleSearchKeyDown(event);
    }
  }

  handleSearchKeyDown(event: KeyboardEvent) {
    const entries = this.effectiveSearchEntries();
    if (entries.length === 0) return;

    if (event.key === 'ArrowDown') {
      event.preventDefault();
      this.selectedSearchIndex.update(i => (i + 1) % entries.length);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      this.selectedSearchIndex.update(i => (i - 1 + entries.length) % entries.length);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const entry = entries[this.selectedSearchIndex()];
      if (entry) {
        this.jumpTo(entry.path);
      }
    } else if (event.key === 'Escape') {
      this.closeSearchDialog();
    }
  }

  private closeSearchDialog(): void {
    const dialog = this.searchDialog?.nativeElement;
    this.selectedSearchIndex.set(0);
    if (!dialog) return;
    if (typeof dialog.close === 'function') {
      dialog.close();
    } else {
      dialog.open = false;
    }
  }

  private closeProfile(): void {
    const popover = this.profilePopover?.nativeElement;
    if (!popover) return;
    if (typeof popover.close === 'function') {
      popover.close();
    } else {
      popover.open = false;
    }
  }

  private applyLanguage(language: string): void {
    this.currentLanguage = language;
    const ui5Language = this.UI5_LANGUAGE_MAP[language] || 'en';
    this.i18nService.setLanguage(ui5Language);
    document.documentElement.setAttribute('lang', ui5Language.replace('_', '-'));
    this.updateLearnPathBanner();
  }

  private applyTheme(theme: string): void {
    document.body.setAttribute('data-sap-theme', theme);
  }

  private updateLearnPathBanner(): void {
    this.learnPathActive = this.learnPath.active;
    if (this.learnPathActive) {
      this.learnPathProgress = this.learnPath.progress();
      this.learnPathStepLabel = this.learnPath.currentStepLabel();
    }
  }

  private normalizePath(path: string): string {
    const normalized = path.split('?')[0].split('#')[0].trim();
    if (!normalized) {
      return '/';
    }
    return normalized.startsWith('/') ? normalized : `/${normalized}`;
  }
}

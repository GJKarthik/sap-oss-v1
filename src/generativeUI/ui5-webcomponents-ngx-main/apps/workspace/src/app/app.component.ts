// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, OnDestroy, OnInit, ViewChild, ElementRef, effect, signal, computed, HostListener } from '@angular/core';
import { Router, NavigationEnd } from '@angular/router';
import { Subject, filter, takeUntil } from 'rxjs';
import { LearnPathService } from './core/learn-path.service';
import { I18nService } from '@ui5/webcomponents-ngx/i18n';
import { WorkspaceService } from './core/workspace.service';
import { NavLinkDatum, normalizeWorkspaceTheme } from './core/workspace.types';
import { ProductNavigationService, ProductAppId } from './core/product-navigation.service';
import { QuickAccessService } from './core/quick-access.service';

@Component({
    selector: 'ui-angular-root',
    templateUrl: './app.component.html',
    styleUrls: ['./app.component.scss'],
    standalone: false
})
export class AppComponent implements OnInit, OnDestroy {
  currentTheme = 'sap_horizon';
  currentLanguage = 'en';
  shellbarA11y = {
    logo: { name: 'SAP AI Experience' },
  };
  learnPathActive = false;
  learnPathDismissed = false;
  learnPathStepLabel = '';
  learnPathProgress = '';
  readonly currentPath = signal('/');
  readonly searchQuery = signal('');
  readonly currentPagePinned = computed(() => this.quickAccess.isPinned(this.currentPath()));
  readonly canPinCurrentPage = computed(() => this.quickAccess.canPin(this.currentPath()));
  readonly pinnedQuickAccess = computed(() =>
    this.quickAccess.pinnedEntries().filter((entry) => entry.path !== this.currentPath()).slice(0, 4),
  );
  readonly recentQuickAccess = computed(() =>
    this.quickAccess.recentEntries().filter((entry) => entry.path !== this.currentPath()).slice(0, 4),
  );
  readonly suggestedQuickAccess = computed(() =>
    this.quickAccess.suggestedEntries().filter((entry) => entry.path !== this.currentPath()).slice(0, 5),
  );
  readonly searchQuickAccess = computed(() => this.quickAccess.search(this.searchQuery()));

  @ViewChild('productPopover') productPopover!: ElementRef<any>;
  @ViewChild('profilePopover') profilePopover!: ElementRef<any>;
  @ViewChild('searchDialog') searchDialog!: ElementRef<any>;
  @ViewChild('searchInput') searchInput!: ElementRef<any>;

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

  skipToMain(event: Event): void {
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

  toggleSearch(): void {
    const dialog = this.searchDialog.nativeElement;
    if (dialog.open) {
      dialog.close();
      return;
    }

    this.searchQuery.set('');
    dialog.show();
    setTimeout(() => this.searchInput.nativeElement.focus(), 100);
  }

  onSearchInput(event: Event): void {
    const input = event.target as HTMLInputElement | null;
    this.searchQuery.set(input?.value ?? '');
  }

  jumpTo(path: string): void {
    this.searchDialog.nativeElement.close();
    void this.router.navigate([path]);
  }

  toggleCurrentPagePin(): void {
    this.quickAccess.togglePinned(this.currentPath());
  }

  togglePinned(path: string, event: Event): void {
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
    this.profilePopover.nativeElement.close();
  }

  onThemeChange(event: Event): void {
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

  onLanguageChange(event: Event): void {
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
    }
  }

  private applyLanguage(language: string): void {
    this.currentLanguage = language;
    const ui5Language = this.UI5_LANGUAGE_MAP[language] || 'en';
    this.i18nService.setLanguage(ui5Language);
    document.documentElement.setAttribute('lang', ui5Language.replace('_', '-'));
    document.documentElement.setAttribute('dir', language === 'ar' ? 'rtl' : 'ltr');
  }

  private applyTheme(theme: string): void {
    const normalizedTheme = normalizeWorkspaceTheme(theme);
    document.documentElement.setAttribute('data-sap-theme', normalizedTheme);
  }

  private updateLearnPathBanner(): void {
    const dismissed = localStorage.getItem('ui5-learn-path-dismissed') === 'true';
    this.learnPathActive = this.learnPath.active && !dismissed;
    const step = this.learnPath.currentStep;
    if (!step) {
      this.learnPathStepLabel = '';
      this.learnPathProgress = '';
      return;
    }

    this.learnPathStepLabel = step.label;
    this.learnPathProgress = `${this.learnPath.currentIndex + 1}/${this.learnPath.steps.length}`;
  }

  private normalizePath(path: string): string {
    const normalized = path.split('?')[0].split('#')[0].trim();
    if (!normalized) {
      return '/';
    }
    return normalized.startsWith('/') ? normalized : `/${normalized}`;
  }
}

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, OnDestroy, OnInit, ViewChild, ElementRef, effect } from '@angular/core';
import { Router, NavigationEnd } from '@angular/router';
import { Subject, filter, takeUntil } from 'rxjs';
import { LearnPathService } from './core/learn-path.service';
import { I18nService } from '@ui5/webcomponents-ngx/i18n';
import { WorkspaceService } from './core/workspace.service';
import { NavLinkDatum } from './core/workspace.types';
import { ProductNavigationService, ProductAppId } from './core/product-navigation.service';

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

  @ViewChild('productPopover') productPopover!: ElementRef<any>;

  private readonly destroy$ = new Subject<void>();

  constructor(
    private router: Router,
    private learnPath: LearnPathService,
    private i18nService: I18nService,
    private workspaceService: WorkspaceService,
    private productNavigation: ProductNavigationService,
  ) {
    effect(() => {
      const settings = this.workspaceService.settings();
      if (settings.theme && settings.theme !== this.currentTheme) {
        this.currentTheme = settings.theme;
        this.applyTheme(settings.theme);
        localStorage.setItem('ui5-theme', settings.theme);
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
    this.currentTheme = this.workspaceService.settings().theme || 'sap_horizon';
    this.applyTheme(this.currentTheme);
    this.learnPathDismissed = localStorage.getItem('learn-path-dismissed') === 'true';

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

  openLanding(): void {
    this.productNavigation.navigateToLanding();
  }

  openProducts(event: any): void {
    this.productPopover.nativeElement.showAt(event.detail.targetRef);
  }

  onProductSelect(event: any): void {
    const appId = event.detail.item.getAttribute('data-app') as ProductAppId | null;
    if (appId) {
      this.productNavigation.navigateToApp(appId);
    }
  }

  onMenuItemClick(event: Event): void {
    const detail = (event as CustomEvent).detail;
    const path = detail?.item?.getAttribute?.('data-path');
    if (path) {
      this.router.navigate([path]);
    }
  }

  onThemeChange(event: Event): void {
    const theme = (event as CustomEvent).detail?.selectedOption?.value;
    if (theme) {
      this.currentTheme = theme;
      this.applyTheme(theme);
      localStorage.setItem('ui5-theme', theme);
      this.workspaceService.updateTheme(theme);
    }
  }

  private readonly SUPPORTED_LANGS = ['en', 'ar', 'fr', 'de', 'ko', 'zh', 'id'];

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

  private applyLanguage(language: string): void {
    this.currentLanguage = language;
    this.i18nService.setLanguage(language);
    document.documentElement.setAttribute('lang', language);
    document.documentElement.setAttribute('dir', language === 'ar' ? 'rtl' : 'ltr');
  }

  private applyTheme(theme: string): void {
    document.documentElement.setAttribute('data-sap-theme', theme);
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
}

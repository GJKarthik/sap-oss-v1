// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, OnDestroy, OnInit, ViewChild, ElementRef } from '@angular/core';
import { Router, NavigationEnd } from '@angular/router';
import { Subject, filter, takeUntil } from 'rxjs';
import { DemoTourService } from './core/demo-tour.service';
import { I18nService } from '@ui5/webcomponents-ngx/i18n';
import { WorkspaceService } from './core/workspace.service';
import { NavLinkDatum, NAV_LINK_DATA } from './core/workspace.types';

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
    logo: { name: 'UI5 Web Components NGX Playground' },
  };
  demoTourActive = false;
  demoTourDismissed = false;
  demoTourStepLabel = '';
  demoTourProgress = '';

  @ViewChild('productPopover') productPopover!: ElementRef<any>;

  private readonly destroy$ = new Subject<void>();

  constructor(
    private router: Router,
    private demoTour: DemoTourService,
    private i18nService: I18nService,
    private workspaceService: WorkspaceService,
  ) {}

  get navLinks(): NavLinkDatum[] {
    return this.workspaceService.visibleNavLinks();
  }

  get shellbarLinks(): NavLinkDatum[] {
    return this.navLinks.filter(l => l.showInShellbar);
  }

  trackByPath(_index: number, link: NavLinkDatum): string {
    return link.path;
  }

  ngOnInit(): void {
    const saved = localStorage.getItem('ui5-theme');
    if (saved) {
      this.currentTheme = saved;
      this.applyTheme(saved);
    }
    this.demoTourDismissed = localStorage.getItem('demo-tour-dismissed') === 'true';

    const savedLanguage = localStorage.getItem('ui5-language');
    const SUPPORTED_LANGS = ['en', 'ar', 'fr', 'de', 'ko', 'zh', 'id'];
    const language = savedLanguage && SUPPORTED_LANGS.includes(savedLanguage) ? savedLanguage : 'en';
    this.currentLanguage = language;
    this.applyLanguage(language);

    this.router.events
      .pipe(
        filter((event): event is NavigationEnd => event instanceof NavigationEnd),
        takeUntil(this.destroy$),
      )
      .subscribe((event) => {
        this.demoTour.syncWithUrl(event.urlAfterRedirects);
        this.updateDemoTourBanner();
      });

    this.updateDemoTourBanner();
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

  openProducts(event: any): void {
    this.productPopover.nativeElement.showAt(event.detail.targetRef);
  }

  onProductSelect(event: any): void {
    const url = event.detail.item.getAttribute('data-url');
    if (url) {
      window.location.href = url;
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

  nextDemoStep(): void {
    const next = this.demoTour.next();
    if (next) {
      this.router.navigate([next.route]);
      return;
    }
    this.router.navigate(['/readiness']);
  }

  endDemoTour(): void {
    this.demoTour.stop();
    localStorage.setItem('ui5-demo-tour-dismissed', 'true');
    this.updateDemoTourBanner();
  }

  dismissDemoTour(): void {
    this.demoTourDismissed = true;
    localStorage.setItem('demo-tour-dismissed', 'true');
    this.demoTour.stop();
    this.updateDemoTourBanner();
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

  private updateDemoTourBanner(): void {
    const dismissed = localStorage.getItem('ui5-demo-tour-dismissed') === 'true';
    this.demoTourActive = this.demoTour.active && !dismissed;
    const step = this.demoTour.currentStep;
    if (!step) {
      this.demoTourStepLabel = '';
      this.demoTourProgress = '';
      return;
    }

    this.demoTourStepLabel = step.label;
    this.demoTourProgress = `${this.demoTour.currentIndex + 1}/${this.demoTour.steps.length}`;
  }
}

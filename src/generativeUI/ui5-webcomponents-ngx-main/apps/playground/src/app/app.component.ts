// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, OnDestroy, OnInit, ViewChild, ElementRef } from '@angular/core';
import { Router, NavigationEnd } from '@angular/router';
import { Subject, filter, takeUntil } from 'rxjs';
import { DemoTourService } from './core/demo-tour.service';
import { I18nService } from '@ui5/webcomponents-ngx/i18n';

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
  demoTourStepLabel = '';
  demoTourProgress = '';

  @ViewChild('productPopover') productPopover!: ElementRef<any>;

  private readonly destroy$ = new Subject<void>();

  constructor(
    private router: Router,
    private demoTour: DemoTourService,
    private i18nService: I18nService,
  ) {}

  ngOnInit(): void {
    const saved = localStorage.getItem('ui5-theme');
    if (saved) {
      this.currentTheme = saved;
      this.applyTheme(saved);
    }
    const savedLanguage = localStorage.getItem('ui5-language');
    const language = savedLanguage === 'ar' ? 'ar' : 'en';
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
    }
  }

  onLanguageChange(event: Event): void {
    const language = (event as CustomEvent).detail?.selectedOption?.value;
    if (language === 'en' || language === 'ar') {
      this.currentLanguage = language;
      this.applyLanguage(language);
      localStorage.setItem('ui5-language', language);
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
    this.demoTourActive = this.demoTour.active;
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

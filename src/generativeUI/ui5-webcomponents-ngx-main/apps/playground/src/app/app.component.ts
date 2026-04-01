// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, OnDestroy, OnInit } from '@angular/core';
import { Router, NavigationEnd } from '@angular/router';
import { Subject, filter, takeUntil } from 'rxjs';
import { DemoTourService } from './core/demo-tour.service';

@Component({
    selector: 'ui-angular-root',
    templateUrl: './app.component.html',
    styleUrls: ['./app.component.scss'],
    standalone: false
})
export class AppComponent implements OnInit, OnDestroy {
  currentTheme = 'sap_horizon';
  shellbarA11y = {
    logo: { name: 'UI5 Web Components NGX Playground' },
  };
  demoTourActive = false;
  demoTourStepLabel = '';
  demoTourProgress = '';

  private readonly destroy$ = new Subject<void>();

  constructor(private router: Router, private demoTour: DemoTourService) {}

  ngOnInit(): void {
    const saved = localStorage.getItem('ui5-theme');
    if (saved) {
      this.currentTheme = saved;
      this.applyTheme(saved);
    }

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

  onMenuItemClick(event: Event): void {
    const detail = (event as CustomEvent).detail;
    if (detail?.item?.text) {
      const map: Record<string, string> = {
        'Home': '/',
        'Forms Demo': '/forms',
        'Joule AI': '/joule',
        'Collaboration': '/collab',
        'Generative UI': '/generative',
        'Components': '/components',
        'MCP': '/mcp',
        'Readiness': '/readiness',
      };
      const path = map[detail.item.text];
      if (path) this.router.navigate([path]);
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

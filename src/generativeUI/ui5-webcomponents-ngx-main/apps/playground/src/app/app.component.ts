// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, OnInit } from '@angular/core';
import { Router, NavigationEnd } from '@angular/router';

@Component({
    selector: 'ui-angular-root',
    templateUrl: './app.component.html',
    styleUrls: ['./app.component.scss'],
    standalone: false
})
export class AppComponent implements OnInit {
  currentTheme = 'sap_horizon';

  constructor(private router: Router) {}

  ngOnInit(): void {
    const saved = localStorage.getItem('ui5-theme');
    if (saved) {
      this.currentTheme = saved;
      this.applyTheme(saved);
    }
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

  private applyTheme(theme: string): void {
    document.documentElement.setAttribute('data-sap-theme', theme);
  }
}

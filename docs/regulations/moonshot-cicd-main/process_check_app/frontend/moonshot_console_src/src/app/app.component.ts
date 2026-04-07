import { AsyncPipe, CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { NavigationEnd, Router, RouterOutlet } from '@angular/router';
import { filter } from 'rxjs';

import { ConnectionState } from './core/models/moonshot.model';
import { MoonshotApiService } from './core/services/moonshot-api.service';

interface NavItem {
  path: string;
  title: string;
  icon: string;
  fixed?: boolean;
}

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, AsyncPipe, RouterOutlet],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <ui5-shellbar
      primary-title="Process Check Console"
      secondary-title="Angular UI5 Runtime (Streamlit Replaced)"
      class="shellbar"
      show-notifications
    >
      <ui5-avatar slot="profile" initials="PC"></ui5-avatar>
    </ui5-shellbar>

    <div class="layout">
      <ui5-side-navigation class="side-nav">
        <ui5-side-navigation-item
          *ngFor="let item of topNavItems"
          [icon]="item.icon"
          [text]="item.title"
          [selected]="isActive(item.path)"
          (click)="navigate(item.path)"
        ></ui5-side-navigation-item>

        <ui5-side-navigation-item
          *ngFor="let item of fixedNavItems"
          slot="fixedItems"
          [icon]="item.icon"
          [text]="item.title"
          [selected]="isActive(item.path)"
          (click)="navigate(item.path)"
        ></ui5-side-navigation-item>
      </ui5-side-navigation>

      <main class="main">
        <ui5-message-strip
          class="status-strip"
          hide-close-button
          [design]="statusDesign()"
        >
          {{ statusMessage() }}
          <ui5-button slot="endButton" design="Transparent" icon="refresh" (click)="refreshHealth()">
            Refresh
          </ui5-button>
        </ui5-message-strip>

        <ui5-message-strip
          *ngIf="(lastError$ | async) as lastError"
          class="status-strip"
          design="Negative"
        >
          {{ lastError }}
        </ui5-message-strip>

        <router-outlet></router-outlet>
      </main>
    </div>
  `,
  styles: [
    `
      :host {
        display: block;
        min-height: 100vh;
      }

      .shellbar {
        position: sticky;
        top: 0;
        z-index: 15;
        border-bottom: 1px solid var(--moonshot-border);
      }

      .layout {
        display: grid;
        grid-template-columns: 248px 1fr;
        min-height: calc(100vh - 3rem);
      }

      .side-nav {
        border-right: 1px solid var(--moonshot-border);
        background: linear-gradient(160deg, #f3f9ff 0%, #eaf2fb 100%);
      }

      .main {
        padding: 1rem 1.2rem 1.4rem;
        overflow: auto;
      }

      .status-strip {
        margin-bottom: 0.7rem;
      }

      @media (max-width: 980px) {
        .layout {
          grid-template-columns: 1fr;
        }

        .side-nav {
          border-right: none;
          border-bottom: 1px solid var(--moonshot-border);
        }
      }
    `,
  ],
})
export class AppComponent {
  private readonly router = inject(Router);
  private readonly destroyRef = inject(DestroyRef);
  private readonly moonshot = inject(MoonshotApiService);

  readonly topNavItems: NavItem[] = [
    { path: '/welcome', title: 'Welcome', icon: 'home' },
    { path: '/getting-started', title: 'Getting Started', icon: 'activate' },
    { path: '/process-checks', title: 'Process Checks', icon: 'survey' },
    { path: '/upload-results', title: 'Upload Results', icon: 'upload' },
    { path: '/generate-report', title: 'Generate Report', icon: 'document-text' },
    { path: '/runs', title: 'Moonshot Run', icon: 'media-play' },
    { path: '/history', title: 'History', icon: 'history' },
  ];

  readonly fixedNavItems: NavItem[] = [
    { path: '/overview', title: 'Runtime', icon: 'inspect' },
    { path: '/catalog', title: 'Catalog', icon: 'list' },
    { path: '/settings', title: 'Settings', icon: 'action-settings', fixed: true },
  ];

  readonly config$ = this.moonshot.config$;
  readonly fallbackMode$ = this.moonshot.fallbackMode$;
  readonly lastError$ = this.moonshot.lastError$;

  connectionState: ConnectionState = 'disconnected';
  private currentPath = '/welcome';

  constructor() {
    this.router.events
      .pipe(
        filter((event): event is NavigationEnd => event instanceof NavigationEnd),
        takeUntilDestroyed(this.destroyRef)
      )
      .subscribe((event) => {
        this.currentPath = event.urlAfterRedirects || '/welcome';
      });

    this.refreshHealth();
  }

  isActive(path: string): boolean {
    return this.currentPath === path || this.currentPath.startsWith(`${path}/`);
  }

  navigate(path: string): void {
    void this.router.navigateByUrl(path);
  }

  refreshHealth(): void {
    this.connectionState = 'connecting';
    this.moonshot
      .checkHealth()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (health) => {
          this.connectionState = health.odata_reachable ? 'connected' : 'degraded';
        },
        error: () => {
          this.connectionState = 'error';
        },
      });
  }

  statusDesign(): 'Positive' | 'Warning' | 'Information' | 'Negative' {
    switch (this.connectionState) {
      case 'connected':
        return 'Positive';
      case 'connecting':
        return 'Information';
      case 'degraded':
      case 'disconnected':
        return 'Warning';
      case 'error':
      default:
        return 'Negative';
    }
  }

  statusMessage(): string {
    const config = this.moonshot.getConfig();
    switch (this.connectionState) {
      case 'connected':
        return `Moonshot backend connected: ${config.baseUrl} (Fabric + OData reachable)`;
      case 'degraded':
        return `Connected to ${config.baseUrl} with degraded persistence path`;
      case 'connecting':
        return `Connecting to Moonshot backend at ${config.baseUrl}...`;
      case 'error':
        return `Moonshot backend connection failed for ${config.baseUrl}`;
      case 'disconnected':
      default:
        return `Moonshot backend not connected. Current URL: ${config.baseUrl}`;
    }
  }
}

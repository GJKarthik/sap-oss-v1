/**
 * Shell Component - Angular/UI5 Version
 * 
 * Main navigation shell using UI5 ShellBar following ui5-webcomponents-ngx standards
 */

import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Router } from '@angular/router';
import { finalize } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { McpService } from '../../services/mcp.service';

interface NavItem {
  id: string;
  text: string;
  icon: string;
  route: string;
}

@Component({
  selector: 'app-shell',
  standalone: false,
  template: `
    <!-- UI5 Shell Bar -->
    <ui5-shellbar
      primary-title="SAP AI Fabric Console"
      secondary-title="Enterprise AI Platform"
      (logo-click)="navigateTo('/dashboard')">
      
      <!-- Logo -->
      <img slot="logo" src="assets/sap-logo.svg" alt="SAP Logo" />

      <!-- Profile Menu -->
      <ui5-avatar slot="profile" [attr.initials]="getUserInitials()" color-scheme="Accent6"></ui5-avatar>
    </ui5-shellbar>

    <!-- Side Navigation -->
    <div class="shell-layout">
      <ui5-side-navigation class="side-nav" [collapsed]="sideNavCollapsed">
        <ui5-side-navigation-item 
          *ngFor="let item of navItems"
          [text]="item.text"
          [icon]="item.icon"
          [selected]="isActive(item.route)"
          (click)="navigateTo(item.route)">
        </ui5-side-navigation-item>
        
        <ui5-side-navigation-item slot="fixedItems" text="Logout" icon="log" (click)="logout()">
        </ui5-side-navigation-item>
      </ui5-side-navigation>

      <!-- Main Content Area -->
      <main class="main-content">
        <router-outlet></router-outlet>
      </main>
    </div>

    <!-- Status Footer -->
    <footer class="status-footer">
      <div class="status-indicator">
        <ui5-icon 
          [name]="overallHealth === 'healthy' ? 'status-positive' : overallHealth === 'error' ? 'status-negative' : 'status-critical'"
          class="status-icon">
        </ui5-icon>
        <span>{{ getStatusText() }}</span>
      </div>
      <span class="version">{{ getSessionLabel() }} | v1.0.0 | UI5 Web Components</span>
    </footer>
  `,
  styles: [`
    :host {
      display: flex;
      flex-direction: column;
      height: 100vh;
    }
    
    ui5-shellbar {
      --_ui5_shellbar_root_height: 44px;
    }
    
    .shell-layout {
      display: flex;
      flex: 1;
      overflow: hidden;
    }
    
    .side-nav {
      width: 240px;
      flex-shrink: 0;
      border-right: 1px solid var(--sapList_BorderColor);
    }
    
    .side-nav[collapsed] {
      width: 48px;
    }
    
    .main-content {
      flex: 1;
      overflow: auto;
      background: var(--sapBackgroundColor);
    }
    
    .status-footer {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.5rem 1rem;
      background: var(--sapList_Background);
      border-top: 1px solid var(--sapList_BorderColor);
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }
    
    .status-indicator {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    
    .status-icon {
      font-size: 1rem;
    }
    
    .version {
      color: var(--sapContent_LabelColor);
    }
  `]
})
export class ShellComponent implements OnInit {
  private readonly destroyRef = inject(DestroyRef);
  private readonly router = inject(Router);
  private readonly authService = inject(AuthService);
  private readonly mcpService = inject(McpService);

  sideNavCollapsed = false;
  overallHealth: 'healthy' | 'degraded' | 'error' | 'unknown' = 'unknown';
  currentUser = this.authService.getUser();
  
  navItems: NavItem[] = [
    { id: 'dashboard', text: 'Dashboard', icon: 'home', route: '/dashboard' },
    { id: 'streaming', text: 'Streaming', icon: 'play', route: '/streaming' },
    { id: 'deployments', text: 'Deployments', icon: 'machine', route: '/deployments' },
    { id: 'rag', text: 'RAG Studio', icon: 'documents', route: '/rag' },
    { id: 'governance', text: 'Governance', icon: 'shield', route: '/governance' },
    { id: 'data', text: 'Data Explorer', icon: 'database', route: '/data' },
    { id: 'playground', text: 'Playground', icon: 'lab', route: '/playground' },
    { id: 'lineage', text: 'Lineage', icon: 'org-chart', route: '/lineage' },
  ];

  ngOnInit(): void {
    this.mcpService.health$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(health => {
        this.overallHealth = health.overall;
      });
  }

  navigateTo(route: string): void {
    this.router.navigate([route]);
  }

  isActive(route: string): boolean {
    return this.router.url === route;
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

  logout(): void {
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

  toggleSideNav(): void {
    this.sideNavCollapsed = !this.sideNavCollapsed;
  }
}

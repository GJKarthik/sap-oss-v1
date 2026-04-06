/**
 * Shell Component - Angular/UI5 Version
 * 
 * Main navigation shell using UI5 ShellBar following ui5-webcomponents-ngx standards
 * Enhanced with accessibility features and responsive mobile navigation
 */

import { Component, DestroyRef, HostListener, OnInit, inject, ElementRef, ViewChild } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Router, NavigationEnd } from '@angular/router';
import { filter, finalize } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { McpService } from '../../services/mcp.service';

interface NavItem {
  id: string;
  text: string;
  icon: string;
  route: string;
  description: string;
}

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
      (menu-item-click)="onMenuItemClick($event)"
      role="banner">
      
      <!-- Menu Button for Mobile -->
      <ui5-button 
        slot="startButton"
        icon="menu2"
        design="Transparent"
        [attr.aria-label]="sideNavCollapsed ? 'Open navigation menu' : 'Close navigation menu'"
        [attr.aria-expanded]="!sideNavCollapsed"
        aria-controls="side-navigation"
        (click)="toggleSideNav()"
        class="menu-button">
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
        <ui5-li icon="BusinessSuiteInAppSymbols/product-switch" data-url="/sac/">SAC AI Integration</ui5-li>
        <ui5-li icon="grid" data-url="/ui5/">Joule AI Playground</ui5-li>
      </ui5-list>
    </ui5-popover>

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
        
        <ui5-side-navigation 
          class="side-nav" 
          [collapsed]="sideNavCollapsed && !isMobile">
          <ui5-side-navigation-item 
            *ngFor="let item of navItems"
            [text]="item.text"
            [icon]="item.icon"
            [selected]="isActive(item.route)"
            [attr.aria-current]="isActive(item.route) ? 'page' : null"
            [attr.aria-label]="item.description"
            (click)="navigateTo(item.route); closeMobileNav()">
          </ui5-side-navigation-item>
          
          <ui5-side-navigation-item 
            slot="fixedItems" 
            text="Logout" 
            icon="log" 
            aria-label="Sign out of the application"
            (click)="logout()">
          </ui5-side-navigation-item>
        </ui5-side-navigation>
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

    <!-- Status Footer -->
    <footer class="status-footer" role="contentinfo">
      <div class="status-indicator" [attr.aria-label]="'System status: ' + getStatusText()">
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
      <span class="version">
        <span class="session-info">{{ getSessionLabel() }}</span>
        <span class="separator" aria-hidden="true">|</span>
        <span>v1.0.0</span>
        <span class="separator hide-mobile" aria-hidden="true">|</span>
        <span class="hide-mobile">UI5 Web Components</span>
      </span>
    </footer>
  `,
  styles: [`
    :host {
      display: flex;
      flex-direction: column;
      height: 100vh;
    }
    
    /* Skip link for accessibility */
    .skip-link {
      position: absolute;
      top: -40px;
      left: 0;
      background: var(--sapBrandColor);
      color: white;
      padding: 0.5rem 1rem;
      z-index: 1000;
      text-decoration: none;
      font-weight: 500;
      border-radius: 0 0 4px 0;
      transition: top 0.2s ease;
    }
    
    .skip-link:focus {
      top: 0;
      outline: 2px solid var(--sapContent_FocusColor);
      outline-offset: 2px;
    }
    
    ui5-shellbar {
      --_ui5_shellbar_root_height: 44px;
    }
    
    .menu-button {
      display: none;
    }
    
    .shell-layout {
      display: flex;
      flex: 1;
      overflow: hidden;
      position: relative;
    }
    
    .side-nav-container {
      position: relative;
      z-index: 100;
    }
    
    .side-nav {
      width: 240px;
      flex-shrink: 0;
      border-right: 1px solid var(--sapList_BorderColor);
      height: 100%;
      transition: width 0.2s ease;
    }
    
    .side-nav-container.collapsed .side-nav {
      width: 48px;
    }
    
    .nav-backdrop {
      display: none;
    }
    
    .main-content {
      flex: 1;
      overflow: auto;
      background: var(--sapBackgroundColor);
      outline: none;
    }
    
    .main-content:focus {
      outline: 2px solid var(--sapContent_FocusColor);
      outline-offset: -2px;
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
      flex-wrap: wrap;
      gap: 0.5rem;
    }
    
    .status-indicator {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    
    .status-icon {
      font-size: 1rem;
    }
    
    .status-icon.status-healthy {
      color: var(--sapPositiveColor, #107e3e);
    }
    
    .status-icon.status-degraded {
      color: var(--sapCriticalColor, #e9730c);
    }
    
    .status-icon.status-error {
      color: var(--sapNegativeColor, #b00);
    }
    
    .version {
      color: var(--sapContent_LabelColor);
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-wrap: wrap;
    }
    
    .separator {
      opacity: 0.5;
    }
    
    /* Mobile Responsive Styles */
    @media (max-width: 768px) {
      .menu-button {
        display: inline-flex;
      }
      
      .side-nav-container {
        position: fixed;
        top: 44px;
        left: 0;
        bottom: 0;
        width: 0;
        overflow: hidden;
        transition: width 0.3s ease;
        z-index: 200;
      }
      
      .side-nav-container.mobile-open {
        width: 280px;
      }
      
      .side-nav-container.mobile-open .side-nav {
        width: 280px;
      }
      
      .nav-backdrop {
        display: block;
        position: fixed;
        top: 44px;
        left: 0;
        right: 0;
        bottom: 0;
        background: rgba(0, 0, 0, 0.5);
        z-index: -1;
      }
      
      .hide-mobile {
        display: none;
      }
      
      .session-info {
        max-width: 150px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
    }
    
    /* Tablet Responsive Styles */
    @media (min-width: 769px) and (max-width: 1024px) {
      .side-nav {
        width: 200px;
      }
    }
  `]
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

  @ViewChild('productPopover') productPopover!: ElementRef<any>;
  
  navItems: NavItem[] = [
    { id: 'dashboard', text: 'Dashboard', icon: 'home', route: '/dashboard', description: 'View system overview and statistics' },
    { id: 'streaming', text: 'Search Ops', icon: 'search', route: '/streaming', description: 'Inspect Elasticsearch and PAL service state' },
    { id: 'deployments', text: 'Deployments', icon: 'machine', route: '/deployments', description: 'Manage AI model deployments' },
    { id: 'rag', text: 'Search Studio', icon: 'documents', route: '/rag', description: 'Elasticsearch-backed retrieval workspace' },
    { id: 'data-quality', text: 'Data Quality', icon: 'validate', route: '/data-quality', description: 'AI-powered data validation and cleaning' },
    { id: 'governance', text: 'Governance', icon: 'shield', route: '/governance', description: 'Configure governance rules and policies' },
    { id: 'data', text: 'Data Explorer', icon: 'database', route: '/data', description: 'Explore vector stores and data' },
    { id: 'playground', text: 'PAL Workbench', icon: 'lab', route: '/playground', description: 'Run PAL tools against registered data assets' },
    { id: 'lineage', text: 'Lineage', icon: 'org-chart', route: '/lineage', description: 'View data lineage and relationships' },
  ];

  @HostListener('window:resize')
  onResize(): void {
    this.checkMobile();
  }

  @HostListener('window:keydown.escape')
  onEscapeKey(): void {
    if (this.mobileNavOpen) {
      this.closeMobileNav();
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

  onMenuItemClick(_event: Event): void {
    // Kept for future shell bar menu extensions (e.g. shellbar-item clicks).
    // No menu items are currently configured in the template.
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
}

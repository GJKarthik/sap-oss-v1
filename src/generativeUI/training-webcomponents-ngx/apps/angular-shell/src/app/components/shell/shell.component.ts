import {
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  ElementRef,
  HostListener,
  OnDestroy,
  OnInit,
  ViewChild,
  computed,
  inject,
  signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router, RouterOutlet, NavigationEnd, Event } from '@angular/router';
import { filter, Subscription } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { ToastService } from '../../services/toast.service';
import { ApiService } from '../../services/api.service';
import { DiagnosticsService } from '../../services/diagnostics.service';
import { UserSettingsService } from '../../services/user-settings.service';
import { AppStore } from '../../store/app.store';
import { I18nService } from '../../services/i18n.service';
import {
  TRAINING_NAV_GROUPS,
  TRAINING_ROUTE_LINKS,
  TrainingNavGroup,
  TrainingRouteLink,
  resolveTrainingGroup,
} from '../../app.navigation';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [CommonModule, RouterOutlet, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <!-- Global breathing canvas (Unibody background) -->
    <div class="app-canvas"></div>

    <div class="app-shell" [class.rtl]="i18n.isRtl()">
      <!-- Unified Header -->
      <header class="app-header">
        <ui5-shellbar
          [primaryTitle]="i18n.t('app.title')"
          [secondaryTitle]="i18n.t('app.subtitle')"
          (profile-click)="onProfileClick($event)">
          <ui5-avatar slot="profile" icon="customer" interactive></ui5-avatar>
          <ui5-button icon="settings" slot="endContent" (click)="toggleSettings()"></ui5-button>
        </ui5-shellbar>
      </header>

      <div class="app-body">
        <!-- Floating Navigation Islands -->
        <nav class="app-nav-island"
             [class.app-nav-island--expanded]="navExpanded()"
             role="navigation"
             [attr.aria-label]="i18n.t('app.mainNav')">
          <button class="nav-toggle"
                  (click)="navExpanded.set(!navExpanded())"
                  [attr.aria-expanded]="navExpanded()"
                  [attr.aria-label]="navExpanded() ? 'Collapse navigation' : 'Expand navigation'">
            <ui5-icon [name]="navExpanded() ? 'navigation-left-arrow' : 'menu2'"></ui5-icon>
          </button>
          <div class="nav-group-stack" role="list">
            @for (group of navGroups; track group.id) {
              <button
                class="nav-island-item"
                role="listitem"
                [class.active]="activeGroupId() === group.id"
                [attr.aria-current]="activeGroupId() === group.id ? 'page' : null"
                (click)="navigateTo(group.defaultPath)"
                [attr.aria-label]="i18n.t(group.labelKey)">
                <ui5-icon [name]="groupIcon(group.id)"></ui5-icon>
                <span class="nav-label">{{ i18n.t(group.labelKey) }}</span>
              </button>
            }
          </div>
        </nav>

        <!-- Main Viewing Area -->
        <main class="app-viewport">
          <!-- Floating Context Bar (Pill Navigation) -->
          @if (activeGroupRoutes().length > 1) {
            <div class="context-pill-bar slideUp">
              <div class="pill-track">
                @for (route of activeGroupRoutes(); track route.path) {
                  <button
                    class="pill-item"
                    [class.pill-item--active]="isRouteActive(route.path)"
                    (click)="navigateTo(route.path)">
                    {{ i18n.t(route.labelKey) }}
                  </button>
                }
              </div>
            </div>
          }

          <div class="content-container" [class.content-container--with-pills]="activeGroupRoutes().length > 1">
            <router-outlet></router-outlet>
          </div>
        </main>
      </div>
    </div>

    <!-- Hidden popovers & settings drawers -->
    <ui5-popover #profilePopover header-text="Account">
      <div style="width: 200px; padding: 1rem; display: flex; flex-direction: column; gap: 1rem;">
        <ui5-button icon="log" design="Negative" (click)="logout()">{{ i18n.t('app.signOut') }}</ui5-button>
      </div>
    </ui5-popover>
  `,
  styles: [`
    .app-shell { display: flex; flex-direction: column; height: 100vh; width: 100vw; position: relative; z-index: 1; }
    .app-header { flex-shrink: 0; }
    
    .app-body { flex: 1; display: flex; padding: 1.5rem; gap: 1.5rem; overflow: hidden; }
    
    /* ── Nav Island (Jobs/Ive refinement) ──────────────────────────────── */
    .app-nav-island {
      width: 80px;
      display: flex;
      flex-direction: column;
      background: var(--glass-bg);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      border: 1px solid var(--glass-border);
      border-radius: 2rem;
      box-shadow: var(--shadow-ambient);
      padding: 1rem 0;
      transition: width 0.3s var(--spring-easing);
      overflow: hidden;
    }
    .app-nav-island:hover,
    .app-nav-island:focus-within,
    .app-nav-island--expanded { width: 200px; }
    .app-nav-island:hover .nav-label,
    .app-nav-island:focus-within .nav-label,
    .app-nav-island--expanded .nav-label { opacity: 1; }

    .nav-toggle {
      display: flex; align-items: center; justify-content: center;
      width: 100%; border: none; background: transparent;
      padding: 0.5rem; cursor: pointer; color: var(--sapContent_LabelColor);
      transition: color 0.2s;
    }
    .nav-toggle:hover { color: var(--sapBrandColor); }

    .nav-group-stack { display: flex; flex-direction: column; gap: 0.5rem; width: 100%; }
    .nav-island-item {
      display: flex; align-items: center; gap: 1.25rem;
      width: 100%; border: none; background: transparent;
      padding: 1rem 1.75rem; cursor: pointer; color: var(--sapContent_LabelColor);
      transition: all 0.2s; position: relative;
    }
    .nav-island-item:hover { background: rgba(0, 0, 0, 0.03); }
    .nav-island-item ui5-icon { font-size: 1.25rem; flex-shrink: 0; }
    .nav-label { font-size: 0.875rem; font-weight: 600; white-space: nowrap; opacity: 0; transition: opacity 0.2s; }

    .nav-island-item.active { color: var(--sapBrandColor); }
    .nav-island-item.active::before {
      content: ''; position: absolute; left: 0; top: 20%; bottom: 20%;
      width: 4px; background: var(--sapBrandColor); border-radius: 0 4px 4px 0;
    }

    /* ── Main Viewport ───────────────────────────────────────────────────── */
    .app-viewport { flex: 1; display: flex; flex-direction: column; position: relative; overflow: hidden; }
    
    .context-pill-bar {
      position: absolute; top: 0; left: 0; right: 0; height: 60px;
      display: flex; align-items: center; justify-content: center; z-index: 10;
    }
    .pill-track {
      background: var(--glass-bg); backdrop-filter: blur(20px);
      border: 1px solid var(--glass-border); border-radius: 999px;
      padding: 0.25rem; display: flex; gap: 0.25rem; box-shadow: var(--shadow-ambient);
    }
    .pill-item {
      border: none; background: transparent; padding: 0.5rem 1.25rem;
      border-radius: 999px; font-size: 0.8125rem; font-weight: 600;
      color: var(--sapContent_LabelColor); cursor: pointer; transition: all 0.3s;
    }
    .pill-item--active { background: var(--sapBrandColor); color: #fff; }

    .content-container { flex: 1; overflow-y: auto; padding-top: 0; }
    .content-container--with-pills { padding-top: 75px; }

    /* RTL */
    .rtl .nav-island-item.active::before { left: auto; right: 0; border-radius: 4px 0 0 4px; }

    /* Touch / Mobile */
    @media (max-width: 768px) {
      .app-nav-island { width: 60px; border-radius: 1.5rem; padding: 0.5rem 0; }
      .app-nav-island:hover,
      .app-nav-island:focus-within { width: 60px; }
      .app-nav-island--expanded { width: 200px; }
      .app-nav-island:hover .nav-label,
      .app-nav-island:focus-within .nav-label { opacity: 0; }
      .app-nav-island--expanded .nav-label { opacity: 1; }
      .nav-island-item { padding: 0.75rem 1.25rem; }
    }
  `],
})
export class ShellComponent implements OnInit, OnDestroy {
  private readonly router = inject(Router);
  private readonly auth = inject(AuthService);
  private readonly i18n = inject(I18nService);
  
  @ViewChild('profilePopover') profilePopover!: ElementRef<any>;

  readonly navGroups = TRAINING_NAV_GROUPS;
  readonly activeGroupId = signal('home');
  readonly navExpanded = signal(false);
  private routerSub?: Subscription;

  readonly activeGroupRoutes = computed(() => {
    const groupId = this.activeGroupId();
    return TRAINING_ROUTE_LINKS.filter(link => link.group === groupId);
  });

  ngOnInit() {
    this.updateActiveGroup(this.router.url);
    this.routerSub = this.router.events.pipe(
      filter((e: Event): e is NavigationEnd => e instanceof NavigationEnd)
    ).subscribe(e => this.updateActiveGroup(e.url));
  }

  ngOnDestroy() { this.routerSub?.unsubscribe(); }

  private updateActiveGroup(url: string) {
    this.activeGroupId.set(resolveTrainingGroup(url));
  }

  groupIcon(id: string): string {
    const icons: Record<string, string> = { home: 'home', 'data-factory': 'folder', 'ai-lab': 'discussion-2', mlops: 'process' };
    return icons[id] || 'grid';
  }

  isRouteActive(path: string): boolean { return this.router.url.startsWith(path); }
  navigateTo(path: string) { this.router.navigate([path]); }
  
  onProfileClick(event: any) {
    const popover = this.profilePopover.nativeElement;
    popover.opener = event.detail.targetRef;
    popover.open = true;
  }

  toggleSettings() { /* Logic for global settings drawer */ }
  logout() { this.auth.clearToken(); this.router.navigate(['/login']); }
}

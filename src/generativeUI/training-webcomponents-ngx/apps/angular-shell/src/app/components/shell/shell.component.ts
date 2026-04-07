import {
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  ElementRef,
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
import { AppStore } from '../../store/app.store';
import { I18nService } from '../../services/i18n.service';
import {
  TRAINING_NAV_GROUPS,
  TRAINING_ROUTE_LINKS,
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
    <!-- Jony's Atmospheric Canvas -->
    <div class="app-canvas" [ngClass]="store.atmosphericClass()"></div>

    <div class="app-shell" [class.rtl]="i18n.isRtl()">
      <header class="app-header">
        <ui5-shellbar
          [primaryTitle]="i18n.t('app.title')"
          [secondaryTitle]="i18n.t('app.subtitle')"
          (profile-click)="onProfileClick($event)">
          <ui5-avatar slot="profile" icon="customer" interactive></ui5-avatar>
          <ui5-button icon="settings" slot="endContent"></ui5-button>
        </ui5-shellbar>
      </header>

      <div class="app-body">
        <nav class="app-nav-island">
          <div class="nav-group-stack">
            @for (group of navGroups; track group.id) {
              <button
                class="nav-island-item"
                [class.active]="activeGroupId() === group.id"
                (click)="navigateTo(group.defaultPath)">
                <ui5-icon [name]="groupIcon(group.id)"></ui5-icon>
                <span class="nav-label">{{ i18n.t(group.labelKey) }}</span>
              </button>
            }
          </div>
        </nav>

        <main class="app-viewport">
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

    <ui5-popover #profilePopover header-text="Account">
      <div style="width: 200px; padding: 1rem;">
        <ui5-button icon="log" design="Negative" (click)="logout()">{{ i18n.t('app.signOut') }}</ui5-button>
      </div>
    </ui5-popover>
  `,
  styles: [`
    .app-shell { display: flex; flex-direction: column; height: 100vh; width: 100vw; position: relative; z-index: 1; }
    .app-header { flex-shrink: 0; }
    .app-body { flex: 1; display: flex; padding: 1.5rem; gap: 1.5rem; overflow: hidden; }
    
    .app-nav-island {
      width: 80px; display: flex; flex-direction: column; background: var(--glass-bg);
      backdrop-filter: blur(20px); border: 1px solid var(--glass-border); border-radius: 2rem;
      box-shadow: var(--shadow-ambient); padding: 1rem 0; transition: width 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
      overflow: hidden;
    }
    .app-nav-island:hover { width: 200px; }
    .nav-group-stack { display: flex; flex-direction: column; gap: 0.5rem; width: 100%; }
    .nav-island-item {
      display: flex; align-items: center; gap: 1.25rem; width: 100%; border: none; background: transparent;
      padding: 1rem 1.75rem; cursor: pointer; color: var(--sapContent_LabelColor); position: relative;
    }
    .nav-label { font-size: 0.875rem; font-weight: 600; white-space: nowrap; opacity: 0; transition: opacity 0.2s; }
    .app-nav-island:hover .nav-label { opacity: 1; }
    .nav-island-item.active { color: var(--sapBrandColor); }
    .nav-island-item.active::before { content: ''; position: absolute; left: 0; top: 20%; bottom: 20%; width: 4px; background: var(--sapBrandColor); border-radius: 0 4px 4px 0; }

    .app-viewport { flex: 1; display: flex; flex-direction: column; position: relative; overflow: hidden; }
    .context-pill-bar { position: absolute; top: 0; left: 0; right: 0; height: 60px; display: flex; align-items: center; justify-content: center; z-index: 10; }
    .pill-track { background: var(--glass-bg); backdrop-filter: blur(20px); border: 1px solid var(--glass-border); border-radius: 999px; padding: 0.25rem; display: flex; gap: 0.25rem; box-shadow: var(--shadow-ambient); }
    .pill-item { border: none; background: transparent; padding: 0.5rem 1.25rem; border-radius: 999px; font-size: 0.8125rem; font-weight: 600; color: var(--sapContent_LabelColor); cursor: pointer; transition: all 0.3s; }
    .pill-item--active { background: var(--sapBrandColor); color: #fff; }
    .content-container { flex: 1; overflow-y: auto; }
    .content-container--with-pills { padding-top: 75px; }
  `],
})
export class ShellComponent implements OnInit, OnDestroy {
  readonly store = inject(AppStore);
  private readonly router = inject(Router);
  private readonly auth = inject(AuthService);
  readonly i18n = inject(I18nService);
  
  @ViewChild('profilePopover') profilePopover!: ElementRef<any>;

  readonly navGroups = TRAINING_NAV_GROUPS;
  readonly activeGroupId = signal('home');
  private routerSub?: Subscription;

  readonly activeGroupRoutes = computed(() => {
    return TRAINING_ROUTE_LINKS.filter(link => link.group === this.activeGroupId());
  });

  ngOnInit() {
    this.updateActiveGroup(this.router.url);
    this.routerSub = this.router.events.pipe(filter((e: Event): e is NavigationEnd => e instanceof NavigationEnd))
      .subscribe(e => this.updateActiveGroup(e.url));
  }

  ngOnDestroy() { this.routerSub?.unsubscribe(); }
  private updateActiveGroup(url: string) { this.activeGroupId.set(resolveTrainingGroup(url)); }
  groupIcon(id: string): string {
    const icons: Record<string, string> = { home: 'home', 'data-factory': 'folder', 'ai-lab': 'discussion-2', mlops: 'process' };
    return icons[id] || 'grid';
  }
  isRouteActive(path: string): boolean { return this.router.url.startsWith(path); }
  navigateTo(path: string) { this.router.navigate([path]); }
  onProfileClick(event: any) { this.profilePopover.nativeElement.opener = event.detail.targetRef; this.profilePopover.nativeElement.open = true; }
  logout() { this.auth.clearToken(); this.router.navigate(['/login']); }
}

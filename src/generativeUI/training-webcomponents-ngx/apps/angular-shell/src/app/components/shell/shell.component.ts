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
  HostListener,
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
    <a href="#main-content" class="skip-link" (click)="skipToMain($event)">Skip to main content</a>
    <div class="app-canvas" [ngClass]="store.atmosphericClass()" [style.transform]="canvasTransform()"></div>

    <div class="app-shell" [class.rtl]="i18n.isRtl()" (mousemove)="onMouseMove($event)">
      <header class="app-header">
        <ui5-shellbar
          [primaryTitle]="i18n.t('app.title')"
          [secondaryTitle]="i18n.t('app.subtitle')"
          (profile-click)="onProfileClick($event)">
          <ui5-avatar slot="profile" icon="customer" interactive></ui5-avatar>
          <ui5-button icon="search" slot="endContent" (click)="toggleSearch()" aria-label="Search (⌘K)"></ui5-button>
          <ui5-button icon="settings" slot="endContent" aria-label="Settings"></ui5-button>
        </ui5-shellbar>
      </header>

      <div class="app-body">
        <nav class="app-nav-island slideUp" role="navigation" aria-label="Main navigation">
          <div class="nav-group-stack">
            @for (group of navGroups; track group.id) {
              <button
                class="nav-island-item"
                [class.active]="activeGroupId() === group.id"
                [attr.aria-current]="activeGroupId() === group.id ? 'page' : null"
                (click)="navigateTo(group.defaultPath)">
                <ui5-icon [name]="groupIcon(group.id)"></ui5-icon>
                <span class="nav-label">{{ i18n.t(group.labelKey) }}</span>
              </button>
            }
          </div>
        </nav>

        <main id="main-content" class="app-viewport" tabindex="-1">
          @if (activeGroupRoutes().length > 1) {
            <div class="context-pill-bar slideUp">
              <div class="pill-track">
                @for (route of activeGroupRoutes(); track route.path) {
                  <button
                    class="pill-item"
                    [class.pill-item--active]="isRouteActive(route.path)"
                    [attr.aria-current]="isRouteActive(route.path) ? 'page' : null"
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

    <!-- Spotlight Command Palette (WWDC Polish) -->
    <ui5-dialog #searchDialog class="spotlight-dialog" [attr.header-text]="'Spotlight Search'" (close)="showSearch.set(false)">
      <div class="spotlight-body">
        <ui5-input #searchInput class="spotlight-input" placeholder="Jump to a hub, model, or task..." (input)="onSearchInput($event)">
          <ui5-icon slot="icon" name="search"></ui5-icon>
        </ui5-input>
        
        <ui5-list class="spotlight-results" separators="None">
          @for (res of filteredResults(); track res.path) {
            <ui5-li icon="navigation-right-arrow" [description]="res.group" (click)="jumpTo(res.path)">
              {{ i18n.t(res.labelKey) }}
            </ui5-li>
          }
          @if (filteredResults().length === 0) {
            <div class="no-results">No matches found for your query.</div>
          }
        </ui5-list>
      </div>
    </ui5-dialog>

    <ui5-popover #profilePopover header-text="Account">
      <div style="width: 200px; padding: 1rem;">
        <ui5-button icon="log" design="Negative" (click)="logout()">{{ i18n.t('app.signOut') }}</ui5-button>
      </div>
    </ui5-popover>
  `,
  styles: [`
    .app-shell { display: flex; flex-direction: column; height: 100vh; width: 100vw; position: relative; z-index: 1; overflow: hidden; }
    .app-header { flex-shrink: 0; }
    .app-body { flex: 1; display: flex; padding: 1.5rem; gap: 1.5rem; overflow: hidden; }
    
    .app-nav-island {
      width: 80px; display: flex; flex-direction: column; background: var(--glass-bg);
      backdrop-filter: blur(20px); border: 1px solid var(--glass-border); border-radius: 2rem;
      box-shadow: var(--shadow-ambient); padding: 1rem 0; transition: width 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
      overflow: hidden;
    }
    .app-nav-island:hover, .app-nav-island:focus-within { width: 200px; }
    .nav-group-stack { display: flex; flex-direction: column; gap: 0.5rem; width: 100%; }
    .nav-island-item {
      display: flex; align-items: center; gap: 1.25rem; width: 100%; border: none; background: transparent;
      padding: 1rem 1.75rem; cursor: pointer; color: var(--sapContent_LabelColor); position: relative;
    }
    .nav-label { font-size: 0.875rem; font-weight: 600; white-space: nowrap; opacity: 0; transition: opacity 0.2s; }
    .app-nav-island:hover .nav-label, .app-nav-island:focus-within .nav-label { opacity: 1; }
    .nav-island-item.active { color: var(--sapBrandColor); }
    .nav-island-item.active::before { content: ''; position: absolute; left: 0; top: 20%; bottom: 20%; width: 4px; background: var(--sapBrandColor); border-radius: 0 4px 4px 0; }

    .app-viewport { flex: 1; display: flex; flex-direction: column; position: relative; overflow: hidden; }
    .context-pill-bar { position: absolute; top: 0; left: 0; right: 0; height: 60px; display: flex; align-items: center; justify-content: center; z-index: 10; }
    .pill-track { background: var(--glass-bg); backdrop-filter: blur(20px); border: 1px solid var(--glass-border); border-radius: 999px; padding: 0.25rem; display: flex; gap: 0.25rem; box-shadow: var(--shadow-ambient); }
    .pill-item { border: none; background: transparent; padding: 0.5rem 1.25rem; border-radius: 999px; font-size: 0.8125rem; font-weight: 600; color: var(--sapContent_LabelColor); cursor: pointer; transition: all 0.3s; }
    .pill-item--active { background: var(--sapBrandColor); color: #fff; }
    .content-container { flex: 1; overflow-y: auto; }
    .content-container--with-pills { padding-top: 75px; }

    /* ── Skip Link ── */
    .skip-link {
      position: absolute; top: -100%; left: 50%; transform: translateX(-50%);
      background: var(--sapBrandColor); color: #fff; padding: 0.75rem 1.5rem;
      border-radius: 0 0 0.75rem 0.75rem; z-index: 9999; font-weight: 600;
      text-decoration: none; transition: top 0.2s;
    }
    .skip-link:focus { top: 0; }

    /* ── Spotlight Polish ── */
    :host .spotlight-dialog { --sapDialog_Content_Padding: 0; border-radius: 1.5rem; }
    .spotlight-body { width: 600px; max-width: 90vw; display: flex; flex-direction: column; }
    .spotlight-input { width: 100%; padding: 1.5rem; --sapField_BorderColor: transparent; --sapField_Focus_BorderColor: transparent; font-size: 1.25rem; }
    .spotlight-results { max-height: 400px; overflow-y: auto; }
    .no-results { padding: 2rem; text-align: center; opacity: 0.5; }
  `],
})
export class ShellComponent implements OnInit, OnDestroy {
  readonly store = inject(AppStore);
  private readonly router = inject(Router);
  private readonly auth = inject(AuthService);
  readonly i18n = inject(I18nService);
  
  @ViewChild('profilePopover') profilePopover!: ElementRef<any>;
  @ViewChild('searchDialog') searchDialog!: ElementRef<any>;
  @ViewChild('searchInput') searchInput!: ElementRef<any>;

  readonly navGroups = TRAINING_NAV_GROUPS;
  readonly activeGroupId = signal('home');
  readonly showSearch = signal(false);
  readonly searchQuery = signal('');
  
  // Magnetic Canvas Logic (rAF-throttled)
  readonly mouseX = signal(0);
  readonly mouseY = signal(0);
  readonly canvasTransform = computed(() => `translate(${this.mouseX() / 100}px, ${this.mouseY() / 100}px) scale(1.05)`);
  private rafId: number | null = null;

  private routerSub?: Subscription;

  readonly activeGroupRoutes = computed(() => {
    return TRAINING_ROUTE_LINKS.filter(link => link.group === this.activeGroupId());
  });

  readonly filteredResults = computed(() => {
    const q = this.searchQuery().toLowerCase();
    if (!q) return TRAINING_ROUTE_LINKS.slice(0, 5);
    return TRAINING_ROUTE_LINKS.filter(link => 
      this.i18n.t(link.labelKey).toLowerCase().includes(q) || 
      link.group.toLowerCase().includes(q)
    );
  });

  @HostListener('window:keydown', ['$event'])
  handleKeyboardEvent(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) && event.key === 'k') {
      event.preventDefault();
      this.toggleSearch();
    }
  }

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
  
  toggleSearch() {
    const dialog = this.searchDialog.nativeElement;
    if (dialog.open) {
      dialog.close();
    } else {
      dialog.show();
      setTimeout(() => this.searchInput.nativeElement.focus(), 100);
    }
  }

  onSearchInput(e: any) { this.searchQuery.set(e.target.value); }
  jumpTo(path: string) { this.searchDialog.nativeElement.close(); this.navigateTo(path); }

  onMouseMove(e: MouseEvent) {
    if (this.rafId !== null) return;
    this.rafId = requestAnimationFrame(() => {
      this.mouseX.set(e.clientX - window.innerWidth / 2);
      this.mouseY.set(e.clientY - window.innerHeight / 2);
      this.rafId = null;
    });
  }

  skipToMain(event: globalThis.Event) {
    event.preventDefault();
    document.getElementById('main-content')?.focus();
  }

  onProfileClick(event: any) { this.profilePopover.nativeElement.opener = event.detail.targetRef; this.profilePopover.nativeElement.open = true; }
  logout() { this.auth.clearToken(); this.router.navigate(['/login']); }
}

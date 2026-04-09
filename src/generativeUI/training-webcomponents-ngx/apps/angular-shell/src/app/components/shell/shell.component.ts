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
import { I18nService, Language } from '../../services/i18n.service';
import { WorkspaceService } from '../../services/workspace.service';
import {
  TRAINING_NAV_GROUPS,
  TRAINING_ROUTE_LINKS,
  TrainingRouteGroupId,
  resolveTrainingGroup,
} from '../../app.navigation';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [CommonModule, RouterOutlet, Ui5TrainingComponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <a href="#main-content" class="skip-link" (click)="skipToMain($event)">{{ i18n.t('shell.skipToMain') }}</a>
    <div
      class="app-canvas"
      aria-hidden="true"
      [ngClass]="store.atmosphericClass()"
      [style.transform]="canvasTransform()"></div>

    <div
      class="app-shell"
      [class.rtl]="i18n.isRtl()"
      [class.app-shell--reduced-motion]="reducedMotion()"
      (mousemove)="onMouseMove($event)">

      <!-- ── Fiori ShellBar ── -->
      <ui5-shellbar
        [primaryTitle]="i18n.t('app.title')"
        [secondaryTitle]="i18n.t('app.subtitle')"
        [accessibilityAttributes]="shellbarA11y"
        (profile-click)="toggleUserMenu($event)"
        (custom-item-click)="onCustomItemClick($event)">

        <ui5-shellbar-search
          slot="searchField"
          [placeholder]="i18n.t('shell.spotlightPlaceholder')"
          show-clear-icon="true"
          (ui5Search)="onShellSearch($event)">
        </ui5-shellbar-search>

        <ui5-avatar
          id="shell-profile-avatar"
          slot="profile"
          shape="Circle"
          size="XS"
          initials="AI"
          color-scheme="Accent6"
          interactive="true"
          [accessibleName]="i18n.t('shell.account')">
        </ui5-avatar>

        <ui5-shellbar-item id="action-lang" icon="globe" [text]="i18n.t('shell.langAriaLabel')"></ui5-shellbar-item>
      </ui5-shellbar>

      <!-- ── User Menu ── -->
      <ui5-user-menu
        [open]="userMenuOpen()"
        opener="shell-profile-avatar"
        show-manage-account="false"
        (ui5ItemClick)="onUserMenuItemClick($event)"
        (ui5SignOutClick)="logout()"
        (ui5Close)="userMenuOpen.set(false)">
        <ui5-user-menu-account
          slot="account"
          avatarInitials="AI"
          [titleText]="i18n.t('app.title')"
          [subtitleText]="i18n.t('app.subtitle')">
        </ui5-user-menu-account>
        <ui5-user-menu-item icon="action-settings" [text]="i18n.t('shell.settingsAriaLabel')" data-path="/workspace"></ui5-user-menu-item>
      </ui5-user-menu>

      <!-- ── Language Menu ── -->
      <ui5-menu #langMenu (item-click)="onLanguageClick($event)">
        @for (lang of i18n.supportedLangs; track lang) {
          <ui5-menu-item [text]="i18n.langLabels[lang]" [id]="lang" [icon]="i18n.currentLang() === lang ? 'accept' : null"></ui5-menu-item>
        }
      </ui5-menu>

      <!-- ── NavigationLayout + SideNavigation + Content ── -->
      <ui5-navigation-layout mode="Auto">
        <ui5-side-navigation
          slot="sideContent"
          (ui5SelectionChange)="onSideNavSelect($event)">

          @for (group of navGroups(); track group.id) {
            <ui5-side-navigation-group [text]="i18n.t(group.labelKey)" [expanded]="activeGroupId() === group.id">
              @for (route of groupRoutes(group.id); track route.path) {
                <ui5-side-navigation-item
                  [text]="i18n.t(route.labelKey)"
                  [icon]="route.icon"
                  [selected]="isRouteActive(route.path)"
                  [attr.data-path]="route.path">
                </ui5-side-navigation-item>
              }
            </ui5-side-navigation-group>
          }

          <ui5-side-navigation-item
            slot="fixedItems"
            [text]="i18n.t('shell.settingsAriaLabel')"
            icon="action-settings"
            [selected]="isRouteActive('/workspace')"
            data-path="/workspace">
          </ui5-side-navigation-item>
        </ui5-side-navigation>

        <!-- ── Main Viewport ── -->
        <main id="main-content" class="app-viewport" tabindex="-1">
          <router-outlet></router-outlet>
        </main>
      </ui5-navigation-layout>
    </div>

    <!-- ── Spotlight Command Palette (Cmd+K) ── -->
    <ui5-dialog #searchDialog class="spotlight-dialog" [attr.header-text]="i18n.t('shell.spotlightTitle')" (close)="showSearch.set(false)">
      <div class="spotlight-body">
        <ui5-input #searchInput class="spotlight-input" [placeholder]="i18n.t('shell.spotlightPlaceholder')" (input)="onSearchInput($event)">
          <ui5-icon slot="icon" name="search"></ui5-icon>
        </ui5-input>
        <ui5-list class="spotlight-results" separators="None">
          @for (res of filteredResults(); track res.path) {
            <ui5-li icon="navigation-right-arrow" [description]="i18n.t(groupLabelKey(res.group))" (click)="jumpTo(res.path)">
              {{ i18n.t(res.labelKey) }}
            </ui5-li>
          }
          @if (filteredResults().length === 0) {
            <div class="no-results">{{ i18n.t('shell.noMatches') }}</div>
          }
        </ui5-list>
      </div>
    </ui5-dialog>
  `,
  styles: [`
    .app-shell {
      display: flex; flex-direction: column; height: 100vh; width: 100vw;
      position: relative; z-index: 1; overflow: hidden;
    }
    .app-shell--reduced-motion * { transition: none !important; }

    /* ── ShellBar Liquid Glass ── */
    ui5-shellbar {
      flex-shrink: 0; position: relative; z-index: 10;
      backdrop-filter: saturate(180%) blur(20px);
      -webkit-backdrop-filter: saturate(180%) blur(20px);
      border-bottom: 0.5px solid rgba(255, 255, 255, 0.18);
      box-shadow: 0 0.5px 0 rgba(255, 255, 255, 0.12), 0 4px 30px rgba(0, 0, 0, 0.08);
    }

    /* ── NavigationLayout fills remaining space ── */
    ui5-navigation-layout { flex: 1; min-height: 0; overflow: hidden; }

    /* ── Side Navigation Liquid Glass ── */
    ui5-side-navigation {
      backdrop-filter: saturate(150%) blur(24px);
      -webkit-backdrop-filter: saturate(150%) blur(24px);
      background: rgba(255, 255, 255, 0.06);
      border-inline-end: 0.5px solid rgba(255, 255, 255, 0.1);
    }

    /* ── Main Viewport ── */
    .app-viewport { flex: 1; overflow-y: auto; }

    /* ── Skip Link ── */
    .skip-link {
      position: absolute; top: -100%; left: 50%; transform: translateX(-50%);
      background: var(--sapBrandColor); color: #fff; padding: 0.75rem 1.5rem;
      border-radius: 0 0 0.75rem 0.75rem; z-index: 9999; font-weight: 600;
      text-decoration: none; transition: top 0.2s;
    }
    .skip-link:focus { top: 0; }

    /* ── Spotlight Command Palette ── */
    :host .spotlight-dialog { --sapDialog_Content_Padding: 0; border-radius: 1.5rem; }
    .spotlight-body { width: 600px; max-width: 90vw; display: flex; flex-direction: column; }
    .spotlight-input {
      width: 100%; padding: 1.5rem;
      --sapField_BorderColor: transparent; --sapField_Focus_BorderColor: transparent;
      font-size: 1.25rem;
    }
    .spotlight-results { max-height: 400px; overflow-y: auto; }
    .no-results { padding: 2rem; text-align: center; opacity: 0.5; }
  `],
})
export class ShellComponent implements OnInit, OnDestroy {
  readonly store = inject(AppStore);
  private readonly router = inject(Router);
  private readonly auth = inject(AuthService);
  readonly i18n = inject(I18nService);
  private readonly workspace = inject(WorkspaceService);

  @ViewChild('langMenu') langMenu!: ElementRef<any>;
  @ViewChild('searchDialog') searchDialog!: ElementRef<any>;
  @ViewChild('searchInput') searchInput!: ElementRef<any>;

  readonly shellbarA11y = {
    logo: { name: 'SAP AI Workbench' },
    profile: { name: 'User Profile', hasPopup: 'menu' as const },
  };

  readonly activeGroupId = signal<TrainingRouteGroupId>('home');
  readonly currentPath = signal('/dashboard');
  readonly showSearch = signal(false);
  readonly searchQuery = signal('');
  readonly reducedMotion = signal(false);
  readonly userMenuOpen = signal(false);

  // Decorative canvas movement
  readonly mouseX = signal(0);
  readonly mouseY = signal(0);
  readonly canvasTransform = computed(() =>
    this.reducedMotion()
      ? 'none'
      : `translate(${this.mouseX() / 100}px, ${this.mouseY() / 100}px) scale(1.05)`,
  );
  private rafId: number | null = null;
  private motionMediaQuery?: MediaQueryList;
  private routerSub?: Subscription;

  readonly visibleRouteLinks = computed(() => {
    const visibleRoutes = new Set(this.workspace.visibleNavLinks().map((link) => link.route));
    return TRAINING_ROUTE_LINKS.filter((link) => visibleRoutes.has(link.path));
  });

  readonly navGroups = computed(() =>
    TRAINING_NAV_GROUPS.filter((group) =>
      this.visibleRouteLinks().some((link) => link.group === group.id),
    ),
  );

  readonly filteredResults = computed(() => {
    const q = this.searchQuery().trim().toLowerCase();
    const routes = this.visibleRouteLinks().filter((link) => {
      if (!q) return link.tier === 'primary';
      return this.i18n.t(link.labelKey).toLowerCase().includes(q)
        || this.i18n.t(this.groupLabelKey(link.group)).toLowerCase().includes(q);
    });
    return routes.slice(0, 8);
  });

  @HostListener('window:keydown', ['$event'])
  handleKeyboardEvent(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) && event.key === 'k') {
      event.preventDefault();
      this.toggleSearch();
    }
  }

  ngOnInit() {
    this.setupMotionPreference();
    this.updateActiveGroup(this.router.url);
    this.routerSub = this.router.events
      .pipe(filter((e: Event): e is NavigationEnd => e instanceof NavigationEnd))
      .subscribe((e) => this.updateActiveGroup(e.url));
  }

  ngOnDestroy() {
    this.routerSub?.unsubscribe();
    if (this.rafId !== null) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    this.teardownMotionPreference();
  }

  // --- Navigation ---

  private updateActiveGroup(url: string) {
    const currentPath = url.split('?')[0].split('#')[0] || '/dashboard';
    this.currentPath.set(currentPath);
    this.activeGroupId.set(resolveTrainingGroup(currentPath));
  }

  groupLabelKey(group: TrainingRouteGroupId): string {
    const keys: Record<TrainingRouteGroupId, string> = {
      home: 'navGroup.home', data: 'navGroup.data',
      assist: 'navGroup.assist', operations: 'navGroup.operations',
    };
    return keys[group];
  }

  /** Returns visible routes for a given nav group (used by side-navigation groups) */
  groupRoutes(groupId: TrainingRouteGroupId) {
    return this.visibleRouteLinks().filter((link) => link.group === groupId);
  }

  isRouteActive(path: string): boolean {
    return this.router.url.startsWith(path);
  }

  navigateTo(path: string) {
    this.router.navigate([path]);
  }

  // --- Side Navigation ---

  onSideNavSelect(event: any): void {
    const path = event.detail?.item?.getAttribute?.('data-path');
    if (path) this.router.navigate([path]);
  }

  // --- ShellBar ---

  toggleUserMenu(_event: any): void {
    this.userMenuOpen.set(!this.userMenuOpen());
  }

  onUserMenuItemClick(event: any): void {
    const path = event.detail?.item?.getAttribute?.('data-path');
    if (path) {
      this.userMenuOpen.set(false);
      this.router.navigate([path]);
    }
  }

  onShellSearch(_event: any): void {
    this.toggleSearch();
  }

  onCustomItemClick(event: any) {
    const icon = event.detail.item.icon;
    if (icon === 'globe') {
      this.toggleLanguageMenu(event);
    }
  }

  // --- Search Spotlight ---

  toggleSearch() {
    const dialog = this.searchDialog.nativeElement;
    if (dialog.open) {
      dialog.close();
    } else {
      dialog.show();
      setTimeout(() => this.searchInput.nativeElement.focus(), 100);
    }
  }

  onSearchInput(e: globalThis.Event) {
    const input = e.target as HTMLInputElement | null;
    this.searchQuery.set(input?.value ?? '');
  }

  jumpTo(path: string) {
    this.searchDialog.nativeElement.close();
    this.navigateTo(path);
  }

  // --- Language ---

  toggleLanguageMenu(event: any) {
    const menu = this.langMenu.nativeElement;
    menu.opener = event.detail.targetRef;
    menu.open = true;
  }

  onLanguageClick(event: CustomEvent) {
    const langId = event.detail.item.id as Language | undefined;
    if (langId) this.i18n.setLanguage(langId);
  }

  // --- Auth ---

  logout() {
    this.userMenuOpen.set(false);
    this.auth.clearToken();
    this.router.navigate(['/login']);
  }

  // --- Canvas / Motion ---

  onMouseMove(e: MouseEvent) {
    if (this.reducedMotion()) return;
    if (this.rafId !== null) return;
    this.rafId = requestAnimationFrame(() => {
      this.mouseX.set(e.clientX - window.innerWidth / 2);
      this.mouseY.set(e.clientY - window.innerHeight / 2);
      this.rafId = null;
    });
  }

  skipToMain(event: globalThis.Event) {
    event.preventDefault();
    const main = document.getElementById('main-content');
    main?.focus();
    main?.scrollIntoView({ block: 'start' });
  }

  private setupMotionPreference(): void {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    this.motionMediaQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    this.applyMotionPreference(this.motionMediaQuery.matches);
    if (typeof this.motionMediaQuery.addEventListener === 'function') {
      this.motionMediaQuery.addEventListener('change', this.handleMotionPreferenceChange);
    } else {
      this.motionMediaQuery.addListener(this.handleMotionPreferenceChange);
    }
  }

  private teardownMotionPreference(): void {
    if (!this.motionMediaQuery) return;
    if (typeof this.motionMediaQuery.removeEventListener === 'function') {
      this.motionMediaQuery.removeEventListener('change', this.handleMotionPreferenceChange);
    } else {
      this.motionMediaQuery.removeListener(this.handleMotionPreferenceChange);
    }
  }

  private readonly handleMotionPreferenceChange = (event: MediaQueryListEvent): void => {
    this.applyMotionPreference(event.matches);
  };

  private applyMotionPreference(matches: boolean): void {
    this.reducedMotion.set(matches);
    if (matches) { this.mouseX.set(0); this.mouseY.set(0); }
  }
}

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
import { CommonModule, NgClass } from '@angular/common';
import { Router, RouterOutlet, NavigationEnd, Event } from '@angular/router';
import { filter, Subscription } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { AppStore } from '../../store/app.store';
import { I18nService, Language } from '../../services/i18n.service';
import { NavigationAssistantService } from '../../services/navigation-assistant.service';
import { WorkspaceService } from '../../services/workspace.service';
import {
  TRAINING_NAV_GROUPS,
  TRAINING_ROUTE_LINKS,
  TrainingRouteGroupId,
  resolveTrainingGroup,
} from '../../app.navigation';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { ModeSwitcherComponent } from '../../shared/components/mode-switcher/mode-switcher.component';
import type { ContextPill } from '../../shared/utils/mode.types';

interface ShellNotificationItem {
  icon: string;
  title: string;
  description: string;
}

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [CommonModule, NgClass, RouterOutlet, Ui5TrainingComponentsModule, ModeSwitcherComponent],
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
      [ngClass]="store.modeThemeClass()"
      (mousemove)="onMouseMove($event)">
      <header class="app-header">
        <ui5-shellbar
          [primaryTitle]="i18n.t('app.title')"
          [secondaryTitle]="i18n.t('app.subtitle')"
          show-notifications
          [attr.notifications-count]="shellNotifications().length"
          show-co-pilot
          (logo-click)="navigateTo('/dashboard')"
          (notifications-click)="onNotificationsClick($event)"
          (co-pilot-click)="onCoPilotClick($event)"
          (profile-click)="onProfileClick($event)">
          <ui5-avatar #profileTrigger slot="profile" [initials]="userInitials()" [colorScheme]="avatarColorScheme()" shape="Circle" size="S" interactive style="box-shadow: 0 0 0 2px rgba(255,255,255,0.4), var(--liquid-glass-shadow);"></ui5-avatar>
        </ui5-shellbar>
        <div class="header-actions">
          <app-mode-switcher></app-mode-switcher>
          <ui5-button icon="home" design="Transparent" (click)="navigateTo('/dashboard')" aria-label="Open dashboard"></ui5-button>
          <ui5-button #searchButton icon="search" design="Transparent" (click)="toggleSearch()" [attr.aria-label]="i18n.t('shell.searchAriaLabel')"></ui5-button>
          
          <div class="header-actions__team">
            <span class="workspace-context">{{ currentWorkspaceLabel() }}</span>
          </div>

          <ui5-button #languageButton icon="globe" design="Transparent" (click)="toggleLanguageMenu($event)" [attr.aria-label]="i18n.t('shell.langAriaLabel')"></ui5-button>
          @if (canPinCurrentPage()) {
            <ui5-button
              icon="favorite"
              design="Transparent"
              [class.header-actions__pin--active]="currentPagePinned()"
              (click)="toggleCurrentPagePin()"
              [attr.aria-label]="currentPagePinned() ? i18n.t('shell.unpinPage', { page: currentPageLabel() }) : i18n.t('shell.pinPage', { page: currentPageLabel() })"></ui5-button>
          }
          <ui5-button icon="settings" design="Transparent" (click)="navigateTo('/workspace')" [attr.aria-label]="i18n.t('shell.settingsAriaLabel')"></ui5-button>
        </div>
      </header>

      <div class="app-body">
        <nav class="app-nav-island slideUp" role="navigation" [attr.aria-label]="i18n.t('shell.mainNavAriaLabel')">
          <div class="nav-group-stack">
            @for (group of navGroups(); track group.id) {
              <button
                type="button"
                class="nav-island-item"
                [class.active]="activeGroupId() === group.id"
                [class.mode-suggested]="isModeRelevantGroup(group.id)"
                [attr.aria-current]="activeGroupId() === group.id ? 'page' : null"
                (click)="navigateTo(group.defaultPath)">
                <ui5-icon [name]="groupIcon(group.id)"></ui5-icon>
                <span class="nav-label">{{ i18n.t(group.labelKey) }}</span>
              </button>
            }
          </div>
        </nav>

        <main id="main-content" class="app-viewport" tabindex="-1">
          @if (store.contextPills().length > 0) {
            <div class="mode-pill-bar slideUp">
              <div class="pill-track">
                @for (pill of store.contextPills(); track pill.label) {
                  <button class="pill-item pill-item--mode" (click)="onModePillClick(pill)">
                    <ui5-icon [name]="pill.icon" class="pill-icon"></ui5-icon>
                    {{ pill.label }}
                  </button>
                }
              </div>
            </div>
          }

          @if (activeGroupRoutes().length > 1) {
            <div class="context-pill-bar slideUp">
              <div class="pill-track">
                @for (route of activeGroupRoutes(); track route.path) {
                  <button
                    type="button"
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

    <!-- Spotlight Command Palette -->
    <ui5-dialog #searchDialog class="spotlight-dialog" [attr.header-text]="i18n.t('shell.spotlightTitle')" (close)="closeSearchDialog()">
      <div class="spotlight-body">
        <div class="spotlight-input-wrapper">
          <ui5-icon name="search" class="spotlight-search-icon"></ui5-icon>
          <input
            #searchInput
            class="spotlight-native-input"
            [placeholder]="i18n.t('shell.spotlightPlaceholder')"
            (input)="onSearchInput($event)"
            [value]="searchQuery()"
            spellcheck="false"
            autocomplete="off" />
          <ui5-button
            *ngIf="searchQuery()"
            icon="decline"
            design="Transparent"
            class="spotlight-clear-btn"
            (click)="searchQuery.set(''); selectedSearchIndex.set(0)"></ui5-button>
        </div>

        <div class="spotlight-results" #resultsList>
          @if (!searchQuery().trim()) {
            @if (pinnedEntries().length > 0) {
              <section class="spotlight-section">
                <div class="spotlight-section__title">{{ i18n.t('shell.savedPages') }}</div>
                @for (res of pinnedEntries(); track res.path) {
                  <div class="spotlight-entry" [class.selected]="effectiveSearchEntries()[selectedSearchIndex()]?.path === res.path">
                    <button type="button" class="spotlight-entry__main" (click)="jumpTo(res.path)">
                      <span class="spotlight-entry__icon" aria-hidden="true"><ui5-icon [name]="res.icon"></ui5-icon></span>
                      <span class="spotlight-entry__copy">
                        <span class="spotlight-entry__eyebrow">{{ i18n.t(groupLabelKey(res.group)) }}</span>
                        <span class="spotlight-entry__title">{{ i18n.t(res.labelKey) }}</span>
                      </span>
                    </button>
                    <button
                      type="button"
                      class="spotlight-entry__pin spotlight-entry__pin--active"
                      (click)="togglePinned(res.path, $event)"
                      [attr.aria-label]="i18n.t('shell.unpinPage', { page: i18n.t(res.labelKey) })">
                      <ui5-icon name="favorite"></ui5-icon>
                    </button>
                  </div>
                }
              </section>
            }

            @if (recentEntries().length > 0) {
              <section class="spotlight-section">
                <div class="spotlight-section__title">{{ i18n.t('shell.recentPages') }}</div>
                @for (res of recentEntries(); track res.path) {
                  <div class="spotlight-entry" [class.selected]="effectiveSearchEntries()[selectedSearchIndex()]?.path === res.path">
                    <button type="button" class="spotlight-entry__main" (click)="jumpTo(res.path)">
                      <span class="spotlight-entry__icon" aria-hidden="true"><ui5-icon [name]="res.icon"></ui5-icon></span>
                      <span class="spotlight-entry__copy">
                        <span class="spotlight-entry__eyebrow">{{ i18n.t(groupLabelKey(res.group)) }}</span>
                        <span class="spotlight-entry__title">{{ i18n.t(res.labelKey) }}</span>
                      </span>
                    </button>
                    <button
                      type="button"
                      class="spotlight-entry__pin"
                      (click)="togglePinned(res.path, $event)"
                      [attr.aria-label]="i18n.t('shell.pinPage', { page: i18n.t(res.labelKey) })">
                      <ui5-icon name="favorite"></ui5-icon>
                    </button>
                  </div>
                }
              </section>
            }

            <section class="spotlight-section">
              <div class="spotlight-section__title">{{ i18n.t('shell.suggestedPages') }}</div>
              @for (res of suggestedEntries(); track res.path) {
                <div class="spotlight-entry" [class.selected]="effectiveSearchEntries()[selectedSearchIndex()]?.path === res.path">
                  <button type="button" class="spotlight-entry__main" (click)="jumpTo(res.path)">
                    <span class="spotlight-entry__icon" aria-hidden="true"><ui5-icon [name]="res.icon"></ui5-icon></span>
                    <span class="spotlight-entry__copy">
                      <span class="spotlight-entry__eyebrow">{{ i18n.t(groupLabelKey(res.group)) }}</span>
                      <span class="spotlight-entry__title">{{ i18n.t(res.labelKey) }}</span>
                    </span>
                  </button>
                  <button
                    type="button"
                    class="spotlight-entry__pin"
                    [class.spotlight-entry__pin--active]="isPinned(res.path)"
                    (click)="togglePinned(res.path, $event)"
                    [attr.aria-label]="isPinned(res.path) ? i18n.t('shell.unpinPage', { page: i18n.t(res.labelKey) }) : i18n.t('shell.pinPage', { page: i18n.t(res.labelKey) })">
                    <ui5-icon name="favorite"></ui5-icon>
                  </button>
                </div>
              }
            </section>
          } @else {
            @if (searchResults().length > 0) {
              <section class="spotlight-section">
                <div class="spotlight-section__title">{{ i18n.t('common.search') }}</div>
                @for (res of searchResults(); track res.path) {
                  <div class="spotlight-entry" [class.selected]="effectiveSearchEntries()[selectedSearchIndex()]?.path === res.path">
                    <button type="button" class="spotlight-entry__main" (click)="jumpTo(res.path)">
                      <span class="spotlight-entry__icon" aria-hidden="true"><ui5-icon [name]="res.icon"></ui5-icon></span>
                      <span class="spotlight-entry__copy">
                        <span class="spotlight-entry__eyebrow">{{ i18n.t(groupLabelKey(res.group)) }}</span>
                        <span class="spotlight-entry__title">{{ i18n.t(res.labelKey) }}</span>
                      </span>
                    </button>
                    <button
                      type="button"
                      class="spotlight-entry__pin"
                      [class.spotlight-entry__pin--active]="isPinned(res.path)"
                      (click)="togglePinned(res.path, $event)"
                      [attr.aria-label]="isPinned(res.path) ? i18n.t('shell.unpinPage', { page: i18n.t(res.labelKey) }) : i18n.t('shell.pinPage', { page: i18n.t(res.labelKey) })">
                      <ui5-icon name="favorite"></ui5-icon>
                    </button>
                  </div>
                }
              </section>
            } @else {
              <div class="no-results">{{ i18n.t('shell.noMatches') }}</div>
            }
          }
        </div>
      </div>
    </ui5-dialog>

    <ui5-popover #notificationsPopover [headerText]="i18n.t('common.notifications')" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
      <div class="user-menu">
        @if (shellNotifications().length > 0) {
          <ui5-list separators="Inner">
            @for (notification of shellNotifications(); track notification.title + notification.description) {
              <ui5-li [icon]="notification.icon" [description]="notification.description">{{ notification.title }}</ui5-li>
            }
          </ui5-list>
        } @else {
          <div class="notification-empty">No active notifications</div>
        }
        <footer class="user-menu__footer">
          <ui5-button design="Transparent" (click)="notificationsPopover.nativeElement.close()">Close</ui5-button>
        </footer>
      </div>
    </ui5-popover>

    <ui5-popover #profilePopover [headerText]="i18n.t('shell.profileTitle')" placement-type="Bottom" vertical-align="Bottom" horizontal-align="Right">
      <div class="user-menu">
        <header class="user-menu__header">
          <div class="avatar-container" style="position: relative; margin-bottom: 0.5rem;">
            <ui5-avatar [initials]="userInitials()" [colorScheme]="avatarColorScheme()" shape="Circle" size="XL" style="box-shadow: 0 12px 32px rgba(0,0,0,0.15); border: 4px solid #fff;"></ui5-avatar>
            <div class="status-indicator" style="position: absolute; bottom: 6px; right: 6px; width: 18px; height: 18px; border-radius: 50%; background: var(--color-success); border: 3px solid #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.1);"></div>
          </div>
          <div class="user-menu__info">
            <span class="user-menu__name">{{ userDisplayName() }}</span>
            <span class="user-menu__role">{{ userTeamName() || 'Personal workspace' }}</span>
            <span class="user-menu__email">{{ userShortId() }}</span>
          </div>
        </header>

        <ui5-list separators="None">
          <ui5-li icon="settings" (click)="closeProfile()">{{ i18n.t('shell.settings') }}</ui5-li>
          <ui5-li icon="palette">{{ i18n.t('shell.appearance') }}</ui5-li>
          <ui5-li icon="customer">{{ i18n.t('shell.account') }}</ui5-li>
        </ui5-list>

        <footer class="user-menu__footer">
          <ui5-button design="Transparent" (click)="logout()" style="width: 100%; color: var(--color-error); font-weight: 700;">{{ i18n.t('shell.logout') }}</ui5-button>
        </footer>
      </div>
    </ui5-popover>

    <ui5-menu #langMenu (item-click)="onLanguageClick($event)">
      @for (lang of i18n.supportedLangs; track lang) {
        <ui5-menu-item [text]="i18n.langLabels[lang]" [id]="lang" [icon]="i18n.currentLang() === lang ? 'accept' : null"></ui5-menu-item>
      }
    </ui5-menu>
  `,
  styles: [`
    .app-shell { display: flex; flex-direction: column; height: 100vh; width: 100vw; position: relative; z-index: 1; overflow: hidden; }
    .app-shell--reduced-motion .app-nav-island,
    .app-shell--reduced-motion .pill-item,
    .app-shell--reduced-motion .nav-label { transition: none; }
    .app-header { flex-shrink: 0; position: relative; }
    
    .header-actions {
      position: absolute;
      top: 0;
      right: 4.5rem;
      height: 100%;
      display: flex;
      align-items: center;
      gap: 0.5rem;
      z-index: 3;
      pointer-events: auto;
    }

    .header-actions__team {
      display: flex;
      align-items: center;
      margin: 0 0.5rem;
      padding: 0 0.75rem;
      border-left: 1px solid rgba(0,0,0,0.05);
      border-right: 1px solid rgba(0,0,0,0.05);
    }

    .workspace-context {
      font-size: 0.75rem;
      font-weight: 700;
      color: var(--text-secondary);
      white-space: nowrap;
    }

    .header-actions ui5-button {
      --sapButton_Lite_Background: transparent;
      --sapButton_Lite_Hover_Background: rgba(0, 0, 0, 0.04);
      border-radius: 999px;
    }

    .app-body { flex: 1; display: flex; padding: 1.5rem; gap: 1.5rem; overflow: hidden; }
    
    .app-nav-island {
      width: 84px; display: flex; flex-direction: column; 
      background: var(--liquid-glass-bg);
      backdrop-filter: var(--liquid-glass-blur);
      -webkit-backdrop-filter: var(--liquid-glass-blur);
      border: var(--liquid-glass-border); 
      border-radius: var(--radius-island);
      box-shadow: var(--liquid-glass-shadow); 
      padding: 1.5rem 0; 
      transition: width 0.5s var(--spring-easing);
      overflow: hidden;
      z-index: 100;
    }
    .app-nav-island:hover, .app-nav-island:focus-within { width: 240px; box-shadow: var(--liquid-glass-shadow-deep); }
    .nav-group-stack { display: flex; flex-direction: column; gap: 0.5rem; width: 100%; }
    .nav-island-item {
      display: flex; align-items: center; gap: 1.75rem; width: 100%; border: none; background: transparent;
      padding: 1.5rem 2rem; cursor: pointer; color: var(--text-secondary); position: relative;
      transition: all 0.3s var(--spring-easing);
    }
    .nav-island-item:hover { 
      background: rgba(255, 255, 255, 0.1); 
      color: var(--text-primary);
      transform: translateX(4px);
    }
    .nav-label { 
      font-size: 1rem; font-weight: 700; white-space: nowrap; opacity: 0; 
      letter-spacing: var(--font-tracking-tight);
      transition: opacity 0.3s var(--spring-easing), transform 0.3s var(--spring-easing); 
      transform: translateX(-10px);
    }
    .app-nav-island:hover .nav-label, .app-nav-island:focus-within .nav-label { opacity: 1; transform: translateX(0); transition-delay: 0.1s; }
    
    .nav-island-item.active { color: var(--color-primary); }
    .nav-island-item.active ui5-icon { transform: scale(1.15); filter: drop-shadow(0 0 12px rgba(var(--color-primary-rgb), 0.4)); }
    .nav-island-item.active::before { 
      content: ''; position: absolute; left: 0; top: 25%; bottom: 25%; width: 5px; 
      background: var(--color-primary); border-radius: 0 6px 6px 0; 
      box-shadow: 0 0 20px var(--color-primary);
      animation: indicator-glow 3s infinite ease-in-out;
    }

    @keyframes indicator-glow {
      0%, 100% { opacity: 1; transform: scaleY(1); }
      50% { opacity: 0.6; transform: scaleY(1.3); filter: brightness(1.5); }
    }

    .nav-island-item {
      transition: opacity 200ms ease, border-color 200ms ease;
    }

    .nav-island-item:not(.active):not(.mode-suggested) {
      opacity: 0.55;
    }

    .nav-island-item.mode-suggested:not(.active) {
      opacity: 1;
      border-left: 3px solid var(--sapLink_Active_Color, #0a6ed1);
    }

    .app-viewport { flex: 1; display: flex; flex-direction: column; position: relative; overflow: hidden; }
    .context-pill-bar { position: absolute; top: 0; left: 0; right: 0; height: 64px; display: flex; align-items: center; justify-content: center; z-index: 10; }
    .pill-track { 
      background: var(--liquid-glass-bg); 
      backdrop-filter: var(--liquid-glass-blur);
      border: var(--liquid-glass-border); 
      border-radius: 999px; padding: 0.35rem; display: flex; gap: 0.35rem; 
      box-shadow: var(--liquid-glass-shadow); 
    }
    .pill-item { 
      border: none; background: transparent; padding: 0.5rem 1.5rem; border-radius: 999px; 
      font-size: 0.8125rem; font-weight: 600; color: #424245; cursor: pointer; 
      transition: all 0.3s cubic-bezier(0.25, 0.8, 0.25, 1); 
    }
    .pill-item--active { background: var(--color-primary); color: #fff; box-shadow: 0 4px 12px rgba(var(--color-primary-rgb), 0.3); transform: scale(1.05); }
    .content-container { flex: 1; overflow-y: auto; }
    .content-container--with-pills { padding-top: 80px; }

    .mode-pill-bar {
      position: absolute;
      top: 3.5rem;
      left: 6rem;
      z-index: 9;
    }

    .pill-item--mode {
      display: flex;
      align-items: center;
      gap: 0.25rem;
      font-size: 0.6875rem;
      opacity: 0.7;
    }

    .pill-item--mode .pill-icon {
      font-size: 0.75rem;
    }

    /* ── Spotlight / Search Polish ── */
    :host .spotlight-dialog { --sapDialog_Content_Padding: 0; border-radius: 24px; box-shadow: var(--liquid-glass-shadow-deep); }
    .spotlight-body { 
      width: 680px; max-width: 90vw; display: flex; flex-direction: column; 
      background: var(--liquid-glass-bg);
      backdrop-filter: var(--liquid-glass-blur);
      border-radius: 24px;
      overflow: hidden;
    }
    
    .spotlight-input-wrapper {
      display: flex; align-items: center; padding: 1.5rem 2rem; 
      border-bottom: 1px solid rgba(0, 0, 0, 0.05);
      position: relative;
    }
    .spotlight-search-icon { font-size: 1.5rem; color: #86868b; margin-right: 1.25rem; }
    .spotlight-native-input {
      flex: 1; border: none; background: transparent; 
      font-size: 1.5rem; font-weight: 500; color: #1d1d1f;
      letter-spacing: var(--font-letter-spacing-tight);
      outline: none;
    }
    .spotlight-native-input::placeholder { color: #86868b; opacity: 0.6; }
    .spotlight-clear-btn { position: absolute; right: 1.5rem; }

    .spotlight-results { max-height: 520px; overflow-y: auto; display: grid; gap: 1.5rem; padding: 1.5rem; scrollbar-width: none; }
    .spotlight-results::-webkit-scrollbar { display: none; }
    .spotlight-section { display: grid; gap: 0.75rem; animation: results-slide-in 0.4s cubic-bezier(0.25, 0.8, 0.25, 1) both; }
    
    @keyframes results-slide-in {
      from { opacity: 0; transform: translateY(10px); }
      to { opacity: 1; transform: translateY(0); }
    }
    
    .spotlight-section__title { 
      font-size: 0.75rem; font-weight: 700; letter-spacing: 0.08em; 
      text-transform: uppercase; color: #86868b; padding: 0 0.75rem; 
    }
    
    .spotlight-entry { 
      display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 0.75rem; align-items: center; 
      border-radius: 18px; transition: all 0.2s cubic-bezier(0.25, 0.8, 0.25, 1);
    }
    .spotlight-entry__main, .spotlight-entry__pin {
      border: var(--liquid-glass-inner-border);
      background: rgba(255, 255, 255, 0.5);
      color: inherit;
      border-radius: 18px;
      transition: inherit;
    }
    .spotlight-entry__main {
      display: grid; grid-template-columns: auto minmax(0, 1fr);
      gap: 1.25rem; align-items: center; width: 100%; padding: 1.15rem;
      text-align: left; cursor: pointer;
    }
    .spotlight-entry:hover .spotlight-entry__main, .spotlight-entry.selected .spotlight-entry__main {
      border-color: rgba(var(--color-primary-rgb), 0.3);
      background: rgba(255, 255, 255, 0.95);
      transform: translateY(-2px) scale(1.01);
      box-shadow: 0 12px 32px rgba(0, 0, 0, 0.08);
    }
    .spotlight-entry.selected .spotlight-entry__main {
      outline: 2px solid var(--color-primary); outline-offset: -2px;
    }
    .spotlight-entry__icon {
      display: inline-flex; align-items: center; justify-content: center;
      width: 3rem; height: 3rem; border-radius: 14px;
      background: linear-gradient(135deg, rgba(var(--color-primary-rgb), 0.12), rgba(var(--color-primary-rgb), 0.04));
      color: var(--color-primary);
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.5);
    }
    .spotlight-entry__copy { display: flex; flex-direction: column; gap: 0.15rem; }
    .spotlight-entry__eyebrow { font-size: 0.75rem; font-weight: 600; color: #86868b; text-transform: uppercase; letter-spacing: 0.04em; }
    .spotlight-entry__title { font-size: 1.05rem; font-weight: 700; color: #1d1d1f; letter-spacing: var(--font-letter-spacing-tight); }

    /* ── User Menu (Fiori Gold) ── */
    .user-menu { width: 340px; display: flex; flex-direction: column; background: var(--liquid-glass-bg); backdrop-filter: var(--liquid-glass-blur); }
    .user-menu__header {
      display: flex; flex-direction: column; align-items: center;
      padding: 3rem 2rem 2rem; text-align: center; gap: 1.25rem;
      background: linear-gradient(180deg, rgba(0, 0, 0, 0.02), transparent);
      border-bottom: 1px solid rgba(0, 0, 0, 0.05);
    }
    .user-menu__info { display: flex; flex-direction: column; gap: 0.25rem; }
    .user-menu__name { font-size: 1.35rem; font-weight: 800; color: #1d1d1f; letter-spacing: -0.03em; }
    .user-menu__role { font-size: 0.9rem; color: #86868b; font-weight: 600; letter-spacing: 0.01em; }
    .user-menu__email { font-size: 0.8125rem; color: #86868b; font-family: var(--sapFontFamilyMono, monospace); }
    .user-menu__footer {
      padding: 1.25rem; display: flex; justify-content: center;
      border-top: 1px solid rgba(0, 0, 0, 0.05);
    }
    ui5-li { --sapList_ItemHeight: 3.75rem; font-weight: 600; }
  `],
})
export class ShellComponent implements OnInit, OnDestroy {
  readonly store = inject(AppStore);
  private readonly router = inject(Router);
  private readonly auth = inject(AuthService);
  readonly i18n = inject(I18nService);
  private readonly navigationAssistant = inject(NavigationAssistantService);
  private readonly workspace = inject(WorkspaceService);
  @ViewChild('profilePopover', { read: ElementRef }) profilePopover!: ElementRef<any>;
  @ViewChild('notificationsPopover', { read: ElementRef }) notificationsPopover!: ElementRef<any>;
  @ViewChild('langMenu', { read: ElementRef }) langMenu!: ElementRef<any>;
  @ViewChild('searchDialog', { read: ElementRef }) searchDialog!: ElementRef<any>;
  @ViewChild('searchInput', { read: ElementRef }) searchInput!: ElementRef<any>;
  @ViewChild('profileTrigger', { read: ElementRef }) profileTrigger!: ElementRef<any>;
  @ViewChild('searchButton', { read: ElementRef }) searchButton!: ElementRef<any>;
  @ViewChild('languageButton', { read: ElementRef }) languageButton!: ElementRef<any>;

  readonly activeGroupId = signal<TrainingRouteGroupId>('home');
  readonly currentPath = signal('/dashboard');
  readonly showSearch = signal(false);
  readonly searchQuery = signal('');
  readonly selectedSearchIndex = signal(0);
  readonly reducedMotion = signal(false);
  readonly activeMode = this.store.activeMode;
  
  // Decorative canvas movement is disabled for reduced-motion users.
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

  readonly activeGroupRoutes = computed(() => {
    const group = this.activeGroupId();
    const currentPath = this.currentPath();
    const groupRoutes = this.visibleRouteLinks().filter((link) => link.group === group);
    const primaryRoutes = groupRoutes.filter((link) => link.tier === 'primary');
    const activeRoute = TRAINING_ROUTE_LINKS.find(
      (link) => currentPath === link.path || currentPath.startsWith(`${link.path}/`),
    );

    if (activeRoute && !primaryRoutes.some((link) => link.path === activeRoute.path)) {
      return [...primaryRoutes, activeRoute];
    }

    return primaryRoutes;
  });

  readonly searchResults = computed(() => {
    return this.navigationAssistant.search(
      this.searchQuery(),
      (key) => this.i18n.t(key),
      (group) => this.i18n.t(this.groupLabelKey(group)),
    );
  });

  readonly effectiveSearchEntries = computed(() => {
    if (this.searchQuery().trim()) {
      return this.searchResults();
    }
    const pinned = this.pinnedEntries();
    const recent = this.recentEntries();
    const suggested = this.suggestedEntries();
    
    const combined = [...pinned, ...recent, ...suggested];
    const seen = new Set<string>();
    return combined.filter(entry => {
      if (seen.has(entry.path)) return false;
      seen.add(entry.path);
      return true;
    }).slice(0, 10);
  });
  readonly shellNotifications = computed<ShellNotificationItem[]>(() => {
    const notifications: ShellNotificationItem[] = [];
    const health = this.store.health().data;
    const gpu = this.store.gpu().data;
    const pipelineState = this.store.pipelineState();

    if (health) {
      if (health.status === 'healthy') {
        notifications.push({
          icon: 'message-success',
          title: 'Platform health is stable',
          description: 'Core services are reachable and ready for work.',
        });
      } else {
        notifications.push({
          icon: 'message-warning',
          title: 'Platform health needs attention',
          description: 'One or more upstream dependencies are degraded.',
        });
      }
    }

    if (pipelineState === 'running') {
      notifications.push({
        icon: 'process',
        title: 'Pipeline execution is active',
        description: 'Training jobs are currently running in the execution backend.',
      });
    }

    if (gpu && gpu.utilization >= 85) {
      notifications.push({
        icon: 'machine',
        title: 'GPU pressure is elevated',
        description: `Utilization is at ${gpu.utilization}% and may affect new runs.`,
      });
    }

    if (notifications.length === 0) {
      notifications.push({
        icon: 'message-information',
        title: 'Workspace is quiet',
        description: `No immediate issues detected while ${this.activeMode()} mode is active.`,
      });
    }

    return notifications.slice(0, 4);
  });

  readonly currentPagePinned = computed(() => this.navigationAssistant.isPinned(this.currentPath()));
  readonly canPinCurrentPage = computed(() => this.navigationAssistant.canPin(this.currentPath()));
  readonly currentPageLabel = computed(() => {
    const active = TRAINING_ROUTE_LINKS.find((link) => link.path === this.currentPath());
    return active ? this.i18n.t(active.labelKey) : this.i18n.t('nav.dashboard');
  });
  readonly pinnedEntries = computed(() =>
    this.navigationAssistant.pinnedEntries().filter((entry) => entry.path !== this.currentPath()).slice(0, 4),
  );
  readonly recentEntries = computed(() =>
    this.navigationAssistant.recentEntries().filter((entry) => entry.path !== this.currentPath()).slice(0, 4),
  );
  readonly suggestedEntries = computed(() =>
    this.navigationAssistant.suggestedEntries().filter((entry) => entry.path !== this.currentPath()).slice(0, 5),
  );

  @HostListener('window:keydown', ['$event'])
  handleKeyboardEvent(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) && event.key === 'k') {
      event.preventDefault();
      this.toggleSearch();
      return;
    }

    if (this.showSearch()) {
      this.handleSearchKeyDown(event);
    }
  }

  handleSearchKeyDown(event: KeyboardEvent) {
    const entries = this.effectiveSearchEntries();
    if (entries.length === 0) return;

    if (event.key === 'ArrowDown') {
      event.preventDefault();
      this.selectedSearchIndex.update(i => (i + 1) % entries.length);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      this.selectedSearchIndex.update(i => (i - 1 + entries.length) % entries.length);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const entry = entries[this.selectedSearchIndex()];
      if (entry) {
        this.jumpTo(entry.path);
      }
    } else if (event.key === 'Escape') {
      this.closeSearchDialog();
    }
  }

  ngOnInit() {
    this.setupMotionPreference();
    this.updateActiveGroup(this.router.url);
    this.navigationAssistant.recordVisit(this.router.url);
    this.routerSub = this.router.events.pipe(filter((e: Event): e is NavigationEnd => e instanceof NavigationEnd))
      .subscribe(e => {
        this.updateActiveGroup(e.urlAfterRedirects);
        this.navigationAssistant.recordVisit(e.urlAfterRedirects);
      });
  }

  ngOnDestroy() {
    this.routerSub?.unsubscribe();
    if (this.rafId !== null) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    this.teardownMotionPreference();
  }
  private updateActiveGroup(url: string) {
    const currentPath = url.split('?')[0].split('#')[0] || '/dashboard';
    this.currentPath.set(currentPath);
    this.activeGroupId.set(resolveTrainingGroup(currentPath));
  }
  groupLabelKey(group: TrainingRouteGroupId): string {
    const keys: Record<TrainingRouteGroupId, string> = {
      home: 'navGroup.home',
      data: 'navGroup.data',
      assist: 'navGroup.assist',
      operations: 'navGroup.operations',
    };
    return keys[group];
  }
  groupIcon(id: string): string {
    const icons: Record<string, string> = { home: 'home', data: 'folder', assist: 'discussion-2', operations: 'process' };
    return icons[id] || 'grid';
  }
  isModeRelevantGroup(groupId: TrainingRouteGroupId): boolean {
    const suggested = this.store.routeRelevance().suggested;
    return TRAINING_ROUTE_LINKS
      .filter(link => link.group === groupId)
      .some(link => suggested.includes(link.path));
  }
  isRouteActive(path: string): boolean { return this.router.url.startsWith(path); }
  navigateTo(path: string) { this.router.navigate([path]); }

  onModePillClick(pill: ContextPill): void {
    if (pill.action === 'navigate' && pill.target) {
      this.navigateTo(pill.target);
    }
  }

  isPinned(path: string): boolean {
    return this.navigationAssistant.isPinned(path);
  }

  toggleCurrentPagePin(): void {
    this.navigationAssistant.togglePinned(this.currentPath());
  }

  togglePinned(path: string, event: globalThis.Event): void {
    event.stopPropagation();
    this.navigationAssistant.togglePinned(path);
  }
  
  toggleSearch() {
    const dialog = this.searchDialog?.nativeElement;
    if (!dialog) {
      return;
    }

    if (dialog.open) {
      this.closeSearchDialog();
      return;
    }

    this.searchQuery.set('');
    this.showSearch.set(true);
    if (typeof dialog.show === 'function') {
      dialog.show();
    } else {
      dialog.open = true;
    }
    setTimeout(() => this.searchInput?.nativeElement?.focus?.(), 100);
  }

  onSearchInput(e: globalThis.Event) {
    const input = e.target as HTMLInputElement | null;
    this.searchQuery.set(input?.value ?? '');
  }
  jumpTo(path: string) {
    this.closeSearchDialog();
    this.navigateTo(path);
  }

  onMouseMove(e: MouseEvent) {
    if (this.reducedMotion()) {
      return;
    }
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

  onProfileClick(event: any) {
    this.openAnchoredOverlay(this.profilePopover, this.resolveOpener(event, this.profileTrigger));
  }

  onNotificationsClick(event: any) {
    this.openAnchoredOverlay(this.notificationsPopover, this.resolveOpener(event));
  }

  onCoPilotClick(event: any) {
    this.navigateTo('/chat');
  }

  toggleLanguageMenu(event: any) {
    this.openAnchoredOverlay(this.langMenu, this.resolveOpener(event, this.languageButton));
  }

  onLanguageClick(event: CustomEvent) {
    const langId = event.detail.item.id as Language | undefined;
    if (langId) {
      this.i18n.setLanguage(langId);
    }
  }

  closeProfile() {
    const popover = this.profilePopover?.nativeElement;
    if (!popover) {
      return;
    }

    if (typeof popover.close === 'function') {
      popover.close();
    } else {
      popover.open = false;
    }
  }

  logout() { this.closeProfile(); this.auth.logout(this.router); }

  readonly userDisplayName = computed(() => {
    const name = this.workspace.identity().displayName?.trim();
    return name || 'User';
  });

  readonly userTeamName = computed(() => this.workspace.identity().teamName?.trim() || '');

  readonly userShortId = computed(() => {
    const id = this.workspace.identity().userId;
    return id.length > 12 ? id.slice(0, 12) + '...' : id;
  });

  readonly userInitials = computed(() => {
    const name = this.userDisplayName();
    const parts = name.split(/\s+/).filter(Boolean);
    if (parts.length >= 2) {
      return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
    }
    return name.slice(0, 2).toUpperCase();
  });

  readonly avatarColorScheme = computed(() => {
    const schemes = ['Accent1', 'Accent2', 'Accent3', 'Accent5', 'Accent6', 'Accent8', 'Accent9', 'Accent10'] as const;
    const name = this.userDisplayName();
    let hash = 0;
    for (let i = 0; i < name.length; i++) {
      hash = ((hash << 5) - hash) + name.charCodeAt(i);
      hash |= 0;
    }
    return schemes[Math.abs(hash) % schemes.length];
  });

  readonly currentWorkspaceLabel = computed(() => {
    const team = this.userTeamName();
    const mode = this.activeMode();
    const modeLabel = mode.charAt(0).toUpperCase() + mode.slice(1);
    return team ? `${team} • ${modeLabel}` : `${modeLabel} workspace`;
  });

  private setupMotionPreference(): void {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      return;
    }

    this.motionMediaQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    this.applyMotionPreference(this.motionMediaQuery.matches);

    if (typeof this.motionMediaQuery.addEventListener === 'function') {
      this.motionMediaQuery.addEventListener('change', this.handleMotionPreferenceChange);
      return;
    }

    this.motionMediaQuery.addListener(this.handleMotionPreferenceChange);
  }

  private teardownMotionPreference(): void {
    if (!this.motionMediaQuery) {
      return;
    }

    if (typeof this.motionMediaQuery.removeEventListener === 'function') {
      this.motionMediaQuery.removeEventListener('change', this.handleMotionPreferenceChange);
      return;
    }

    this.motionMediaQuery.removeListener(this.handleMotionPreferenceChange);
  }

  private readonly handleMotionPreferenceChange = (event: MediaQueryListEvent): void => {
    this.applyMotionPreference(event.matches);
  };

  private applyMotionPreference(matches: boolean): void {
    this.reducedMotion.set(matches);
    if (matches) {
      this.mouseX.set(0);
      this.mouseY.set(0);
    }
  }

  closeSearchDialog(): void {
    const dialog = this.searchDialog?.nativeElement;
    this.showSearch.set(false);
    if (!dialog) {
      return;
    }

    if (typeof dialog.close === 'function') {
      dialog.close();
    } else {
      dialog.open = false;
    }
  }

  private resolveOpener(event: any, fallback?: ElementRef<any>): HTMLElement | null {
    const candidates = [event?.detail?.targetRef, event?.currentTarget, event?.target, fallback?.nativeElement];
    return candidates.find((candidate): candidate is HTMLElement => candidate instanceof HTMLElement) ?? null;
  }

  private openAnchoredOverlay(overlayRef: ElementRef<any> | undefined, opener: HTMLElement | null): void {
    const overlay = overlayRef?.nativeElement;
    if (!overlay || !opener) {
      return;
    }

    if (typeof overlay.showAt === 'function') {
      overlay.showAt(opener);
      return;
    }

    overlay.opener = opener;
    overlay.open = true;
  }
}

import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy } from '@angular/core';
import { RouterOutlet, RouterLink, RouterLinkActive, Router } from '@angular/router';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { AuthService } from '../../services/auth.service';

interface NavItem {
  label: string;
  icon: string;
  route: string;
}

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [RouterOutlet, RouterLink, RouterLinkActive, CommonModule, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="shell-layout">
      <header class="shell-header">
        <div class="header-brand">
          <span class="brand-icon">⚙</span>
          <span class="brand-name">Training Console</span>
          <span class="brand-version">v{{ version }}</span>
        </div>
        <div class="header-actions">
          <button class="header-btn" (click)="logout()" title="Sign out">Sign out</button>
        </div>
      </header>

      <div class="shell-body">
        <nav class="side-nav">
          <ul class="nav-list">
            @for (item of navItems; track trackByRoute) {
              <li>
                <a
                  [routerLink]="item.route"
                  routerLinkActive="nav-link--active"
                  class="nav-link"
                  [attr.aria-label]="item.label"
                >
                  <span class="nav-icon" aria-hidden="true">{{ item.icon }}</span>
                  <span class="nav-label">{{ item.label }}</span>
                </a>
              </li>
            }
          </ul>

          <div class="nav-footer">
            <div class="api-key-row">
              <input
                type="password"
                class="api-key-input"
                [(ngModel)]="apiKeyDraft"
                placeholder="API key (optional)"
                (keydown.enter)="saveApiKey()"
              />
              <button class="api-key-save" (click)="saveApiKey()">Save</button>
            </div>
          </div>
        </nav>

        <main class="shell-content" id="main-content">
          <router-outlet />
        </main>
      </div>
    </div>
  `,
  styles: [
    `
      .shell-layout {
        display: flex;
        flex-direction: column;
        height: 100vh;
        overflow: hidden;
        background: var(--sapBackgroundColor, #f5f5f5);
      }

      .shell-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 0 1.25rem;
        height: 3rem;
        background: var(--sapShellColor, #354a5e);
        color: #fff;
        flex-shrink: 0;
        box-shadow: 0 2px 4px rgba(0, 0, 0, 0.2);
      }

      .header-brand {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        font-weight: 600;
        font-size: 1rem;
        letter-spacing: 0.01em;
      }

      .brand-icon {
        font-size: 1.25rem;
      }

      .brand-name {
        color: #fff;
      }

      .brand-version {
        font-size: 0.7rem;
        color: rgba(255, 255, 255, 0.6);
        font-weight: 400;
        margin-top: 0.1rem;
      }

      .header-btn {
        background: transparent;
        border: 1px solid rgba(255, 255, 255, 0.4);
        color: #fff;
        padding: 0.25rem 0.75rem;
        border-radius: 0.25rem;
        cursor: pointer;
        font-size: 0.8125rem;
        transition: background 0.15s;

        &:hover {
          background: rgba(255, 255, 255, 0.1);
        }
      }

      .shell-body {
        display: flex;
        flex: 1;
        overflow: hidden;
      }

      .side-nav {
        width: 220px;
        background: var(--sapBaseColor, #fff);
        border-right: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
        display: flex;
        flex-direction: column;
        flex-shrink: 0;
        overflow-y: auto;
      }

      .nav-list {
        list-style: none;
        padding: 0.5rem 0;
        margin: 0;
        flex: 1;
      }

      .nav-link {
        display: flex;
        align-items: center;
        gap: 0.625rem;
        padding: 0.625rem 1rem;
        color: var(--sapTextColor, #32363a);
        text-decoration: none;
        font-size: 0.875rem;
        border-left: 3px solid transparent;
        transition: background 0.12s, border-color 0.12s;

        &:hover {
          background: var(--sapList_Hover_Background, #f5f5f5);
        }

        &.nav-link--active {
          background: var(--sapList_SelectionBackgroundColor, #e8f2ff);
          border-left-color: var(--sapBrandColor, #0854a0);
          color: var(--sapBrandColor, #0854a0);
          font-weight: 600;
        }
      }

      .nav-icon {
        font-size: 1rem;
        width: 1.25rem;
        text-align: center;
      }

      .nav-footer {
        padding: 0.75rem;
        border-top: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      }

      .api-key-row {
        display: flex;
        gap: 0.375rem;
      }

      .api-key-input {
        flex: 1;
        padding: 0.3rem 0.5rem;
        font-size: 0.75rem;
        border: 1px solid var(--sapField_BorderColor, #89919a);
        border-radius: 0.25rem;
        background: var(--sapField_Background, #fff);
        color: var(--sapTextColor, #32363a);
        min-width: 0;
      }

      .api-key-save {
        padding: 0.3rem 0.6rem;
        font-size: 0.75rem;
        background: var(--sapBrandColor, #0854a0);
        color: #fff;
        border: none;
        border-radius: 0.25rem;
        cursor: pointer;
        white-space: nowrap;

        &:hover {
          background: var(--sapButton_Hover_Background, #0a6ed1);
        }
      }

      .shell-content {
        flex: 1;
        overflow-y: auto;
      }
    `,
  ],
})
export class ShellComponent {
  navItems: NavItem[] = [
    { label: 'Dashboard', icon: '📊', route: '/dashboard' },
    { label: 'Pipeline', icon: '🔄', route: '/pipeline' },
    { label: 'Model Optimizer', icon: '🤖', route: '/model-optimizer' },
    { label: 'HippoCPP', icon: '🕸', route: '/hippocpp' },
    { label: 'Data Explorer', icon: '📂', route: '/data-explorer' },
    { label: 'Chat', icon: '💬', route: '/chat' },
  ];

  version = '1.0.0';
  apiKeyDraft = '';

  constructor(
    private auth: AuthService,
    private router: Router
  ) {
    this.apiKeyDraft = auth.token() ?? '';
  }

  saveApiKey(): void {
    if (this.apiKeyDraft.trim()) {
      this.auth.setToken(this.apiKeyDraft.trim());
    } else {
      this.auth.clearToken();
    }
  }

  logout(): void {
    this.auth.clearToken();
    this.router.navigate(['/login']);
  }

  trackByRoute(index: number, item: NavItem): string {
    return item.route;
  }
}

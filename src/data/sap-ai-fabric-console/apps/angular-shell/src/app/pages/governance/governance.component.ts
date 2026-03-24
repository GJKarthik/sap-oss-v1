import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { HttpClient } from '@angular/common/http';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { environment } from '../../../environments/environment';
import { AuthService } from '../../services/auth.service';

interface GovernanceRule {
  id: string;
  name: string;
  rule_type: string;
  active: boolean;
  description?: string;
}

@Component({
  selector: 'app-governance',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Governance Rules</ui5-title>
        <ui5-button *ngIf="canManage" slot="endContent" design="Emphasized" icon="add">Add Rule</ui5-button>
      </ui5-bar>
      <div class="governance-content">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="!canManage" design="Information" [hideCloseButton]="true">
          Viewer mode: governance changes are disabled.
        </ui5-message-strip>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Active Rules" [additionalText]="rules.length + ''"></ui5-card-header>
          <ui5-table *ngIf="rules.length > 0">
            <ui5-table-header-cell><span>Rule Name</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Type</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let rule of rules">
              <ui5-table-cell>{{ rule.name }}</ui5-table-cell>
              <ui5-table-cell>{{ rule.rule_type }}</ui5-table-cell>
              <ui5-table-cell><ui5-tag [design]="rule.active ? 'Positive' : 'Negative'">{{ rule.active ? 'Active' : 'Inactive' }}</ui5-tag></ui5-table-cell>
              <ui5-table-cell>
                <ui5-button *ngIf="canManage" design="Transparent" icon="action-settings" (click)="toggleRule(rule)">
                  {{ rule.active ? 'Disable' : 'Enable' }}
                </ui5-button>
                <span *ngIf="!canManage" class="read-only-label">Read only</span>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <div *ngIf="!loading && rules.length === 0" class="empty-state">
            No governance rules configured.
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .governance-content { padding: 1rem; }
    ui5-message-strip { margin-bottom: 1rem; }
    .empty-state { padding: 1rem; color: var(--sapContent_LabelColor); }
    .read-only-label { color: var(--sapContent_LabelColor); font-size: var(--sapFontSmallSize); }
  `]
})
export class GovernanceComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

  rules: GovernanceRule[] = [];
  loading = false;
  error = '';
  readonly canManage = this.authService.getUser()?.role === 'admin';

  ngOnInit(): void {
    this.loadRules();
  }

  loadRules(): void {
    this.loading = true;
    this.error = '';
    this.http.get<{ rules: GovernanceRule[]; total: number }>(`${environment.apiBaseUrl}/governance`)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: res => { this.rules = res.rules; this.loading = false; },
        error: () => { this.error = 'Failed to load governance rules.'; this.loading = false; }
      });
  }

  toggleRule(rule: GovernanceRule): void {
    if (!this.canManage) {
      return;
    }
    this.http.patch<{ id: string; active: boolean }>(`${environment.apiBaseUrl}/governance/${rule.id}/toggle`, {})
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: res => { rule.active = res.active; },
        error: () => { this.error = `Failed to toggle rule "${rule.name}".`; }
      });
  }
}

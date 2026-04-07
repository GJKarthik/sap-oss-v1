import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, inject } from '@angular/core';
import { Router } from '@angular/router';

type AssessmentStatus = 'not_started' | 'in_progress' | 'completed';

interface PrincipleCheck {
  id: string;
  title: string;
  status: AssessmentStatus;
  notes: string;
}

interface ProcessCheckSnapshot {
  updated_at: string;
  checks: PrincipleCheck[];
}

const STORAGE_KEY = 'process_check_snapshot_v1';

@Component({
  selector: 'app-process-checks',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <div class="header-row">
        <div>
          <ui5-title level="H2">Process Checks</ui5-title>
          <p class="subtitle">Track governance implementation status across the AI Verify principles.</p>
        </div>
        <div class="header-actions">
          <ui5-button design="Transparent" icon="download" (click)="downloadSnapshot()">Export</ui5-button>
          <ui5-button design="Transparent" icon="refresh" (click)="reset()">Reset</ui5-button>
        </div>
      </div>

      <ui5-message-strip design="Information" hide-close-button>
        Completed {{ completedCount() }} / {{ checks.length }} checks
      </ui5-message-strip>

      <div class="grid">
        <ui5-card *ngFor="let check of checks">
          <ui5-card-header slot="header" [title-text]="check.title"></ui5-card-header>
          <div class="card-content">
            <label class="field">
              <span>Status</span>
              <ui5-select [value]="check.status" (change)="setStatusFromEvent(check.id, $event)">
                <ui5-option value="not_started">Not Started</ui5-option>
                <ui5-option value="in_progress">In Progress</ui5-option>
                <ui5-option value="completed">Completed</ui5-option>
              </ui5-select>
            </label>

            <label class="field">
              <span>Notes</span>
              <ui5-textarea
                growing
                growing-max-lines="6"
                [value]="check.notes"
                (input)="setNotes(check.id, valueFromEvent($event))"
                placeholder="Evidence, links, controls, policy references"
              ></ui5-textarea>
            </label>
          </div>
        </ui5-card>
      </div>

      <div class="footer-actions">
        <ui5-button design="Transparent" icon="navigation-left-arrow" (click)="go('/getting-started')">Back</ui5-button>
        <ui5-button design="Emphasized" icon="navigation-right-arrow" (click)="go('/upload-results')">
          Continue
        </ui5-button>
      </div>
    </section>
  `,
  styles: [
    `
      .page {
        display: grid;
        gap: 0.8rem;
      }

      .header-row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        align-items: flex-start;
      }

      .subtitle {
        margin: 0.35rem 0 0;
        color: var(--sapContent_LabelColor);
      }

      .header-actions {
        display: flex;
        gap: 0.5rem;
      }

      .grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
        gap: 0.8rem;
      }

      .card-content {
        padding: 0.8rem;
        display: grid;
        gap: 0.7rem;
      }

      .field {
        display: grid;
        gap: 0.3rem;
      }

      .field span {
        font-size: 0.78rem;
        color: var(--sapContent_LabelColor);
      }

      .footer-actions {
        display: flex;
        justify-content: space-between;
      }

      @media (max-width: 760px) {
        .header-row {
          flex-direction: column;
        }
      }
    `,
  ],
})
export class ProcessChecksComponent {
  private readonly router = inject(Router);

  checks: PrincipleCheck[] = this.loadSnapshot();

  valueFromEvent(event: Event): string {
    const target = event.target as { value?: string };
    return target.value ?? '';
  }

  setStatus(id: string, status: AssessmentStatus): void {
    this.checks = this.checks.map((check) => (check.id === id ? { ...check, status } : check));
    this.persist();
  }

  setStatusFromEvent(id: string, event: Event): void {
    const raw = this.valueFromEvent(event);
    const status: AssessmentStatus =
      raw === 'completed' || raw === 'in_progress' || raw === 'not_started' ? raw : 'not_started';
    this.setStatus(id, status);
  }

  setNotes(id: string, notes: string): void {
    this.checks = this.checks.map((check) => (check.id === id ? { ...check, notes } : check));
    this.persist();
  }

  completedCount(): number {
    return this.checks.filter((check) => check.status === 'completed').length;
  }

  reset(): void {
    this.checks = this.defaultChecks();
    this.persist();
  }

  downloadSnapshot(): void {
    const payload: ProcessCheckSnapshot = {
      updated_at: new Date().toISOString(),
      checks: this.checks,
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = 'process-checks.json';
    anchor.click();
    URL.revokeObjectURL(url);
  }

  go(path: string): void {
    void this.router.navigateByUrl(path);
  }

  private persist(): void {
    if (typeof window === 'undefined') {
      return;
    }
    const payload: ProcessCheckSnapshot = {
      updated_at: new Date().toISOString(),
      checks: this.checks,
    };
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
  }

  private loadSnapshot(): PrincipleCheck[] {
    if (typeof window === 'undefined') {
      return this.defaultChecks();
    }

    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return this.defaultChecks();
    }

    try {
      const parsed = JSON.parse(raw) as ProcessCheckSnapshot;
      if (!Array.isArray(parsed.checks)) {
        return this.defaultChecks();
      }
      return parsed.checks.map((check) => ({
        id: check.id,
        title: check.title,
        status: check.status,
        notes: check.notes ?? '',
      }));
    } catch {
      return this.defaultChecks();
    }
  }

  private defaultChecks(): PrincipleCheck[] {
    return [
      { id: 'transparency', title: 'Transparency', status: 'not_started', notes: '' },
      { id: 'explainability', title: 'Explainability', status: 'not_started', notes: '' },
      { id: 'reproducibility', title: 'Reproducibility', status: 'not_started', notes: '' },
      { id: 'safety', title: 'Safety', status: 'not_started', notes: '' },
      { id: 'security', title: 'Security', status: 'not_started', notes: '' },
      { id: 'robustness', title: 'Robustness', status: 'not_started', notes: '' },
      { id: 'fairness', title: 'Fairness', status: 'not_started', notes: '' },
      { id: 'data_governance', title: 'Data Governance', status: 'not_started', notes: '' },
      { id: 'accountability', title: 'Accountability', status: 'not_started', notes: '' },
      { id: 'human_agency', title: 'Human Agency and Oversight', status: 'not_started', notes: '' },
      { id: 'inclusive_growth', title: 'Inclusive Growth and Well-being', status: 'not_started', notes: '' },
    ];
  }
}

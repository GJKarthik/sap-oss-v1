import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, inject } from '@angular/core';
import { Router } from '@angular/router';

interface PrincipleCheck {
  id: string;
  title: string;
  status: 'not_started' | 'in_progress' | 'completed';
  notes: string;
}

interface ProcessCheckSnapshot {
  updated_at: string;
  checks: PrincipleCheck[];
}

interface UploadedSummary {
  filename: string;
  run_id: string;
  test_id: string;
  connector: string;
  tests_executed: number;
  dry_run_prompts: number;
  imported_at: string;
}

interface ReportPayload {
  generated_at: string;
  process_checks: ProcessCheckSnapshot | null;
  uploaded_result: UploadedSummary | null;
  summary: {
    completed_checks: number;
    total_checks: number;
    readiness_ratio: number;
  };
}

const CHECK_STORAGE_KEY = 'process_check_snapshot_v1';
const RESULT_STORAGE_KEY = 'process_check_uploaded_result_v1';

@Component({
  selector: 'app-generate-report',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <div class="header-row">
        <div>
          <ui5-title level="H2">Generate Report</ui5-title>
          <p class="subtitle">Create a consolidated JSON report from process checks and test results.</p>
        </div>
        <ui5-button design="Transparent" icon="refresh" (click)="refresh()">Refresh</ui5-button>
      </div>

      <ui5-card>
        <ui5-card-header slot="header" title-text="Assessment Summary"></ui5-card-header>
        <div class="content">
          <div class="summary-row"><span>Completed checks</span><strong>{{ completedChecks }}</strong></div>
          <div class="summary-row"><span>Total checks</span><strong>{{ totalChecks }}</strong></div>
          <div class="summary-row"><span>Readiness ratio</span><strong>{{ readinessRatio() }}%</strong></div>
          <div class="summary-row"><span>Uploaded run</span><strong>{{ uploadedResult?.run_id ?? 'none' }}</strong></div>

          <div class="actions">
            <ui5-button design="Transparent" icon="navigation-left-arrow" (click)="go('/upload-results')">Back</ui5-button>
            <ui5-button design="Transparent" icon="machine" (click)="go('/history')">Open Run History</ui5-button>
            <ui5-button design="Emphasized" icon="download" (click)="downloadReport()">Download Report JSON</ui5-button>
          </div>
        </div>
      </ui5-card>

      <ui5-card>
        <ui5-card-header slot="header" title-text="Report Preview"></ui5-card-header>
        <div class="content">
          <pre>{{ reportPreview() }}</pre>
        </div>
      </ui5-card>
    </section>
  `,
  styles: [
    `
      .page {
        display: grid;
        gap: 0.9rem;
      }

      .header-row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
      }

      .subtitle {
        margin: 0.35rem 0 0;
        color: var(--sapContent_LabelColor);
      }

      .content {
        padding: 0.9rem;
      }

      .summary-row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        margin-bottom: 0.5rem;
      }

      .actions {
        margin-top: 0.8rem;
        display: flex;
        gap: 0.5rem;
        flex-wrap: wrap;
      }

      pre {
        margin: 0;
        white-space: pre-wrap;
        word-break: break-word;
      }

      @media (max-width: 760px) {
        .header-row {
          flex-direction: column;
        }
      }
    `,
  ],
})
export class GenerateReportComponent {
  private readonly router = inject(Router);

  processSnapshot: ProcessCheckSnapshot | null = null;
  uploadedResult: UploadedSummary | null = null;

  completedChecks = 0;
  totalChecks = 0;

  constructor() {
    this.refresh();
  }

  refresh(): void {
    this.processSnapshot = this.loadJson<ProcessCheckSnapshot>(CHECK_STORAGE_KEY);
    this.uploadedResult = this.loadJson<UploadedSummary>(RESULT_STORAGE_KEY);

    const checks = this.processSnapshot?.checks ?? [];
    this.totalChecks = checks.length;
    this.completedChecks = checks.filter((check) => check.status === 'completed').length;
  }

  readinessRatio(): number {
    if (this.totalChecks === 0) {
      return 0;
    }
    return Math.round((this.completedChecks / this.totalChecks) * 100);
  }

  reportPreview(): string {
    return JSON.stringify(this.buildPayload(), null, 2);
  }

  downloadReport(): void {
    const payload = this.buildPayload();
    const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = `process-check-report-${new Date().toISOString().slice(0, 10)}.json`;
    anchor.click();
    URL.revokeObjectURL(url);
  }

  go(path: string): void {
    void this.router.navigateByUrl(path);
  }

  private loadJson<T>(storageKey: string): T | null {
    if (typeof window === 'undefined') {
      return null;
    }
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) {
      return null;
    }

    try {
      return JSON.parse(raw) as T;
    } catch {
      return null;
    }
  }

  private buildPayload(): ReportPayload {
    return {
      generated_at: new Date().toISOString(),
      process_checks: this.processSnapshot,
      uploaded_result: this.uploadedResult,
      summary: {
        completed_checks: this.completedChecks,
        total_checks: this.totalChecks,
        readiness_ratio: this.readinessRatio(),
      },
    };
  }
}

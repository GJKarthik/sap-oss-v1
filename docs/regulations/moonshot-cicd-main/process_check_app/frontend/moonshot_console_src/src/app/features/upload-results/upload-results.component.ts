import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, inject } from '@angular/core';
import { Router } from '@angular/router';

interface UploadedSummary {
  filename: string;
  run_id: string;
  test_id: string;
  connector: string;
  tests_executed: number;
  dry_run_prompts: number;
  imported_at: string;
}

const STORAGE_KEY = 'process_check_uploaded_result_v1';

@Component({
  selector: 'app-upload-results',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <ui5-card>
        <ui5-card-header slot="header" title-text="Upload Technical Test Results" subtitle-text="Import Moonshot JSON output">
          <ui5-icon slot="avatar" name="upload"></ui5-icon>
        </ui5-card-header>

        <div class="content">
          <label class="upload-box">
            <span>Select Moonshot result file (.json)</span>
            <input type="file" accept="application/json,.json" (change)="onFileSelected($event)" />
          </label>

          <ui5-message-strip *ngIf="errorMessage" design="Negative">{{ errorMessage }}</ui5-message-strip>
          <ui5-message-strip *ngIf="successMessage" design="Positive">{{ successMessage }}</ui5-message-strip>

          <ui5-card *ngIf="summary">
            <ui5-card-header slot="header" title-text="Imported Summary"></ui5-card-header>
            <div class="summary">
              <div class="row"><span>file</span><strong>{{ summary.filename }}</strong></div>
              <div class="row"><span>run_id</span><strong>{{ summary.run_id }}</strong></div>
              <div class="row"><span>test_id</span><strong>{{ summary.test_id }}</strong></div>
              <div class="row"><span>connector</span><strong>{{ summary.connector }}</strong></div>
              <div class="row"><span>tests_executed</span><strong>{{ summary.tests_executed }}</strong></div>
              <div class="row"><span>dry_run_prompts</span><strong>{{ summary.dry_run_prompts }}</strong></div>
            </div>
          </ui5-card>

          <div class="actions">
            <ui5-button design="Transparent" icon="navigation-left-arrow" (click)="go('/process-checks')">Back</ui5-button>
            <ui5-button design="Transparent" icon="media-play" (click)="go('/runs')">Trigger New Run</ui5-button>
            <ui5-button design="Emphasized" icon="navigation-right-arrow" (click)="go('/generate-report')" [disabled]="!summary">
              Continue
            </ui5-button>
          </div>
        </div>
      </ui5-card>
    </section>
  `,
  styles: [
    `
      .page {
        display: grid;
      }

      .content {
        padding: 1rem;
        display: grid;
        gap: 0.9rem;
      }

      .upload-box {
        display: grid;
        gap: 0.45rem;
        padding: 0.85rem;
        border: 1px dashed var(--moonshot-border);
        border-radius: 8px;
        background: var(--moonshot-panel);
      }

      .summary {
        padding: 0.8rem;
      }

      .row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        margin-bottom: 0.4rem;
      }

      .actions {
        display: flex;
        justify-content: space-between;
        gap: 0.5rem;
        flex-wrap: wrap;
      }
    `,
  ],
})
export class UploadResultsComponent {
  private readonly router = inject(Router);

  summary: UploadedSummary | null = this.loadSummary();
  errorMessage = '';
  successMessage = '';

  onFileSelected(event: Event): void {
    this.errorMessage = '';
    this.successMessage = '';

    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) {
      return;
    }

    const reader = new FileReader();
    reader.onload = () => {
      const content = typeof reader.result === 'string' ? reader.result : '';
      if (!content) {
        this.errorMessage = 'Selected file is empty.';
        return;
      }

      try {
        const parsed = JSON.parse(content) as {
          run_metadata?: {
            run_id?: string;
            test_id?: string;
            connector?: string;
          };
          run_results?: Array<{ dry_run_prompts?: number }>;
        };

        const runMetadata = parsed.run_metadata ?? {};
        const runResults = Array.isArray(parsed.run_results) ? parsed.run_results : [];
        const dryRunPrompts = runResults.reduce((total, item) => total + (item.dry_run_prompts ?? 0), 0);

        this.summary = {
          filename: file.name,
          run_id: runMetadata.run_id ?? 'unknown',
          test_id: runMetadata.test_id ?? 'unknown',
          connector: runMetadata.connector ?? 'unknown',
          tests_executed: runResults.length,
          dry_run_prompts: dryRunPrompts,
          imported_at: new Date().toISOString(),
        };

        this.persistSummary();
        this.successMessage = 'Result file imported successfully.';
      } catch {
        this.errorMessage = 'Invalid JSON file. Please upload a Moonshot result JSON.';
      }
    };

    reader.onerror = () => {
      this.errorMessage = 'Failed to read file.';
    };

    reader.readAsText(file);
  }

  go(path: string): void {
    void this.router.navigateByUrl(path);
  }

  private persistSummary(): void {
    if (typeof window === 'undefined' || !this.summary) {
      return;
    }
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(this.summary));
  }

  private loadSummary(): UploadedSummary | null {
    if (typeof window === 'undefined') {
      return null;
    }
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return null;
    }

    try {
      return JSON.parse(raw) as UploadedSummary;
    } catch {
      return null;
    }
  }
}

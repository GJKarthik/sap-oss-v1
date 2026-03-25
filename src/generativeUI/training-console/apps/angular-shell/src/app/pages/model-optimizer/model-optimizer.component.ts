import { Component, OnInit, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../../services/api.service';

interface ModelInfo {
  name: string;
  size_gb: number;
  parameters: string;
  recommended_quant: string;
  t4_compatible: boolean;
}

interface JobResponse {
  id: string;
  name: string;
  status: string;
  config: {
    model_name: string;
    quant_format: string;
    export_format: string;
  };
  created_at: string;
  progress: number;
  error?: string;
}

interface CreateJobForm {
  model_name: string;
  quant_format: string;
  calib_samples: number;
  calib_seq_len: number;
  export_format: string;
  enable_pruning: boolean;
}

@Component({
  selector: 'app-model-optimizer',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">Model Optimizer</h1>
        <button class="btn-primary" (click)="loadData()">↻ Refresh</button>
      </div>

      <!-- Model Catalog -->
      <section class="section">
        <h2 class="section-title">Model Catalog</h2>
        <div class="model-grid">
          <div
            class="model-card"
            *ngFor="let m of models"
            [class.model-card--selected]="form.model_name === m.name"
            (click)="selectModel(m)"
          >
            <div class="model-name">{{ m.name }}</div>
            <div class="model-meta">
              <span class="badge">{{ m.parameters }}</span>
              <span class="badge">{{ m.size_gb }} GB</span>
              <span class="badge badge--quant">{{ m.recommended_quant }}</span>
            </div>
            <div *ngIf="!m.t4_compatible" class="text-small" style="color:#c62828">⚠ T4 incompatible</div>
          </div>
        </div>
        <p class="text-muted text-small" *ngIf="!models.length && !loading">No models found — is the backend running?</p>
      </section>

      <!-- Create Job Form -->
      <section class="section">
        <h2 class="section-title">Create Optimization Job</h2>
        <form class="job-form" (ngSubmit)="createJob()">
          <div class="form-row">
            <div class="field-group">
              <label class="field-label">Model</label>
              <input class="form-input" [(ngModel)]="form.model_name" name="model_name" placeholder="HuggingFace model name" />
            </div>
            <div class="field-group">
              <label class="field-label">Quant Format</label>
              <select class="form-input" [(ngModel)]="form.quant_format" name="quant_format">
                <option value="int8">INT8 SmoothQuant</option>
                <option value="int4_awq">INT4 AWQ</option>
                <option value="w4a16">W4A16</option>
              </select>
            </div>
            <div class="field-group">
              <label class="field-label">Export Format</label>
              <select class="form-input" [(ngModel)]="form.export_format" name="export_format">
                <option value="hf">HuggingFace</option>
                <option value="tensorrt_llm">TensorRT-LLM</option>
                <option value="vllm">vLLM</option>
              </select>
            </div>
            <div class="field-group">
              <label class="field-label">Calib Samples</label>
              <input type="number" class="form-input" [(ngModel)]="form.calib_samples" name="calib_samples" min="32" max="2048" />
            </div>
          </div>
          <div class="form-actions">
            <button type="submit" class="btn-primary" [disabled]="!form.model_name || submitting">
              {{ submitting ? 'Submitting…' : '▶ Run Job' }}
            </button>
            <span class="text-small text-muted" *ngIf="submitMsg">{{ submitMsg }}</span>
          </div>
        </form>
      </section>

      <!-- Jobs Table -->
      <section class="section">
        <h2 class="section-title">Jobs <span class="text-muted text-small">({{ jobs.length }})</span></h2>
        <div class="table-wrapper" *ngIf="jobs.length">
          <table class="data-table">
            <thead>
              <tr>
                <th>ID</th>
                <th>Name</th>
                <th>Model</th>
                <th>Quant</th>
                <th>Status</th>
                <th>Progress</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody>
              <tr *ngFor="let j of jobs">
                <td class="mono text-small">{{ j.id.slice(0,8) }}</td>
                <td>{{ j.name }}</td>
                <td class="text-small">{{ j.config.model_name }}</td>
                <td><code>{{ j.config.quant_format }}</code></td>
                <td><span class="status-badge {{ jobBadge(j.status) }}">{{ j.status }}</span></td>
                <td>
                  <div class="progress-bar">
                    <div class="progress-fill" [style.width.%]="j.progress * 100"></div>
                  </div>
                  <span class="text-small">{{ (j.progress * 100).toFixed(0) }}%</span>
                </td>
                <td class="text-small text-muted">{{ j.created_at | date:'short' }}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-muted text-small" *ngIf="!jobs.length && !loading">No jobs yet.</p>
      </section>

      <div class="loading-container" *ngIf="loading">
        <span class="loading-text">Loading…</span>
      </div>
    </div>
  `,
  styles: [`
    .section { margin-bottom: 2rem; }

    .section-title {
      font-size: 1rem;
      font-weight: 600;
      margin: 0 0 0.75rem;
      color: var(--sapTextColor, #32363a);
    }

    .model-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
      gap: 0.75rem;
      margin-bottom: 0.5rem;
    }

    .model-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 0.875rem;
      cursor: pointer;
      transition: border-color 0.12s, box-shadow 0.12s;

      &:hover { border-color: var(--sapBrandColor, #0854a0); }

      &.model-card--selected {
        border-color: var(--sapBrandColor, #0854a0);
        box-shadow: 0 0 0 2px rgba(8, 84, 160, 0.2);
      }
    }

    .model-name {
      font-size: 0.8rem;
      font-weight: 600;
      color: var(--sapTextColor, #32363a);
      margin-bottom: 0.5rem;
      word-break: break-all;
    }

    .model-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 0.25rem;
    }

    .badge {
      padding: 0.1rem 0.4rem;
      background: var(--sapList_Background, #f5f5f5);
      border-radius: 0.25rem;
      font-size: 0.7rem;
      color: var(--sapContent_LabelColor, #6a6d70);

      &.badge--quant {
        background: #e3f2fd;
        color: #1565c0;
      }
    }

    .job-form {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1.25rem;
    }

    .form-row {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
      gap: 1rem;
      margin-bottom: 1rem;
    }

    .form-input {
      padding: 0.4rem 0.625rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem;
      font-size: 0.875rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
      width: 100%;
      box-sizing: border-box;
    }

    .form-actions {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .btn-primary {
      padding: 0.375rem 0.875rem;
      background: var(--sapBrandColor, #0854a0);
      color: #fff;
      border: none;
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.875rem;
      font-weight: 500;

      &:disabled { opacity: 0.5; cursor: default; }
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }

    .table-wrapper { overflow-x: auto; }

    .data-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.8125rem;
      background: var(--sapTile_Background, #fff);
      border-radius: 0.5rem;
      overflow: hidden;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);

      th {
        padding: 0.5rem 0.75rem;
        background: var(--sapList_HeaderBackground, #f5f5f5);
        text-align: left;
        font-weight: 600;
        color: var(--sapContent_LabelColor, #6a6d70);
        font-size: 0.7rem;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
      }

      td {
        padding: 0.5rem 0.75rem;
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
        vertical-align: middle;
      }

      tr:last-child td { border-bottom: none; }
      tr:hover td { background: var(--sapList_Hover_Background, #f5f5f5); }
    }

    .mono { font-family: monospace; }

    .progress-bar {
      height: 4px;
      background: var(--sapList_Background, #f5f5f5);
      border-radius: 2px;
      overflow: hidden;
      margin-bottom: 0.2rem;
    }

    .progress-fill {
      height: 100%;
      background: var(--sapBrandColor, #0854a0);
      border-radius: 2px;
      transition: width 0.3s;
    }
  `],
})
export class ModelOptimizerComponent implements OnInit {
  models: ModelInfo[] = [];
  jobs: JobResponse[] = [];
  loading = false;
  submitting = false;
  submitMsg = '';

  form: CreateJobForm = {
    model_name: '',
    quant_format: 'int8',
    calib_samples: 512,
    calib_seq_len: 2048,
    export_format: 'hf',
    enable_pruning: false,
  };

  constructor(private api: ApiService) {}

  ngOnInit(): void {
    this.loadData();
  }

  loadData(): void {
    this.loading = true;
    this.api.get<ModelInfo[]>('/models/catalog').subscribe({
      next: (m) => (this.models = m),
      error: () => {},
    });
    this.api.get<JobResponse[]>('/jobs').subscribe({
      next: (j) => (this.jobs = j),
      error: () => {},
      complete: () => (this.loading = false),
    });
  }

  selectModel(m: ModelInfo): void {
    this.form.model_name = m.name;
    this.form.quant_format = m.recommended_quant;
  }

  createJob(): void {
    if (!this.form.model_name) return;
    this.submitting = true;
    this.submitMsg = '';
    const payload = {
      config: {
        model_name: this.form.model_name,
        quant_format: this.form.quant_format,
        calib_samples: this.form.calib_samples,
        calib_seq_len: this.form.calib_seq_len,
        export_format: this.form.export_format,
        enable_pruning: this.form.enable_pruning,
        pruning_sparsity: 0.2,
      },
    };
    this.api.post<JobResponse>('/jobs', payload).subscribe({
      next: (j) => {
        this.jobs = [j, ...this.jobs];
        this.submitMsg = `Job ${j.id.slice(0, 8)} submitted ✓`;
        this.submitting = false;
      },
      error: (e) => {
        this.submitMsg = `Error: ${e?.error?.detail ?? 'unknown'}`;
        this.submitting = false;
      },
    });
  }

  jobBadge(status: string): string {
    const map: Record<string, string> = {
      pending: 'status-pending',
      running: 'status-running',
      completed: 'status-success',
      failed: 'status-error',
      cancelled: 'status-warning',
    };
    return map[status] ?? 'status-info';
  }
}

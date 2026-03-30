import { Component, OnInit, OnDestroy, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ReactiveFormsModule, FormBuilder, Validators } from '@angular/forms';
import { Subject, takeUntil, forkJoin, catchError, of } from 'rxjs';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { HttpErrorResponse } from '@angular/common/http';
import { HttpErrorResponse } from '@angular/common/http';
import { UserSettingsService } from '../../services/user-settings.service';
import { AppStore } from '../../store/app.store';
import { toSignal } from '@angular/core/rxjs-interop';

interface ModelInfo {
  name: string;
  size_gb: number;
  parameters: string;
  recommended_quant: string;
  t4_compatible: boolean;
}

interface JobConfig {
  model_name: string;
  quant_format: string;
  export_format: string;
}

interface JobHistory {
  epoch: number;
  train_loss: number;
  val_loss: number;
}

interface JobResponse {
  id: string;
  name: string;
  status: string;
  config: JobConfig;
  created_at: string;
  progress: number;
  error?: string;
  history?: JobHistory[];
}

interface JobPayloadConfig {
  model_name: string;
  quant_format: string;
  calib_samples: number;
  calib_seq_len: number;
  export_format: string;
  enable_pruning: boolean;
  pruning_sparsity: number;
  compute_strategy?: string;
  [key: string]: unknown;
}

@Component({
  selector: 'app-model-optimizer',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
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
          @for (m of models(); track m.name) {
            <div
              class="model-card"
              [class.model-card--selected]="jobForm.value.model_name === m.name"
              (click)="selectModel(m)"
            >
              <div class="model-name">{{ m.name }}</div>
              <div class="model-meta">
                <span class="badge">{{ m.parameters }}</span>
                <span class="badge">{{ m.size_gb }} GB</span>
                <span class="badge badge--quant">{{ m.recommended_quant }}</span>
              </div>
              @if (!m.t4_compatible) {
                <div class="text-small t4-warn">⚠ T4 incompatible</div>
              }
            </div>
          }
        </div>
        @if (!models().length && !loading()) {
          <p class="text-muted text-small">No models found — is the backend running?</p>
        }
      </section>

      <!-- Create Job Form -->
      <section class="section">
        <h2 class="section-title">Create Optimization Job</h2>
        <form class="job-form" [formGroup]="jobForm" (ngSubmit)="createJob()">
          
          <!-- Novice Mode -->
          @if (userSettings.mode() === 'novice') {
            <div class="form-row">
              <div class="field-group">
                <label class="field-label">Template</label>
                <select class="form-input" (change)="applyTemplate($any($event.target).value)">
                  <option value="">Select a template…</option>
                  <option value="sql">Fine-tune Text-to-SQL (Recommended)</option>
                  <option value="finance">Finance Schema Optimization</option>
                  <option value="hr">HR Data Optimizer</option>
                </select>
              </div>
              <div class="field-group">
                <label class="field-label">Model Name</label>
                <input class="form-input" formControlName="model_name" placeholder="Auto-populated by template" readonly />
              </div>
            </div>
            
            @if (jobForm.value.model_name) {
              <div class="cost-estimate">
                <span class="icon">💰</span> Estimated cost: ~$2.50 | Time: ~45 mins | Auto-scaling Compute
              </div>
            }
          }
          
          <!-- VRAM Integration (All Modes) -->
          @if (estimatedVram() > 0 && gpuTotalNum() > 0) {
            <div class="vram-profiler" [class.vram-danger]="isVramExceeded()">
              <div class="vram-header">
                <span class="vram-title">⚡ A-Priori VRAM Profiler</span>
                <span class="vram-values">{{ estimatedVram().toFixed(1) }} GB required / {{ gpuTotalNum() }} GB available</span>
              </div>
              <div class="progress-bar">
                <div class="progress-fill" 
                     [style.width.%]="mathMin(100, (estimatedVram() / gpuTotalNum()) * 100)" 
                     [class.danger-fill]="isVramExceeded()">
                </div>
              </div>
              @if (isVramExceeded()) {
                <div class="text-small error-text mt-1">⚠ Critical: Configuration exceeds physical VRAM bounds. Job will OOM crash.</div>
              }
            </div>
          }
          
          <!-- Intermediate Mode -->
          @if (userSettings.mode() === 'intermediate') {
            <div class="form-row">
              <div class="field-group">
                <label class="field-label">Model</label>
                <input class="form-input" formControlName="model_name" placeholder="HuggingFace model name" />
              </div>
              <div class="field-group">
                <label class="field-label">Quant Format</label>
                <select class="form-input" formControlName="quant_format">
                  <option value="int8">INT8 SmoothQuant (Fast)</option>
                  <option value="int4_awq">INT4 AWQ (Best compression)</option>
                  <option value="w4a16">W4A16 (Balanced)</option>
                </select>
              </div>
              <div class="field-group">
                <label class="field-label">Export Format</label>
                <select class="form-input" formControlName="export_format">
                  <option value="hf">HuggingFace</option>
                  <option value="tensorrt_llm">TensorRT-LLM</option>
                  <option value="vllm">vLLM</option>
                </select>
              </div>
              <div class="field-group">
                <label class="field-label">Calib Samples <span class="badge badge--best">Best Practice: 512</span></label>
                <input type="range" class="form-input" formControlName="calib_samples" min="32" max="2048" step="32" />
                <div class="text-small text-muted">{{ jobForm.value.calib_samples }} samples</div>
              </div>
            </div>
          }

          <!-- Expert Mode -->
          @if (userSettings.mode() === 'expert') {
            <div class="form-row">
              <div class="field-group">
                <label class="field-label">Model Override</label>
                <input class="form-input" formControlName="model_name" placeholder="Custom URI / HF Repo" />
              </div>
              <ng-container formGroupName="expertConfig">
                <div class="field-group">
                  <label class="field-label">Compute Strategy</label>
                  <select class="form-input" formControlName="compute">
                    <option value="auto">Auto (Default)</option>
                    <option value="deepspeed_1">DeepSpeed Stage 1</option>
                    <option value="deepspeed_3">DeepSpeed Stage 3 (Multi-Node)</option>
                  </select>
                </div>
                <div class="field-group full-width">
                  <label class="field-label">Raw JSON Override (Arguments Map)</label>
                  <textarea class="form-input mono" rows="5" formControlName="rawJson" placeholder='{"quant_format": "int8", "enable_pruning": true}'></textarea>
                </div>
              </ng-container>
            </div>
          }

          <div class="form-actions" style="margin-top: 1rem;">
            <button type="submit" class="btn-primary" [disabled]="jobForm.invalid || submitting() || isVramExceeded()">
              {{ submitting() ? 'Submitting…' : '▶ Run Job' }}
            </button>
          </div>
        </form>
      </section>

      <!-- Jobs Table -->
      <section class="section">
        <h2 class="section-title">Jobs <span class="text-muted text-small">({{ jobs().length }})</span></h2>
        @if (jobs().length) {
          <div class="table-wrapper">
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
                @for (j of jobs(); track j.id) {
                  <tr>
                    <td class="mono text-small">{{ j.id.slice(0,8) }}</td>
                    <td>{{ j.name }}</td>
                    <td class="text-small">{{ j.config.model_name }}</td>
                    <td><code>{{ j.config.quant_format }}</code></td>
                    <td><span class="status-badge {{ jobBadge(j.status) }}">{{ j.status }}</span></td>
                    <td>
                      <div style="display: flex; justify-content: space-between; margin-bottom: 0.2rem;">
                        <span class="text-small">{{ (j.progress * 100).toFixed(0) }}%</span>
                        <span class="text-small text-muted">{{ calculateETA(j) }}</span>
                      </div>
                      <div class="progress-bar">
                        <div class="progress-fill" [style.width.%]="j.progress * 100"></div>
                      </div>
                      @if (j.history && j.history.length > 0) {
                        <div class="sparkline-container mt-1" title="Training Loss (Solid) vs Val Loss (Dashed)">
                          <svg viewBox="0 0 100 20" class="sparkline-svg" preserveAspectRatio="none">
                            <polyline fill="none" class="train-line" [attr.points]="generateSparklinePath(j.history, 'train_loss')" />
                            <polyline fill="none" class="val-line" [attr.points]="generateSparklinePath(j.history, 'val_loss')" />
                          </svg>
                        </div>
                      }
                    </td>
                    <td class="text-small text-muted">{{ j.created_at | date:'short' }}</td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
        }
        @if (!jobs().length && !loading()) {
          <p class="text-muted text-small">No jobs yet.</p>
        }
      </section>

      @if (loading()) {
        <div class="loading-container">
          <span class="loading-text">Loading…</span>
        </div>
      }
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

    .badge--best {
      background: #e0f2f1;
      color: #00695c;
    }

    .t4-warn {
      color: #c62828;
    }

    .full-width {
      grid-column: 1 / -1;
    }

    .cost-estimate {
      background: #e8f4fd;
      color: #0d47a1;
      padding: 0.75rem 1rem;
      border-radius: 0.5rem;
      font-size: 0.8125rem;
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .loading-container {
      padding: 2rem;
      text-align: center;
    }

    .loading-text {
      color: var(--sapContent_LabelColor, #6a6d70);
    }
    
    .vram-profiler {
      background: var(--sapList_Background, #f5f5f5);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      padding: 0.75rem 1rem;
      border-radius: 0.5rem;
      margin-top: 1rem;
      grid-column: 1 / -1;
    }
    
    .vram-danger {
      border-color: var(--sapNegativeColor, #b00);
      background: #ffebee;
      color: #c62828;
    }
    
    .vram-header {
      display: flex;
      justify-content: space-between;
      margin-bottom: 0.5rem;
      font-size: 0.8125rem;
      font-weight: 600;
    }
    
    .danger-fill {
      background: var(--sapNegativeColor, #b00) !important;
    }
    
    .sparkline-container { width: 100%; height: 20px; background: rgba(0,0,0,0.02); border-radius: 2px; }
    .sparkline-svg { width: 100%; height: 100%; overflow: visible; }
    .train-line { stroke: var(--sapBrandColor, #0854a0); stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }
    .val-line { stroke: var(--sapNegativeColor, #b00); stroke-width: 1; stroke-dasharray: 2 2; }
  `],
})
export class ModelOptimizerComponent implements OnInit, OnDestroy {
  public readonly userSettings = inject(UserSettingsService);
  public readonly store = inject(AppStore);
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  private readonly fb = inject(FormBuilder);
  private readonly destroy$ = new Subject<void>();

  readonly models = signal<ModelInfo[]>([]);
  readonly jobs = signal<JobResponse[]>([]);
  readonly loading = signal(false);
  readonly submitting = signal(false);

  readonly jobForm = this.fb.nonNullable.group({
    model_name: ['', Validators.required],
    quant_format: ['int8', Validators.required],
    calib_samples: [512, [Validators.required, Validators.min(32)]],
    calib_seq_len: [2048, Validators.required],
    export_format: ['hf', Validators.required],
    enable_pruning: [false],
    expertConfig: this.fb.nonNullable.group({
      compute: ['auto'],
      rawJson: ['']
    })
  });

  readonly formValue = toSignal(this.jobForm.valueChanges, { initialValue: this.jobForm.getRawValue() });

  readonly estimatedVram = computed(() => {
    const vals = this.formValue();
    const modelName = vals.model_name;
    const quant = vals.quant_format;
    
    if (!modelName) return 0;
    
    const m = this.models().find(x => x.name === modelName);
    if (!m) return 0; // Fallback if custom URI
    
    let multiplier = 1.0;
    if (quant === 'int8') multiplier = 0.5;
    else if (quant === 'int4_awq') multiplier = 0.3;
    else if (quant === 'w4a16') multiplier = 0.35;
    
    const base = m.size_gb;
    return (base * multiplier) + 1.5; // +1.5GB overhead context
  });

  readonly gpuTotalNum = computed(() => {
    const t = this.store.gpuMemoryTotal();
    if (t === '—') return 0;
    return parseFloat(t);
  });

  readonly isVramExceeded = computed(() => {
    const required = this.estimatedVram();
    const total = this.gpuTotalNum();
    if (required === 0 || total === 0) return false;
    return required > total * 0.95;
  });

  mathMin(a: number, b: number) { return Math.min(a, b); }

  generateSparklinePath(history: any[], key: 'train_loss' | 'val_loss'): string {
    if (!history || history.length < 2) return '';
    const maxVal = Math.max(...history.map(h => Math.max(h.train_loss, h.val_loss)));
    const minVal = 0;
    const w = 100;
    const h = 20;
    
    return history.map((pt, i) => {
      const x = (i / (history.length - 1)) * w;
      const y = h - ((pt[key] - minVal) / (maxVal - minVal) * h);
      return `${x},${y}`;
    }).join(' ');
  }

  calculateETA(j: JobResponse): string {
    if (j.status === 'completed' || j.progress >= 1.0) return 'Done';
    if (j.status === 'failed' || j.status === 'cancelled') return '';
    if (j.progress < 0.05) return 'Calculating...';

    const created = new Date(j.created_at).getTime();
    const now = Date.now();
    const elapsedMs = now - created;
    if (elapsedMs < 0) return 'Calculating...';

    const totalExpectedMs = elapsedMs / j.progress;
    const remainingMs = totalExpectedMs - elapsedMs;

    const totalSeconds = Math.floor(remainingMs / 1000);
    const mins = Math.floor(totalSeconds / 60);
    const secs = totalSeconds % 60;
    
    return `ETA: ${mins}m ${secs}s`;
  }

  ngOnInit(): void {
    this.loadData();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  loadData(): void {
    this.loading.set(true);

    forkJoin({
      models: this.api.get<ModelInfo[]>('/models/catalog').pipe(
        catchError((err: HttpErrorResponse) => {
          this.toast.error('Failed to load model catalog', 'Models');
          console.error('Model catalog failed:', err);
          return of([]);
        })
      ),
      jobs: this.api.get<JobResponse[]>('/jobs').pipe(
        catchError((err: HttpErrorResponse) => {
          this.toast.warning('Failed to load jobs', 'Jobs');
          console.warn('Jobs load failed:', err);
          return of([]);
        })
      ),
    })
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (results: { models: ModelInfo[]; jobs: JobResponse[] }) => {
          this.models.set(results.models);
          this.jobs.set(results.jobs);
          this.loading.set(false);
        },
        error: (err: HttpErrorResponse) => {
          this.toast.error('Failed to load data', 'Error');
          console.error('Load failed:', err);
          this.loading.set(false);
        },
      });
  }

  selectModel(m: ModelInfo): void {
    if (this.userSettings.mode() === 'novice') {
      this.toast.info('Switch to Intermediate mode to select a model manually.');
      return;
    }
    this.jobForm.patchValue({
      model_name: m.name,
      quant_format: m.recommended_quant
    });
  }

  applyTemplate(templateId: string): void {
    if (templateId === 'sql' || templateId === 'finance') {
      this.jobForm.patchValue({ model_name: 'Qwen/Qwen3.5-0.6B', quant_format: 'int4_awq' });
    } else if (templateId === 'hr') {
      this.jobForm.patchValue({ model_name: 'meta-llama/Llama-3-8B-Instruct', quant_format: 'int8' });
    } else {
      this.jobForm.patchValue({ model_name: '' });
    }
  }

  createJob(): void {
    if (this.jobForm.invalid) return;
    this.submitting.set(true);

    const formVal = this.jobForm.getRawValue();

    let payloadConfig: JobPayloadConfig = {
      model_name: formVal.model_name,
      quant_format: formVal.quant_format,
      calib_samples: formVal.calib_samples,
      calib_seq_len: formVal.calib_seq_len,
      export_format: formVal.export_format,
      enable_pruning: formVal.enable_pruning,
      pruning_sparsity: 0.2, // Fixed server-side default mapped natively
    };

    if (this.userSettings.mode() === 'expert' && formVal.expertConfig.rawJson.trim()) {
      try {
        const parsedOverride = JSON.parse(formVal.expertConfig.rawJson) as Record<string, unknown>;
        payloadConfig = { ...payloadConfig, ...parsedOverride, compute_strategy: formVal.expertConfig.compute };
      } catch (e) {
        this.toast.error('Invalid JSON configuration', 'Syntax Error');
        this.submitting.set(false);
        return;
      }
    }

    const payload = { config: payloadConfig };

    const fakeId = 'job-optimistic-' + Date.now();
    const optimisticJob: JobResponse = {
      id: fakeId,
      name: `Optimizing ${formVal.model_name}`,
      status: 'pending',
      progress: 0,
      created_at: new Date().toISOString(),
      config: payloadConfig as JobConfig,
    };
    
    // Optimistic UI update
    this.jobs.update((jobs) => [optimisticJob, ...jobs]);

    this.api.post<JobResponse>('/jobs', payload)
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (j: JobResponse) => {
          // Replace optimistic mock with actual job
          this.jobs.update((jobs) => jobs.map(existing => existing.id === fakeId ? j : existing));
          this.toast.success(`Job ${j.id.slice(0, 8)} submitted successfully`, 'Job Created');
          this.submitting.set(false);
          this.jobForm.patchValue({ model_name: '' }); // Reset main field post-success
        },
        error: (e: HttpErrorResponse) => {
          // Rollback on failure
          this.jobs.update((jobs) => jobs.filter(existing => existing.id !== fakeId));
          const detail = (e.error as { detail?: string })?.detail ?? 'Unknown error';
          this.toast.error(`Failed to create job: ${detail}`, 'Job Error');
          console.error('Job creation failed:', e);
          this.submitting.set(false);
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
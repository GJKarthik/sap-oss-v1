import { Component, OnInit, OnDestroy, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, signal, computed, ViewChild, ElementRef } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ReactiveFormsModule, FormBuilder, Validators } from '@angular/forms';
import { Subject, takeUntil, forkJoin, catchError, of } from 'rxjs';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { HttpErrorResponse } from '@angular/common/http';
import { UserSettingsService } from '../../services/user-settings.service';
import { AppStore } from '../../store/app.store';
import { toSignal } from '@angular/core/rxjs-interop';
import { I18nService } from '../../services/i18n.service';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { JobDetailComponent } from '../../components/job-detail/job-detail.component';

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
  deployed?: boolean;
  evaluation?: {
    perplexity: number;
    eval_loss: number;
    runtime_sec: number;
  };
}

@Component({
  selector: 'app-model-optimizer',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule, JobDetailComponent, Ui5TrainingComponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="optimizer-viewport fadeIn">
      <!-- Floating Header -->
      <div class="glass-panel floating-header slideUp">
        <div class="header-left">
          <ui5-title level="H3">{{ i18n.t('modelOpt.title') }}</ui5-title>
          <ui5-tag design="Information">NVIDIA ModelOpt v0.15</ui5-tag>
        </div>
        <ui5-button design="Transparent" icon="refresh" (click)="loadData()">{{ i18n.t('modelOpt.refresh') }}</ui5-button>
      </div>

      <div class="optimizer-scroll-area">
        <div class="optimizer-layout">
          <!-- Profiler Section -->
          <section class="telemetry-grid">
            <div class="glass-panel stat-material slideUp" style="animation-delay: 0.1s">
              <div class="stat-header">
                <ui5-icon name="it-host"></ui5-icon>
                <span>Compute Allocation</span>
              </div>
              <div class="vram-profile">
                @if (estimatedVram() > 0) {
                  <div class="vram-visual">
                    <ui5-radial-progress-indicator 
                      [value]="mathMin(100, (estimatedVram() / gpuTotalNum()) * 100)" 
                      style="width: 80px; height: 80px;">
                    </ui5-radial-progress-indicator>
                    <div class="vram-data">
                      <span class="v-val">{{ estimatedVram().toFixed(1) }} GB</span>
                      <span class="v-label">Estimated VRAM</span>
                    </div>
                  </div>
                } @else {
                  <p class="text-muted text-small">Select a model to calculate VRAM footprint.</p>
                }
              </div>
            </div>

            <div class="glass-panel stat-material slideUp" style="animation-delay: 0.2s">
              <div class="stat-header">
                <ui5-icon name="line-chart"></ui5-icon>
                <span>Optimization Pareto Frontier</span>
              </div>
              <div class="pareto-summary">
                <div class="p-item">
                  <span class="p-label">Precision</span>
                  <ui5-tag [design]="precisionDesign()">{{ jobForm.value.quant_format?.toUpperCase() }}</ui5-tag>
                </div>
                <div class="p-item">
                  <span class="p-label">Efficiency Gain</span>
                  <span class="p-value status-success">+{{ efficiencyGain() }}%</span>
                </div>
              </div>
            </div>
          </section>

          <div class="main-grid">
            <!-- Left: Configurator -->
            <aside class="config-side">
              <div class="glass-panel config-card slideUp" style="animation-delay: 0.3s">
                <ui5-title level="H4" class="p-1">{{ i18n.t('modelOpt.createJob') }}</ui5-title>
                <form class="p-1 display-flex flex-column gap-1" [formGroup]="jobForm">
                  
                  <ui5-label show-colon>{{ i18n.t('modelOpt.modelCatalog') }}</ui5-label>
                  <div class="model-picker">
                    @for (m of models(); track m.name) {
                      <div class="mini-model-card" [class.selected]="jobForm.value.model_name === m.name" (click)="selectModel(m)">
                        <div class="m-name">{{ m.name }}</div>
                        <div class="m-meta">{{ m.parameters }} · {{ m.size_gb }}GB</div>
                      </div>
                    }
                  </div>

                  <ui5-label show-colon>{{ i18n.t('modelOpt.quantFormat') }}</ui5-label>
                  <ui5-select formControlName="quant_format" class="w-100">
                    <ui5-option value="int8">INT8 (Standard)</ui5-option>
                    <ui5-option value="int4_awq">INT4-AWQ (High Efficiency)</ui5-option>
                    <ui5-option value="fp8">FP8 (Production Performance)</ui5-option>
                  </ui5-select>

                  <ui5-label show-colon>{{ i18n.t('modelOpt.exportFormat') }}</ui5-label>
                  <ui5-select formControlName="export_format" class="w-100">
                    <ui5-option value="hf">HuggingFace SafeTensors</ui5-option>
                    <ui5-option value="vllm">vLLM Engine Compiled</ui5-option>
                  </ui5-select>

                  <ui5-button design="Emphasized" (click)="createJob()" [disabled]="jobForm.invalid || submitting() || isVramExceeded()">
                    {{ submitting() ? 'Initializing Agent...' : 'Execute Optimization' }}
                  </ui5-button>
                </form>
              </div>
            </aside>

            <!-- Right: Monitor -->
            <main class="jobs-side">
              <div class="glass-panel monitor-card slideUp" style="animation-delay: 0.4s">
                <ui5-bar design="Header">
                  <ui5-title slot="startContent" level="H4">Job Monitor</ui5-title>
                  <ui5-tag slot="endContent" design="Neutral">{{ jobs().length }} Sessions</ui5-tag>
                </ui5-bar>
                
                <div class="jobs-list">
                  @for (j of jobs(); track j.id) {
                    <div class="job-entry" [class.expanded]="expandedJobId() === j.id">
                      <div class="job-main-row" (click)="toggleExpand(j.id)">
                        <div class="j-info">
                          <div class="j-title">{{ j.name }}</div>
                          <div class="j-meta">{{ j.config.model_name }} · {{ j.config.quant_format }}</div>
                        </div>
                        <div class="j-progress">
                          <ui5-progress-indicator [value]="j.progress * 100" [design]="j.status === 'completed' ? 'Positive' : 'Information'"></ui5-progress-indicator>
                        </div>
                        <ui5-tag [design]="jobBadgeDesign(j.status)">{{ j.status.toUpperCase() }}</ui5-tag>
                      </div>
                      
                      @if (expandedJobId() === j.id) {
                        <div class="job-expanded-content">
                          <app-job-detail [job]="j"></app-job-detail>
                          <div class="job-actions">
                            @if (j.status === 'completed') {
                              @if (!j.deployed) {
                                <ui5-button design="Emphasized" (click)="deployJob(j)" [disabled]="deployingJob() === j.id">Deploy to Inference</ui5-button>
                              } @else {
                                <ui5-button design="Positive" icon="discussion" (click)="openChat(j)">{{ i18n.t('modelOpt.openWorkspace') }}</ui5-button>
                              }
                            }
                          </div>
                        </div>
                      }
                    </div>
                  }
                  @if (jobs().length === 0) {
                    <div class="p-2 text-center opacity-5">No optimization jobs found.</div>
                  }
                </div>
              </div>
            </main>
          </div>
        </div>
      </div>

      <!-- Workspace Dialog -->
      @if (activeChatJob(); as chatJob) {
        <ui5-dialog #chatDialog [attr.header-text]="i18n.t('modelOpt.workspace') + ': ' + chatJob.config.model_name" open (close)="closeChat()" class="glass-panel">
          <div class="workspace-chat">
            <div class="chat-history">
              @for (msg of chatHistory(); track $index) {
                <div class="p-bubble" [class.user]="msg.role === 'user'">
                  <div class="p-text">{{ msg.text }}</div>
                </div>
              }
            </div>
            <div class="chat-input-row">
              <ui5-input class="w-100" [value]="chatInput.value" (input)="chatInput.setValue($event.target.value)" 
                         placeholder="Prompt the optimized model..." (keydown.enter)="sendChat()"></ui5-input>
              <ui5-button design="Emphasized" icon="paper-plane" (click)="sendChat()" [disabled]="chatLoading()"></ui5-button>
            </div>
          </div>
          <div slot="footer" style="padding: 0.5rem; display: flex; justify-content: flex-end;">
            <ui5-button (click)="closeChat()">{{ i18n.t('common.close') }}</ui5-button>
          </div>
        </ui5-dialog>
      }
    </div>
  `,
  styles: [`
    .optimizer-viewport { height: 100%; display: flex; flex-direction: column; overflow: hidden; }
    .optimizer-scroll-area { flex: 1; overflow-y: auto; padding: 1rem 2rem 4rem; }
    .optimizer-layout { max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 2rem; }

    .floating-header {
      margin: 1.5rem 2rem 0.5rem; padding: 0.75rem 1.5rem;
      display: flex; justify-content: space-between; align-items: center;
      z-index: 10; border-radius: 999px !important;
    }
    .header-left { display: flex; align-items: center; gap: 1rem; }

    .telemetry-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; }
    .stat-material { padding: 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
    .stat-header { display: flex; align-items: center; gap: 0.75rem; font-size: 0.8125rem; font-weight: 600; opacity: 0.6; }
    
    .vram-profile { display: flex; align-items: center; min-height: 80px; }
    .vram-visual { display: flex; align-items: center; gap: 1.5rem; }
    .vram-data { display: flex; flex-direction: column; }
    .v-val { font-size: 1.5rem; font-weight: 800; color: var(--sapBrandColor); }
    .v-label { font-size: 0.75rem; opacity: 0.6; }

    .pareto-summary { display: flex; gap: 3rem; align-items: center; min-height: 80px; }
    .p-item { display: flex; flex-direction: column; gap: 0.5rem; }
    .p-label { font-size: 0.75rem; font-weight: 700; opacity: 0.6; text-transform: uppercase; }
    .p-value { font-size: 1.5rem; font-weight: 800; }

    .main-grid { display: grid; grid-template-columns: 400px 1fr; gap: 1.5rem; }
    @media (max-width: 1100px) { .main-grid { grid-template-columns: 1fr; } }

    .model-picker { display: grid; grid-template-columns: repeat(auto-fill, minmax(110px, 1fr)); gap: 0.5rem; max-height: 240px; overflow-y: auto; padding: 0.5rem; background: rgba(0,0,0,0.03); border-radius: 0.75rem; }
    .mini-model-card { padding: 0.75rem; background: #fff; border: 1px solid var(--sapList_BorderColor); border-radius: 0.5rem; cursor: pointer; transition: all 0.2s; }
    .mini-model-card:hover { border-color: var(--sapBrandColor); transform: translateY(-2px); }
    .mini-model-card.selected { background: var(--sapBrandColor); color: #fff; border-color: var(--sapBrandColor); box-shadow: 0 4px 12px rgba(8, 84, 160, 0.3); }
    .m-name { font-size: 0.75rem; font-weight: 800; overflow: hidden; text-overflow: ellipsis; }
    .m-meta { font-size: 0.65rem; opacity: 0.8; }

    .jobs-list { display: flex; flex-direction: column; }
    .job-entry { border-bottom: 1px solid var(--sapList_BorderColor); }
    .job-main-row { display: flex; align-items: center; gap: 1.5rem; padding: 1.25rem; cursor: pointer; transition: background 0.2s; }
    .job-main-row:hover { background: rgba(0,0,0,0.02); }
    .j-info { flex: 1; }
    .j-title { font-weight: 700; font-size: 0.9375rem; }
    .j-meta { font-size: 0.75rem; opacity: 0.6; }
    .j-progress { width: 150px; }

    .job-expanded-content { padding: 1.5rem; background: rgba(0,0,0,0.01); border-top: 1px solid var(--sapList_BorderColor); animation: slideDown 0.3s cubic-bezier(0.34, 1.56, 0.64, 1); }
    .job-actions { margin-top: 1rem; display: flex; gap: 0.5rem; }

    .status-success { color: var(--sapPositiveColor); }
    
    .p-1 { padding: 1rem; }
    .p-2 { padding: 2rem; }
    .w-100 { width: 100%; }
    .display-flex { display: flex; }
    .flex-column { flex-direction: column; }
    .gap-1 { gap: 1rem; }
    .mt-1 { margin-top: 1rem; }
    .opacity-5 { opacity: 0.5; }
    .text-center { text-align: center; }

    .workspace-chat { width: 500px; max-width: 90vw; height: 500px; display: flex; flex-direction: column; gap: 1rem; }
    .chat-history { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 0.75rem; padding: 0.5rem; }
    .p-bubble { padding: 0.75rem 1rem; border-radius: 1rem; max-width: 85%; background: var(--sapList_Background); }
    .p-bubble.user { align-self: flex-end; background: var(--sapBrandColor); color: #fff; }
    .chat-input-row { display: flex; gap: 0.5rem; }
  `],
})
export class ModelOptimizerComponent implements OnInit, OnDestroy {
  public readonly store = inject(AppStore);
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
  private readonly fb = inject(FormBuilder);
  private readonly destroy$ = new Subject<void>();

  readonly expandedJobId = signal<string | null>(null);
  private refreshInterval: ReturnType<typeof setInterval> | null = null;

  readonly models = signal<ModelInfo[]>([]);
  readonly jobs = signal<JobResponse[]>([]);
  readonly loading = signal(false);
  readonly submitting = signal(false);

  readonly deployingJob = signal<string | null>(null);
  readonly activeChatJob = signal<JobResponse | null>(null);
  readonly chatInput = this.fb.control('');
  readonly chatHistory = signal<{role: 'user'|'model', text: string}[]>([]);
  readonly chatLoading = signal(false);

  readonly jobForm = this.fb.nonNullable.group({
    model_name: ['', Validators.required],
    quant_format: ['int8', Validators.required],
    export_format: ['vllm', Validators.required],
  });

  readonly formValue = toSignal(this.jobForm.valueChanges, { initialValue: this.jobForm.getRawValue() });

  readonly estimatedVram = computed(() => {
    const vals = this.formValue();
    const m = this.models().find(x => x.name === vals.model_name);
    if (!m) return 0;
    let mult = vals.quant_format === 'int8' ? 0.5 : vals.quant_format === 'int4_awq' ? 0.3 : 0.35;
    return (m.size_gb * mult) + 1.2;
  });

  readonly efficiencyGain = computed(() => {
    const q = this.formValue().quant_format;
    if (q === 'int8') return '45';
    if (q === 'int4_awq') return '72';
    return '68';
  });

  readonly gpuTotalNum = computed(() => {
    const t = this.store.gpuMemoryTotal();
    return t === 0 ? 40 : t; // Fallback to 40GB (L40S)
  });

  readonly isVramExceeded = computed(() => {
    const req = this.estimatedVram();
    const tot = this.gpuTotalNum();
    return req > 0 && req > tot * 0.95;
  });

  mathMin(a: number, b: number) { return Math.min(a, b); }

  ngOnInit(): void {
    this.refreshInterval = setInterval(() => {
      if (!this.expandedJobId() && !this.loading()) {
        this.api.get<JobResponse[]>('/jobs').pipe(takeUntil(this.destroy$)).subscribe({ 
          next: (res) => this.jobs.set(res),
          error: () => {}
        });
      }
    }, 5000);
    this.loadData();
  }

  toggleExpand(jobId: string) { this.expandedJobId.update(v => v === jobId ? null : jobId); }

  ngOnDestroy(): void {
    if (this.refreshInterval) clearInterval(this.refreshInterval);
    this.destroy$.next(); this.destroy$.complete();
  }

  loadData(): void {
    this.loading.set(true);
    forkJoin({
      models: this.api.get<ModelInfo[]>('/models/catalog').pipe(catchError(() => of([]))),
      jobs: this.api.get<JobResponse[]>('/jobs').pipe(catchError(() => of([]))),
    }).pipe(takeUntil(this.destroy$)).subscribe((res) => {
      this.models.set(res.models); this.jobs.set(res.jobs); this.loading.set(false);
    });
  }

  selectModel(m: ModelInfo): void { this.jobForm.patchValue({ model_name: m.name, quant_format: m.recommended_quant }); }

  createJob(): void {
    if (this.jobForm.invalid) return;
    this.submitting.set(true);
    this.api.post<JobResponse>('/jobs', { config: this.jobForm.getRawValue() }).pipe(takeUntil(this.destroy$)).subscribe({
      next: (j) => { this.jobs.update(js => [j, ...js]); this.submitting.set(false); this.toast.success(this.i18n.t('modelOptimizer.jobCreated')); },
      error: () => { this.submitting.set(false); this.toast.error(this.i18n.t('modelOptimizer.jobFailed')); }
    });
  }

  jobBadgeDesign(status: string): 'Neutral' | 'Positive' | 'Critical' | 'Negative' | 'Information' {
    const map: Record<string, 'Neutral' | 'Positive' | 'Critical' | 'Negative' | 'Information'> = { pending: 'Neutral', running: 'Information', completed: 'Positive', failed: 'Negative' };
    return map[status] ?? 'Information';
  }

  precisionDesign(): 'Information' | 'Critical' | 'Positive' {
    const q = this.jobForm.value.quant_format;
    if (q === 'int8') return 'Positive';
    if (q === 'int4_awq') return 'Critical';
    return 'Information';
  }

  deployJob(job: JobResponse) {
    this.deployingJob.set(job.id);
    this.api.post(`/jobs/${job.id}/deploy`, {}).pipe(takeUntil(this.destroy$)).subscribe({
      next: () => { this.jobs.update(js => js.map(j => j.id === job.id ? {...j, deployed: true} : j)); this.deployingJob.set(null); },
      error: () => this.deployingJob.set(null)
    });
  }

  openChat(job: JobResponse) {
    this.activeChatJob.set(job);
    this.chatHistory.set([{ role: 'model', text: 'Inference pipeline connected. I am ready to receive your text.' }]);
  }

  closeChat() { this.activeChatJob.set(null); }

  sendChat() {
    const text = this.chatInput.value?.trim();
    const job = this.activeChatJob();
    if (!text || !job) return;
    this.chatHistory.update(h => [...h, { role: 'user', text }]);
    this.chatInput.setValue('');
    this.chatLoading.set(true);
    this.api.post<{response: string}>(`/inference/${job.id}/chat`, { prompt: text }).pipe(takeUntil(this.destroy$)).subscribe({
      next: (res) => { this.chatHistory.update(h => [...h, { role: 'model', text: res.response }]); this.chatLoading.set(false); },
      error: () => this.chatLoading.set(false)
    });
  }
}

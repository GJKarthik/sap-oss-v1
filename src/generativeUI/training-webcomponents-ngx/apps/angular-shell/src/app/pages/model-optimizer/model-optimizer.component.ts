import { Component, OnInit, OnDestroy, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, signal, computed } from '@angular/core';
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

import { JobDetailComponent } from '../../components/job-detail/job-detail.component';

@Component({
  selector: 'app-model-optimizer',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule, JobDetailComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">{{ i18n.t('modelOpt.title') }}</h1>
        <button class="btn-primary" (click)="loadData()">{{ i18n.t('modelOpt.refresh') }}</button>
      </div>

      <!-- Engine & Dataset -->
      <h2 class="section-title">{{ i18n.t('modelOpt.engineConfig') }}</h2>
      <div class="card grid-2" style="margin-bottom: 1.5rem;" [formGroup]="jobForm">
        <div class="form-group">
          <label>{{ i18n.t('modelOpt.framework') }}</label>
          <select formControlName="framework" class="form-input">
            <option value="PyTorch">{{ i18n.t('modelOpt.pytorch') }}</option>
            <option value="TensorFlow" disabled>{{ i18n.t('modelOpt.tensorflow') }}</option>
          </select>
        </div>
        <div class="form-group">
          <label>{{ i18n.t('modelOpt.datasetSplit') }}</label>
          <select formControlName="dataset" class="form-input">
            <option value="spider-train">{{ i18n.t('modelOpt.spiderTrain') }}</option>
            <option value="bird-train" disabled>{{ i18n.t('modelOpt.birdTrain') }}</option>
          </select>
        </div>
      </div>

      <!-- Mangle Data Validation -->
      <h2 class="section-title">{{ i18n.t('modelOpt.datalogValidation') }}</h2>
      <div class="card" style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 2rem; background: #fafafa; border-inline-start: 4px solid var(--sapBrandColor);">
        <div>
          <p style="margin: 0 0 0.25rem; font-size: 0.875rem; color: #333;">{{ i18n.t('modelOpt.datalogDesc') }}</p>
          @if (mangleStatus() === 'passed') {
            <span class="status-success text-small" style="font-weight: 600; display: inline-block; padding: 2px 6px; border-radius: 4px; background: #e8f5e9;">{{ i18n.t('modelOpt.invariantsPassed') }}</span>
          } @else if (mangleStatus() === 'failed') {
            <span class="status-error text-small" style="font-weight: 600; display: inline-block; padding: 2px 6px; border-radius: 4px; background: #ffebee;">{{ i18n.t('modelOpt.violationDetected') }}</span>
          } @else {
            <span class="text-muted text-small" style="display: inline-block;">{{ i18n.t('modelOpt.unverified') }}</span>
          }
        </div>
        <button type="button" class="btn-secondary" (click)="validateMangleRules()" [disabled]="mangleStatus() === 'checking'">
          {{ mangleStatus() === 'checking' ? i18n.t('modelOpt.validating') : i18n.t('modelOpt.checkConstraints') }}
        </button>
      </div>

      <!-- Model Catalog -->
      <section class="section">
        <h2 class="section-title">{{ i18n.t('modelOpt.modelCatalog') }}</h2>
        <div class="model-grid">
          @for (m of models(); track m.name) {
            <div
              class="model-card"
              [class.model-card--selected]="jobForm.value.model_name === m.name"
              (click)="selectModel(m)"
            >
              <div class="model-name"><bdi>{{ m.name }}</bdi></div>
              <div class="model-meta">
                <span class="badge"><bdi>{{ m.parameters }}</bdi></span>
                <span class="badge"><bdi>{{ m.size_gb }} GB</bdi></span>
                <span class="badge badge--quant"><bdi>{{ m.recommended_quant }}</bdi></span>
              </div>
              @if (!m.t4_compatible) {
                <div class="text-small t4-warn">{{ i18n.t('modelOpt.t4Incompatible') }}</div>
              }
            </div>
          }
        </div>
        @if (!models().length && !loading()) {
          <p class="text-muted text-small">{{ i18n.t('modelOpt.noModels') }}</p>
        }
      </section>

      <!-- Create Job Form -->
      <section class="section">
        <h2 class="section-title">{{ i18n.t('modelOpt.createJob') }}</h2>
        <form class="job-form" [formGroup]="jobForm" (ngSubmit)="createJob()">
          
          <!-- Novice Mode -->
          @if (userSettings.mode() === 'novice') {
            <div class="form-row">
              <div class="field-group">
                <label class="field-label">{{ i18n.t('modelOpt.template') }}</label>
                <select class="form-input" (change)="applyTemplate($any($event.target).value)">
                  <option value="">{{ i18n.t('modelOpt.selectTemplate') }}</option>
                  <option value="sql">{{ i18n.t('modelOpt.sqlTemplate') }}</option>
                  <option value="finance">{{ i18n.t('modelOpt.financeTemplate') }}</option>
                  <option value="hr">{{ i18n.t('modelOpt.hrTemplate') }}</option>
                </select>
              </div>
              <div class="field-group">
                <label class="field-label">{{ i18n.t('modelOpt.modelName') }}</label>
                <input class="form-input" formControlName="model_name" [placeholder]="i18n.t('modelOpt.autoPopulated')" readonly />
              </div>
            </div>

            @if (jobForm.value.model_name) {
              <div class="cost-estimate">
                <span class="icon"><ui5-icon name="loan"></ui5-icon></span> {{ i18n.t('modelOpt.costEstimate') }}
              </div>
            }
          }

          <!-- VRAM Integration (All Modes) -->
          @if (estimatedVram() > 0 && gpuTotalNum() > 0) {
            <div class="vram-profiler" [class.vram-danger]="isVramExceeded()">
              <div class="vram-header">
                <span class="vram-title">{{ i18n.t('modelOpt.vramProfiler') }}</span>
                <span class="vram-values">{{ i18n.t('modelOpt.vramRequired', { required: estimatedVram().toFixed(1), available: gpuTotalNum() }) }}</span>
              </div>
              <div class="progress-bar">
                <div class="progress-fill" 
                     [style.width.%]="mathMin(100, (estimatedVram() / gpuTotalNum()) * 100)" 
                     [class.danger-fill]="isVramExceeded()">
                </div>
              </div>
              @if (isVramExceeded()) {
                <div class="text-small error-text mt-1">{{ i18n.t('modelOpt.vramExceeded') }}</div>
              }
            </div>
          }

          <!-- Intermediate Mode -->
          @if (userSettings.mode() === 'intermediate') {
            <div class="form-row">
              <div class="field-group">
                <label class="field-label">{{ i18n.t('modelOpt.model') }}</label>
                <input class="form-input" formControlName="model_name" [placeholder]="i18n.t('modelOpt.hfModelName')" />
              </div>
              <div class="field-group">
                <label class="field-label">{{ i18n.t('modelOpt.quantFormat') }}</label>
                <select class="form-input" formControlName="quant_format">
                  <option value="int8">{{ i18n.t('modelOpt.int8') }}</option>
                  <option value="int4_awq">{{ i18n.t('modelOpt.int4awq') }}</option>
                  <option value="w4a16">{{ i18n.t('modelOpt.w4a16') }}</option>
                </select>
              </div>
              <div class="field-group">
                <label class="field-label">{{ i18n.t('modelOpt.exportFormat') }}</label>
                <select class="form-input" formControlName="export_format">
                  <option value="hf">HuggingFace</option>
                  <option value="tensorrt_llm">TensorRT-LLM</option>
                  <option value="vllm">vLLM</option>
                </select>
              </div>
              <div class="field-group">
                <label class="field-label">{{ i18n.t('modelOpt.calibSamples') }} <span class="badge badge--best">{{ i18n.t('modelOpt.bestPractice') }}</span></label>
                <input type="range" class="form-input" formControlName="calib_samples" min="32" max="2048" step="32" />
                <div class="text-small text-muted">{{ jobForm.value.calib_samples }} {{ i18n.t('modelOpt.samples') }}</div>
              </div>
            </div>
          }

          <!-- Expert Mode -->
          @if (userSettings.mode() === 'expert') {
            <div class="form-row">
              <div class="field-group">
                <label class="field-label">{{ i18n.t('modelOpt.modelOverride') }}</label>
                <input class="form-input" formControlName="model_name" [placeholder]="i18n.t('modelOpt.customUri')" />
              </div>
              <ng-container formGroupName="expertConfig">
                <div class="field-group">
                  <label class="field-label">{{ i18n.t('modelOpt.computeStrategy') }}</label>
                  <select class="form-input" formControlName="compute">
                    <option value="auto">{{ i18n.t('modelOpt.autoDefault') }}</option>
                    <option value="deepspeed_1">{{ i18n.t('modelOpt.deepspeed1') }}</option>
                    <option value="deepspeed_3">{{ i18n.t('modelOpt.deepspeed3') }}</option>
                  </select>
                </div>

                <div class="field-group full-width" style="background: rgba(8, 84, 160, 0.05); padding: 1rem; border-radius: 0.5rem; display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 1rem;">
                  <div class="full-width" style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: -0.5rem;">
                    <input type="checkbox" id="peftToggle" formControlName="use_peft" />
                    <label for="peftToggle" class="field-label" style="margin: 0; font-weight: 600;">{{ i18n.t('modelOpt.enablePeft') }}</label>
                  </div>
                  @if (jobForm.value.expertConfig?.use_peft) {
                    <div class="field-group">
                      <label class="field-label">{{ i18n.t('modelOpt.rank') }}</label>
                      <input type="number" class="form-input" formControlName="peft_r" />
                    </div>
                    <div class="field-group">
                      <label class="field-label">{{ i18n.t('modelOpt.loraAlpha') }}</label>
                      <input type="number" class="form-input" formControlName="peft_alpha" />
                    </div>
                    <div class="field-group">
                      <label class="field-label">{{ i18n.t('modelOpt.dropout') }}</label>
                      <input type="number" class="form-input" formControlName="peft_dropout" step="0.01" />
                    </div>
                  }
                </div>

                <div class="field-group full-width">
                  <label class="field-label">{{ i18n.t('modelOpt.rawJson') }}</label>
                  <textarea class="form-input mono" rows="5" formControlName="rawJson" placeholder='{"quant_format": "int8", "enable_pruning": true}'></textarea>
                </div>
              </ng-container>
            </div>
          }

          <div class="form-actions" style="margin-top: 1rem;">
            <button type="submit" class="btn-primary" [disabled]="jobForm.invalid || submitting() || isVramExceeded()">
              {{ submitting() ? i18n.t('modelOpt.submitting') : i18n.t('modelOpt.runJob') }}
            </button>
          </div>
        </form>
      </section>

      <!-- Jobs Table -->
      <section class="section">
        <h2 class="section-title">{{ i18n.t('modelOpt.jobs') }} <span class="text-muted text-small">({{ jobs().length }})</span></h2>
        @if (jobs().length) {
          <div class="table-wrapper">
            <table class="data-table">
              <thead>
                <tr>
                  <th>{{ i18n.t('modelOpt.jobId') }}</th>
                  <th>{{ i18n.t('modelOpt.jobName') }}</th>
                  <th>{{ i18n.t('modelOpt.jobModel') }}</th>
                  <th>{{ i18n.t('modelOpt.jobQuant') }}</th>
                  <th>{{ i18n.t('modelOpt.jobStatus') }}</th>
                  <th>{{ i18n.t('modelOpt.jobProgress') }}</th>
                  <th>{{ i18n.t('modelOpt.jobCreated') }}</th>
                </tr>
              </thead>
              <tbody>
                @for (j of jobs(); track j.id) {
                  <ng-container>
                    <tr class="job-row" (click)="toggleExpand(j.id)" [class.expanded]="expandedJobId() === j.id">
                      <td class="mono text-small" style="cursor: pointer;">
                        <span style="display: inline-block; width: 12px; margin-right: 4px;">{{ expandedJobId() === j.id ? '-' : '+' }}</span>
                        {{ j.id.slice(0,8) }}
                      </td>
                      <td>{{ j.name }}</td>
                      <td class="text-small"><bdi>{{ j.config.model_name }}</bdi></td>
                      <td><code><bdi>{{ j.config.quant_format }}</bdi></code></td>
                      <td><span class="status-badge {{ jobBadge(j.status) }}">{{ j.status }}</span></td>
                      <td>
                        <div style="display: flex; justify-content: space-between; margin-bottom: 0.2rem;">
                          <span class="text-small">{{ (j.progress * 100).toFixed(0) }}%</span>
                          <span class="text-small text-muted">{{ calculateETA(j) }}</span>
                        </div>
                        <div class="progress-bar">
                          <div class="progress-fill" [style.width.%]="j.progress * 100"></div>
                        </div>
                        @if (j.history && j.history.length > 0 && expandedJobId() !== j.id) {
                          <div class="sparkline-container mt-1" title="Training Loss (Solid) vs Val Loss (Dashed)">
                            <svg viewBox="0 0 100 20" class="sparkline-svg" preserveAspectRatio="none">
                              <polyline fill="none" class="train-line" [attr.points]="generateSparklinePath(j.history, 'train_loss')" />
                              <polyline fill="none" class="val-line" [attr.points]="generateSparklinePath(j.history, 'val_loss')" />
                            </svg>
                          </div>
                        }
                        
                        @if (j.evaluation) {
                          <div class="eval-metrics mt-1">
                            <span class="badge badge--best" title="Perplexity (Lower is better)">PPL: {{ j.evaluation.perplexity }}</span>
                            <span class="badge" title="Validation Loss">Loss: {{ j.evaluation.eval_loss }}</span>
                            <span class="text-small text-muted">{{ j.evaluation.runtime_sec }}s</span>
                          </div>
                        }
                      </td>
                      <td class="text-small text-muted" style="min-width: 100px;">
                        {{ j.created_at | date:'short' }}
                        @if (j.status === 'completed') {
                          <div class="mt-1" style="display: flex; gap: 0.5rem; flex-direction: column;" (click)="$event.stopPropagation()">
                            @if (!j.deployed) {
                              <button class="btn-primary" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" 
                                      (click)="deployJob(j)" [disabled]="deployingJob() === j.id">
                                {{ deployingJob() === j.id ? i18n.t('modelOpt.deploying') : i18n.t('modelOpt.deployModel') }}
                              </button>
                            } @else {
                              <button class="btn-primary" style="padding: 0.2rem 0.5rem; font-size: 0.75rem; background: #00695c;"
                                      (click)="openChat(j)">
                                {{ i18n.t('modelOpt.chatPlayground') }}
                              </button>
                            }
                          </div>
                        }
                      </td>
                    </tr>
                    @if (expandedJobId() === j.id) {
                      <tr>
                        <td colspan="7" style="padding: 0;">
                          <app-job-detail [job]="j"></app-job-detail>
                        </td>
                      </tr>
                    }
                  </ng-container>
                }
              </tbody>
            </table>
          </div>
        }
        @if (!jobs().length && !loading()) {
          <p class="text-muted text-small">{{ i18n.t('modelOpt.noJobs') }}</p>
        }
      </section>

      @if (loading()) {
        <div class="loading-container">
          <span class="loading-text">Loading…</span>
        </div>
      }

      <!-- Chat Playground Modal -->
      @if (activeChatJob(); as chatJob) {
        <div class="modal-overlay" (click)="closeChat()">
          <div class="modal-content" (click)="$event.stopPropagation()">
            <div class="modal-header">
              <h3 style="margin: 0; font-size: 1rem;">{{ i18n.t('modelOpt.playground') }}: <bdi>{{ chatJob.config.model_name }}</bdi></h3>
              <button class="close-btn" (click)="closeChat()">✕</button>
            </div>
            <div class="chat-window">
              @for (msg of chatHistory(); track $index) {
                <div class="chat-bubble" [class.user]="msg.role === 'user'">
                  <strong style="font-size: 0.75rem; color: #666;">{{ msg.role === 'user' ? i18n.t('chat.you') : i18n.t('chat.model') }}</strong>
                  <p style="margin: 0.2rem 0 0; font-size: 0.875rem;"><bdi>{{ msg.text }}</bdi></p>
                </div>
              }
              @if (chatLoading()) {
                <div class="chat-bubble loading">
                  <em style="font-size: 0.875rem; color: #666;">{{ i18n.t('modelOpt.computing') }}</em>
                </div>
              }
            </div>
            <div class="chat-input-area">
              <input type="text" [formControl]="chatInput" class="form-input" [placeholder]="i18n.t('modelOpt.promptModel')" (keyup.enter)="sendChat()" />
              <button class="btn-primary" (click)="sendChat()" [disabled]="chatLoading() || !chatInput.value">{{ i18n.t('chat.send') }}</button>
            </div>
          </div>
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
    
    .eval-metrics {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding-top: 0.25rem;
    }
    
    .modal-overlay {
      position: fixed; top: 0; left: 0; width: 100vw; height: 100vh;
      background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 1000;
    }
    .modal-content {
      background: #fff; width: 500px; max-width: 90vw; border-radius: 0.5rem; overflow: hidden;
      display: flex; flex-direction: column; box-shadow: 0 10px 30px rgba(0,0,0,0.2);
    }
    .modal-header {
      padding: 1rem; background: #f5f5f5; border-bottom: 1px solid #e4e4e4;
      display: flex; justify-content: space-between; align-items: center;
    }
    .close-btn { background: none; border: none; font-size: 1.2rem; cursor: pointer; color: #666; }
    .chat-window {
      padding: 1rem; height: 300px; overflow-y: auto; background: #fafafa; display: flex; flex-direction: column; gap: 0.8rem;
    }
    .chat-bubble {
      padding: 0.75rem; border-radius: 0.5rem; max-width: 85%; background: #e3f2fd; align-self: flex-start;
      &.user { background: #e8f5e9; align-self: flex-end; }
    }
    .chat-input-area {
      padding: 1rem; background: #fff; border-top: 1px solid #e4e4e4; display: flex; gap: 0.5rem;
    }
  `],
})
export class ModelOptimizerComponent implements OnInit, OnDestroy {
  public readonly userSettings = inject(UserSettingsService);
  public readonly store = inject(AppStore);
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
  private readonly fb = inject(FormBuilder);
  private readonly destroy$ = new Subject<void>();

  readonly expandedJobId = signal<string | null>(null);
  private refreshInterval: any;

  readonly models = signal<ModelInfo[]>([]);
  readonly jobs = signal<JobResponse[]>([]);
  readonly loading = signal(false);
  readonly submitting = signal(false);

  readonly mangleStatus = signal<'checking'|'passed'|'failed'|null>(null);
  readonly deployingJob = signal<string | null>(null);
  readonly activeChatJob = signal<JobResponse | null>(null);
  readonly chatInput = this.fb.control('');
  readonly chatHistory = signal<{role: 'user'|'model', text: string}[]>([]);
  readonly chatLoading = signal(false);

  readonly jobForm = this.fb.nonNullable.group({
    model_name: ['', Validators.required],
    quant_format: ['int8', Validators.required],
    calib_samples: [512, [Validators.required, Validators.min(32)]],
    calib_seq_len: [2048, Validators.required],
    export_format: ['hf', Validators.required],
    enable_pruning: [false],
    framework: ['PyTorch'],
    dataset: ['spider-train'],
    expertConfig: this.fb.nonNullable.group({
      compute: ['auto'],
      use_peft: [false],
      peft_r: [8],
      peft_alpha: [16],
      peft_dropout: [0.05],
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
    const t = this.store.gpuMemoryTotal() as string;
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
    this.refreshInterval = setInterval(() => {
      // Don't poll REST if a row is actively WS streaming
      if (!this.expandedJobId() && !this.loading()) {
        const isBackground = true;
        this.api.get<JobResponse[]>('/jobs').pipe(takeUntil(this.destroy$)).subscribe({
          next: (res) => this.jobs.set(res)
        });
      }
    }, 4000);
    this.loadData();
  }

  toggleExpand(jobId: string) {
    this.expandedJobId.update(v => v === jobId ? null : jobId);
  }

  ngOnDestroy(): void {
    if (this.refreshInterval) {
      clearInterval(this.refreshInterval);
    }
    this.destroy$.next();
    this.destroy$.complete();
  }

  validateMangleRules() {
    this.mangleStatus.set('checking');
    this.api.post<{status: string, output: string}>('/mangle/validate', {}).pipe(takeUntil(this.destroy$)).subscribe({
      next: (res) => {
        if (res.status === 'passed') {
          this.mangleStatus.set('passed');
          this.toast.success('Datalog schema constraints successfully verified.', 'Mangle Passed');
        } else {
          this.mangleStatus.set('failed');
          this.toast.error('Mangle invariant violations detected!', 'Mangle Failed');
        }
      },
      error: () => {
        this.mangleStatus.set('failed');
        this.toast.error('Failed to execute Mangle validation bounds.', 'Check Failed');
      }
    });
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

    if (this.userSettings.mode() === 'expert') {
      const expert = formVal.expertConfig;
      
      if (expert.use_peft) {
        payloadConfig['use_peft'] = true;
        payloadConfig['peft_config'] = {
          r: expert.peft_r,
          lora_alpha: expert.peft_alpha,
          lora_dropout: expert.peft_dropout
        };
      }

      if (expert.rawJson.trim()) {
        try {
          const parsedOverride = JSON.parse(expert.rawJson) as Record<string, unknown>;
          payloadConfig = { ...payloadConfig, ...parsedOverride, compute_strategy: expert.compute };
        } catch (e) {
          this.toast.error('Invalid JSON configuration', 'Syntax Error');
          this.submitting.set(false);
          return;
        }
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

  deployJob(job: JobResponse) {
    this.deployingJob.set(job.id);
    this.api.post(`/jobs/${job.id}/deploy`, {}).pipe(takeUntil(this.destroy$)).subscribe({
      next: () => {
        this.jobs.update(jobs => jobs.map(j => j.id === job.id ? {...j, deployed: true} : j));
        this.toast.success('Model mounted to inference pool successfully.', 'Deploy Complete');
        this.deployingJob.set(null);
      },
      error: (e: HttpErrorResponse) => {
        const detail = (e.error as { detail?: string })?.detail ?? 'Unknown error';
        this.toast.error(`Deploy failed: ${detail}`, 'Deployment Error');
        this.deployingJob.set(null);
      }
    });
  }

  openChat(job: JobResponse) {
    this.activeChatJob.set(job);
    this.chatHistory.set([{ role: 'model', text: 'Inference pipeline connected. I am ready to receive your text.' }]);
    this.chatInput.setValue('');
  }

  closeChat() {
    this.activeChatJob.set(null);
  }

  sendChat() {
    const text = this.chatInput.value?.trim();
    const job = this.activeChatJob();
    if (!text || !job) return;

    this.chatHistory.update(h => [...h, { role: 'user', text }]);
    this.chatInput.setValue('');
    this.chatLoading.set(true);

    this.api.post<{response: string}>(`/inference/${job.id}/chat`, { prompt: text }).pipe(takeUntil(this.destroy$)).subscribe({
      next: (res) => {
        this.chatHistory.update(h => [...h, { role: 'model', text: res.response }]);
        this.chatLoading.set(false);
      },
      error: (e: HttpErrorResponse) => {
        const detail = (e.error as { detail?: string })?.detail ?? 'Unknown error';
        this.toast.error(`Inference failed: ${detail}`, 'Error');
        this.chatLoading.set(false);
      }
    });
  }
}
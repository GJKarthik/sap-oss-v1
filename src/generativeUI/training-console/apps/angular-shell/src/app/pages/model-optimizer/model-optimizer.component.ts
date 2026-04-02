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
        <h1 class="page-title">Model Optimizer</h1>
        <button class="btn-primary" (click)="loadData()">↻ Refresh</button>
      </div>

      <!-- Engine & Dataset -->
      <h2 class="section-title">Engine Configuration</h2>
      <div class="card grid-2" style="margin-bottom: 1.5rem;">
        <div class="form-group">
          <label>Training Framework</label>
          <select [formControl]="frameworkControl" class="form-input">
            <option value="PyTorch">PyTorch Native (SFTTrainer)</option>
            <option value="TensorFlow" disabled>TensorFlow (Coming Soon)</option>
          </select>
        </div>
        <div class="form-group">
          <label>Dataset Split</label>
          <select [formControl]="datasetControl" class="form-input">
            <option value="spider-train">Spider Training Split (Text-to-SQL)</option>
            <option value="bird-train" disabled>BIRD Benchmark (Coming Soon)</option>
          </select>
        </div>
      </div>

      <!-- Mangle Data Validation -->
      <h2 class="section-title">Datalog Validation Pre-Flight</h2>
      <div class="card" style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 2rem; background: #fafafa; border-left: 4px solid var(--sapBrandColor);">
        <div>
          <p style="margin: 0 0 0.25rem; font-size: 0.875rem; color: #333;">Verify dataset mathematical integrity against <strong>Mangle</strong> schema invariants prior to tensor optimization.</p>
          @if (mangleStatus() === 'passed') {
            <span class="status-success text-small" style="font-weight: 600; display: inline-block; padding: 2px 6px; border-radius: 4px; background: #e8f5e9;">✓ All 48 Invariants Passed</span>
          } @else if (mangleStatus() === 'failed') {
            <span class="status-error text-small" style="font-weight: 600; display: inline-block; padding: 2px 6px; border-radius: 4px; background: #ffebee;">⚠ Datalog Violation Detected</span>
          } @else {
            <span class="text-muted text-small" style="display: inline-block;">Data invariants unverified.</span>
          }
        </div>
        <button type="button" class="btn-secondary" (click)="validateMangleRules()" [disabled]="mangleStatus() === 'checking'">
          {{ mangleStatus() === 'checking' ? 'Validating...' : 'Check Constraints' }}
        </button>
      </div>

      <!-- Model Catalog -->
      <section class="section">
        <h2 class="section-title">Model Catalog</h2>
        <div class="model-grid">
          @for (m of models(); track m.name) {
            <div
              class="model-card"
              [class.model-card--selected]="jobForm.value.model_name === m.name"
              [class.model-card--recommended]="m.recommended_quant === 'int4_awq'"
              (click)="selectModel(m)"
            >
              @if (m.recommended_quant === 'int4_awq') {
                <div class="recommended-ribbon">★ Recommended</div>
              }
              <div class="model-card-body">
                <div class="model-name-row">
                  <div class="model-name">{{ m.name.split('/').pop() }}</div>
                  <span class="size-indicator size-{{ getModelSize(m) }}">{{ getModelSize(m) }}</span>
                </div>
                <div class="model-org text-small text-muted">{{ m.name.includes('/') ? m.name.split('/')[0] : 'community' }}</div>
                <div class="model-meta">
                  <span class="badge badge--param">{{ m.parameters }}</span>
                  <span class="badge">{{ m.size_gb }} GB</span>
                  <span class="badge badge--quant">{{ m.recommended_quant }}</span>
                </div>
                <div class="model-arch-tags">
                  <span class="arch-pill">Transformer</span>
                  <span class="arch-pill">Causal LM</span>
                  @if (m.t4_compatible) {
                    <span class="arch-pill arch-pill--compat">T4 ✓</span>
                  } @else {
                    <span class="arch-pill arch-pill--warn">T4 ✗</span>
                  }
                </div>
              </div>
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
                <span class="vram-values">
                  <span class="vram-used">{{ estimatedVram().toFixed(1) }} GB</span>
                  <span class="vram-sep">/</span>
                  <span>{{ gpuTotalNum() }} GB</span>
                  <span class="vram-pct">({{ ((estimatedVram() / gpuTotalNum()) * 100).toFixed(0) }}%)</span>
                </span>
              </div>
              <div class="vram-bar">
                <div class="vram-fill vram-fill--animated"
                     [style.width.%]="mathMin(100, (estimatedVram() / gpuTotalNum()) * 100)"
                     [class.vram-fill--green]="(estimatedVram() / gpuTotalNum()) < 0.5"
                     [class.vram-fill--yellow]="(estimatedVram() / gpuTotalNum()) >= 0.5 && (estimatedVram() / gpuTotalNum()) < 0.8"
                     [class.vram-fill--red]="(estimatedVram() / gpuTotalNum()) >= 0.8">
                </div>
                <div class="vram-segments">
                  <div class="vram-segment" [style.width.%]="vramModelPct()">
                    <span class="vram-segment-label">Weights</span>
                  </div>
                  <div class="vram-segment" [style.width.%]="vramKvPct()">
                    <span class="vram-segment-label">KV Cache</span>
                  </div>
                  <div class="vram-segment" [style.width.%]="vramOverheadPct()">
                    <span class="vram-segment-label">Overhead</span>
                  </div>
                </div>
              </div>
              @if (isVramExceeded()) {
                <div class="vram-warning">
                  <span class="vram-warning-icon">⚠</span>
                  Critical: Configuration exceeds physical VRAM bounds. Job will OOM crash.
                </div>
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

                <div class="field-group full-width" style="background: rgba(8, 84, 160, 0.05); padding: 1rem; border-radius: 0.5rem; display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 1rem;">
                  <div class="full-width" style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: -0.5rem;">
                    <input type="checkbox" id="peftToggle" formControlName="use_peft" />
                    <label for="peftToggle" class="field-label" style="margin: 0; font-weight: 600;">Enable PEFT (LoRA Matrices)</label>
                  </div>
                  @if (jobForm.value.expertConfig?.use_peft) {
                    <div class="field-group">
                      <label class="field-label">Rank (r)</label>
                      <input type="number" class="form-input" formControlName="peft_r" />
                    </div>
                    <div class="field-group">
                      <label class="field-label">LoRA Alpha</label>
                      <input type="number" class="form-input" formControlName="peft_alpha" />
                    </div>
                    <div class="field-group">
                      <label class="field-label">Dropout</label>
                      <input type="number" class="form-input" formControlName="peft_dropout" step="0.01" />
                    </div>
                  }
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
        <h2 class="section-title">Jobs <span class="jobs-count">{{ jobs().length }}</span></h2>
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
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                @for (j of jobs(); track j.id) {
                  <ng-container>
                    <tr class="job-row" (click)="toggleExpand(j.id)" [class.expanded]="expandedJobId() === j.id">
                      <td class="mono text-small" style="cursor: pointer;">
                        <span class="expand-icon" [class.expand-icon--open]="expandedJobId() === j.id">▶</span>
                        {{ j.id.slice(0,8) }}
                      </td>
                      <td class="job-name-cell">{{ j.name }}</td>
                      <td class="text-small">{{ j.config.model_name }}</td>
                      <td><code class="quant-code">{{ j.config.quant_format }}</code></td>
                      <td>
                        <span class="status-badge-v2 status-{{ j.status }}">
                          <span class="status-dot"></span>
                          {{ j.status }}
                        </span>
                      </td>
                      <td style="min-width: 160px;">
                        <div class="progress-info">
                          <span class="text-small">{{ (j.progress * 100).toFixed(0) }}%</span>
                          <span class="text-small text-muted">{{ calculateETA(j) }}</span>
                        </div>
                        <div class="job-progress-bar">
                          <div class="job-progress-fill"
                               [style.width.%]="j.progress * 100"
                               [class.job-progress--running]="j.status === 'running'"
                               [class.job-progress--complete]="j.status === 'completed'">
                          </div>
                        </div>
                        @if (j.history && j.history.length > 0 && expandedJobId() !== j.id) {
                          <div class="sparkline-container mt-1" title="Training Loss (Solid) vs Val Loss (Dashed)">
                            <svg viewBox="0 0 100 24" class="sparkline-svg" preserveAspectRatio="none">
                              <defs>
                                <linearGradient [attr.id]="'sparkGrad-' + j.id" x1="0" y1="0" x2="0" y2="1">
                                  <stop offset="0%" stop-color="rgba(8,84,160,0.2)" />
                                  <stop offset="100%" stop-color="rgba(8,84,160,0)" />
                                </linearGradient>
                              </defs>
                              <path [attr.d]="generateSparklineArea(j.history, 'train_loss')" [attr.fill]="'url(#sparkGrad-' + j.id + ')'" />
                              <path [attr.d]="generateSparklineCurve(j.history, 'train_loss')" fill="none" class="train-line" />
                              <path [attr.d]="generateSparklineCurve(j.history, 'val_loss')" fill="none" class="val-line" />
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
                      <td class="actions-cell" (click)="$event.stopPropagation()">
                        <span class="text-small text-muted">{{ j.created_at | date:'short' }}</span>
                        @if (j.status === 'completed') {
                          <div class="action-buttons">
                            @if (!j.deployed) {
                              <button class="btn-deploy" (click)="deployJob(j)" [disabled]="deployingJob() === j.id">
                                {{ deployingJob() === j.id ? '⏳ Deploying...' : '🚀 Deploy' }}
                              </button>
                            } @else {
                              <button class="btn-chat" (click)="openChat(j)">
                                💬 Chat
                              </button>
                            }
                          </div>
                        }
                        @if (j.status === 'running') {
                          <div class="action-buttons">
                            <span class="running-indicator">● Running</span>
                          </div>
                        }
                      </td>
                    </tr>
                    @if (expandedJobId() === j.id) {
                      <tr class="detail-row">
                        <td colspan="7" class="detail-cell">
                          <div class="detail-expand-wrapper">
                            <app-job-detail [job]="j"></app-job-detail>
                          </div>
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
          <p class="text-muted text-small">No jobs yet.</p>
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
              <h3 style="margin: 0; font-size: 1rem;">💬 Playground: {{ chatJob.config.model_name }}</h3>
              <button class="close-btn" (click)="closeChat()">✕</button>
            </div>
            <div class="chat-window">
              @for (msg of chatHistory(); track $index) {
                <div class="chat-bubble" [class.user]="msg.role === 'user'">
                  <strong style="font-size: 0.75rem; color: #666;">{{ msg.role === 'user' ? 'You' : 'Model' }}</strong>
                  <p style="margin: 0.2rem 0 0; font-size: 0.875rem;">{{ msg.text }}</p>
                </div>
              }
              @if (chatLoading()) {
                <div class="chat-bubble loading">
                  <em style="font-size: 0.875rem; color: #666;">Model is computing tensors...</em>
                </div>
              }
            </div>
            <div class="chat-input-area">
              <input type="text" [formControl]="chatInput" class="form-input" placeholder="Prompt your finetuned model..." (keyup.enter)="sendChat()" />
              <button class="btn-primary" (click)="sendChat()" [disabled]="chatLoading() || !chatInput.value">Send</button>
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
      grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
      gap: 0.875rem;
      margin-bottom: 0.5rem;
    }

    .model-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.625rem;
      cursor: pointer;
      transition: border-color 0.2s, box-shadow 0.2s, transform 0.2s;
      position: relative;
      overflow: hidden;

      &:hover {
        border-color: var(--sapBrandColor, #0854a0);
        box-shadow: 0 4px 16px rgba(8, 84, 160, 0.12), 0 0 0 1px rgba(8, 84, 160, 0.08);
        transform: translateY(-2px);
      }

      &.model-card--selected {
        border-color: var(--sapBrandColor, #0854a0);
        box-shadow: 0 0 0 2px rgba(8, 84, 160, 0.25), 0 4px 12px rgba(8, 84, 160, 0.1);
      }

      &.model-card--recommended {
        border-color: rgba(8, 84, 160, 0.3);
      }
    }

    .model-card-body { padding: 0.875rem; }

    .recommended-ribbon {
      background: linear-gradient(135deg, var(--sapBrandColor, #0854a0), #1976d2);
      color: #fff;
      font-size: 0.65rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      padding: 0.2rem 0.75rem;
      text-align: center;
    }

    .model-name-row {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 0.5rem;
      margin-bottom: 0.15rem;
    }

    .model-name {
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--sapTextColor, #32363a);
      word-break: break-word;
      line-height: 1.3;
    }

    .model-org {
      font-size: 0.7rem;
      margin-bottom: 0.5rem;
    }

    .size-indicator {
      font-size: 0.6rem;
      font-weight: 700;
      padding: 0.15rem 0.4rem;
      border-radius: 0.25rem;
      flex-shrink: 0;
      text-transform: uppercase;
      letter-spacing: 0.03em;

      &.size-S { background: #e8f5e9; color: #2e7d32; }
      &.size-M { background: #e3f2fd; color: #1565c0; }
      &.size-L { background: #fff3e0; color: #e65100; }
      &.size-XL { background: #fce4ec; color: #c62828; }
    }

    .model-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 0.3rem;
      margin-bottom: 0.5rem;
    }

    .model-arch-tags {
      display: flex;
      flex-wrap: wrap;
      gap: 0.25rem;
    }

    .arch-pill {
      font-size: 0.6rem;
      padding: 0.1rem 0.4rem;
      border-radius: 1rem;
      background: var(--sapList_Background, #f5f5f5);
      color: var(--sapContent_LabelColor, #6a6d70);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);

      &.arch-pill--compat { background: #e8f5e9; color: #2e7d32; border-color: #c8e6c9; }
      &.arch-pill--warn { background: #fff3e0; color: #e65100; border-color: #ffe0b2; }
    }

    .badge {
      padding: 0.15rem 0.45rem;
      background: var(--sapList_Background, #f5f5f5);
      border-radius: 0.25rem;
      font-size: 0.7rem;
      color: var(--sapContent_LabelColor, #6a6d70);

      &.badge--param {
        background: var(--sapList_Background, #f5f5f5);
        font-weight: 600;
        color: var(--sapTextColor, #32363a);
      }

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
      background: var(--sapBaseColor, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      padding: 1rem 1.25rem;
      border-radius: 0.625rem;
      margin-top: 1rem;
      grid-column: 1 / -1;
      box-shadow: 0 1px 3px rgba(0,0,0,0.04);
    }

    .vram-danger {
      border-color: var(--sapNegativeColor, #b00);
      background: #fff5f5;
    }

    .vram-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 0.75rem;
      font-size: 0.8125rem;
    }

    .vram-title { font-weight: 600; color: var(--sapTextColor, #32363a); }
    .vram-values { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .vram-used { font-weight: 600; color: var(--sapTextColor, #32363a); }
    .vram-sep { margin: 0 0.2rem; }
    .vram-pct { margin-left: 0.3rem; font-weight: 600; }

    .vram-bar {
      height: 28px;
      background: var(--sapList_Background, #f5f5f5);
      border-radius: 6px;
      overflow: hidden;
      position: relative;
      margin-bottom: 0.5rem;
    }

    .vram-fill {
      height: 100%;
      border-radius: 6px;
      transition: width 0.6s cubic-bezier(0.4, 0, 0.2, 1);
      position: absolute;
      top: 0;
      left: 0;

      &.vram-fill--animated { animation: vramSlideIn 0.8s cubic-bezier(0.4, 0, 0.2, 1); }
      &.vram-fill--green { background: linear-gradient(90deg, #43a047, #66bb6a); }
      &.vram-fill--yellow { background: linear-gradient(90deg, #f9a825, #fdd835); }
      &.vram-fill--red { background: linear-gradient(90deg, #e53935, #ff5252); }
    }

    @keyframes vramSlideIn { from { width: 0 !important; } }

    .vram-segments {
      position: absolute;
      top: 0;
      left: 0;
      height: 100%;
      display: flex;
      width: 100%;
      pointer-events: none;
    }

    .vram-segment {
      height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
      border-right: 1px solid rgba(255,255,255,0.3);

      &:last-child { border-right: none; }
    }

    .vram-segment-label {
      font-size: 0.6rem;
      font-weight: 600;
      color: rgba(255,255,255,0.9);
      text-shadow: 0 1px 2px rgba(0,0,0,0.2);
      white-space: nowrap;
      overflow: hidden;
    }

    .vram-warning {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      font-size: 0.75rem;
      color: #c62828;
      font-weight: 500;
      padding: 0.4rem 0;
    }

    .vram-warning-icon { font-size: 0.875rem; }
    
    .jobs-count {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      background: var(--sapList_Background, #f5f5f5);
      color: var(--sapContent_LabelColor, #6a6d70);
      font-size: 0.7rem;
      font-weight: 600;
      min-width: 1.25rem;
      height: 1.25rem;
      border-radius: 1rem;
      padding: 0 0.35rem;
      margin-left: 0.35rem;
      vertical-align: middle;
    }

    .expand-icon {
      display: inline-block;
      width: 12px;
      margin-right: 4px;
      transition: transform 0.2s ease;
      font-size: 0.6rem;

      &.expand-icon--open { transform: rotate(90deg); }
    }

    .job-name-cell { font-weight: 500; }

    .quant-code {
      background: var(--sapList_Background, #f5f5f5);
      padding: 0.1rem 0.35rem;
      border-radius: 0.2rem;
      font-size: 0.75rem;
    }

    .status-badge-v2 {
      display: inline-flex;
      align-items: center;
      gap: 0.35rem;
      padding: 0.2rem 0.6rem;
      border-radius: 1rem;
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: capitalize;

      &.status-pending { background: #fff8e1; color: #f57f17; }
      &.status-running { background: #e3f2fd; color: #1565c0; }
      &.status-completed { background: #e8f5e9; color: #2e7d32; }
      &.status-failed { background: #ffebee; color: #c62828; }
      &.status-cancelled { background: #fafafa; color: #9e9e9e; }
    }

    .status-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: currentColor;
      flex-shrink: 0;
    }

    .status-running .status-dot { animation: statusPulse 1.5s ease-in-out infinite; }
    @keyframes statusPulse {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.4; transform: scale(0.8); }
    }

    .progress-info {
      display: flex;
      justify-content: space-between;
      margin-bottom: 0.2rem;
    }

    .job-progress-bar {
      height: 5px;
      background: var(--sapList_Background, #f5f5f5);
      border-radius: 3px;
      overflow: hidden;
    }

    .job-progress-fill {
      height: 100%;
      border-radius: 3px;
      transition: width 0.5s cubic-bezier(0.4, 0, 0.2, 1);
      background: var(--sapBrandColor, #0854a0);

      &.job-progress--running {
        background: linear-gradient(90deg, var(--sapBrandColor, #0854a0), #1976d2);
        animation: progressShimmer 2s ease-in-out infinite;
      }

      &.job-progress--complete {
        background: linear-gradient(90deg, #43a047, #66bb6a);
      }
    }

    @keyframes progressShimmer {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.7; }
    }

    .detail-cell { padding: 0 !important; }

    .detail-expand-wrapper {
      animation: expandIn 0.25s ease-out;
      overflow: hidden;
    }

    @keyframes expandIn {
      from { max-height: 0; opacity: 0; }
      to { max-height: 600px; opacity: 1; }
    }

    .job-row {
      cursor: pointer;
      transition: background-color 0.15s;

      &.expanded td { background: var(--sapList_Background, #f5f5f5); }
    }

    .actions-cell { min-width: 110px; }

    .action-buttons {
      display: flex;
      gap: 0.4rem;
      margin-top: 0.35rem;
    }

    .btn-deploy {
      padding: 0.25rem 0.6rem;
      font-size: 0.7rem;
      font-weight: 600;
      background: var(--sapBrandColor, #0854a0);
      color: #fff;
      border: none;
      border-radius: 0.3rem;
      cursor: pointer;
      transition: background 0.15s, transform 0.1s;

      &:hover:not(:disabled) { background: #0a6ed1; transform: translateY(-1px); }
      &:disabled { opacity: 0.5; cursor: default; }
    }

    .btn-chat {
      padding: 0.25rem 0.6rem;
      font-size: 0.7rem;
      font-weight: 600;
      background: #00695c;
      color: #fff;
      border: none;
      border-radius: 0.3rem;
      cursor: pointer;
      transition: background 0.15s, transform 0.1s;

      &:hover { background: #00897b; transform: translateY(-1px); }
    }

    .running-indicator {
      font-size: 0.7rem;
      color: #1565c0;
      font-weight: 600;
      animation: statusPulse 1.5s ease-in-out infinite;
    }

    .sparkline-container { width: 100%; height: 24px; background: rgba(0,0,0,0.015); border-radius: 4px; }
    .sparkline-svg { width: 100%; height: 100%; overflow: visible; }
    .train-line { stroke: var(--sapBrandColor, #0854a0); stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }
    .val-line { stroke: var(--sapNegativeColor, #b00); stroke-width: 1; stroke-dasharray: 3 2; stroke-linecap: round; }

    .eval-metrics {
      display: flex;
      align-items: center;
      gap: 0.4rem;
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

  readonly frameworkControl = this.jobForm.controls.framework;
  readonly datasetControl = this.jobForm.controls.dataset;

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

  readonly vramModelPct = computed(() => {
    const total = this.estimatedVram();
    if (total <= 0) return 0;
    const overhead = 1.5;
    const modelWeight = total - overhead;
    return Math.max(0, (modelWeight * 0.7 / total) * 100);
  });

  readonly vramKvPct = computed(() => {
    const total = this.estimatedVram();
    if (total <= 0) return 0;
    const overhead = 1.5;
    const modelWeight = total - overhead;
    return Math.max(0, (modelWeight * 0.3 / total) * 100);
  });

  readonly vramOverheadPct = computed(() => {
    const total = this.estimatedVram();
    if (total <= 0) return 0;
    return Math.max(0, (1.5 / total) * 100);
  });

  mathMin(a: number, b: number) { return Math.min(a, b); }

  getModelSize(m: ModelInfo): string {
    const gb = m.size_gb;
    if (gb <= 2) return 'S';
    if (gb <= 8) return 'M';
    if (gb <= 20) return 'L';
    return 'XL';
  }

  generateSparklinePath(history: any[], key: 'train_loss' | 'val_loss'): string {
    if (!history || history.length < 2) return '';
    const maxVal = Math.max(...history.map((h: any) => Math.max(h.train_loss, h.val_loss)));
    const minVal = 0;
    const w = 100;
    const h = 24;

    return history.map((pt: any, i: number) => {
      const x = (i / (history.length - 1)) * w;
      const y = h - ((pt[key] - minVal) / (maxVal - minVal) * h);
      return `${x},${y}`;
    }).join(' ');
  }

  generateSparklineCurve(history: any[], key: 'train_loss' | 'val_loss'): string {
    if (!history || history.length < 2) return '';
    const maxVal = Math.max(...history.map((h: any) => Math.max(h.train_loss, h.val_loss)));
    const minVal = 0;
    const w = 100;
    const h = 24;
    const pad = 2;

    const points = history.map((pt: any, i: number) => ({
      x: (i / (history.length - 1)) * w,
      y: pad + (h - 2 * pad) - ((pt[key] - minVal) / (maxVal - minVal) * (h - 2 * pad))
    }));

    let d = `M ${points[0].x},${points[0].y}`;
    for (let i = 1; i < points.length; i++) {
      const prev = points[i - 1];
      const curr = points[i];
      const cpx = (prev.x + curr.x) / 2;
      d += ` Q ${cpx},${prev.y} ${curr.x},${curr.y}`;
    }
    return d;
  }

  generateSparklineArea(history: any[], key: 'train_loss' | 'val_loss'): string {
    const curve = this.generateSparklineCurve(history, key);
    if (!curve) return '';
    const w = 100;
    const h = 24;
    const firstX = 0;
    return `${curve} L ${w},${h} L ${firstX},${h} Z`;
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
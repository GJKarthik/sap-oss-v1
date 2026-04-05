import { Component, OnInit, OnDestroy, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ReactiveFormsModule, FormBuilder, Validators } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
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
  imports: [CommonModule, ReactiveFormsModule, Ui5WebcomponentsModule, JobDetailComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Model Optimizer</ui5-title>
        <ui5-button slot="endContent" icon="refresh" design="Transparent"
          (click)="loadData()">Refresh</ui5-button>
      </ui5-bar>

      <div style="padding: 1.5rem; display: flex; flex-direction: column; gap: 1.5rem;">

      <!-- Engine & Dataset -->
      <ui5-title level="H5">Engine Configuration</ui5-title>
      <ui5-card>
        <ui5-card-header slot="header" title-text="Engine & Dataset"></ui5-card-header>
        <div style="padding: 1rem; display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
          <div class="field-group">
            <ui5-label for="frameworkSelect">Training Framework</ui5-label>
            <ui5-select id="frameworkSelect" style="width: 100%;" (change)="onFrameworkChange($event)">
              <ui5-option value="PyTorch" [selected]="frameworkControl.value === 'PyTorch'">PyTorch Native (SFTTrainer)</ui5-option>
              <ui5-option value="TensorFlow" disabled>TensorFlow (Coming Soon)</ui5-option>
            </ui5-select>
          </div>
          <div class="field-group">
            <ui5-label for="datasetSelect">Dataset Split</ui5-label>
            <ui5-select id="datasetSelect" style="width: 100%;" (change)="onDatasetChange($event)">
              <ui5-option value="spider-train" [selected]="datasetControl.value === 'spider-train'">Spider Training Split (Text-to-SQL)</ui5-option>
              <ui5-option value="bird-train" disabled>BIRD Benchmark (Coming Soon)</ui5-option>
            </ui5-select>
          </div>
        </div>
      </ui5-card>

      <!-- Mangle Data Validation -->
      <ui5-title level="H5">Datalog Validation Pre-Flight</ui5-title>
      <ui5-card>
        <div style="padding: 1rem; display: flex; justify-content: space-between; align-items: center;">
          <div>
            <ui5-text style="font-size: 0.875rem;">Verify dataset mathematical integrity against Mangle schema invariants prior to tensor optimization.</ui5-text>
            <div style="margin-top: 0.25rem;">
              @if (mangleStatus() === 'passed') {
                <ui5-tag design="Positive">✓ All 48 Invariants Passed</ui5-tag>
              } @else if (mangleStatus() === 'failed') {
                <ui5-tag design="Negative">⚠ Datalog Violation Detected</ui5-tag>
              } @else {
                <ui5-tag design="Set2">Data invariants unverified</ui5-tag>
              }
            </div>
          </div>
          <ui5-button design="Default" (click)="validateMangleRules()" [disabled]="mangleStatus() === 'checking'">
            {{ mangleStatus() === 'checking' ? 'Validating...' : 'Check Constraints' }}
          </ui5-button>
        </div>
      </ui5-card>

      <!-- Model Catalog -->
      <section class="section">
        <ui5-title level="H5">Model Catalog</ui5-title>
        <div class="model-grid">
          @for (m of models(); track m.name) {
            <ui5-card
              class="model-card"
              [class.model-card--selected]="jobForm.value.model_name === m.name"
              [class.model-card--recommended]="m.recommended_quant === 'int4_awq'"
              (click)="selectModel(m)"
            >
              <ui5-card-header slot="header"
                [titleText]="m.name.split('/').pop() ?? m.name"
                [subtitleText]="m.name.includes('/') ? m.name.split('/')[0] : 'community'">
              </ui5-card-header>
              <div class="model-card-body">
                @if (m.recommended_quant === 'int4_awq') {
                  <ui5-tag design="Positive" style="margin-bottom: 0.5rem;">★ Recommended</ui5-tag>
                }
                <div class="model-meta">
                  <ui5-tag design="Set2">{{ m.parameters }}</ui5-tag>
                  <ui5-tag design="Set2">{{ m.size_gb }} GB</ui5-tag>
                  <ui5-tag design="Information">{{ m.recommended_quant }}</ui5-tag>
                </div>
                <div class="model-arch-tags">
                  <ui5-tag design="Set2">Transformer</ui5-tag>
                  <ui5-tag design="Set2">Causal LM</ui5-tag>
                  @if (m.t4_compatible) {
                    <ui5-tag design="Positive">T4 ✓</ui5-tag>
                  } @else {
                    <ui5-tag design="Critical">T4 ✗</ui5-tag>
                  }
                </div>
              </div>
            </ui5-card>
          }
        </div>
        @if (!models().length && !loading()) {
          <ui5-message-strip design="Warning" hide-close-button>No models found — is the backend running?</ui5-message-strip>
        }
      </section>

      <!-- Create Job Form -->
      <section class="section">
        <ui5-title level="H5">Create Optimization Job</ui5-title>
        <ui5-card>
        <form class="job-form" [formGroup]="jobForm" (ngSubmit)="createJob()" style="padding: 1.25rem;">

          <!-- Novice Mode -->
          @if (userSettings.mode() === 'novice') {
            <div class="form-row">
              <div class="field-group">
                <ui5-label>Template</ui5-label>
                <ui5-select style="width: 100%;" (change)="onTemplateChange($event)">
                  <ui5-option value="" selected>Select a template…</ui5-option>
                  <ui5-option value="sql">Fine-tune Text-to-SQL (Recommended)</ui5-option>
                  <ui5-option value="finance">Finance Schema Optimization</ui5-option>
                  <ui5-option value="hr">HR Data Optimizer</ui5-option>
                </ui5-select>
              </div>
              <div class="field-group">
                <ui5-label>Model Name</ui5-label>
                <ui5-input style="width: 100%;" formControlName="model_name" placeholder="Auto-populated by template" readonly></ui5-input>
              </div>
            </div>

            @if (jobForm.value.model_name) {
              <ui5-message-strip design="Information" hide-close-button style="margin-bottom: 1rem;">
                💰 Estimated cost: ~$2.50 | Time: ~45 mins | Auto-scaling Compute
              </ui5-message-strip>
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
                <ui5-label>Model</ui5-label>
                <ui5-input style="width: 100%;" formControlName="model_name" placeholder="HuggingFace model name"></ui5-input>
              </div>
              <div class="field-group">
                <ui5-label>Quant Format</ui5-label>
                <ui5-select style="width: 100%;" (change)="onQuantFormatChange($event)">
                  <ui5-option value="int8" [selected]="jobForm.value.quant_format === 'int8'">INT8 SmoothQuant (Fast)</ui5-option>
                  <ui5-option value="int4_awq" [selected]="jobForm.value.quant_format === 'int4_awq'">INT4 AWQ (Best compression)</ui5-option>
                  <ui5-option value="w4a16" [selected]="jobForm.value.quant_format === 'w4a16'">W4A16 (Balanced)</ui5-option>
                </ui5-select>
              </div>
              <div class="field-group">
                <ui5-label>Export Format</ui5-label>
                <ui5-select style="width: 100%;" (change)="onExportFormatChange($event)">
                  <ui5-option value="hf" [selected]="jobForm.value.export_format === 'hf'">HuggingFace</ui5-option>
                  <ui5-option value="tensorrt_llm" [selected]="jobForm.value.export_format === 'tensorrt_llm'">TensorRT-LLM</ui5-option>
                  <ui5-option value="vllm" [selected]="jobForm.value.export_format === 'vllm'">vLLM</ui5-option>
                </ui5-select>
              </div>
              <div class="field-group">
                <ui5-label>Calib Samples <ui5-tag design="Positive" style="margin-left: 0.5rem;">Best Practice: 512</ui5-tag></ui5-label>
                <ui5-slider [value]="jobForm.value.calib_samples ?? 512" min="32" max="2048" step="32"
                  show-tooltip label-interval="8"
                  (input)="onCalibSamplesChange($event)"></ui5-slider>
                <ui5-text style="font-size: 0.75rem; color: var(--sapContent_LabelColor);">{{ jobForm.value.calib_samples }} samples</ui5-text>
              </div>
            </div>
          }

          <!-- Expert Mode -->
          @if (userSettings.mode() === 'expert') {
            <div class="form-row">
              <div class="field-group">
                <ui5-label>Model Override</ui5-label>
                <ui5-input style="width: 100%;" formControlName="model_name" placeholder="Custom URI / HF Repo"></ui5-input>
              </div>
              <ng-container formGroupName="expertConfig">
                <div class="field-group">
                  <ui5-label>Compute Strategy</ui5-label>
                  <ui5-select style="width: 100%;" (change)="onComputeStrategyChange($event)">
                    <ui5-option value="auto" [selected]="jobForm.value.expertConfig?.compute === 'auto'">Auto (Default)</ui5-option>
                    <ui5-option value="deepspeed_1" [selected]="jobForm.value.expertConfig?.compute === 'deepspeed_1'">DeepSpeed Stage 1</ui5-option>
                    <ui5-option value="deepspeed_3" [selected]="jobForm.value.expertConfig?.compute === 'deepspeed_3'">DeepSpeed Stage 3 (Multi-Node)</ui5-option>
                  </ui5-select>
                </div>

                <div class="field-group full-width" style="background: rgba(8, 84, 160, 0.05); padding: 1rem; border-radius: 0.5rem; display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 1rem;">
                  <div class="full-width" style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: -0.5rem;">
                    <ui5-checkbox id="peftToggle" text="Enable PEFT (LoRA Matrices)"
                      [checked]="jobForm.value.expertConfig?.use_peft ?? false"
                      (change)="onPeftToggle($event)"></ui5-checkbox>
                  </div>
                  @if (jobForm.value.expertConfig?.use_peft) {
                    <div class="field-group">
                      <ui5-label>Rank (r)</ui5-label>
                      <ui5-input type="Number" style="width: 100%;" formControlName="peft_r"></ui5-input>
                    </div>
                    <div class="field-group">
                      <ui5-label>LoRA Alpha</ui5-label>
                      <ui5-input type="Number" style="width: 100%;" formControlName="peft_alpha"></ui5-input>
                    </div>
                    <div class="field-group">
                      <ui5-label>Dropout</ui5-label>
                      <ui5-input type="Number" style="width: 100%;" formControlName="peft_dropout"></ui5-input>
                    </div>
                  }
                </div>

                <div class="field-group full-width">
                  <ui5-label>Raw JSON Override (Arguments Map)</ui5-label>
                  <ui5-textarea style="width: 100%;" rows="5" formControlName="rawJson"
                    placeholder='{"quant_format": "int8", "enable_pruning": true}'></ui5-textarea>
                </div>
              </ng-container>
            </div>
          }

          <div class="form-actions" style="margin-top: 1rem;">
            <ui5-button design="Emphasized" type="Submit" (click)="createJob()" [disabled]="jobForm.invalid || submitting() || isVramExceeded()">
              {{ submitting() ? 'Submitting…' : '▶ Run Job' }}
            </ui5-button>
          </div>
        </form>
        </ui5-card>
      </section>

      <!-- Jobs Table -->
      <section class="section">
        <div style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.75rem;">
          <ui5-title level="H5">Jobs</ui5-title>
          <ui5-tag design="Set2">{{ jobs().length }}</ui5-tag>
        </div>
        @if (jobs().length) {
          <ui5-table>
            <ui5-table-header-row slot="headerRow">
              <ui5-table-header-cell>ID</ui5-table-header-cell>
              <ui5-table-header-cell>Name</ui5-table-header-cell>
              <ui5-table-header-cell>Model</ui5-table-header-cell>
              <ui5-table-header-cell>Quant</ui5-table-header-cell>
              <ui5-table-header-cell>Status</ui5-table-header-cell>
              <ui5-table-header-cell min-width="160">Progress</ui5-table-header-cell>
              <ui5-table-header-cell>Actions</ui5-table-header-cell>
            </ui5-table-header-row>
            @for (j of jobs(); track j.id) {
              <ui5-table-row class="job-row" (click)="toggleExpand(j.id)" style="cursor: pointer;">
                <ui5-table-cell>
                  <code style="font-size: 0.75rem;">
                    <span class="expand-icon" [class.expand-icon--open]="expandedJobId() === j.id">▶</span>
                    {{ j.id.slice(0,8) }}
                  </code>
                </ui5-table-cell>
                <ui5-table-cell><ui5-text style="font-weight: 500;">{{ j.name }}</ui5-text></ui5-table-cell>
                <ui5-table-cell><ui5-text style="font-size: 0.8rem;">{{ j.config.model_name }}</ui5-text></ui5-table-cell>
                <ui5-table-cell><ui5-tag design="Set2">{{ j.config.quant_format }}</ui5-tag></ui5-table-cell>
                <ui5-table-cell>
                  <ui5-tag [design]="getStatusDesign(j.status)">{{ j.status }}</ui5-tag>
                </ui5-table-cell>
                <ui5-table-cell>
                  <div style="display: flex; flex-direction: column; gap: 0.25rem;">
                    <div class="progress-info">
                      <ui5-text style="font-size: 0.75rem;">{{ (j.progress * 100).toFixed(0) }}%</ui5-text>
                      <ui5-text style="font-size: 0.75rem; color: var(--sapContent_LabelColor);">{{ calculateETA(j) }}</ui5-text>
                    </div>
                    <ui5-progress-indicator
                      [value]="j.progress * 100"
                      [valueState]="j.status === 'completed' ? 'Positive' : j.status === 'failed' ? 'Negative' : 'Information'"
                      style="min-width: 120px;">
                    </ui5-progress-indicator>
                    @if (j.history && j.history.length > 0 && expandedJobId() !== j.id) {
                      <div class="sparkline-container" title="Training Loss (Solid) vs Val Loss (Dashed)">
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
                      <div class="eval-metrics">
                        <ui5-tag design="Positive" title="Perplexity (Lower is better)">PPL: {{ j.evaluation.perplexity }}</ui5-tag>
                        <ui5-tag design="Set2" title="Validation Loss">Loss: {{ j.evaluation.eval_loss }}</ui5-tag>
                        <ui5-text style="font-size: 0.7rem; color: var(--sapContent_LabelColor);">{{ j.evaluation.runtime_sec }}s</ui5-text>
                      </div>
                    }
                  </div>
                </ui5-table-cell>
                <ui5-table-cell (click)="$event.stopPropagation()">
                  <div style="display: flex; flex-direction: column; gap: 0.35rem;">
                    <ui5-text style="font-size: 0.75rem; color: var(--sapContent_LabelColor);">{{ j.created_at | date:'short' }}</ui5-text>
                    @if (j.status === 'completed') {
                      @if (!j.deployed) {
                        <ui5-button design="Emphasized" icon="process" (click)="deployJob(j)" [disabled]="deployingJob() === j.id">
                          {{ deployingJob() === j.id ? 'Deploying...' : 'Deploy' }}
                        </ui5-button>
                      } @else {
                        <ui5-button design="Transparent" icon="discussion" (click)="openChat(j)">Chat</ui5-button>
                      }
                    }
                    @if (j.status === 'running') {
                      <ui5-tag design="Information" class="running-indicator">● Running</ui5-tag>
                    }
                  </div>
                </ui5-table-cell>
              </ui5-table-row>
              @if (expandedJobId() === j.id) {
                <ui5-table-row class="detail-row">
                  <ui5-table-cell colspan="7" class="detail-cell">
                    <div class="detail-expand-wrapper">
                      <app-job-detail [job]="j"></app-job-detail>
                    </div>
                  </ui5-table-cell>
                </ui5-table-row>
              }
            }
          </ui5-table>
        }
        @if (!jobs().length && !loading()) {
          <ui5-message-strip design="Information" hide-close-button>No jobs yet.</ui5-message-strip>
        }
      </section>

      @if (loading()) {
        <ui5-busy-indicator active size="L" style="width: 100%; padding: 2rem;"></ui5-busy-indicator>
      }

      <!-- Chat Playground Modal -->
      @if (activeChatJob(); as chatJob) {
        <ui5-dialog [open]="true" header-text="💬 Playground: {{ chatJob.config.model_name }}" (after-close)="closeChat()">
          <div class="chat-window">
            @for (msg of chatHistory(); track $index) {
              <div class="chat-bubble" [class.user]="msg.role === 'user'">
                <ui5-text style="font-size: 0.75rem; color: #666;">{{ msg.role === 'user' ? 'You' : 'Model' }}</ui5-text>
                <ui5-text style="display: block; margin-top: 0.2rem; font-size: 0.875rem;">{{ msg.text }}</ui5-text>
              </div>
            }
            @if (chatLoading()) {
              <div class="chat-bubble loading">
                <ui5-busy-indicator active size="S"></ui5-busy-indicator>
                <ui5-text style="font-size: 0.875rem; color: #666;">Model is computing tensors...</ui5-text>
              </div>
            }
          </div>
          <div slot="footer" class="chat-input-area">
            <ui5-input style="flex: 1;" [formControl]="chatInput" placeholder="Prompt your finetuned model..." (keyup.enter)="sendChat()"></ui5-input>
            <ui5-button design="Emphasized" (click)="sendChat()" [disabled]="chatLoading() || !chatInput.value">Send</ui5-button>
          </div>
        </ui5-dialog>
      }

      </div>
    </ui5-page>
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

  // UI5 select/slider change handlers
  onFrameworkChange(event: any): void {
    const val = event?.detail?.selectedOption?.getAttribute('value') ?? event?.detail?.selectedOption?.value;
    if (val) this.frameworkControl.setValue(val);
  }

  onDatasetChange(event: any): void {
    const val = event?.detail?.selectedOption?.getAttribute('value') ?? event?.detail?.selectedOption?.value;
    if (val) this.datasetControl.setValue(val);
  }

  onTemplateChange(event: any): void {
    const val = event?.detail?.selectedOption?.getAttribute('value') ?? event?.detail?.selectedOption?.value ?? '';
    this.applyTemplate(val);
  }

  onQuantFormatChange(event: any): void {
    const val = event?.detail?.selectedOption?.getAttribute('value') ?? event?.detail?.selectedOption?.value;
    if (val) this.jobForm.patchValue({ quant_format: val });
  }

  onExportFormatChange(event: any): void {
    const val = event?.detail?.selectedOption?.getAttribute('value') ?? event?.detail?.selectedOption?.value;
    if (val) this.jobForm.patchValue({ export_format: val });
  }

  onCalibSamplesChange(event: any): void {
    const val = event?.detail?.value ?? event?.target?.value;
    if (val != null) this.jobForm.patchValue({ calib_samples: +val });
  }

  onComputeStrategyChange(event: any): void {
    const val = event?.detail?.selectedOption?.getAttribute('value') ?? event?.detail?.selectedOption?.value;
    if (val) this.jobForm.controls.expertConfig.controls.compute.setValue(val);
  }

  onPeftToggle(event: any): void {
    const checked = event?.detail?.checked ?? false;
    this.jobForm.controls.expertConfig.controls.use_peft.setValue(checked);
  }

  getStatusDesign(status: string): string {
    const map: Record<string, string> = {
      pending: 'Critical',
      running: 'Information',
      completed: 'Positive',
      failed: 'Negative',
      cancelled: 'Set2',
    };
    return map[status] ?? 'Set2';
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

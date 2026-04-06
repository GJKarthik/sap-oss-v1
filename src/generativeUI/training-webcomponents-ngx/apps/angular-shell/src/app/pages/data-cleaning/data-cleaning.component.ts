import { ChangeDetectionStrategy, Component, CUSTOM_ELEMENTS_SCHEMA, OnDestroy, OnInit, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpErrorResponse } from '@angular/common/http';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';

interface DataCleaningHealth {
  status: string;
  session_ready?: boolean;
  aicore_config_ready?: boolean;
  [key: string]: unknown;
}

interface DataCleaningChatResponse {
  response: string;
}

type DataCleaningCheck = Record<string, unknown>;

interface DataCleaningWorkflowRunResponse {
  run_id: string;
  status: string;
}

interface DataCleaningWorkflowStatus {
  run_id: string;
  status: string;
  result?: Record<string, unknown> | null;
}

interface DataCleaningWorkflowEventsResponse {
  run_id: string;
  status: string;
  events: Array<Record<string, unknown>>;
}

@Component({
  selector: 'app-data-cleaning',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">{{ i18n.t('dataCleaning.title') }}</h1>
        <p class="text-muted">{{ i18n.t('dataCleaning.subtitle') }}</p>
      </div>

      <div class="toolbar">
        <span class="status-pill" [class.status-pill--ok]="healthStatus() === 'ok'">
          {{ i18n.t('dataCleaning.backend') }}: {{ healthStatus() }}
        </span>
        @if (activeWorkflowId()) {
          <span class="status-pill" [class.status-pill--ok]="workflowStatus() === 'completed'">
            {{ i18n.t('dataCleaning.workflow') }}: {{ workflowStatus() }}
          </span>
        }
        <ui5-button design="Default" (click)="refreshAll()" [disabled]="loadingHealth() || loadingChecks()">
          {{ i18n.t('dataCleaning.refresh') }}
        </ui5-button>
        <ui5-button design="Transparent" (click)="clearSession()" [disabled]="sending() || workflowRunning()">
          {{ i18n.t('dataCleaning.clearSession') }}
        </ui5-button>
      </div>

      <div class="grid">
        <section class="panel">
          <h2>{{ i18n.t('dataCleaning.copilotChat') }}</h2>
          <div class="chat-log">
            @if (!messages().length) {
              <div class="empty">{{ i18n.t('dataCleaning.emptyChat') }}</div>
            }
            @for (msg of messages(); track msg.ts) {
              <div class="msg" [class.msg--user]="msg.role === 'user'" [class.msg--assistant]="msg.role === 'assistant'">
                <div class="msg-role">{{ msg.role === 'user' ? i18n.t('dataCleaning.you') : i18n.t('dataCleaning.copilot') }}</div>
                <div class="msg-content">{{ msg.content }}</div>
              </div>
            }
          </div>
          <form class="chat-input-row" (ngSubmit)="sendMessage()">
            <textarea
              class="chat-input"
              name="prompt"
              [(ngModel)]="prompt"
              rows="2"
              [placeholder]="i18n.t('dataCleaning.placeholder')"
            ></textarea>
            <ui5-button design="Emphasized" (click)="sendMessage()" [disabled]="sending() || !prompt.trim()">
              {{ sending() ? '...' : i18n.t('dataCleaning.send') }}
            </ui5-button>
          </form>

          <div class="workflow-cta">
            <ui5-button design="Emphasized" (click)="runWorkflow()" [disabled]="workflowRunning() || !lastPrompt">
              {{ workflowRunning() ? i18n.t('dataCleaning.runningWorkflow') : i18n.t('dataCleaning.runWorkflow') }}
            </ui5-button>
            <span class="empty">{{ i18n.t('dataCleaning.workflowDesc') }}</span>
          </div>
        </section>

        <section class="panel">
          <h2>{{ i18n.t('dataCleaning.generatedChecks') }}</h2>
          @if (loadingChecks()) {
            <div class="empty">{{ i18n.t('dataCleaning.loadingChecks') }}</div>
          } @else if (!checks().length) {
            <div class="empty">{{ i18n.t('dataCleaning.noChecks') }}</div>
          } @else {
            <div class="checks-list">
              @for (check of checks(); track $index) {
                <pre class="check-item">{{ check | json }}</pre>
              }
            </div>
          }

          <h2>{{ i18n.t('dataCleaning.workflowEvents') }}</h2>
          @if (!workflowEvents().length) {
            <div class="empty">{{ i18n.t('dataCleaning.noEvents') }}</div>
          } @else {
            <div class="events-list">
              @for (event of workflowEvents(); track $index) {
                <pre class="check-item">{{ event | json }}</pre>
              }
            </div>
          }
        </section>
      </div>
    </div>
  `,
  styles: [`
    .toolbar { display: flex; gap: .5rem; align-items: center; margin-bottom: 1rem; }
    .status-pill {
      border-radius: 999px; padding: .2rem .6rem; font-size: .75rem; font-weight: 600;
      background: #ffebee; color: #b71c1c;
    }
    .status-pill--ok { background: #e8f5e9; color: #2e7d32; }
    .refresh-btn {
      border: 1px solid var(--sapField_BorderColor, #89919a);
      background: #fff; border-radius: .25rem; padding: .3rem .65rem; cursor: pointer;
    }
    .grid { display: grid; grid-template-columns: 1.2fr 1fr; gap: 1rem; }
    .panel {
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: .5rem; background: #fff; padding: 1rem; min-height: 420px;
      display: flex; flex-direction: column; gap: .75rem;
    }
    .panel h2 { margin: 0; font-size: .95rem; }
    .chat-log { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: .6rem; }
    .msg { border: 1px solid #e4e4e4; border-radius: .45rem; padding: .55rem .7rem; background: #fafafa; }
    .msg--user { background: #e8f2ff; border-color: #bfd6f8; }
    .msg-role { font-size: .68rem; font-weight: 700; text-transform: uppercase; opacity: .7; margin-bottom: .2rem; }
    .msg-content { font-size: .84rem; white-space: pre-wrap; word-break: break-word; }
    .chat-input-row { display: flex; gap: .5rem; align-items: flex-end; }
    .chat-input {
      flex: 1; border: 1px solid var(--sapField_BorderColor, #89919a); border-radius: .35rem;
      padding: .5rem .65rem; font-family: inherit; resize: none;
    }
    .send-btn {
      border: none; border-radius: .35rem; background: var(--sapBrandColor, #0854a0);
      color: #fff; padding: .45rem .85rem; cursor: pointer;
    }
    .send-btn:disabled { opacity: .6; cursor: default; }
    .workflow-cta { display: flex; flex-direction: column; gap: .4rem; margin-top: .5rem; }
    .run-btn {
      border: none; border-radius: .35rem; background: #1b5e20;
      color: #fff; padding: .45rem .85rem; cursor: pointer; width: fit-content;
    }
    .run-btn:disabled { opacity: .6; cursor: default; }
    .checks-list { overflow-y: auto; display: flex; flex-direction: column; gap: .55rem; }
    .events-list { overflow-y: auto; display: flex; flex-direction: column; gap: .55rem; max-height: 220px; }
    .check-item {
      margin: 0; background: #111827; color: #c7d2fe; border-radius: .4rem;
      padding: .6rem .75rem; font-size: .74rem; white-space: pre-wrap;
    }
    .empty { color: #6a6d70; font-size: .82rem; }
  `],
})
export class DataCleaningComponent implements OnInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
  private workflowPollTimer: ReturnType<typeof setInterval> | null = null;

  readonly healthStatus = signal('unknown');
  readonly loadingHealth = signal(false);
  readonly loadingChecks = signal(false);
  readonly checks = signal<DataCleaningCheck[]>([]);
  readonly sending = signal(false);
  readonly workflowRunning = signal(false);
  readonly workflowStatus = signal('idle');
  readonly activeWorkflowId = signal<string | null>(null);
  readonly workflowEvents = signal<Array<Record<string, unknown>>>([]);
  readonly messages = signal<Array<{ role: 'user' | 'assistant'; content: string; ts: number }>>([]);

  prompt = '';
  lastPrompt = '';

  ngOnInit(): void {
    this.refreshAll();
  }

  ngOnDestroy(): void {
    this.stopWorkflowPolling();
  }

  refreshAll(): void {
    this.loadHealth();
    this.loadChecks();
    const runId = this.activeWorkflowId();
    if (runId) {
      this.loadWorkflowEvents(runId);
    }
  }

  sendMessage(): void {
    const message = this.prompt.trim();
    if (!message || this.sending()) {
      return;
    }
    this.lastPrompt = message;
    this.messages.update((m) => [...m, { role: 'user', content: message, ts: Date.now() }]);
    this.prompt = '';
    this.sending.set(true);

    this.api.post<DataCleaningChatResponse>('/data-cleaning/chat', { message }).subscribe({
      next: (response) => {
        this.messages.update((m) => [...m, { role: 'assistant', content: response.response ?? '(no response)', ts: Date.now() }]);
        this.sending.set(false);
        this.loadChecks();
      },
      error: (error: HttpErrorResponse) => {
        this.toast.error(this.extractDetail(error), 'Data Cleaning Error');
        this.sending.set(false);
      },
    });
  }

  runWorkflow(): void {
    if (this.workflowRunning() || !this.lastPrompt.trim()) {
      return;
    }
    this.workflowRunning.set(true);
    this.workflowStatus.set('pending');
    this.workflowEvents.set([]);

    this.api.post<DataCleaningWorkflowRunResponse>('/data-cleaning/workflow/run', { message: this.lastPrompt }).subscribe({
      next: (run) => {
        const runId = run.run_id;
        this.activeWorkflowId.set(runId);
        this.workflowStatus.set(run.status ?? 'pending');
        this.startWorkflowPolling(runId);
      },
      error: (error: HttpErrorResponse) => {
        this.toast.error(this.extractDetail(error), 'Workflow Error');
        this.workflowRunning.set(false);
      },
    });
  }

  clearSession(): void {
    this.api.delete<{ status: string }>('/data-cleaning/session').subscribe({
      next: () => {
        this.messages.set([]);
        this.checks.set([]);
        this.workflowEvents.set([]);
        this.activeWorkflowId.set(null);
        this.workflowStatus.set('idle');
        this.workflowRunning.set(false);
        this.stopWorkflowPolling();
        this.toast.info(this.i18n.t('dataCleaning.sessionCleared'));
      },
      error: (error: HttpErrorResponse) => {
        this.toast.warning(this.extractDetail(error), 'Data Cleaning Session');
      },
    });
  }

  private loadHealth(): void {
    this.loadingHealth.set(true);
    this.api.get<DataCleaningHealth>('/data-cleaning/health').subscribe({
      next: (health) => {
        this.healthStatus.set(String(health.status ?? 'unknown'));
        this.loadingHealth.set(false);
      },
      error: (error: HttpErrorResponse) => {
        this.healthStatus.set('unreachable');
        this.toast.warning(this.extractDetail(error), 'Data Cleaning Health');
        this.loadingHealth.set(false);
      },
    });
  }

  private loadChecks(): void {
    this.loadingChecks.set(true);
    this.api.get<DataCleaningCheck[]>('/data-cleaning/checks').subscribe({
      next: (checks) => {
        this.checks.set(Array.isArray(checks) ? checks : []);
        this.loadingChecks.set(false);
      },
      error: (error: HttpErrorResponse) => {
        this.toast.warning(this.extractDetail(error), 'Data Cleaning Checks');
        this.loadingChecks.set(false);
      },
    });
  }

  private startWorkflowPolling(runId: string): void {
    this.stopWorkflowPolling();
    this.loadWorkflowStatus(runId);
    this.loadWorkflowEvents(runId);
    this.workflowPollTimer = setInterval(() => {
      this.loadWorkflowStatus(runId);
      this.loadWorkflowEvents(runId);
    }, 1000);
  }

  private stopWorkflowPolling(): void {
    if (this.workflowPollTimer) {
      clearInterval(this.workflowPollTimer);
      this.workflowPollTimer = null;
    }
  }

  private loadWorkflowStatus(runId: string): void {
    this.api.get<DataCleaningWorkflowStatus>(`/data-cleaning/workflow/${runId}`).subscribe({
      next: (status) => {
        const value = status.status ?? 'unknown';
        this.workflowStatus.set(value);
        if (value === 'completed' || value === 'failed') {
          this.workflowRunning.set(false);
          this.stopWorkflowPolling();
        }
      },
      error: (error: HttpErrorResponse) => {
        this.workflowRunning.set(false);
        this.stopWorkflowPolling();
        this.toast.warning(this.extractDetail(error), 'Workflow Status');
      },
    });
  }

  private loadWorkflowEvents(runId: string): void {
    this.api.get<DataCleaningWorkflowEventsResponse>(`/data-cleaning/workflow/${runId}/events`).subscribe({
      next: (result) => {
        this.workflowEvents.set(Array.isArray(result.events) ? result.events : []);
      },
      error: (error: HttpErrorResponse) => {
        this.toast.warning(this.extractDetail(error), 'Workflow Events');
      },
    });
  }

  private extractDetail(error: HttpErrorResponse): string {
    return (error.error as { detail?: string })?.detail ?? error.message ?? 'Request failed';
  }
}


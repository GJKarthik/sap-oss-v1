import { ChangeDetectionStrategy, Component, CUSTOM_ELEMENTS_SCHEMA, OnDestroy, OnInit, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpErrorResponse } from '@angular/common/http';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';

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
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Data Cleaning Copilot</ui5-title>
        <ui5-button slot="endContent" icon="refresh" design="Transparent"
          (click)="refreshAll()" [disabled]="loadingHealth() || loadingChecks()">
          Refresh
        </ui5-button>
        <ui5-button slot="endContent" icon="decline" design="Negative"
          (click)="clearSession()" [disabled]="sending() || workflowRunning()">
          Clear Session
        </ui5-button>
      </ui5-bar>

      <div style="padding: 1.5rem; display: flex; flex-direction: column; gap: 1.5rem;">

      <!-- Summary Stats -->
      <div class="stats-grid">
        <ui5-card>
          <ui5-card-header slot="header" title-text="Checks Generated" subtitle-text="Data quality checks"></ui5-card-header>
          <div style="padding: 1rem; text-align: center;">
            <ui5-title level="H1">{{ checks().length }}</ui5-title>
          </div>
        </ui5-card>
        <ui5-card>
          <ui5-card-header slot="header" title-text="Pass Rate" subtitle-text="Percentage passing"></ui5-card-header>
          <div style="padding: 1rem; text-align: center;">
            <ui5-title level="H1">{{ passRate() }}%</ui5-title>
          </div>
        </ui5-card>
        <ui5-card>
          <ui5-card-header slot="header" title-text="Issues Found" subtitle-text="Checks with issues"></ui5-card-header>
          <div style="padding: 1rem; text-align: center;">
            <ui5-title level="H1">{{ issueCount() }}</ui5-title>
          </div>
        </ui5-card>
        <ui5-card>
          <ui5-card-header slot="header" title-text="Backend Status"></ui5-card-header>
          <div style="padding: 1rem; text-align: center; display: flex; flex-direction: column; align-items: center; gap: 0.5rem;">
            <ui5-tag [design]="healthStatus() === 'ok' ? 'Positive' : 'Negative'">
              {{ healthStatus() === 'ok' ? 'Online' : healthStatus() }}
            </ui5-tag>
          </div>
        </ui5-card>
      </div>

      <div class="grid">
        <!-- ─── Chat Panel ─── -->
        <ui5-card class="chat-panel">
          <ui5-card-header slot="header" title-text="Copilot Chat" subtitle-text="AI-assisted data cleaning">
            <ui5-icon slot="avatar" name="co"></ui5-icon>
            @if (activeWorkflowId()) {
              <ui5-tag slot="action"
                [design]="workflowStatus() === 'completed' ? 'Positive' : workflowStatus() === 'failed' ? 'Negative' : 'Information'">
                {{ workflowStatus() }}
              </ui5-tag>
            }
          </ui5-card-header>

          <div class="chat-log">
            @if (!messages().length) {
              <div class="empty-state">
                <ui5-icon name="discussion" style="font-size: 3rem; color: var(--sapContent_IllustratedMessageNeutralColor);"></ui5-icon>
                <ui5-title level="H5">Start a Conversation</ui5-title>
                <ui5-label>Describe a data quality issue to generate cleaning checks</ui5-label>
                <div class="suggestion-chips">
                  @for (s of suggestions; track s) {
                    <ui5-button design="Transparent" (click)="usePrompt(s)">{{ s }}</ui5-button>
                  }
                </div>
              </div>
            }
            @for (msg of messages(); track msg.ts) {
              <div class="message-row" [class.message-row--user]="msg.role === 'user'">
                <div class="avatar" [class.avatar--user]="msg.role === 'user'" [class.avatar--bot]="msg.role === 'assistant'">
                  {{ msg.role === 'user' ? '👤' : '🤖' }}
                </div>
                <div class="bubble" [class.bubble--user]="msg.role === 'user'" [class.bubble--bot]="msg.role === 'assistant'">
                  <div class="bubble-header">
                    <span class="bubble-role">{{ msg.role === 'user' ? 'You' : 'Copilot' }}</span>
                    <span class="bubble-ts">{{ formatTime(msg.ts) }}</span>
                  </div>
                  <div class="bubble-content">{{ msg.content }}</div>
                </div>
              </div>
            }
            @if (sending()) {
              <div class="message-row">
                <div class="avatar avatar--bot">🤖</div>
                <ui5-busy-indicator [active]="true" size="S" text="Copilot is thinking…"></ui5-busy-indicator>
              </div>
            }
          </div>

          <form class="chat-input-row" (ngSubmit)="sendMessage()">
            <ui5-textarea
              class="chat-input"
              placeholder="e.g. Profile CUSTOMER table and suggest null-value remediations"
              [value]="prompt"
              (input)="onTextAreaInput($event)"
              rows="2"
              growing="true"
              growing-max-rows="4"
              (keydown.meta.enter)="sendMessage()"
            ></ui5-textarea>
            <ui5-button icon="paper-plane" design="Emphasized"
              (click)="sendMessage()"
              [disabled]="sending() || !prompt.trim()">
            </ui5-button>
          </form>

          <div class="workflow-cta">
            <ui5-button icon="media-play" design="Emphasized"
              (click)="runWorkflow()" [disabled]="workflowRunning() || !lastPrompt">
              {{ workflowRunning() ? 'Running…' : 'Run Cleaning Workflow' }}
            </ui5-button>
            <ui5-label>Uses your last prompt to create cleaning actions</ui5-label>
          </div>
        </ui5-card>

        <!-- ─── Right Panel: Checks & Timeline ─── -->
        <div class="right-panel">
          <!-- Generated Checks -->
          <ui5-card>
            <ui5-card-header slot="header" title-text="Generated Checks" [subtitleText]="checks().length + ' checks'">
              <ui5-icon slot="avatar" name="quality-issue"></ui5-icon>
            </ui5-card-header>

            @if (loadingChecks()) {
              <ui5-busy-indicator [active]="true" size="M" style="width: 100%; padding: 1rem;"></ui5-busy-indicator>
            } @else if (!checks().length) {
              <div class="empty-state empty-state-sm">
                <ui5-icon name="checklist-item" style="font-size: 2rem; color: var(--sapContent_NonInteractiveIconColor);"></ui5-icon>
                <ui5-label wrapping-type="Normal">No checks generated yet. Send a chat prompt to get started.</ui5-label>
              </div>
            } @else {
              <div class="checks-list">
                @for (check of checks(); track $index) {
                  <ui5-card class="check-card">
                    <ui5-card-header slot="header" [titleText]="getCheckName(check)">
                      <ui5-tag slot="action"
                        [design]="getSeverity(check) === 'critical' ? 'Negative' : getSeverity(check) === 'warning' ? 'Critical' : 'Information'">
                        {{ getSeverity(check) }}
                      </ui5-tag>
                    </ui5-card-header>
                    <div style="padding: 0.5rem 1rem;">
                      @if (getCheckDesc(check)) {
                        <ui5-label wrapping-type="Normal" class="check-desc">{{ getCheckDesc(check) }}</ui5-label>
                      }
                      @if (getColumns(check).length) {
                        <div class="column-pills">
                          @for (col of getColumns(check); track col) {
                            <ui5-tag design="Set2">{{ col }}</ui5-tag>
                          }
                        </div>
                      }
                      @if (getCheckSql(check)) {
                        <pre class="check-sql">{{ getCheckSql(check) }}</pre>
                      }
                    </div>
                  </ui5-card>
                }
              </div>
            }
          </ui5-card>

          <!-- Workflow Events -->
          <ui5-card>
            <ui5-card-header slot="header" title-text="Workflow Events" [subtitleText]="workflowEvents().length + ' events'">
              <ui5-icon slot="avatar" name="activity-items"></ui5-icon>
            </ui5-card-header>

            @if (!workflowEvents().length) {
              <div class="empty-state empty-state-sm">
                <ui5-icon name="process" style="font-size: 2rem; color: var(--sapContent_NonInteractiveIconColor);"></ui5-icon>
                <ui5-label wrapping-type="Normal">No workflow events yet. Run a workflow after generating checks.</ui5-label>
              </div>
            } @else {
              <div class="timeline">
                @for (event of workflowEvents(); track $index) {
                  <div class="tl-item">
                    <div class="tl-rail">
                      <div class="tl-dot"
                        [class.tl-success]="getEventStatus(event) === 'success' || getEventStatus(event) === 'completed'"
                        [class.tl-fail]="getEventStatus(event) === 'failed' || getEventStatus(event) === 'error'"
                        [class.tl-running]="getEventStatus(event) === 'running'"
                        [class.tl-pending]="getEventStatus(event) === 'pending'"></div>
                      @if ($index < workflowEvents().length - 1) {
                        <div class="tl-line"></div>
                      }
                    </div>
                    <div class="tl-body">
                      <div class="tl-head">
                        <ui5-label class="tl-type">{{ getEventType(event) }}</ui5-label>
                        <ui5-label class="tl-time">{{ getEventTime(event) }}</ui5-label>
                      </div>
                      <ui5-label wrapping-type="Normal" class="tl-desc">{{ getEventDesc(event) }}</ui5-label>
                    </div>
                  </div>
                }
              </div>
            }
          </ui5-card>
        </div>
      </div>

      </div>
    </ui5-page>
  `,
  styles: [`
    /* ─── Layout ─── */
    .stats-grid {
      display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem;
    }
    @media (min-width: 1440px) {
      :host .stats-grid { grid-template-columns: repeat(4, 1fr) !important; }
    }

    .grid { display: grid; grid-template-columns: 1.2fr 1fr; gap: 1rem; }
    .right-panel { display: flex; flex-direction: column; gap: 1rem; overflow-y: auto; }

    /* ─── Chat (custom bubble styling kept) ─── */
    .chat-panel { min-height: 520px; }
    .chat-log {
      flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 0.75rem;
      padding: 0.75rem 1rem; scroll-behavior: smooth; min-height: 300px;
    }

    .message-row { display: flex; gap: 0.5rem; align-items: flex-end; animation: fadeSlide 0.25s ease-out; }
    .message-row--user { flex-direction: row-reverse; }

    .avatar {
      width: 30px; height: 30px; border-radius: 50%; display: flex; align-items: center; justify-content: center;
      font-size: 0.8rem; flex-shrink: 0;
    }
    .avatar--user { background: var(--sapBrandColor, #0854a0); }
    .avatar--bot { background: var(--sapTile_BorderColor, #e4e4e4); }

    .bubble { max-width: 78%; padding: 0.65rem 0.85rem; }
    .bubble--user {
      background: var(--sapBrandColor, #0854a0); color: #fff;
      border-radius: 14px 14px 4px 14px;
    }
    .bubble--bot {
      background: var(--sapBaseColor, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      color: var(--sapTextColor, #32363a); border-radius: 14px 14px 14px 4px;
    }
    .bubble-header { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; margin-bottom: 0.2rem; }
    .bubble-role { font-size: 0.65rem; font-weight: 700; text-transform: uppercase; opacity: 0.7; }
    .bubble-ts { font-size: 0.6rem; opacity: 0.5; }
    .bubble-content { font-size: 0.84rem; line-height: 1.5; white-space: pre-wrap; word-break: break-word; }

    /* ─── Input ─── */
    .chat-input-row { display: flex; gap: 0.5rem; align-items: flex-end; padding: 0 1rem; }
    .chat-input { flex: 1; }

    .workflow-cta { display: flex; align-items: center; gap: 0.75rem; padding: 0.5rem 1rem; }

    /* ─── Empty States ─── */
    .empty-state {
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      height: 100%; gap: 0.5rem; text-align: center; padding: 2rem;
    }
    .empty-state-sm { padding: 1.5rem; height: auto; }

    .suggestion-chips { display: flex; flex-wrap: wrap; gap: 0.4rem; justify-content: center; max-width: 480px; margin-top: 0.5rem; }

    /* ─── Check Cards ─── */
    .checks-list { overflow-y: auto; display: flex; flex-direction: column; gap: 0.5rem; max-height: 320px; padding: 0.5rem 1rem; }
    .check-desc { margin: 0 0 0.35rem; font-size: 0.78rem; color: var(--sapContent_LabelColor, #6a6d70); line-height: 1.4; }
    .column-pills { display: flex; flex-wrap: wrap; gap: 0.25rem; margin-bottom: 0.35rem; }
    .check-sql {
      margin: 0; padding: 0.45rem 0.6rem; border-radius: 0.3rem;
      background: #1e1e2e; color: #cdd6f4; font-size: 0.72rem; line-height: 1.45;
      white-space: pre-wrap; word-break: break-all; overflow-x: auto;
      font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
    }

    /* ─── Timeline ─── */
    .timeline { display: flex; flex-direction: column; max-height: 240px; overflow-y: auto; padding: 0.5rem 1rem; }
    .tl-item { display: flex; gap: 0.6rem; }
    .tl-rail { display: flex; flex-direction: column; align-items: center; flex-shrink: 0; width: 14px; }
    .tl-dot {
      width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0;
      background: var(--sapContent_LabelColor, #6a6d70); border: 2px solid var(--sapTile_Background, #fff);
    }
    .tl-success { background: var(--sapPositiveColor, #2e7d32); }
    .tl-fail { background: var(--sapNegativeColor, #c62828); }
    .tl-running { background: var(--sapBrandColor, #0854a0); animation: pulse-dot 1.5s ease-in-out infinite; }
    .tl-pending { background: var(--sapNeutralColor, #bdbdbd); }
    .tl-line { width: 2px; flex: 1; background: var(--sapTile_BorderColor, #e4e4e4); min-height: 16px; }
    .tl-body { flex: 1; padding-bottom: 0.65rem; }
    .tl-head { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
    .tl-type { font-weight: 600; }
    .tl-time { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .tl-desc { margin: 0.15rem 0 0; }

    @keyframes pulse-dot {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.4; transform: scale(0.7); }
    }
    @keyframes fadeSlide {
      from { opacity: 0; transform: translateY(6px); }
      to { opacity: 1; transform: translateY(0); }
    }
  `],
})
export class DataCleaningComponent implements OnInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
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

  readonly passRate = computed(() => {
    const c = this.checks();
    if (!c.length) return 0;
    const passed = c.filter(ck => {
      const s = String(ck['status'] ?? ck['severity'] ?? '').toLowerCase();
      return s === 'pass' || s === 'success' || s === 'info';
    }).length;
    return Math.round((passed / c.length) * 100);
  });
  readonly issueCount = computed(() => {
    return this.checks().filter(c => {
      const s = String(c['status'] ?? c['severity'] ?? '').toLowerCase();
      return s === 'fail' || s === 'warn' || s === 'warning' || s === 'critical' || s === 'error';
    }).length;
  });

  prompt = '';
  lastPrompt = '';

  readonly suggestions = [
    'Profile CUSTOMER table for null values',
    'Check ORDER_ITEMS for duplicate keys',
    'Validate date formats in TRANSACTIONS',
  ];

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
        this.toast.info('Data cleaning session cleared');
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

  /* ─── Template helpers ─── */
  onTextAreaInput(event: Event): void {
    const target = event.target as HTMLTextAreaElement;
    this.prompt = target?.value ?? '';
  }

  usePrompt(s: string): void {
    this.prompt = s;
    this.sendMessage();
  }

  formatTime(ts: number): string {
    const d = new Date(ts);
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  getCheckName(c: DataCleaningCheck): string {
    return String(c['name'] ?? c['check_name'] ?? c['title'] ?? 'Unnamed Check');
  }
  getCheckDesc(c: DataCleaningCheck): string {
    return String(c['description'] ?? c['desc'] ?? '');
  }
  getSeverity(c: DataCleaningCheck): string {
    return String(c['severity'] ?? c['level'] ?? 'info').toLowerCase();
  }
  getColumns(c: DataCleaningCheck): string[] {
    const cols = c['columns'] ?? c['affected_columns'] ?? c['fields'] ?? [];
    return Array.isArray(cols) ? cols.map(String) : [];
  }
  getCheckSql(c: DataCleaningCheck): string {
    return String(c['sql'] ?? c['query'] ?? c['logic'] ?? c['expression'] ?? '');
  }
  getEventType(e: Record<string, unknown>): string {
    return String(e['event_type'] ?? e['type'] ?? e['name'] ?? 'Event');
  }
  getEventStatus(e: Record<string, unknown>): string {
    return String(e['status'] ?? 'pending').toLowerCase();
  }
  getEventTime(e: Record<string, unknown>): string {
    const t = e['timestamp'] ?? e['time'] ?? e['created_at'];
    if (!t) return '';
    try { return new Date(String(t)).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
    catch { return String(t); }
  }
  getEventDesc(e: Record<string, unknown>): string {
    return String(e['description'] ?? e['message'] ?? e['detail'] ?? '');
  }
}


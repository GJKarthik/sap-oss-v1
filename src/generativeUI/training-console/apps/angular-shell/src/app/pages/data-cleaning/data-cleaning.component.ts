import { ChangeDetectionStrategy, Component, CUSTOM_ELEMENTS_SCHEMA, OnDestroy, OnInit, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
import { HttpErrorResponse } from '@angular/common/http';
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
    <div class="page-content">
      <div class="page-header">
        <div>
          <h1 class="page-title">Data Cleaning Copilot</h1>
          <p class="text-muted">Prepare and validate training data quality directly in model workflows.</p>
        </div>
        <div class="header-actions">
          <ui5-button design="Transparent" icon="refresh" (click)="refreshAll()" [disabled]="loadingHealth() || loadingChecks()">
            Refresh
          </ui5-button>
          <ui5-button design="Negative" icon="decline" (click)="clearSession()" [disabled]="sending() || workflowRunning()">
            Clear Session
          </ui5-button>
        </div>
      </div>

      <!-- Summary Stats -->
      <div class="stats-row">
        <ui5-card>
          <ui5-card-header slot="header" title-text="Checks Generated"></ui5-card-header>
          <div class="stat-body-inner">
            <span class="stat-value">{{ checks().length }}</span>
          </div>
        </ui5-card>
        <ui5-card>
          <ui5-card-header slot="header" title-text="Pass Rate"></ui5-card-header>
          <div class="stat-body-inner">
            <span class="stat-value">{{ passRate() }}%</span>
          </div>
        </ui5-card>
        <ui5-card>
          <ui5-card-header slot="header" title-text="Issues Found"></ui5-card-header>
          <div class="stat-body-inner">
            <span class="stat-value">{{ issueCount() }}</span>
          </div>
        </ui5-card>
        <ui5-card>
          <ui5-card-header slot="header" title-text="Backend Status"></ui5-card-header>
          <div class="stat-body-inner">
            <ui5-tag [design]="healthStatus() === 'ok' ? 'Positive' : 'Negative'">
              {{ healthStatus() === 'ok' ? 'Online' : healthStatus() }}
            </ui5-tag>
          </div>
        </ui5-card>
      </div>

      <div class="grid">
        <!-- ─── Chat Panel ─── -->
        <section class="panel chat-panel">
          <div class="panel-header">
            <h2 class="panel-title">🤖 Copilot Chat</h2>
            @if (activeWorkflowId()) {
              <ui5-tag
                [design]="workflowStatus() === 'completed' ? 'Positive' : workflowStatus() === 'failed' ? 'Negative' : 'Information'">
                {{ workflowStatus() }}
              </ui5-tag>
            }
          </div>

          <div class="chat-log">
            @if (!messages().length) {
              <div class="empty-state">
                <div class="empty-icon">💬</div>
                <h3 class="empty-title">Start a Conversation</h3>
                <p class="empty-sub">Describe a data quality issue to generate cleaning checks</p>
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
                <div class="typing-indicator">
                  <div class="typing-dots"><span></span><span></span><span></span></div>
                  <span class="typing-text">Copilot is thinking…</span>
                </div>
              </div>
            }
          </div>

          <div class="chat-input-row">
            <div class="input-wrapper">
              <ui5-textarea
                [value]="prompt"
                (input)="onPromptInput($event)"
                rows="2"
                placeholder="e.g. Profile CUSTOMER table and suggest null-value remediations"
                growing
                growing-max-rows="4"
                style="width: 100%;"
                (keydown.meta.enter)="sendMessage()"
              ></ui5-textarea>
              <span class="input-hint">⌘ Enter to send</span>
            </div>
            <ui5-button icon="paper-plane" design="Emphasized"
              [disabled]="sending() || !prompt.trim()"
              (click)="sendMessage()">
            </ui5-button>
          </div>

          <div class="workflow-cta">
            <ui5-button design="Emphasized" icon="play" (click)="runWorkflow()" [disabled]="workflowRunning() || !lastPrompt">
              {{ workflowRunning() ? 'Running…' : 'Run Cleaning Workflow' }}
            </ui5-button>
            <span class="cta-hint">Uses your last prompt to create cleaning actions</span>
          </div>
        </section>

        <!-- ─── Right Panel: Checks & Timeline ─── -->
        <section class="panel right-panel">
          <!-- Generated Checks -->
          <div class="panel-header">
            <h2 class="panel-title">🛡 Generated Checks</h2>
            <ui5-tag design="Set2">{{ checks().length }}</ui5-tag>
          </div>

          @if (loadingChecks()) {
            <ui5-busy-indicator active size="M" style="width: 100%; min-height: 60px;"></ui5-busy-indicator>
          } @else if (!checks().length) {
            <div class="empty-state empty-state-sm">
              <div class="empty-icon-sm">📋</div>
              <p class="empty-hint">No checks generated yet.<br>Send a chat prompt to get started.</p>
            </div>
          } @else {
            <div class="checks-list">
              @for (check of checks(); track $index) {
                <ui5-card>
                  <ui5-card-header slot="header"
                    [titleText]="getCheckName(check)"
                    [subtitleText]="getCheckDesc(check)">
                  </ui5-card-header>
                  <div style="padding: 0.5rem 1rem;">
                    <div style="margin-bottom: 0.35rem;">
                      <ui5-tag
                        [design]="getSeverity(check) === 'critical' ? 'Negative' : getSeverity(check) === 'warning' ? 'Critical' : 'Information'">
                        {{ getSeverity(check) }}
                      </ui5-tag>
                    </div>
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

          <!-- Workflow Timeline -->
          <div class="panel-header timeline-header">
            <h2 class="panel-title">📡 Workflow Events</h2>
            <ui5-tag design="Set2">{{ workflowEvents().length }}</ui5-tag>
          </div>

          @if (!workflowEvents().length) {
            <div class="empty-state empty-state-sm">
              <div class="empty-icon-sm">🔄</div>
              <p class="empty-hint">No workflow events yet.<br>Run a workflow after generating checks.</p>
            </div>
          } @else {
            <ui5-timeline>
              @for (event of workflowEvents(); track $index) {
                <ui5-timeline-item
                  [titleText]="getEventType(event)"
                  [subtitleText]="getEventTime(event)"
                  [icon]="getTimelineIcon(getEventStatus(event))">
                  {{ getEventDesc(event) }}
                </ui5-timeline-item>
              }
            </ui5-timeline>
          }
        </section>
      </div>
    </div>
  `,
  styles: [`
    /* ─── Layout ─── */
    .header-actions { display: flex; gap: 0.5rem; }
    .stats-row {
      display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem; margin-bottom: 1rem;
    }
    .stat-body-inner {
      padding: 1rem; text-align: center;
    }
    .stat-value { font-size: 1.25rem; font-weight: 700; color: var(--sapTextColor, #32363a); line-height: 1.2; }

    .grid { display: grid; grid-template-columns: 1.2fr 1fr; gap: 1rem; }
    .panel {
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem;
      background: var(--sapTile_Background, #fff); padding: 1rem; min-height: 480px;
      display: flex; flex-direction: column; gap: 0.75rem;
    }
    .panel-header { display: flex; align-items: center; justify-content: space-between; }
    .panel-title { margin: 0; font-size: 0.9375rem; font-weight: 600; color: var(--sapTextColor, #32363a); }
    .timeline-header { margin-top: 0.5rem; padding-top: 0.75rem; border-top: 1px solid var(--sapTile_BorderColor, #e4e4e4); }

    /* ─── Chat (custom bubble styling kept) ─── */
    .chat-panel { min-height: 520px; }
    .chat-log { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 0.75rem; padding: 0.5rem 0; scroll-behavior: smooth; }

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

    .typing-indicator {
      display: flex; align-items: center; gap: 0.5rem; padding: 0.65rem 0.85rem;
      background: var(--sapBaseColor, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 14px 14px 14px 4px;
    }
    .typing-dots { display: flex; gap: 0.2rem; }
    .typing-dots span {
      width: 6px; height: 6px; background: var(--sapContent_LabelColor, #6a6d70);
      border-radius: 50%; animation: typingBounce 1.2s ease-in-out infinite;
    }
    .typing-dots span:nth-child(2) { animation-delay: 0.15s; }
    .typing-dots span:nth-child(3) { animation-delay: 0.3s; }
    .typing-text { font-size: 0.72rem; color: var(--sapContent_LabelColor, #6a6d70); font-style: italic; }
    @keyframes typingBounce {
      0%, 60%, 100% { transform: translateY(0); opacity: 0.4; }
      30% { transform: translateY(-4px); opacity: 1; }
    }

    /* ─── Input ─── */
    .chat-input-row { display: flex; gap: 0.5rem; align-items: flex-end; }
    .input-wrapper { flex: 1; position: relative; }
    .input-hint {
      position: absolute; bottom: 0.3rem; right: 0.7rem;
      font-size: 0.6rem; color: var(--sapContent_LabelColor, #6a6d70); pointer-events: none;
    }

    .workflow-cta { display: flex; align-items: center; gap: 0.75rem; margin-top: 0.25rem; }
    .cta-hint { font-size: 0.72rem; color: var(--sapContent_LabelColor, #6a6d70); }

    /* ─── Empty States ─── */
    .empty-state {
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      height: 100%; gap: 0.35rem; text-align: center; animation: fadeSlide 0.3s ease-out;
    }
    .empty-state-sm { padding: 1.5rem 0; height: auto; }
    .empty-icon { font-size: 3rem; margin-bottom: 0.15rem; }
    .empty-icon-sm { font-size: 2rem; }
    .empty-title { font-size: 1.1rem; font-weight: 700; color: var(--sapTextColor, #32363a); margin: 0; }
    .empty-sub { font-size: 0.8rem; color: var(--sapContent_LabelColor, #6a6d70); margin: 0 0 0.6rem; max-width: 300px; }
    .empty-hint { font-size: 0.78rem; color: var(--sapContent_LabelColor, #6a6d70); margin: 0; line-height: 1.45; }

    .suggestion-chips { display: flex; flex-wrap: wrap; gap: 0.4rem; justify-content: center; max-width: 420px; }

    /* ─── Check Cards ─── */
    .checks-list { overflow-y: auto; display: flex; flex-direction: column; gap: 0.5rem; max-height: 320px; }
    .column-pills { display: flex; flex-wrap: wrap; gap: 0.25rem; margin-bottom: 0.35rem; }
    .check-sql {
      margin: 0; padding: 0.45rem 0.6rem; border-radius: 0.3rem;
      background: #1e1e2e; color: #cdd6f4; font-size: 0.72rem; line-height: 1.45;
      white-space: pre-wrap; word-break: break-all; overflow-x: auto;
      font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
    }

    @keyframes fadeSlide {
      from { opacity: 0; transform: translateY(6px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .right-panel { overflow-y: auto; }
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
  onPromptInput(event: Event): void {
    const target = event.target as HTMLTextAreaElement;
    this.prompt = target?.value ?? '';
  }

  usePrompt(s: string): void {
    this.prompt = s;
    this.sendMessage();
  }

  getTimelineIcon(status: string): string {
    if (status === 'success' || status === 'completed') return 'status-positive';
    if (status === 'failed' || status === 'error') return 'status-negative';
    if (status === 'running') return 'synchronize';
    return 'pending';
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


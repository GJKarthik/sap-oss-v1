import { ChangeDetectionStrategy, Component, CUSTOM_ELEMENTS_SCHEMA, OnDestroy, OnInit, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
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
  imports: [CommonModule, FormsModule],
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
          <button class="btn-secondary" (click)="refreshAll()" [disabled]="loadingHealth() || loadingChecks()">
            <span class="btn-icon">↻</span> Refresh
          </button>
          <button class="btn-secondary btn-danger-outline" (click)="clearSession()" [disabled]="sending() || workflowRunning()">
            <span class="btn-icon">✕</span> Clear Session
          </button>
        </div>
      </div>

      <!-- Summary Stats -->
      <div class="stats-row">
        <div class="stat-card">
          <span class="stat-icon">🛡</span>
          <div class="stat-body">
            <span class="stat-value">{{ checks().length }}</span>
            <span class="stat-label">Checks Generated</span>
          </div>
        </div>
        <div class="stat-card">
          <span class="stat-icon">📊</span>
          <div class="stat-body">
            <span class="stat-value">{{ passRate() }}%</span>
            <span class="stat-label">Pass Rate</span>
          </div>
        </div>
        <div class="stat-card">
          <span class="stat-icon">⚠</span>
          <div class="stat-body">
            <span class="stat-value">{{ issueCount() }}</span>
            <span class="stat-label">Issues Found</span>
          </div>
        </div>
        <div class="stat-card">
          <span class="stat-icon stat-icon-status" [class.stat-icon-ok]="healthStatus() === 'ok'" [class.stat-icon-err]="healthStatus() !== 'ok'">●</span>
          <div class="stat-body">
            <span class="stat-value stat-value-sm">{{ healthStatus() === 'ok' ? 'Online' : healthStatus() }}</span>
            <span class="stat-label">Backend Status</span>
          </div>
        </div>
      </div>

      <div class="grid">
        <!-- ─── Chat Panel ─── -->
        <section class="panel chat-panel">
          <div class="panel-header">
            <h2 class="panel-title">🤖 Copilot Chat</h2>
            @if (activeWorkflowId()) {
              <span class="wf-status-pill"
                [class.wf-running]="workflowStatus() === 'pending' || workflowStatus() === 'running'"
                [class.wf-complete]="workflowStatus() === 'completed'"
                [class.wf-failed]="workflowStatus() === 'failed'">
                @if (workflowStatus() === 'pending' || workflowStatus() === 'running') {
                  <span class="pulse-dot"></span>
                }
                @if (workflowStatus() === 'completed') { <span>✓</span> }
                @if (workflowStatus() === 'failed') { <span>✕</span> }
                {{ workflowStatus() }}
              </span>
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
                    <button class="chip" (click)="usePrompt(s)">{{ s }}</button>
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

          <form class="chat-input-row" (ngSubmit)="sendMessage()">
            <div class="input-wrapper">
              <textarea
                class="chat-input"
                name="prompt"
                [(ngModel)]="prompt"
                rows="2"
                placeholder="e.g. Profile CUSTOMER table and suggest null-value remediations"
                (keydown.meta.enter)="sendMessage()"
              ></textarea>
              <span class="input-hint">⌘ Enter to send</span>
            </div>
            <button class="send-btn" type="submit" [disabled]="sending() || !prompt.trim()">
              <span class="send-icon">{{ sending() ? '⏳' : '→' }}</span>
            </button>
          </form>

          <div class="workflow-cta">
            <button class="btn-primary" (click)="runWorkflow()" [disabled]="workflowRunning() || !lastPrompt">
              @if (workflowRunning()) {
                <span class="btn-spinner"></span> Running…
              } @else {
                <span class="btn-icon">▶</span> Run Cleaning Workflow
              }
            </button>
            <span class="cta-hint">Uses your last prompt to create cleaning actions</span>
          </div>
        </section>

        <!-- ─── Right Panel: Checks & Timeline ─── -->
        <section class="panel right-panel">
          <!-- Generated Checks -->
          <div class="panel-header">
            <h2 class="panel-title">🛡 Generated Checks</h2>
            <span class="badge-count">{{ checks().length }}</span>
          </div>

          @if (loadingChecks()) {
            <div class="loading-bar"><div class="loading-bar-inner"></div></div>
          } @else if (!checks().length) {
            <div class="empty-state empty-state-sm">
              <div class="empty-icon-sm">📋</div>
              <p class="empty-hint">No checks generated yet.<br>Send a chat prompt to get started.</p>
            </div>
          } @else {
            <div class="checks-list">
              @for (check of checks(); track $index) {
                <div class="check-card" [class.severity-critical]="getSeverity(check) === 'critical'" [class.severity-warning]="getSeverity(check) === 'warning'" [class.severity-info]="getSeverity(check) === 'info'">
                  <div class="check-card-header">
                    <h3 class="check-name">{{ getCheckName(check) }}</h3>
                    <span class="severity-badge" [class.sev-critical]="getSeverity(check) === 'critical'" [class.sev-warning]="getSeverity(check) === 'warning'" [class.sev-info]="getSeverity(check) === 'info'">
                      {{ getSeverity(check) }}
                    </span>
                  </div>
                  @if (getCheckDesc(check)) {
                    <p class="check-desc">{{ getCheckDesc(check) }}</p>
                  }
                  @if (getColumns(check).length) {
                    <div class="column-pills">
                      @for (col of getColumns(check); track col) {
                        <span class="col-pill">{{ col }}</span>
                      }
                    </div>
                  }
                  @if (getCheckSql(check)) {
                    <pre class="check-sql">{{ getCheckSql(check) }}</pre>
                  }
                </div>
              }
            </div>
          }

          <!-- Workflow Timeline -->
          <div class="panel-header timeline-header">
            <h2 class="panel-title">📡 Workflow Events</h2>
            <span class="badge-count">{{ workflowEvents().length }}</span>
          </div>

          @if (!workflowEvents().length) {
            <div class="empty-state empty-state-sm">
              <div class="empty-icon-sm">🔄</div>
              <p class="empty-hint">No workflow events yet.<br>Run a workflow after generating checks.</p>
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
                      <span class="tl-type">{{ getEventType(event) }}</span>
                      <span class="tl-time">{{ getEventTime(event) }}</span>
                    </div>
                    <p class="tl-desc">{{ getEventDesc(event) }}</p>
                  </div>
                </div>
              }
            </div>
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
    .stat-card {
      display: flex; align-items: center; gap: 0.75rem; padding: 0.875rem 1rem;
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; transition: box-shadow 0.2s ease;
    }
    .stat-card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
    .stat-icon { font-size: 1.5rem; }
    .stat-icon-status { font-size: 1.25rem; }
    .stat-icon-ok { color: #2e7d32; }
    .stat-icon-err { color: #c62828; }
    .stat-body { display: flex; flex-direction: column; }
    .stat-value { font-size: 1.25rem; font-weight: 700; color: var(--sapTextColor, #32363a); line-height: 1.2; }
    .stat-value-sm { font-size: 1rem; }
    .stat-label { font-size: 0.6875rem; color: var(--sapContent_LabelColor, #6a6d70); text-transform: uppercase; letter-spacing: 0.04em; font-weight: 500; }

    .grid { display: grid; grid-template-columns: 1.2fr 1fr; gap: 1rem; }
    .panel {
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem;
      background: var(--sapTile_Background, #fff); padding: 1rem; min-height: 480px;
      display: flex; flex-direction: column; gap: 0.75rem;
    }
    .panel-header { display: flex; align-items: center; justify-content: space-between; }
    .panel-title { margin: 0; font-size: 0.9375rem; font-weight: 600; color: var(--sapTextColor, #32363a); }
    .badge-count {
      font-size: 0.6875rem; font-weight: 700; min-width: 22px; text-align: center;
      padding: 0.1rem 0.45rem; border-radius: 999px;
      background: var(--sapBackgroundColor, #f5f5f5); color: var(--sapContent_LabelColor, #6a6d70);
    }
    .timeline-header { margin-top: 0.5rem; padding-top: 0.75rem; border-top: 1px solid var(--sapTile_BorderColor, #e4e4e4); }

    /* ─── Buttons ─── */
    .btn-secondary {
      display: inline-flex; align-items: center; gap: 0.3rem;
      background: var(--sapBaseColor, #fff); color: var(--sapTextColor, #32363a);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.25rem;
      padding: 0.4rem 0.75rem; cursor: pointer; font-size: 0.8125rem; font-weight: 500;
      transition: all 0.15s ease;
    }
    .btn-secondary:hover:not(:disabled) { background: var(--sapBackgroundColor, #f5f5f5); }
    .btn-secondary:disabled { opacity: 0.4; cursor: not-allowed; }
    .btn-danger-outline { color: #c62828; border-color: #e0bfbf; }
    .btn-danger-outline:hover:not(:disabled) { background: #fff5f5; }
    .btn-primary {
      display: inline-flex; align-items: center; justify-content: center; gap: 0.4rem;
      background: var(--sapBrandColor, #0854a0); color: #fff; border: none; border-radius: 0.25rem;
      padding: 0.5rem 1rem; cursor: pointer; font-size: 0.8125rem; font-weight: 600;
      transition: background 0.15s ease; min-width: 180px;
    }
    .btn-primary:hover:not(:disabled) { background: #063d75; }
    .btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-icon { font-size: 0.75rem; }
    .btn-spinner {
      display: inline-block; width: 14px; height: 14px;
      border: 2px solid rgba(255,255,255,0.3); border-top-color: #fff;
      border-radius: 50%; animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* ─── Workflow Status Pill ─── */
    .wf-status-pill {
      display: inline-flex; align-items: center; gap: 0.3rem; font-size: 0.7rem; font-weight: 600;
      padding: 0.15rem 0.55rem; border-radius: 999px; text-transform: capitalize;
      background: var(--sapBackgroundColor, #f5f5f5); color: var(--sapContent_LabelColor, #6a6d70);
    }
    .wf-running { background: rgba(8,84,160,0.1); color: var(--sapBrandColor, #0854a0); }
    .wf-complete { background: #e8f5e9; color: #2e7d32; }
    .wf-failed { background: #ffebee; color: #c62828; }
    .pulse-dot {
      width: 6px; height: 6px; border-radius: 50%;
      background: var(--sapBrandColor, #0854a0); animation: pulse-dot 1.5s ease-in-out infinite;
    }
    @keyframes pulse-dot {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.4; transform: scale(0.7); }
    }

    /* ─── Chat ─── */
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
    .chat-input {
      width: 100%; box-sizing: border-box; padding: 0.55rem 0.7rem; padding-bottom: 1.25rem;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.65rem;
      font-size: 0.84rem; background: var(--sapBackgroundColor, #f5f5f5);
      color: var(--sapTextColor, #32363a); resize: none; font-family: inherit;
      transition: border-color 0.15s ease;
    }
    .chat-input:focus { outline: none; border-color: var(--sapBrandColor, #0854a0); }
    .input-hint {
      position: absolute; bottom: 0.3rem; right: 0.7rem;
      font-size: 0.6rem; color: var(--sapContent_LabelColor, #6a6d70); pointer-events: none;
    }
    .send-btn {
      width: 36px; height: 36px; background: var(--sapBrandColor, #0854a0); color: #fff;
      border: none; border-radius: 50%; cursor: pointer; font-size: 1rem;
      display: flex; align-items: center; justify-content: center; flex-shrink: 0;
      transition: background 0.15s ease, transform 0.1s ease;
    }
    .send-btn:disabled { opacity: 0.4; cursor: default; }
    .send-btn:hover:not(:disabled) { background: var(--sapShellColor, #354a5e); transform: scale(1.05); }
    .send-icon { line-height: 1; }

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
    .chip {
      display: inline-flex; align-items: center; padding: 0.4rem 0.85rem;
      background: var(--sapBaseColor, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 2rem; cursor: pointer; font-size: 0.75rem; color: var(--sapTextColor, #32363a);
      transition: transform 0.15s ease, box-shadow 0.15s ease;
    }
    .chip:hover { transform: translateY(-2px); box-shadow: 0 3px 10px rgba(0,0,0,0.08); }

    /* ─── Check Cards ─── */
    .checks-list { overflow-y: auto; display: flex; flex-direction: column; gap: 0.5rem; max-height: 320px; }
    .check-card {
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.45rem;
      padding: 0.7rem 0.85rem; background: var(--sapBaseColor, #fff);
      border-left: 3px solid var(--sapTile_BorderColor, #e4e4e4);
      transition: box-shadow 0.15s ease;
    }
    .check-card:hover { box-shadow: 0 2px 6px rgba(0,0,0,0.05); }
    .severity-critical { border-left-color: #c62828; }
    .severity-warning { border-left-color: #f57f17; }
    .severity-info { border-left-color: var(--sapBrandColor, #0854a0); }
    .check-card-header { display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; margin-bottom: 0.25rem; }
    .check-name { margin: 0; font-size: 0.8125rem; font-weight: 600; color: var(--sapTextColor, #32363a); }
    .severity-badge {
      font-size: 0.6rem; font-weight: 700; padding: 0.1rem 0.45rem; border-radius: 0.2rem;
      text-transform: uppercase; letter-spacing: 0.03em; flex-shrink: 0;
    }
    .sev-critical { background: #ffebee; color: #c62828; }
    .sev-warning { background: #fff8e1; color: #f57f17; }
    .sev-info { background: rgba(8,84,160,0.08); color: var(--sapBrandColor, #0854a0); }
    .check-desc { margin: 0 0 0.35rem; font-size: 0.78rem; color: var(--sapContent_LabelColor, #6a6d70); line-height: 1.4; }
    .column-pills { display: flex; flex-wrap: wrap; gap: 0.25rem; margin-bottom: 0.35rem; }
    .col-pill {
      font-size: 0.65rem; font-weight: 500; padding: 0.1rem 0.4rem; border-radius: 0.2rem;
      background: var(--sapBackgroundColor, #f5f5f5); color: var(--sapTextColor, #32363a);
      font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
    }
    .check-sql {
      margin: 0; padding: 0.45rem 0.6rem; border-radius: 0.3rem;
      background: #1e1e2e; color: #cdd6f4; font-size: 0.72rem; line-height: 1.45;
      white-space: pre-wrap; word-break: break-all; overflow-x: auto;
      font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
    }

    /* ─── Timeline ─── */
    .timeline { display: flex; flex-direction: column; max-height: 240px; overflow-y: auto; }
    .tl-item { display: flex; gap: 0.6rem; }
    .tl-rail { display: flex; flex-direction: column; align-items: center; flex-shrink: 0; width: 14px; }
    .tl-dot {
      width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0;
      background: var(--sapContent_LabelColor, #6a6d70); border: 2px solid var(--sapTile_Background, #fff);
    }
    .tl-success { background: #2e7d32; }
    .tl-fail { background: #c62828; }
    .tl-running { background: var(--sapBrandColor, #0854a0); animation: pulse-dot 1.5s ease-in-out infinite; }
    .tl-pending { background: #bdbdbd; }
    .tl-line { width: 2px; flex: 1; background: var(--sapTile_BorderColor, #e4e4e4); min-height: 16px; }
    .tl-body { flex: 1; padding-bottom: 0.65rem; }
    .tl-head { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
    .tl-type { font-size: 0.78rem; font-weight: 600; color: var(--sapTextColor, #32363a); }
    .tl-time { font-size: 0.65rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .tl-desc { margin: 0.15rem 0 0; font-size: 0.72rem; color: var(--sapContent_LabelColor, #6a6d70); line-height: 1.35; }

    /* ─── Loading ─── */
    .loading-bar { width: 100%; height: 3px; background: var(--sapBackgroundColor, #f5f5f5); border-radius: 2px; overflow: hidden; }
    .loading-bar-inner {
      width: 40%; height: 100%; background: var(--sapBrandColor, #0854a0); border-radius: 2px;
      animation: loading-slide 1.2s ease-in-out infinite;
    }
    @keyframes loading-slide {
      0% { transform: translateX(-100%); }
      100% { transform: translateX(350%); }
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


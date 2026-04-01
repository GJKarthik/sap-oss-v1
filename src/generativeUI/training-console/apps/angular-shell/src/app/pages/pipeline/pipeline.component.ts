import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit, OnDestroy, ViewChild, ElementRef, AfterViewChecked, NgZone
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
import { environment } from '../../../environments/environment';

type PipelineState = 'idle' | 'running' | 'completed' | 'error';
type StageStatus = 'idle' | 'running' | 'done' | 'error';

interface PipelineStage {
  num: number;
  name: string;
  tool: string;
  input: string;
  output: string;
  status: StageStatus;
  duration?: string;
  startTime?: number;
}

interface LogLine {
  text: string;
  kind: 'info' | 'success' | 'error' | 'warn' | 'dim';
}

@Component({
  selector: 'app-pipeline',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">Pipeline</h1>
        <span class="text-muted text-small">7-stage Text-to-SQL data generation — Live WebSocket Stream</span>
      </div>

      <!-- Control card -->
      <div class="control-card">
        <div class="control-info">
          <p>Converts banking Excel schemas into Spider/BIRD-format training pairs via a native Zig binary.</p>
          <!-- Visual Flow Diagram / Stepper -->
          <div class="pipeline-stepper">
            @for (s of stages(); track s.num) {
              <div class="stepper-step" [class.step-done]="s.status === 'done'" [class.step-active]="s.status === 'running'" [class.step-error]="s.status === 'error'">
                <div class="step-node">
                  @if (s.status === 'done') { <span class="step-icon">✓</span> }
                  @else if (s.status === 'error') { <span class="step-icon">✕</span> }
                  @else if (s.status === 'running') { <span class="step-icon step-icon-pulse">{{ s.num }}</span> }
                  @else { <span class="step-icon">{{ s.num }}</span> }
                </div>
                <span class="step-label">{{ s.name }}</span>
              </div>
              @if (s.num < stages().length) {
                <div class="stepper-connector" [class.connector-done]="s.status === 'done'" [class.connector-active]="s.status === 'running'"></div>
              }
            }
          </div>
        </div>
        <div class="control-actions">
          <div class="ws-badge" [class.ws-connected]="wsConnected()" [class.ws-disconnected]="!wsConnected()">
            {{ wsConnected() ? '🟢 Live' : '🔴 Offline' }}
          </div>
          <div class="btn-group">
            <button class="btn-primary" (click)="startPipeline()"
              [disabled]="pipelineState() === 'running' || starting()">
              @if (starting()) {
                <span class="btn-spinner"></span> Starting…
              } @else if (pipelineState() === 'running') {
                <span class="btn-spinner"></span> Processing…
              } @else {
                <span class="btn-icon">▶</span> Execute Pipeline
              }
            </button>
            <button class="btn-secondary" (click)="stopPipeline()" [disabled]="pipelineState() !== 'running'" title="Stop pipeline">
              <span class="btn-icon">⏹</span> Stop
            </button>
          </div>
        </div>
      </div>

      <!-- Live Terminal — macOS style -->
      <div class="pipeline-terminal" *ngIf="logLines().length > 0 || pipelineState() !== 'idle'">
        <div class="terminal-titlebar">
          <div class="terminal-dots">
            <span class="dot dot-red"></span>
            <span class="dot dot-yellow"></span>
            <span class="dot dot-green"></span>
          </div>
          <span class="terminal-titlebar-text">training-pipeline — zsh</span>
          <div class="terminal-titlebar-actions">
            <span class="terminal-status" [class]="stateClass()">{{ pipelineState().toUpperCase() }}</span>
          </div>
        </div>
        <div class="terminal-body" #terminalBody>
          @for (line of logLines(); track $index) {
            <div class="log-line log-line--{{ line.kind }}">
              <span class="log-prefix">›</span>
              <span>{{ line.text }}</span>
            </div>
          }
          @if (pipelineState() === 'running') {
            <div class="cursor-blink">█</div>
          }
        </div>
        <div class="terminal-footer">
          <span class="text-small text-muted">{{ logLines().length }} lines</span>
          <div class="terminal-footer-actions">
            <button class="btn-term" (click)="copyLogs()" title="Copy output">📋 Copy</button>
            <button class="btn-term btn-term-danger" (click)="clearLogs()" title="Clear output">🗑 Clear</button>
          </div>
        </div>
      </div>

      <!-- Idle state prompt -->
      @if (pipelineState() === 'idle' && logLines().length === 0) {
        <div class="idle-prompt">
          <div style="font-size: 2.5rem; margin-bottom: 0.75rem;">🔌</div>
          <p>Connected to the live stream. Execute the pipeline to see Zig subprocess logs here in real-time.</p>
        </div>
      }

      <!-- Stage Progress -->
      <div class="stages-section">
        <h2 class="section-title">Pipeline Stages</h2>
        <div class="stages-table-wrapper">
          <table class="stages-table">
            <thead>
              <tr>
                <th style="width:2.5rem">#</th><th>Stage</th><th>Tool</th><th>Input</th><th>Output</th><th style="width:5.5rem">Duration</th><th style="width:5.5rem">Status</th>
              </tr>
            </thead>
            <tbody>
              @for (s of stages(); track s.num) {
                <tr [class.stage-running]="s.status === 'running'" [class.stage-done]="s.status === 'done'" [class.stage-error]="s.status === 'error'">
                  <td class="stage-num">{{ s.num }}</td>
                  <td class="stage-name">{{ s.name }}</td>
                  <td><code>{{ s.tool }}</code></td>
                  <td class="text-muted text-small">{{ s.input }}</td>
                  <td class="text-muted text-small">{{ s.output }}</td>
                  <td class="stage-duration">{{ s.duration ?? '—' }}</td>
                  <td>
                    <span class="status-badge" [class]="statusClass(s.status)">
                      @if (s.status === 'done') { ✓ Done }
                      @else if (s.status === 'error') { ✕ Error }
                      @else if (s.status === 'running') { ◉ Running }
                      @else { ○ Idle }
                    </span>
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      </div>

      <!-- Quick commands -->
      <div class="pipeline-commands">
        <h2 class="section-title">Run Commands</h2>
        <div class="cmd-grid">
          @for (cmd of commands; track cmd.title) {
            <div class="cmd-card">
              <h3 class="cmd-title">{{ cmd.title }}</h3>
              <pre>{{ cmd.command }}</pre>
            </div>
          }
        </div>
      </div>
    </div>
  `,
  styles: [`
    /* ── Control card ── */
    .control-card {
      display: flex; justify-content: space-between; align-items: flex-start; gap: 1.5rem;
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 1.25rem; margin-bottom: 1.5rem;
      font-size: 0.875rem; color: var(--sapTextColor, #32363a);
    }
    .control-info { flex: 1; p { margin: 0 0 1rem; } }
    .control-actions { display: flex; flex-direction: column; align-items: flex-end; gap: 0.75rem; }

    .ws-badge {
      padding: 0.2rem 0.6rem; border-radius: 1rem; font-size: 0.75rem; font-weight: 600;
      &.ws-connected { background: #e8f5e9; color: #2e7d32; }
      &.ws-disconnected { background: #ffebee; color: #c62828; }
    }

    .btn-group { display: flex; gap: 0.5rem; }

    /* ── Visual Stepper ── */
    .pipeline-stepper {
      display: flex; align-items: center; gap: 0;
      padding: 0.75rem 0.5rem; overflow-x: auto;
    }
    .stepper-step {
      display: flex; flex-direction: column; align-items: center; gap: 0.35rem; min-width: 52px;
    }
    .step-node {
      width: 32px; height: 32px; border-radius: 50%; display: flex; align-items: center; justify-content: center;
      background: var(--sapBackgroundColor, #f5f5f5); border: 2px solid var(--sapTile_BorderColor, #e4e4e4);
      font-size: 0.75rem; font-weight: 700; color: var(--sapContent_LabelColor, #6a6d70);
      transition: all 0.4s ease;
    }
    .step-label {
      font-size: 0.625rem; color: var(--sapContent_LabelColor, #6a6d70); text-align: center;
      font-weight: 500; max-width: 60px; line-height: 1.2; transition: color 0.3s ease;
    }
    .step-done .step-node {
      background: #2e7d32; border-color: #2e7d32; color: #fff;
    }
    .step-done .step-label { color: #2e7d32; }
    .step-active .step-node {
      background: var(--sapBrandColor, #0854a0); border-color: var(--sapBrandColor, #0854a0); color: #fff;
      animation: pulse-node 1.5s ease-in-out infinite;
      box-shadow: 0 0 0 0 rgba(8, 84, 160, 0.4);
    }
    .step-active .step-label { color: var(--sapBrandColor, #0854a0); font-weight: 600; }
    .step-error .step-node { background: #c62828; border-color: #c62828; color: #fff; }
    .step-error .step-label { color: #c62828; }
    .step-icon { font-size: 0.75rem; line-height: 1; }
    .step-icon-pulse { animation: pulse-text 1.5s ease-in-out infinite; }
    .stepper-connector {
      flex: 1; height: 2px; min-width: 16px; background: var(--sapTile_BorderColor, #e4e4e4);
      margin: 0 2px; margin-bottom: 1.25rem; transition: background 0.4s ease;
    }
    .connector-done { background: #2e7d32; }
    .connector-active { background: var(--sapBrandColor, #0854a0); animation: pulse-connector 1.5s ease-in-out infinite; }

    @keyframes pulse-node {
      0%, 100% { box-shadow: 0 0 0 0 rgba(8,84,160,0.4); }
      50% { box-shadow: 0 0 0 6px rgba(8,84,160,0); }
    }
    @keyframes pulse-text {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.5; }
    }
    @keyframes pulse-connector {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.4; }
    }

    /* ── Terminal — macOS style ── */
    .pipeline-terminal {
      background: #1e1e1e; border-radius: 0.5rem; margin-bottom: 1.5rem;
      overflow: hidden; font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 0.8rem; box-shadow: 0 8px 32px rgba(0,0,0,0.35);
      border: 1px solid #3a3a3a;
    }
    .terminal-titlebar {
      background: linear-gradient(180deg, #3c3c3c 0%, #323232 100%);
      padding: 0.5rem 0.75rem; display: flex; align-items: center;
      border-bottom: 1px solid #2a2a2a; position: relative; min-height: 36px;
    }
    .terminal-dots { display: flex; gap: 6px; align-items: center; }
    .dot {
      width: 12px; height: 12px; border-radius: 50%;
      &.dot-red { background: #ff5f57; border: 1px solid #e0443e; }
      &.dot-yellow { background: #febc2e; border: 1px solid #dea123; }
      &.dot-green { background: #28c840; border: 1px solid #1aab29; }
    }
    .terminal-titlebar-text {
      position: absolute; left: 50%; transform: translateX(-50%);
      color: #9a9a9a; font-size: 0.75rem; font-weight: 500;
    }
    .terminal-titlebar-actions { margin-left: auto; }
    .terminal-status {
      font-size: 0.65rem; font-weight: 700; padding: 0.1rem 0.5rem; border-radius: 0.2rem;
      text-transform: uppercase; letter-spacing: 0.03em;
      &.state-running { background: #1f3a2e; color: #3fb950; }
      &.state-completed { background: #0d2818; color: #56d364; }
      &.state-error { background: #3b1219; color: #f85149; }
      &.state-idle { background: #2a2a2a; color: #8b949e; }
    }
    .terminal-body {
      padding: 0.875rem 1rem; min-height: 120px; max-height: 450px;
      overflow-y: auto; display: flex; flex-direction: column; gap: 0.15rem;
      scroll-behavior: smooth; background: #1e1e1e;
    }
    .log-line {
      display: flex; gap: 0.5rem; line-height: 1.6;
      text-shadow: 0 0 1px rgba(255,255,255,0.05);
      .log-prefix { color: #555; user-select: none; flex-shrink: 0; }
      &.log-line--info { color: #d4d4d4; }
      &.log-line--success { color: #3fb950; }
      &.log-line--error { color: #f85149; }
      &.log-line--warn { color: #d29922; }
      &.log-line--dim { color: #6a6a6a; }
    }
    .cursor-blink { color: #3fb950; animation: blink 1s step-end infinite; }
    @keyframes blink { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }

    .terminal-footer {
      padding: 0.35rem 0.75rem; background: #282828; border-top: 1px solid #3a3a3a;
      display: flex; justify-content: space-between; align-items: center;
    }
    .terminal-footer-actions { display: flex; gap: 0.4rem; }
    .btn-term {
      background: transparent; border: 1px solid #4a4a4a; color: #9a9a9a;
      padding: 0.15rem 0.5rem; border-radius: 0.2rem; cursor: pointer;
      font-size: 0.7rem; font-family: inherit; transition: all 0.15s ease;
      &:hover { background: #3a3a3a; color: #e0e0e0; }
    }
    .btn-term-danger:hover { background: #3b1219; color: #f85149; border-color: #f85149; }

    /* ── Idle ── */
    .idle-prompt {
      text-align: center; padding: 2.5rem; color: var(--sapContent_LabelColor, #6a6d70);
      background: var(--sapTile_Background, #fff); border: 1px dashed var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; margin-bottom: 1.5rem; font-size: 0.875rem;
      p { margin: 0; }
    }

    /* ── Buttons ── */
    .btn-primary {
      background: var(--sapButton_Emphasized_Background, #0854a0); color: #fff;
      border: none; border-radius: 0.25rem; cursor: pointer;
      font-weight: 600; font-size: 0.875rem; padding: 0.6rem 1.2rem; min-width: 170px;
      transition: all 0.2s ease; display: inline-flex; align-items: center; justify-content: center; gap: 0.4rem;
      &:hover:not(:disabled) { background: var(--sapButton_Emphasized_Hover_Background, #063d75); }
      &:disabled { opacity: 0.5; cursor: not-allowed; filter: grayscale(30%); }
    }
    .btn-secondary {
      background: var(--sapBaseColor, #fff); color: var(--sapTextColor, #32363a);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.25rem; cursor: pointer;
      font-weight: 600; font-size: 0.875rem; padding: 0.6rem 1rem;
      transition: all 0.2s ease; display: inline-flex; align-items: center; gap: 0.3rem;
      &:hover:not(:disabled) { background: var(--sapBackgroundColor, #f5f5f5); }
      &:disabled { opacity: 0.35; cursor: not-allowed; }
    }
    .btn-icon { font-size: 0.75rem; }
    .btn-spinner {
      display: inline-block; width: 14px; height: 14px; border: 2px solid rgba(255,255,255,0.3);
      border-top-color: #fff; border-radius: 50%; animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* ── Stage Table ── */
    .stages-section { margin-bottom: 1.5rem; }
    .stages-table-wrapper { overflow-x: auto; }
    .stages-table {
      width: 100%; border-collapse: collapse; font-size: 0.8125rem;
      background: var(--sapTile_Background, #fff); border-radius: 0.5rem;
      overflow: hidden; border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      th {
        padding: 0.625rem 0.75rem; background: var(--sapList_HeaderBackground, #f5f5f5);
        text-align: left; font-weight: 600; color: var(--sapContent_LabelColor, #6a6d70);
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
        text-transform: uppercase; font-size: 0.7rem; letter-spacing: 0.04em;
      }
      td {
        padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
        vertical-align: middle; transition: all 0.3s ease;
      }
      tr:last-child td { border-bottom: none; }
      tr:hover td { background: var(--sapList_Hover_Background, #f5f5f5); }
    }
    .stage-running td {
      background: rgba(8, 84, 160, 0.04);
      border-left: 3px solid var(--sapBrandColor, #0854a0);
      animation: row-pulse 2s ease-in-out infinite;
    }
    .stage-done td { border-left: 3px solid #2e7d32; }
    .stage-error td { border-left: 3px solid #c62828; }
    @keyframes row-pulse {
      0%, 100% { background: rgba(8,84,160,0.04); }
      50% { background: rgba(8,84,160,0.08); }
    }
    .stage-num { color: var(--sapBrandColor, #0854a0); font-weight: 700; width: 2rem; text-align: center; }
    .stage-name { font-weight: 500; }
    .stage-duration { font-family: 'SF Mono', 'SFMono-Regular', Menlo, monospace; font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .section-title { font-size: 1rem; font-weight: 600; color: var(--sapTextColor, #32363a); margin: 0 0 0.75rem; }

    .status-badge {
      font-size: 0.7rem; font-weight: 600; padding: 0.15rem 0.5rem; border-radius: 0.2rem;
      display: inline-flex; align-items: center; gap: 0.2rem; transition: all 0.3s ease;
    }
    .status-pending { background: var(--sapBackgroundColor, #f5f5f5); color: var(--sapContent_LabelColor, #6a6d70); }
    .status-running { background: rgba(8,84,160,0.1); color: var(--sapBrandColor, #0854a0); animation: badge-pulse 1.5s ease-in-out infinite; }
    .status-success { background: #e8f5e9; color: #2e7d32; }
    .status-error { background: #ffebee; color: #c62828; }
    @keyframes badge-pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.6; }
    }

    /* ── Commands ── */
    .pipeline-commands { margin-bottom: 1.5rem; }
    .cmd-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; }
    .cmd-card {
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 1rem; transition: box-shadow 0.2s ease;
      &:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
    }
    .cmd-title { font-size: 0.8125rem; font-weight: 600; margin: 0 0 0.5rem; color: var(--sapTextColor, #32363a); }
    pre { margin: 0; font-size: 0.8rem; background: var(--sapList_Background, #f5f5f5); padding: 0.5rem; border-radius: 0.25rem; overflow-x: auto; }
  `],
})
export class PipelineComponent implements OnInit, OnDestroy, AfterViewChecked {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);
  private readonly zone = inject(NgZone);

  @ViewChild('terminalBody') private terminalBody?: ElementRef;

  readonly pipelineState = signal<PipelineState>('idle');
  readonly logLines = signal<LogLine[]>([]);
  readonly starting = signal(false);
  readonly wsConnected = signal(false);

  private ws: WebSocket | null = null;
  private reconnectTimer: any = null;
  private shouldAutoScroll = true;

  readonly stages = signal<PipelineStage[]>([
    { num: 1, name: 'Preconvert', tool: 'Python (openpyxl)', input: 'data/*.xlsx', output: 'staging/*.csv', status: 'idle' },
    { num: 2, name: 'Build', tool: 'zig build', input: 'Source code', output: 'Pipeline binary', status: 'idle' },
    { num: 3, name: 'Extract Schema', tool: 'Zig', input: 'staging/*.csv', output: 'Schema registry', status: 'idle' },
    { num: 4, name: 'Parse Templates', tool: 'Zig', input: 'data/prompt_templates.csv', output: 'Parameterised templates', status: 'idle' },
    { num: 5, name: 'Expand', tool: 'Zig', input: 'Templates + Schema', output: 'Text-SQL pairs', status: 'idle' },
    { num: 6, name: 'Validate', tool: 'Mangle', input: 'Pairs + Rules', output: 'Validated pairs', status: 'idle' },
    { num: 7, name: 'Format', tool: 'Zig', input: 'Validated pairs', output: 'Spider/BIRD JSONL', status: 'idle' },
  ]);

  readonly commands = [
    { title: 'Full pipeline (all 7 stages)', command: 'cd pipeline && make all' },
    { title: 'Step 1 — Preconvert Excel → CSV', command: 'cd pipeline && make preconvert' },
    { title: 'Step 2 — Build Zig binary', command: 'cd pipeline/zig && zig build' },
    { title: 'Run Zig pipeline tests', command: 'cd pipeline/zig && zig build test' },
  ];

  ngOnInit() {
    this.connectWebSocket();
  }

  ngOnDestroy() {
    this.ws?.close();
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
  }

  ngAfterViewChecked() {
    if (this.shouldAutoScroll) this.scrollToBottom();
  }

  private connectWebSocket() {
    const wsBase = environment.apiBaseUrl.replace(/^http/, 'ws');
    const wsUrl = `${wsBase}/ws/pipeline`;

    this.ws = new WebSocket(wsUrl);

    this.ws.onopen = () => {
      this.zone.run(() => {
        this.wsConnected.set(true);
      });
      // Heartbeat ping every 25s to keep the connection alive through proxies
      const ping = setInterval(() => {
        if (this.ws?.readyState === WebSocket.OPEN) {
          this.ws.send('ping');
        } else {
          clearInterval(ping);
        }
      }, 25000);
    };

    this.ws.onmessage = (event: MessageEvent) => {
      this.zone.run(() => {
        try {
          const msg = JSON.parse(event.data as string);
          this.handleMessage(msg);
        } catch { /* ignore malformed frames */ }
      });
    };

    this.ws.onclose = () => {
      this.zone.run(() => {
        this.wsConnected.set(false);
      });
      // Auto-reconnect after 3s
      this.reconnectTimer = setTimeout(() => this.connectWebSocket(), 3000);
    };

    this.ws.onerror = () => {
      this.ws?.close();
    };
  }

  private handleMessage(msg: {type: string; state?: string; logs?: string[]; text?: string}) {
    if (msg.type === 'init') {
      const state = (msg.state ?? 'idle') as PipelineState;
      this.pipelineState.set(state);
      this.logLines.set((msg.logs ?? []).map(t => this.parseLine(t)));
      this.updateStagesFromState(state);
    } else if (msg.type === 'log') {
      this.appendLine(msg.text ?? '');
    } else if (msg.type === 'done') {
      const state = (msg.state ?? 'completed') as PipelineState;
      this.pipelineState.set(state);
      this.appendLine(msg.text ?? '');
      this.updateStagesFromState(state);
      if (state === 'completed') {
        this.toast.success('Pipeline finished — JSONL pairs ready for training!', 'Pipeline Complete');
      } else {
        this.toast.error('Pipeline encountered an error. Check the terminal.', 'Pipeline Error');
      }
    }
  }

  private parseLine(text: string): LogLine {
    if (!text) return { text: '', kind: 'dim' };
    if (text.startsWith('✅') || text.includes('finished') || text.includes('success')) return { text, kind: 'success' };
    if (text.startsWith('❌') || text.startsWith('💥') || text.toLowerCase().includes('error') || text.toLowerCase().includes('fail')) return { text, kind: 'error' };
    if (text.startsWith('⚠') || text.toLowerCase().includes('warn')) return { text, kind: 'warn' };
    if (text.startsWith('#') || text.startsWith('--') || text.startsWith('//')) return { text, kind: 'dim' };
    return { text, kind: 'info' };
  }

  private appendLine(text: string) {
    this.logLines.update(lines => [...lines, this.parseLine(text)]);
  }

  private updateStagesFromState(state: PipelineState) {
    const now = Date.now();
    if (state === 'running') {
      this.stages.update(stages => stages.map((s, i) => ({
        ...s,
        status: (i === 0 ? 'running' : 'idle') as StageStatus,
        startTime: i === 0 ? now : undefined,
        duration: undefined,
      })));
    } else if (state === 'completed') {
      this.stages.update(stages => stages.map(s => ({
        ...s,
        status: 'done' as StageStatus,
        duration: s.startTime ? this.formatDuration(now - s.startTime) : s.duration ?? '< 1s',
      })));
    } else if (state === 'error') {
      this.stages.update(stages => stages.map(s => ({
        ...s,
        status: (s.status === 'running' ? 'error' : s.status) as StageStatus,
        duration: s.status === 'running' && s.startTime ? this.formatDuration(now - s.startTime) : s.duration,
      })));
    }
  }

  private formatDuration(ms: number): string {
    if (ms < 1000) return '< 1s';
    const s = Math.floor(ms / 1000);
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    return `${m}m ${s % 60}s`;
  }

  startPipeline() {
    this.starting.set(true);
    this.logLines.set([]);
    this.http.post(`${environment.apiBaseUrl}/pipeline/start`, {}).subscribe({
      next: () => {
        this.pipelineState.set('running');
        this.starting.set(false);
        this.toast.success('Pipeline started — streaming logs live below', 'Started');
      },
      error: (e: { error?: { detail?: string } }) => {
        const detail = e?.error?.detail || 'Failed to start pipeline';
        this.toast.error(detail, 'Error');
        this.starting.set(false);
      }
    });
  }

  stopPipeline() {
    this.http.post(`${environment.apiBaseUrl}/pipeline/stop`, {}).subscribe({
      next: () => {
        this.pipelineState.set('idle');
        this.toast.success('Pipeline stopped', 'Stopped');
      },
      error: () => {
        this.toast.error('Failed to stop pipeline', 'Error');
      }
    });
  }

  clearLogs() {
    this.logLines.set([]);
  }

  copyLogs() {
    const text = this.logLines().map(l => l.text).join('\n');
    navigator.clipboard.writeText(text).then(
      () => this.toast.success('Terminal output copied to clipboard', 'Copied'),
      () => this.toast.error('Failed to copy to clipboard', 'Error')
    );
  }

  stateClass(): string {
    const map: Record<PipelineState, string> = {
      idle: 'state-idle', running: 'state-running',
      completed: 'state-completed', error: 'state-error'
    };
    return map[this.pipelineState()] ?? 'state-idle';
  }

  statusClass(status: StageStatus): string {
    const classMap: Record<StageStatus, string> = {
      idle: 'status-pending', running: 'status-running',
      done: 'status-success', error: 'status-error',
    };
    return classMap[status];
  }

  private scrollToBottom() {
    try {
      if (this.terminalBody) {
        const el: HTMLElement = this.terminalBody.nativeElement;
        el.scrollTop = el.scrollHeight;
      }
    } catch { /* noop */ }
  }
}
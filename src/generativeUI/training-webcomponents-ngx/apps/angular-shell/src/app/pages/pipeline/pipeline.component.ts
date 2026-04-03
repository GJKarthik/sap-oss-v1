import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit, OnDestroy, ViewChild, ElementRef, AfterViewChecked, NgZone
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
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
        <h1 class="page-title">{{ i18n.t('pipeline.title') }}</h1>
        <span class="text-muted text-small">{{ i18n.t('pipeline.subtitle') }}</span>
      </div>

      <!-- Control card -->
      <div class="control-card">
        <div class="control-info">
          <p>{{ i18n.t('pipeline.description') }}</p>
          <div class="flow-diagram">{{ i18n.t('pipeline.flowDiagram') }}</div>
        </div>
        <div class="control-actions">
          <div class="ws-badge" [class.ws-connected]="wsConnected()" [class.ws-disconnected]="!wsConnected()">
            {{ wsConnected() ? i18n.t('app.live') : i18n.t('app.offline') }}
          </div>
          <button class="btn-primary" (click)="startPipeline()"
            [disabled]="pipelineState() === 'running' || starting()">
            {{ starting() ? i18n.t('pipeline.starting') : pipelineState() === 'running' ? i18n.t('pipeline.processing') : i18n.t('pipeline.execute') }}
          </button>
        </div>
      </div>

      <!-- Live Terminal -->
      <div class="pipeline-terminal" *ngIf="logLines().length > 0 || pipelineState() !== 'idle'">
        <div class="terminal-header">
          <span class="terminal-title">{{ i18n.t('pipeline.terminalTitle') }}</span>
          <span class="terminal-status" [class]="stateClass()">{{ pipelineState().toUpperCase() }}</span>
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
          <span class="text-small text-muted">{{ logLines().length }} {{ i18n.t('pipeline.lines') }}</span>
          <button class="btn-clear" (click)="clearLogs()">{{ i18n.t('pipeline.clear') }}</button>
        </div>
      </div>

      <!-- Idle state prompt -->
      @if (pipelineState() === 'idle' && logLines().length === 0) {
        <div class="idle-prompt">
          <div style="font-size: 2.5rem; margin-bottom: 0.75rem;"><ui5-icon name="connected"></ui5-icon></div>
          <p>{{ i18n.t('pipeline.idlePrompt') }}</p>
        </div>
      }

      <!-- Stage Progress -->
      <div class="stages-section">
        <h2 class="section-title">{{ i18n.t('pipeline.stages') }}</h2>
        <div class="stages-table-wrapper">
          <table class="stages-table">
            <thead>
              <tr>
                <th>{{ i18n.t('pipeline.stageNum') }}</th><th>{{ i18n.t('pipeline.stageName') }}</th><th>{{ i18n.t('pipeline.stageTool') }}</th><th>{{ i18n.t('pipeline.stageInput') }}</th><th>{{ i18n.t('pipeline.stageOutput') }}</th><th>{{ i18n.t('pipeline.stageStatus') }}</th>
              </tr>
            </thead>
            <tbody>
              @for (s of stages(); track s.num) {
                <tr [class.stage-active]="s.status === 'running'">
                  <td class="stage-num">{{ s.num }}</td>
                  <td class="stage-name">{{ s.name }}</td>
                  <td><code>{{ s.tool }}</code></td>
                  <td class="text-muted text-small">{{ s.input }}</td>
                  <td class="text-muted text-small">{{ s.output }}</td>
                  <td>
                    <span class="status-badge {{ statusClass(s.status) }}">{{ s.status }}</span>
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      </div>

      <!-- Quick commands -->
      <div class="pipeline-commands">
        <h2 class="section-title">{{ i18n.t('pipeline.runCommands') }}</h2>
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
    /* Control card */
    .control-card {
      display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem;
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 1.25rem; margin-bottom: 1.5rem;
      font-size: 0.875rem; color: var(--sapTextColor, #32363a);
    }
    .control-info { flex: 1; p { margin: 0 0 0.75rem; } }
    .control-actions { display: flex; flex-direction: column; align-items: flex-end; gap: 0.75rem; }

    .ws-badge {
      padding: 0.2rem 0.6rem; border-radius: 1rem; font-size: 0.75rem; font-weight: 600;
      &.ws-connected { background: #e8f5e9; color: #2e7d32; }
      &.ws-disconnected { background: #ffebee; color: #c62828; }
    }

    .flow-diagram {
      background: var(--sapList_Background, #f5f5f5); border-radius: 0.25rem;
      padding: 0.625rem 1rem; font-family: 'SFMono-Regular', Consolas, monospace;
      font-size: 0.8125rem; color: var(--sapBrandColor, #0854a0);
      overflow-x: auto; white-space: nowrap;
    }

    /* Terminal */
    .pipeline-terminal {
      background: #0d1117; border-radius: 0.5rem; margin-bottom: 1.5rem;
      overflow: hidden; font-family: 'SFMono-Regular', Consolas, monospace;
      font-size: 0.8rem; box-shadow: 0 4px 20px rgba(0,0,0,0.4);
      border: 1px solid #30363d;
    }
    .terminal-header {
      background: #161b22; padding: 0.5rem 1rem; display: flex;
      justify-content: space-between; align-items: center;
      border-bottom: 1px solid #30363d;
    }
    .terminal-title { color: #8b949e; font-weight: 600; font-size: 0.75rem; }
    .terminal-status {
      font-size: 0.7rem; font-weight: 700; padding: 0.1rem 0.5rem; border-radius: 0.2rem;
      &.state-running { background: #1f3a2e; color: #3fb950; }
      &.state-completed { background: #0d2818; color: #56d364; }
      &.state-error { background: #3b1219; color: #f85149; }
      &.state-idle { background: #21262d; color: #8b949e; }
    }
    .terminal-body {
      padding: 0.875rem 1rem; min-height: 120px; max-height: 450px;
      overflow-y: auto; display: flex; flex-direction: column; gap: 0.15rem;
      scroll-behavior: smooth;
    }
    .log-line {
      display: flex; gap: 0.5rem; line-height: 1.5;
      .log-prefix { color: #30363d; user-select: none; flex-shrink: 0; }
      &.log-line--info { color: #e6edf3; }
      &.log-line--success { color: #3fb950; }
      &.log-line--error { color: #f85149; }
      &.log-line--warn { color: #d29922; }
      &.log-line--dim { color: #8b949e; }
    }
    .cursor-blink {
      color: #3fb950; animation: blink 1s step-end infinite;
    }
    @keyframes blink { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }
    .terminal-footer {
      padding: 0.3rem 1rem; background: #161b22; border-top: 1px solid #30363d;
      display: flex; justify-content: space-between; align-items: center;
    }
    .btn-clear {
      background: transparent; border: 1px solid #30363d; color: #8b949e;
      padding: 0.15rem 0.5rem; border-radius: 0.2rem; cursor: pointer; font-size: 0.7rem;
      &:hover { background: #21262d; color: #e6edf3; }
    }

    /* Idle */
    .idle-prompt {
      text-align: center; padding: 2.5rem; color: var(--sapContent_LabelColor, #6a6d70);
      background: var(--sapTile_Background, #fff); border: 1px dashed var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; margin-bottom: 1.5rem; font-size: 0.875rem;
      p { margin: 0; }
    }

    /* Buttons */
    .btn-primary {
      background: var(--sapButton_Emphasized_Background, #0854a0); color: #fff;
      border: none; border-radius: 0.25rem; cursor: pointer;
      font-weight: 600; font-size: 0.875rem; padding: 0.6rem 1.2rem; min-width: 170px;
      transition: background 0.2s;
      &:hover:not(:disabled) { background: var(--sapButton_Emphasized_Hover_Background, #063d75); }
      &:disabled { opacity: 0.6; cursor: not-allowed; }
    }

    /* Stages */
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
      td { padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4); vertical-align: middle; }
      tr:last-child td { border-bottom: none; }
      tr:hover td { background: var(--sapList_Hover_Background, #f5f5f5); }
      tr.stage-active td { background: #f0f7ff !important; }
    }
    .stage-num { color: var(--sapBrandColor, #0854a0); font-weight: 700; width: 2rem; text-align: center; }
    .stage-name { font-weight: 500; }
    .section-title { font-size: 1rem; font-weight: 600; color: var(--sapTextColor, #32363a); margin: 0 0 0.75rem; }

    /* Commands */
    .pipeline-commands { margin-bottom: 1.5rem; }
    .cmd-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; }
    .cmd-card { background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 1rem; }
    .cmd-title { font-size: 0.8125rem; font-weight: 600; margin: 0 0 0.5rem; color: var(--sapTextColor, #32363a); }
    pre { margin: 0; font-size: 0.8rem; background: var(--sapList_Background, #f5f5f5); padding: 0.5rem; border-radius: 0.25rem; overflow-x: auto; }
  `],
})
export class PipelineComponent implements OnInit, OnDestroy, AfterViewChecked {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
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
        this.toast.success(this.i18n.t('pipeline.completeMsg'), this.i18n.t('pipeline.completeTitle'));
      } else {
        this.toast.error(this.i18n.t('pipeline.errorMsg'), this.i18n.t('pipeline.errorTitle'));
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
    if (state === 'running') {
      this.stages.update(stages => stages.map((s, i) => ({ ...s, status: i === 0 ? 'running' : 'idle' })));
    } else if (state === 'completed') {
      this.stages.update(stages => stages.map(s => ({ ...s, status: 'done' })));
    } else if (state === 'error') {
      this.stages.update(stages => stages.map(s => ({ ...s, status: s.status === 'running' ? 'error' : s.status })));
    }
  }

  startPipeline() {
    this.starting.set(true);
    this.logLines.set([]);
    this.http.post(`${environment.apiBaseUrl}/pipeline/start`, {}).subscribe({
      next: () => {
        this.pipelineState.set('running');
        this.starting.set(false);
        this.toast.success(this.i18n.t('pipeline.startedMsg'), this.i18n.t('pipeline.startedTitle'));
      },
      error: (e: { error?: { detail?: string } }) => {
        const detail = e?.error?.detail || this.i18n.t('pipeline.startFailed');
        this.toast.error(detail, this.i18n.t('pipeline.errorTitle'));
        this.starting.set(false);
      }
    });
  }

  clearLogs() {
    this.logLines.set([]);
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
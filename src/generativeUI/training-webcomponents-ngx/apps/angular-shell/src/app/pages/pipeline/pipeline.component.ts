import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit, OnDestroy, ViewChild, ElementRef, AfterViewChecked, NgZone, computed
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { take } from 'rxjs/operators';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { environment } from '../../../environments/environment';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { AppStore } from '../../store/app.store';
import { PipelineFlowComponent, FlowStage } from '../../shared/components/pipeline-flow/pipeline-flow.component';
import { RealtimeConnectionService } from '../../services/realtime-connection.service';
import { ConfirmationDialogComponent, type ConfirmationDialogData } from '../../shared/components/confirmation-dialog/confirmation-dialog.component';

type PipelineState = 'idle' | 'running' | 'completed' | 'error';
type StageStatus = 'idle' | 'running' | 'done' | 'error';

interface PipelineStage extends FlowStage {
  tool: string;
  input: string;
  output: string;
}

interface LogLine {
  text: string;
  kind: 'info' | 'success' | 'error' | 'warn' | 'dim';
}

@Component({
  selector: 'app-pipeline',
  standalone: true,
  imports: [CommonModule, Ui5TrainingComponentsModule, PipelineFlowComponent, ConfirmationDialogComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="mission-control fadeIn">
      <div class="floating-header glass-panel slideUp">
        <div class="header-left">
          <ui5-title level="H3">{{ i18n.t('pipeline.title') }}</ui5-title>
          <ui5-tag [design]="stateDesign()">{{ pipelineState().toUpperCase() }}</ui5-tag>
        </div>
        <div class="header-right">
          @if (wsConnected()) { <span class="live-indicator">{{ i18n.t('pipeline.liveLink') }}</span> }
          <span class="mode-guidance">{{ modeGuidance() }}</span>
          <ui5-button design="Emphasized" icon="play" (click)="startPipeline()" 
            [disabled]="pipelineState() === 'running' || starting()">
            {{ pipelineState() === 'running' ? i18n.t('pipeline.processingEngine') : executeButtonLabel() }}
          </ui5-button>
        </div>
      </div>

      <div class="mission-layout">
        <!-- Center: Visual Flow & Concurrency -->
        <div class="center-stage">
          <section class="flow-card glass-panel slideUp" [style.--stagger]="'0.1s'">
            <app-pipeline-flow [stages]="stages()"></app-pipeline-flow>
          </section>

          <!-- Pipeline Execution Monitor -->
          <section class="concurrency-section glass-panel slideUp" [style.--stagger]="'0.2s'">
            <div class="card-header">
              <ui5-title level="H5">{{ i18n.t('pipeline.execMatrix') }}</ui5-title>
              <span class="text-small opacity-6">{{ i18n.t('pipeline.execMatrixDesc') }}</span>
            </div>
            <div class="thread-grid">
              @for (t of threads(); track $index) {
                <div class="thread-cell" [class.active]="t.active" [style.opacity]="t.load">
                  <div class="cell-fill" [style.height.%]="t.load * 100"></div>
                </div>
              }
            </div>
            <div class="concurrency-footer">
              <div class="footer-stat"><span>{{ i18n.t('pipeline.workers') }}</span> <strong>{{ i18n.t('pipeline.workerCount') }}</strong></div>
              <div class="footer-stat"><span>{{ i18n.t('pipeline.throughputLabel') }}</span> <strong>{{ i18n.t('pipeline.throughputValue', { value: throughput() }) }}</strong></div>
            </div>
          </section>

          <section class="terminal-container glass-panel slideUp" [style.--stagger]="'0.3s'">
            <div class="terminal-header">
              <ui5-icon name="command-line-interfaces"></ui5-icon>
              <span>{{ i18n.t('pipeline.binaryStreamLogs') }}</span>
            </div>
            <div class="terminal-body" #terminalBody role="log" aria-live="polite" aria-label="Pipeline execution logs">
              @for (line of logLines(); track $index) {
                <div class="log-line log-line--{{ line.kind }}">
                  <span class="log-text">{{ line.text }}</span>
                </div>
              }
              @if (pipelineState() === 'running') { <div class="cursor-blink">█</div> }
            </div>
          </section>
        </div>

        <!-- Side: Metadata & Constraints -->
        <aside class="side-stage">
          <ui5-card class="glass-panel slideUp" [style.--stagger]="'0.4s'">
            <ui5-card-header slot="header" [attr.title-text]="i18n.t('pipeline.pipelineMetrics')"></ui5-card-header>
            <div class="p-1 display-flex flex-column gap-1">
              <div class="mini-stat">
                <span class="label">{{ i18n.t('pipeline.completion') }}</span>
                <ui5-progress-indicator [value]="progress()" design="Positive"></ui5-progress-indicator>
              </div>
              <div class="mini-stat">
                <span class="label">{{ i18n.t('pipeline.memoryAllocator') }}</span>
                <ui5-tag design="Information">{{ i18n.t('pipeline.pythonRuntime') }}</ui5-tag>
              </div>
            </div>
          </ui5-card>

          <ui5-card class="glass-panel slideUp mt-1" [style.--stagger]="'0.5s'">
            <ui5-card-header slot="header" [attr.title-text]="i18n.t('pipeline.stageStatusCard')"></ui5-card-header>
            <div class="stages-mini-list">
              @for (s of stages(); track s.num) {
                <div class="mini-stage-item" [class.done]="s.status === 'done'" [class.running]="s.status === 'running'">
                  <ui5-icon [name]="statusIcon(s.status)"></ui5-icon>
                  <span>{{ s.name }}</span>
                </div>
              }
            </div>
          </ui5-card>
        </aside>
      </div>

      <app-confirmation-dialog
        [open]="confirmExecutionOpen()"
        [data]="confirmExecutionData()"
        (confirmed)="confirmExecutionOpen.set(false); launchPipeline()"
        (cancelled)="confirmExecutionOpen.set(false)">
      </app-confirmation-dialog>
    </div>
  `,
  styles: [`
    .mission-control { 
      height: 100%; display: flex; flex-direction: column; overflow: hidden; 
      padding: clamp(1rem, 4vw, 3rem); gap: 2rem; 
      background: radial-gradient(circle at 100% 0%, rgba(0, 112, 242, 0.08), transparent 40rem);
    }
    
    .floating-header { 
      padding: 1.25rem 2rem; display: flex; justify-content: space-between; align-items: center; 
      background: var(--liquid-glass-bg);
      backdrop-filter: var(--liquid-glass-blur);
      border: var(--liquid-glass-border);
      box-shadow: var(--liquid-glass-shadow);
      border-radius: 999px; 
    }
    .slideUp, .fadeIn { animation-delay: var(--stagger, 0s); }
    .header-left, .header-right { display: flex; align-items: center; gap: 1.25rem; }
    .header-left ui5-title { margin: 0; font-weight: 800; }
    .mode-guidance {
      font-size: 0.75rem;
      color: var(--text-secondary);
      font-weight: 600;
      max-width: 20rem;
      text-align: right;
    }
    .live-indicator { 
      font-size: 0.7rem; font-weight: 800; color: var(--color-success); 
      background: rgba(var(--color-success-rgb), 0.1); padding: 0.25rem 0.75rem; border-radius: 999px; 
      text-transform: uppercase; letter-spacing: 0.05em;
    }

    .mission-layout { flex: 1; display: grid; grid-template-columns: 1fr 340px; gap: 2rem; overflow: hidden; }
    .center-stage { display: flex; flex-direction: column; gap: 2rem; overflow-y: auto; padding-right: 0.5rem; }
    .side-stage { display: flex; flex-direction: column; gap: 1.5rem; }

    .glass-panel {
      background: var(--liquid-glass-bg);
      backdrop-filter: var(--liquid-glass-blur);
      border: var(--liquid-glass-border);
      box-shadow: var(--liquid-glass-shadow);
      border-radius: 28px;
    }

    /* ── Concurrency Matrix ──────────────────────────────────────────────── */
    .concurrency-section { padding: 2rem; display: flex; flex-direction: column; gap: 1.5rem; }
    .card-header { display: flex; justify-content: space-between; align-items: center; }
    .thread-grid { 
      display: grid; 
      grid-template-columns: repeat(16, 1fr); 
      grid-template-rows: repeat(4, 1fr);
      gap: 6px; height: 100px; 
    }
    .thread-cell { 
      background: rgba(0,0,0,0.04); border-radius: 4px; position: relative; overflow: hidden; 
      transition: opacity 0.15s;
    }
    .thread-cell.active { background: rgba(var(--color-primary-rgb), 0.1); }
    .cell-fill { 
      position: absolute; bottom: 0; left: 0; right: 0; 
      background: var(--color-primary); opacity: 0.8;
      transition: height 0.4s cubic-bezier(0.25, 0.8, 0.25, 1);
    }
    .concurrency-footer { display: flex; gap: 2.5rem; border-top: 1px solid rgba(0,0,0,0.05); padding-top: 1.25rem; }
    .footer-stat { font-size: 0.8125rem; color: var(--text-secondary); font-weight: 500; }
    .footer-stat strong { color: var(--text-primary); font-weight: 700; margin-left: 0.5rem; }

    /* ── Terminal ── */
    .terminal-container { flex: 1; display: flex; flex-direction: column; min-height: 350px; overflow: hidden; }
    .terminal-header { 
      padding: 1rem 1.5rem; background: rgba(0,0,0,0.03); 
      display: flex; align-items: center; gap: 0.75rem; 
      font-size: 0.75rem; font-weight: 700; color: var(--text-secondary);
      text-transform: uppercase; letter-spacing: 0.05em;
    }
    .terminal-body { 
      flex: 1; background: var(--code-bg); padding: 1.5rem; overflow-y: auto; 
      font-family: var(--sapFontFamilyMono, monospace); font-size: 0.875rem; color: #e6edf3; 
      line-height: 1.6;
    }
    .log-line { margin-bottom: 0.25rem; }
    .log-line--success { color: #7ee787; }
    .log-line--error { color: #ff7b72; }
    .log-line--warn { color: #d29922; }
    
    .cursor-blink { display: inline-block; width: 8px; height: 15px; background: #7ee787; animation: blink 1s step-end infinite; vertical-align: middle; }
    @keyframes blink { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }

    .mini-stage-item { 
      display: flex; align-items: center; gap: 1rem; padding: 0.75rem 1rem; 
      font-size: 0.875rem; font-weight: 500; color: var(--text-secondary);
      border-radius: 12px; transition: all 0.2s;
    }
    .mini-stage-item.done { color: var(--color-success); background: rgba(var(--color-success-rgb), 0.05); }
    .mini-stage-item.running { color: var(--color-primary); background: rgba(var(--color-primary-rgb), 0.05); font-weight: 700; }

    .mini-stat { display: flex; flex-direction: column; gap: 0.5rem; }
    .mini-stat .label { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); letter-spacing: 0.05em; }

    .stages-mini-list { display: flex; flex-direction: column; gap: 0.25rem; padding: 1rem; }
    
    .p-1 { padding: 1.5rem; }
    .display-flex { display: flex; }
    .flex-column { flex-direction: column; }
    .gap-1 { gap: 1.25rem; }
    .mt-1 { margin-top: 1.5rem; }
    .opacity-6 { opacity: 0.6; }
  `],
})
export class PipelineComponent implements OnInit, OnDestroy, AfterViewChecked {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
  private readonly zone = inject(NgZone);
  private readonly appStore = inject(AppStore);
  private readonly realtime = inject(RealtimeConnectionService);

  @ViewChild('terminalBody') private terminalBody?: ElementRef;

  readonly pipelineState = computed<PipelineState>(() => this.appStore.pipelineState());
  readonly activeMode = this.appStore.activeMode;
  readonly logLines = signal<LogLine[]>([]);
  readonly starting = signal(false);
  readonly wsConnected = signal(false);
  readonly confirmExecutionOpen = signal(false);
  readonly confirmExecutionData = computed<ConfirmationDialogData>(() => ({
    title: 'Review pipeline launch',
    message: 'Cowork mode requires explicit approval before a pipeline run starts. Confirm the launch when the plan is ready.',
    confirmText: 'Start run',
    cancelText: 'Keep reviewing',
    confirmDesign: 'Positive',
    icon: 'process',
  }));
  readonly executeButtonLabel = computed(() => {
    const labels = {
      chat: 'Switch to training',
      cowork: 'Review launch',
      training: this.i18n.t('pipeline.execute'),
    } as const;
    return labels[this.activeMode()];
  });
  readonly modeGuidance = computed(() => {
    const guidance = {
      chat: 'Execution is disabled in chat mode until you switch the workspace into training.',
      cowork: 'Cowork mode stages the run and asks for approval before execution.',
      training: 'Training mode launches the run immediately against the live backend.',
    } as const;
    return guidance[this.activeMode()];
  });
  
  // High-perf thread simulation
  readonly threads = signal(Array.from({length: 64}, () => ({ active: false, load: 0 })));
  readonly throughput = signal('0.00');
  private threadInterval?: ReturnType<typeof setInterval>;

  readonly stages = signal<PipelineStage[]>([
    { num: 1, name: 'Preconvert', tool: 'Python', input: 'data/*.xlsx', output: 'staging/*.csv', status: 'idle' },
    { num: 2, name: 'Extract Schema', tool: 'Python', input: 'CSV', output: 'Registry', status: 'idle' },
    { num: 3, name: 'Parse Templates', tool: 'Python', input: 'CSV', output: 'JSON', status: 'idle' },
    { num: 4, name: 'Expand', tool: 'Python', input: 'Tpl', output: 'Pairs', status: 'idle' },
    { num: 5, name: 'Build SQL', tool: 'Python', input: 'Pairs', output: 'HANA SQL', status: 'idle' },
    { num: 6, name: 'Format', tool: 'Python', input: 'JSON', output: 'JSONL', status: 'idle' },
  ]);

  readonly progress = computed(() => {
    const done = this.stages().filter(s => s.status === 'done').length;
    return (done / this.stages().length) * 100;
  });

  private ws: WebSocket | null = null;
  private shouldAutoScroll = true;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private destroyed = false;

  ngOnInit() { 
    this.connectWebSocket();
    this.threadInterval = setInterval(() => this.updateThreadMatrix(), 150);
  }
  
  ngOnDestroy() { 
    this.destroyed = true;
    this.ws?.close(); 
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    if (this.threadInterval) clearInterval(this.threadInterval);
    if (this.pipelineState() !== 'running') this.appStore.setPipelineState('idle');
  }
  
  ngAfterViewChecked() { if (this.shouldAutoScroll) this.scrollToBottom(); }

  private updateThreadMatrix() {
    if (this.pipelineState() !== 'running') {
      this.threads.update(ts => ts.map(t => ({ active: false, load: Math.max(0, t.load - 0.1) })));
      this.throughput.set('0.00');
      return;
    }
    this.threads.update(ts => ts.map(() => ({
      active: Math.random() > 0.3,
      load: Math.random()
    })));
    this.throughput.set((Math.random() * 4 + 2).toFixed(2));
  }

  private connectWebSocket() {
    if (this.destroyed) {
      return;
    }

    this.realtime.probeApiHealth().pipe(take(1)).subscribe((ready) => {
      if (!ready) {
        this.zone.run(() => this.wsConnected.set(false));
        this.scheduleReconnect();
        return;
      }

      this.openWebSocket();
    });
  }

  private openWebSocket(): void {
    const wsUrl = this.realtime.buildWebSocketUrl('/ws/pipeline');

    try {
      this.ws = new WebSocket(wsUrl);
    } catch {
      this.zone.run(() => this.wsConnected.set(false));
      this.scheduleReconnect();
      return;
    }

    this.ws.onopen = () => this.zone.run(() => {
      this.wsConnected.set(true);
      this.startHeartbeat();
    });
    this.ws.onmessage = (event) => this.zone.run(() => { try { this.handleMessage(JSON.parse(event.data)); } catch { } });
    this.ws.onclose = () => {
      this.stopHeartbeat();
      this.zone.run(() => this.wsConnected.set(false));
      this.scheduleReconnect();
    };
    this.ws.onerror = () => {
      this.stopHeartbeat();
      this.ws?.close();
    };
  }

  private startHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
    }

    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send('ping');
      }
    }, 25000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private scheduleReconnect(): void {
    if (this.destroyed || this.reconnectTimer) {
      return;
    }

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connectWebSocket();
    }, 3000);
  }

  private handleMessage(msg: Record<string, unknown>) {
    if (msg['type'] === 'init') {
      const s = (msg['state'] as PipelineState) || 'idle';
      this.appStore.setPipelineState(s);
      this.logLines.set(((msg['logs'] as string[]) || []).map((t: string) => this.parseLine(t)));
      this.updateStagesFromState(s);
    } else if (msg['type'] === 'log') {
      this.appendLine((msg['text'] as string) || '');
    } else if (msg['type'] === 'done') {
      const s = (msg['state'] as PipelineState) || 'completed';
      this.appStore.setPipelineState(s);
      this.appendLine((msg['text'] as string) || '');
      this.updateStagesFromState(s);
      if (s === 'completed') {
        this.toast.success((msg['text'] as string) || this.i18n.t('pipeline.finished'));
      } else if (s === 'error') {
        this.toast.error((msg['text'] as string) || this.i18n.t('pipeline.failed'));
      }
    }
  }

  private parseLine(text: string): LogLine {
    const trimmed = text.trim();
    const lower = trimmed.toLowerCase();
    if (trimmed.startsWith('#') || trimmed.startsWith('--')) return { text, kind: 'dim' };
    if (trimmed.includes('✅') || lower.includes('success')) return { text, kind: 'success' };
    if (trimmed.includes('❌') || trimmed.includes('💥') || lower.includes('error') || lower.includes('fail')) return { text, kind: 'error' };
    if (trimmed.includes('⚠') || lower.includes('warn')) return { text, kind: 'warn' };
    return { text, kind: 'info' };
  }

  private appendLine(text: string) { 
    const lower = text.toLowerCase();
    this.logLines.update(lines => [...lines, this.parseLine(text)]);

    if (lower.includes('converting')) this.setStageStatus(1, 'running');
    if (lower.includes('extracting')) { this.setStageStatus(1, 'done'); this.setStageStatus(2, 'running'); }
    if (lower.includes('parsing')) { this.setStageStatus(2, 'done'); this.setStageStatus(3, 'running'); }
    if (lower.includes('expanding')) { this.setStageStatus(3, 'done'); this.setStageStatus(4, 'running'); }
    if (lower.includes('validating')) { this.setStageStatus(4, 'done'); this.setStageStatus(5, 'running'); }
    if (lower.includes('formatting')) { this.setStageStatus(5, 'done'); this.setStageStatus(6, 'running'); }
  }

  private setStageStatus(num: number, status: StageStatus) {
    this.stages.update(stages => stages.map(s => s.num === num ? { ...s, status } : s));
  }

  private updateStagesFromState(state: PipelineState) {
    if (state === 'idle') {
      this.stages.update((stages) => stages.map((stage) => ({ ...stage, status: 'idle' })));
      return;
    }

    if (state === 'running') {
      this.stages.update((stages) => stages.map((stage, index) => ({ ...stage, status: index === 0 ? 'running' : 'idle' })));
      return;
    }

    if (state === 'completed') {
      this.stages.update((stages) => stages.map((stage) => ({ ...stage, status: 'done' })));
      return;
    }

    this.stages.update((stages) => stages.map((stage) => ({ ...stage, status: stage.status === 'running' ? 'error' : stage.status })));
  }

  startPipeline() {
    if (this.pipelineState() === 'running' || this.starting()) {
      return;
    }

    if (this.activeMode() === 'chat') {
      this.appStore.setMode('training');
      this.toast.info('Training mode enabled. Review the run configuration and launch again.');
      return;
    }

    if (this.activeMode() === 'cowork') {
      this.confirmExecutionOpen.set(true);
      return;
    }

    this.launchPipeline();
  }

  launchPipeline() {
    this.starting.set(true);
    this.http.post(`${environment.apiBaseUrl}/pipeline/start`, {}).subscribe({
      next: () => {
        this.appStore.setPipelineState('running');
        this.updateStagesFromState('running');
        this.starting.set(false);
        this.toast.success(this.i18n.t('pipeline.started'));
      },
      error: () => {
        this.starting.set(false);
        this.toast.error(this.i18n.t('pipeline.startFailed'));
      }
    });
  }

  stateDesign(): 'Neutral' | 'Positive' | 'Information' | 'Negative' {
    const map: Record<string, 'Neutral' | 'Positive' | 'Information' | 'Negative'> = { idle: 'Neutral', running: 'Information', completed: 'Positive', error: 'Negative' };
    return map[this.pipelineState()] ?? 'Neutral';
  }

  statusIcon(status: StageStatus): string {
    const map: Record<StageStatus, string> = { idle: 'circle-task', running: 'synchronize', done: 'status-completed', error: 'status-error' };
    return map[status];
  }

  private scrollToBottom() { try { if (this.terminalBody) this.terminalBody.nativeElement.scrollTop = this.terminalBody.nativeElement.scrollHeight; } catch { } }
}

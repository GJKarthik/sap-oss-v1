import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit, OnDestroy, ViewChild, ElementRef, AfterViewChecked, NgZone, computed
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { environment } from '../../../environments/environment';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { AppStore } from '../../store/app.store';
import { PipelineFlowComponent, FlowStage } from '../../shared/components/pipeline-flow/pipeline-flow.component';

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
  imports: [CommonModule, Ui5WebcomponentsModule, PipelineFlowComponent],
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
          <ui5-button design="Emphasized" icon="play" (click)="startPipeline()" 
            [disabled]="pipelineState() === 'running' || starting()">
            {{ pipelineState() === 'running' ? i18n.t('pipeline.processingEngine') : i18n.t('pipeline.execute') }}
          </ui5-button>
        </div>
      </div>

      <div class="mission-layout">
        <!-- Center: Visual Flow & Concurrency -->
        <div class="center-stage">
          <section class="flow-card glass-panel slideUp" [style.--stagger]="'0.1s'">
            <app-pipeline-flow [stages]="stages()"></app-pipeline-flow>
          </section>

          <!-- Zig Concurrency Matrix (True Leverage of Zig Backend) -->
          <section class="concurrency-section glass-panel slideUp" [style.--stagger]="'0.2s'">
            <div class="card-header">
              <ui5-title level="H5">{{ i18n.t('pipeline.zigMatrix') }}</ui5-title>
              <span class="text-small opacity-6">{{ i18n.t('pipeline.zigMatrixDesc') }}</span>
            </div>
            <div class="thread-grid">
              @for (t of threads(); track $index) {
                <div class="thread-cell" [class.active]="t.active" [style.opacity]="t.load">
                  <div class="cell-fill" [style.height.%]="t.load * 100"></div>
                </div>
              }
            </div>
            <div class="concurrency-footer">
              <div class="footer-stat"><span>{{ i18n.t('pipeline.simdSlots') }}</span> <strong>{{ i18n.t('pipeline.simd512') }}</strong></div>
              <div class="footer-stat"><span>{{ i18n.t('pipeline.throughputLabel') }}</span> <strong>{{ i18n.t('pipeline.throughputValue', { value: throughput() }) }}</strong></div>
            </div>
          </section>

          <section class="terminal-container glass-panel slideUp" [style.--stagger]="'0.3s'">
            <div class="terminal-header">
              <ui5-icon name="command-line-interface"></ui5-icon>
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
                <ui5-tag design="Information">{{ i18n.t('pipeline.gpaZig') }}</ui5-tag>
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
    </div>
  `,
  styles: [`
    .mission-control { height: 100%; display: flex; flex-direction: column; overflow: hidden; padding: 1.5rem 2rem; gap: 1.5rem; }
    
    .floating-header { padding: 0.75rem 1.5rem; display: flex; justify-content: space-between; align-items: center; border-radius: 999px; }
    .slideUp, .fadeIn { animation-delay: var(--stagger, 0s); }
    .header-left, .header-right { display: flex; align-items: center; gap: 1rem; }
    .live-indicator { font-size: 0.65rem; font-weight: 800; color: var(--sapPositiveColor); border: 1px solid currentColor; padding: 0.1rem 0.4rem; border-radius: 4px; }

    .mission-layout { flex: 1; display: grid; grid-template-columns: 1fr 300px; gap: 1.5rem; overflow: hidden; }
    .center-stage { display: flex; flex-direction: column; gap: 1.5rem; overflow-y: auto; padding-right: 0.5rem; }
    .side-stage { display: flex; flex-direction: column; gap: 1rem; }

    /* ── Concurrency Matrix ──────────────────────────────────────────────── */
    .concurrency-section { padding: 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
    .card-header { display: flex; justify-content: space-between; align-items: baseline; }
    .thread-grid { 
      display: grid; 
      grid-template-columns: repeat(16, 1fr); 
      grid-template-rows: repeat(4, 1fr);
      gap: 4px; height: 80px; 
    }
    .thread-cell { 
      background: rgba(0,0,0,0.05); border-radius: 2px; position: relative; overflow: hidden; 
      transition: opacity 0.1s;
    }
    .thread-cell.active { background: color-mix(in srgb, var(--sapBrandColor) 20%, transparent); }
    .cell-fill { 
      position: absolute; bottom: 0; left: 0; right: 0; 
      background: var(--sapBrandColor); opacity: 0.6;
      transition: height 0.3s var(--spring-easing);
    }
    .concurrency-footer { display: flex; gap: 2rem; border-top: 1px solid rgba(0,0,0,0.05); padding-top: 0.75rem; }
    .footer-stat { font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .footer-stat strong { color: var(--sapTextColor); }

    /* ── Terminal ── */
    .terminal-container { flex: 1; display: flex; flex-direction: column; min-height: 300px; overflow: hidden; }
    .terminal-header { padding: 0.75rem 1.25rem; background: rgba(0,0,0,0.03); display: flex; align-items: center; gap: 0.75rem; font-size: 0.75rem; font-weight: 700; opacity: 0.7; }
    .terminal-body { flex: 1; background: #0d1117; padding: 1.5rem; overflow-y: auto; font-family: 'Fira Code', monospace; font-size: 0.8125rem; color: #e6edf3; }
    .log-line { line-height: 1.6; margin-bottom: 0.25rem; }
    .log-line--success { color: #7ee787; }
    .log-line--error { color: #ff7b72; }
    
    .cursor-blink { display: inline-block; width: 8px; height: 15px; background: #7ee787; animation: blink 1s step-end infinite; vertical-align: middle; }
    @keyframes blink { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }

    .mini-stage-item { display: flex; align-items: center; gap: 0.75rem; padding: 0.5rem; font-size: 0.8125rem; opacity: 0.4; }
    .mini-stage-item.done { opacity: 1; color: var(--sapPositiveColor); }
    .mini-stage-item.running { opacity: 1; color: var(--sapBrandColor); font-weight: bold; }

    .p-1 { padding: 1rem; }
    .display-flex { display: flex; }
    .flex-column { flex-direction: column; }
    .gap-1 { gap: 1rem; }
    .mt-1 { margin-top: 1rem; }
    .opacity-6 { opacity: 0.6; }
  `],
})
export class PipelineComponent implements OnInit, OnDestroy, AfterViewChecked {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
  private readonly zone = inject(NgZone);
  private readonly appStore = inject(AppStore);

  @ViewChild('terminalBody') private terminalBody?: ElementRef;

  readonly pipelineState = computed<PipelineState>(() => this.appStore.pipelineState());
  readonly logLines = signal<LogLine[]>([]);
  readonly starting = signal(false);
  readonly wsConnected = signal(false);
  
  // High-perf thread simulation
  readonly threads = signal(Array.from({length: 64}, () => ({ active: false, load: 0 })));
  readonly throughput = signal('0.00');
  private threadInterval?: any;

  readonly stages = signal<PipelineStage[]>([
    { num: 1, name: 'Preconvert', tool: 'Python', input: 'data/*.xlsx', output: 'staging/*.csv', status: 'idle' },
    { num: 2, name: 'Build', tool: 'Zig', input: 'Source', output: 'Binary', status: 'idle' },
    { num: 3, name: 'Extract Schema', tool: 'Zig', input: 'CSV', output: 'Registry', status: 'idle' },
    { num: 4, name: 'Parse Templates', tool: 'Zig', input: 'CSV', output: 'JSON', status: 'idle' },
    { num: 5, name: 'Expand', tool: 'Zig', input: 'Tpl', output: 'Pairs', status: 'idle' },
    { num: 6, name: 'Validate', tool: 'Mangle', input: 'Rules', output: 'Valid', status: 'idle' },
    { num: 7, name: 'Format', tool: 'Zig', input: 'JSON', output: 'JSONL', status: 'idle' },
  ]);

  readonly progress = computed(() => {
    const done = this.stages().filter(s => s.status === 'done').length;
    return (done / this.stages().length) * 100;
  });

  private ws: WebSocket | null = null;
  private shouldAutoScroll = true;

  ngOnInit() { 
    this.connectWebSocket();
    this.threadInterval = setInterval(() => this.updateThreadMatrix(), 150);
  }
  
  ngOnDestroy() { 
    this.ws?.close(); 
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
    const wsBase = environment.apiBaseUrl.startsWith('http')
      ? environment.apiBaseUrl.replace(/^http/, 'ws').replace(/\/api\/?$/, '')
      : `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}`;
    const wsUrl = `${wsBase}/ws/pipeline`;

    this.ws = new WebSocket(wsUrl);
    this.ws.onopen = () => this.zone.run(() => this.wsConnected.set(true));
    this.ws.onmessage = (event) => this.zone.run(() => { try { this.handleMessage(JSON.parse(event.data)); } catch { } });
    this.ws.onclose = () => { this.zone.run(() => this.wsConnected.set(false)); setTimeout(() => this.connectWebSocket(), 3000); };
  }

  private handleMessage(msg: any) {
    if (msg.type === 'init') {
      const s = msg.state || 'idle';
      this.appStore.setPipelineState(s);
      this.logLines.set((msg.logs || []).map((t: string) => this.parseLine(t)));
      this.updateStagesFromState(s);
    } else if (msg.type === 'log') {
      this.appendLine(msg.text || '');
    } else if (msg.type === 'done') {
      const s = msg.state || 'completed';
      this.appStore.setPipelineState(s);
      this.appendLine(msg.text || '');
      this.updateStagesFromState(s);
    }
  }

  private parseLine(text: string): LogLine {
    if (text.includes('✅') || text.includes('success')) return { text, kind: 'success' };
    if (text.includes('❌') || text.includes('error')) return { text, kind: 'error' };
    return { text, kind: 'info' };
  }

  private appendLine(text: string) { 
    this.logLines.update(lines => [...lines, this.parseLine(text)]); 
    if (text.toLowerCase().includes('converting')) this.setStageStatus(1, 'running');
    if (text.toLowerCase().includes('extracting')) { this.setStageStatus(1, 'done'); this.setStageStatus(3, 'running'); }
    if (text.toLowerCase().includes('parsing')) { this.setStageStatus(3, 'done'); this.setStageStatus(4, 'running'); }
    if (text.toLowerCase().includes('expanding')) { this.setStageStatus(4, 'done'); this.setStageStatus(5, 'running'); }
    if (text.toLowerCase().includes('validating')) { this.setStageStatus(5, 'done'); this.setStageStatus(6, 'running'); }
    if (text.toLowerCase().includes('formatting')) { this.setStageStatus(6, 'done'); this.setStageStatus(7, 'running'); }
  }

  private setStageStatus(num: number, status: StageStatus) {
    this.stages.update(stages => stages.map(s => s.num === num ? { ...s, status } : s));
  }

  private updateStagesFromState(state: PipelineState) {
    if (state === 'completed') this.stages.update(stages => stages.map(s => ({ ...s, status: 'done' })));
  }

  startPipeline() {
    this.starting.set(true);
    this.http.post(`${environment.apiBaseUrl}/pipeline/start`, {}).subscribe({
      next: () => { this.appStore.setPipelineState('running'); this.starting.set(false); },
      error: () => this.starting.set(false)
    });
  }

  stateDesign(): 'Neutral' | 'Positive' | 'Information' | 'Negative' {
    const map: any = { idle: 'Neutral', running: 'Information', completed: 'Positive', error: 'Negative' };
    return map[this.pipelineState()];
  }

  statusIcon(status: StageStatus): string {
    const map: any = { idle: 'circle-task', running: 'synchronize', done: 'status-completed', error: 'status-error' };
    return map[status];
  }

  private scrollToBottom() { try { if (this.terminalBody) this.terminalBody.nativeElement.scrollTop = this.terminalBody.nativeElement.scrollHeight; } catch { } }
}

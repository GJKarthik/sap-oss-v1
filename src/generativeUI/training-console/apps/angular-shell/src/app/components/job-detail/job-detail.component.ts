import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit, OnDestroy, ElementRef, ViewChild, AfterViewInit, NgZone, Input
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
import { environment } from '../../../environments/environment';

interface JobResponse {
  id: string;
  status: string;
  progress: number;
  config: Record<string, unknown>;
  history: { step: number; loss: number; epoch: number }[];
  evaluation?: { perplexity: number; eval_loss: number; runtime_sec: number };
  deployed?: boolean;
  created_at: string;
  error?: string;
}

interface LogLine { text: string; kind: 'info' | 'success' | 'error' | 'warn' | 'dim'; }

@Component({
  selector: 'app-job-detail',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="job-detail-panel">
      <!-- Header -->
      <div class="detail-header">
        <div class="detail-meta">
          <code class="job-id">{{ job.id.slice(0, 8) }}</code>
          <span class="badge badge-{{ job.status }}">
            <span class="badge-dot"></span>
            {{ job.status }}
          </span>
          <span class="detail-model">{{ job.config['model_name'] }}</span>
        </div>
        <div class="ws-indicator" [class.live]="wsConnected()">
          <span class="ws-dot"></span>
          {{ wsConnected() ? 'Live' : 'Offline' }}
        </div>
      </div>

      <!-- Progress -->
      <div class="progress-row">
        <div class="progress-bar">
          <div class="progress-fill" [style.width]="liveProgress() + '%'"
               [class.animated]="liveStatus() === 'running'"
               [class.complete]="liveStatus() === 'completed'"></div>
        </div>
        <span class="progress-pct">{{ liveProgress().toFixed(0) }}%</span>
      </div>

      <!-- Loss Chart Canvas -->
      <div class="chart-section">
        <div class="chart-header">
          <span class="chart-title">📉 Training Loss Curve</span>
          @if (liveEval()) {
            <div class="eval-badges">
              <span class="eval-badge eval-badge--ppl">PPL {{ liveEval()!.perplexity }}</span>
              <span class="eval-badge">Loss {{ liveEval()!.eval_loss }}</span>
              <span class="eval-runtime">{{ liveEval()!.runtime_sec }}s</span>
            </div>
          }
        </div>
        <canvas #chartCanvas class="loss-canvas" width="600" height="200"></canvas>
      </div>

      <!-- Live Terminal -->
      @if (logLines().length > 0) {
        <div class="terminal">
          <div class="terminal-head">
            <span class="terminal-dot"></span>
            <span class="terminal-dot terminal-dot--yellow"></span>
            <span class="terminal-dot terminal-dot--green"></span>
            <span class="terminal-title">Log Stream</span>
          </div>
          <div class="terminal-body" #logBody>
            @for (l of logLines(); track $index) {
              <div class="log line-{{ l.kind }}">{{ l.text }}</div>
            }
          </div>
        </div>
      }
    </div>
  `,
  styles: [`
    .job-detail-panel {
      padding: 1.25rem;
      background: linear-gradient(180deg, #f8f9fa 0%, #fff 100%);
      animation: panelSlideIn 0.3s ease-out;
    }

    @keyframes panelSlideIn {
      from { opacity: 0; transform: translateY(-8px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .detail-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 1rem;
      gap: 0.5rem;
    }

    .detail-meta { display: flex; align-items: center; gap: 0.5rem; }
    .detail-model { font-size: 0.75rem; color: #6a6d70; }

    .job-id {
      font-size: 0.7rem;
      background: #eef1f4;
      padding: 0.15rem 0.5rem;
      border-radius: 0.25rem;
      color: #32363a;
      font-family: monospace;
    }

    .badge {
      display: inline-flex;
      align-items: center;
      gap: 0.3rem;
      padding: 0.15rem 0.6rem;
      border-radius: 1rem;
      font-size: 0.65rem;
      font-weight: 600;
      text-transform: capitalize;

      &.badge-running { background: #e3f2fd; color: #1565c0; }
      &.badge-completed { background: #e8f5e9; color: #2e7d32; }
      &.badge-failed { background: #ffebee; color: #c62828; }
      &.badge-pending { background: #fff8e1; color: #f57f17; }
    }

    .badge-dot {
      width: 5px;
      height: 5px;
      border-radius: 50%;
      background: currentColor;
    }

    .badge-running .badge-dot {
      animation: dotPulse 1.5s ease-in-out infinite;
    }

    .ws-indicator {
      display: flex;
      align-items: center;
      gap: 0.35rem;
      font-size: 0.7rem;
      padding: 0.2rem 0.6rem;
      border-radius: 1rem;
      background: #f0f0f0;
      color: #666;

      &.live { background: #e8f5e9; color: #2e7d32; }
    }

    .ws-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: #bbb;
    }

    .ws-indicator.live .ws-dot {
      background: #43a047;
      animation: dotPulse 2s ease-in-out infinite;
    }

    @keyframes dotPulse {
      0%, 100% { opacity: 1; box-shadow: 0 0 0 0 currentColor; }
      50% { opacity: 0.5; }
    }

    .progress-row {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      margin-bottom: 1rem;
    }

    .progress-bar {
      flex: 1;
      height: 6px;
      background: #e8eaed;
      border-radius: 3px;
      overflow: hidden;
    }

    .progress-fill {
      height: 100%;
      background: linear-gradient(90deg, #0854a0, #1976d2);
      border-radius: 3px;
      transition: width 0.6s cubic-bezier(0.4, 0, 0.2, 1);

      &.animated {
        animation: progressPulse 2s ease-in-out infinite;
      }

      &.complete {
        background: linear-gradient(90deg, #43a047, #66bb6a);
      }
    }

    @keyframes progressPulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.65; } }

    .progress-pct {
      font-size: 0.75rem;
      font-weight: 600;
      color: #32363a;
      min-width: 35px;
      text-align: right;
    }

    .chart-section {
      background: #fff;
      border: 1px solid #e4e4e4;
      border-radius: 0.625rem;
      margin-bottom: 1rem;
      overflow: hidden;
      box-shadow: 0 1px 3px rgba(0,0,0,0.04);
    }

    .chart-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.6rem 1rem;
      background: #f8f9fa;
      border-bottom: 1px solid #e4e4e4;
    }

    .chart-title { font-size: 0.8rem; font-weight: 600; color: #32363a; }

    .eval-badges { display: flex; gap: 0.4rem; align-items: center; }

    .eval-badge {
      background: #e8f5e9;
      color: #2e7d32;
      padding: 0.15rem 0.5rem;
      border-radius: 1rem;
      font-size: 0.65rem;
      font-weight: 600;

      &.eval-badge--ppl { background: #e3f2fd; color: #1565c0; }
    }

    .eval-runtime { font-size: 0.65rem; color: #9e9e9e; }

    .loss-canvas { width: 100%; display: block; }

    .terminal {
      background: #0d1117;
      border-radius: 0.625rem;
      overflow: hidden;
      font-family: 'SF Mono', 'Fira Code', monospace;
      font-size: 0.7rem;
      box-shadow: 0 2px 8px rgba(0,0,0,0.15);
    }

    .terminal-head {
      background: #161b22;
      padding: 0.5rem 0.75rem;
      display: flex;
      align-items: center;
      gap: 0.35rem;
      border-bottom: 1px solid #30363d;
    }

    .terminal-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #f85149;

      &.terminal-dot--yellow { background: #d29922; }
      &.terminal-dot--green { background: #3fb950; }
    }

    .terminal-title {
      color: #8b949e;
      font-size: 0.65rem;
      font-weight: 600;
      margin-left: 0.4rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .terminal-body {
      padding: 0.6rem 0.75rem;
      max-height: 200px;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      gap: 0.15rem;
    }

    .log {
      color: #e6edf3;
      line-height: 1.5;
      font-size: 0.7rem;

      &.line-success { color: #3fb950; }
      &.line-error { color: #f85149; }
      &.line-warn { color: #d29922; }
      &.line-dim { color: #8b949e; }
    }
  `]
})
export class JobDetailComponent implements OnInit, OnDestroy, AfterViewInit {
  @Input({ required: true }) job!: JobResponse;
  @ViewChild('chartCanvas') private chartCanvas!: ElementRef<HTMLCanvasElement>;
  @ViewChild('logBody') private logBody?: ElementRef;

  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);
  private readonly zone = inject(NgZone);

  readonly wsConnected = signal(false);
  readonly liveStatus = signal<string>('pending');
  readonly liveProgress = signal(0);
  readonly liveEval = signal<{ perplexity: number; eval_loss: number; runtime_sec: number } | null>(null);
  readonly logLines = signal<LogLine[]>([]);

  private ws: WebSocket | null = null;
  private reconnect: any = null;
  // Loss data: [step, loss]
  private lossPoints: [number, number][] = [];

  ngOnInit() {
    this.liveStatus.set(this.job.status);
    this.liveProgress.set(this.job.progress ?? 0);
    this.liveEval.set(this.job.evaluation ?? null);
    this.lossPoints = (this.job.history ?? []).map(h => [h.step, h.loss]);
    this.connect();
  }

  ngAfterViewInit() {
    this.drawChart();
  }

  ngOnDestroy() {
    this.ws?.close();
    if (this.reconnect) clearTimeout(this.reconnect);
  }

  private connect() {
    const wsBase = environment.apiBaseUrl.replace(/^http/, 'ws');
    this.ws = new WebSocket(`${wsBase}/ws/jobs/${this.job.id}`);

    this.ws.onopen = () => this.zone.run(() => this.wsConnected.set(true));

    this.ws.onmessage = (ev: MessageEvent) => this.zone.run(() => {
      try {
        const msg = JSON.parse(ev.data as string);
        this.handleMsg(msg);
      } catch { /* noop */ }
    });

    this.ws.onclose = () => {
      this.zone.run(() => this.wsConnected.set(false));
      if (['running', 'pending'].includes(this.liveStatus())) {
        this.reconnect = setTimeout(() => this.connect(), 3000);
      }
    };

    this.ws.onerror = () => this.ws?.close();

    // Heartbeat
    setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) this.ws.send('ping');
    }, 25000);
  }

  private handleMsg(msg: Record<string, unknown>) {
    const type = msg['type'] as string;
    if (type === 'init') {
      const data = msg['data'] as JobResponse;
      this.liveStatus.set(data.status);
      this.liveProgress.set(data.progress ?? 0);
      this.liveEval.set(data.evaluation ?? null);
      this.lossPoints = (data.history ?? []).map(h => [h.step, h.loss]);
      this.drawChart();
    } else if (type === 'loss') {
      const pt = msg['point'] as { step: number; loss: number };
      this.lossPoints.push([pt.step, pt.loss]);
      this.liveProgress.set((msg['progress'] as number) ?? this.liveProgress());
      this.drawChart();
    } else if (type === 'evaluation') {
      const ev = msg['data'] as { perplexity: number; eval_loss: number; runtime_sec: number };
      this.liveEval.set(ev);
    } else if (type === 'status') {
      this.liveStatus.set(msg['status'] as string);
      this.liveProgress.set((msg['progress'] as number) ?? this.liveProgress());
    } else if (type === 'log') {
      const data = msg['data'] as { step: string; loss: number | null };
      this.appendLog(data?.step ?? '', data?.loss);
    }
  }

  private appendLog(text: string, loss: number | null = null) {
    let kind: LogLine['kind'] = 'info';
    if (text.startsWith('✅') || text.includes('success')) kind = 'success';
    else if (text.startsWith('❌') || text.toLowerCase().includes('error')) kind = 'error';
    else if (text.startsWith('⚠') || text.toLowerCase().includes('warn')) kind = 'warn';
    else if (loss !== null) kind = 'dim';
    this.logLines.update(lines => [...lines.slice(-199), { text: loss !== null ? `step=${text.match(/\d+/)?.[0] ?? ''} loss=${loss?.toFixed(4)}` : text, kind }]);
    setTimeout(() => {
      if (this.logBody) {
        const el: HTMLElement = this.logBody.nativeElement;
        el.scrollTop = el.scrollHeight;
      }
    }, 0);
  }

  private drawChart() {
    const canvas = this.chartCanvas?.nativeElement;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const W = canvas.offsetWidth || 600;
    const H = canvas.height;
    canvas.width = W;
    ctx.clearRect(0, 0, W, H);

    const pts = this.lossPoints;
    if (pts.length < 2) {
      ctx.fillStyle = '#8b949e';
      ctx.font = '12px system-ui';
      ctx.textAlign = 'center';
      ctx.fillText('Waiting for training data…', W / 2, H / 2);
      return;
    }

    const pad = { t: 20, r: 20, b: 32, l: 52 };
    const chartW = W - pad.l - pad.r;
    const chartH = H - pad.t - pad.b;
    const losses = pts.map(p => p[1]);
    const minL = Math.min(...losses) * 0.95;
    const maxL = Math.max(...losses) * 1.05;
    const maxStep = pts[pts.length - 1][0] || 1;

    const xScale = (s: number) => pad.l + (s / maxStep) * chartW;
    const yScale = (l: number) => pad.t + chartH - ((l - minL) / (maxL - minL)) * chartH;

    // Grid lines
    ctx.strokeStyle = '#e4e4e4';
    ctx.lineWidth = 0.5;
    for (let i = 0; i <= 4; i++) {
      const y = pad.t + (chartH / 4) * i;
      ctx.beginPath(); ctx.moveTo(pad.l, y); ctx.lineTo(pad.l + chartW, y); ctx.stroke();
      const val = maxL - ((maxL - minL) / 4) * i;
      ctx.fillStyle = '#9e9e9e'; ctx.font = '10px system-ui'; ctx.textAlign = 'right';
      ctx.fillText(val.toFixed(3), pad.l - 6, y + 4);
    }

    // Y-axis label
    ctx.save();
    ctx.fillStyle = '#9e9e9e'; ctx.font = '9px system-ui'; ctx.textAlign = 'center';
    ctx.translate(12, pad.t + chartH / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText('Loss', 0, 0);
    ctx.restore();

    // Area fill
    ctx.beginPath();
    ctx.moveTo(xScale(pts[0][0]), yScale(pts[0][1]));
    for (let i = 1; i < pts.length; i++) ctx.lineTo(xScale(pts[i][0]), yScale(pts[i][1]));
    ctx.lineTo(xScale(pts[pts.length - 1][0]), pad.t + chartH);
    ctx.lineTo(xScale(pts[0][0]), pad.t + chartH);
    ctx.closePath();
    const grad = ctx.createLinearGradient(0, pad.t, 0, pad.t + chartH);
    grad.addColorStop(0, '#0854a030'); grad.addColorStop(1, '#0854a005');
    ctx.fillStyle = grad; ctx.fill();

    // Loss line
    ctx.beginPath();
    ctx.strokeStyle = '#0854a0'; ctx.lineWidth = 2; ctx.lineJoin = 'round';
    pts.forEach(([s, l], i) => i === 0 ? ctx.moveTo(xScale(s), yScale(l)) : ctx.lineTo(xScale(s), yScale(l)));
    ctx.stroke();

    // Eval overlay
    const ev = this.liveEval();
    if (ev) {
      ctx.strokeStyle = '#3fb950'; ctx.lineWidth = 1.5; ctx.setLineDash([4, 3]);
      const ey = yScale(ev.eval_loss);
      ctx.beginPath(); ctx.moveTo(pad.l, ey); ctx.lineTo(pad.l + chartW, ey); ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = '#3fb950'; ctx.font = 'bold 10px system-ui'; ctx.textAlign = 'left';
      ctx.fillText(`Final PPL ${ev.perplexity}`, pad.l + 4, ey - 3);
    }

    // X axis step labels
    ctx.fillStyle = '#9e9e9e'; ctx.font = '9px system-ui'; ctx.textAlign = 'center';
    [0, 0.25, 0.5, 0.75, 1].forEach(r => {
      const s = Math.round(r * maxStep);
      ctx.fillText(`Step ${s}`, xScale(s), H - 8);
    });
  }
}

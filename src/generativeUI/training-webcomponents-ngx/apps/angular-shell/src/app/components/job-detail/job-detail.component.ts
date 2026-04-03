import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit, OnDestroy, ElementRef, ViewChild, AfterViewInit, NgZone, Input
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
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
          <span class="badge badge-{{ job.status }}">{{ job.status }}</span>
          <span class="text-small text-muted">{{ job.config['model_name'] }}</span>
        </div>
        <div class="ws-indicator" [class.live]="wsConnected()">
          {{ wsConnected() ? i18n.t('app.live') : i18n.t('app.offline') }}
        </div>
      </div>

      <!-- Progress -->
      <div class="progress-row">
        <div class="progress-bar">
          <div class="progress-fill" [style.width]="liveProgress() + '%'"
               [class.animated]="liveStatus() === 'running'"></div>
        </div>
        <span class="progress-pct">{{ liveProgress().toFixed(0) }}%</span>
      </div>

      <!-- Loss Chart Canvas -->
      <div class="chart-section">
        <div class="chart-header">
          <span><ui5-icon name="line-chart"></ui5-icon> Training Loss Curve</span>
          @if (liveEval()) {
            <span class="eval-badge">PPL {{ liveEval()!.perplexity }} · Loss {{ liveEval()!.eval_loss }}</span>
          }
        </div>
        <canvas #chartCanvas class="loss-canvas" width="600" height="180"></canvas>
      </div>

      <!-- Live Terminal -->
      @if (logLines().length > 0) {
        <div class="terminal">
          <div class="terminal-head">Log Stream</div>
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
    .job-detail-panel { padding: 1rem; border-top: 1px solid #e4e4e4; background: #fafafa; }
    .detail-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem; gap: 0.5rem; }
    .detail-meta { display: flex; align-items: center; gap: 0.5rem; }
    .job-id { font-size: 0.75rem; background: #f0f0f0; padding: 2px 6px; border-radius: 4px; }
    .ws-indicator { font-size: 0.7rem; padding: 2px 8px; border-radius: 1rem;
      background: #f0f0f0; color: #666;
      &.live { background: #e8f5e9; color: #2e7d32; } }
    .badge { padding: 2px 8px; border-radius: 1rem; font-size: 0.7rem; font-weight: 600;
      &.badge-running { background: #e3f2fd; color: #1565c0; }
      &.badge-completed { background: #e8f5e9; color: #2e7d32; }
      &.badge-failed { background: #ffebee; color: #c62828; }
      &.badge-pending { background: #fff8e1; color: #f57f17; } }
    .progress-row { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }
    .progress-bar { flex: 1; height: 6px; background: #e0e0e0; border-radius: 3px; overflow: hidden; }
    .progress-fill { height: 100%; background: #0854a0; border-radius: 3px; transition: width 0.5s ease;
      &.animated { animation: pulse 2s ease-in-out infinite; }
    }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.6; } }
    .progress-pct { font-size: 0.75rem; color: #666; min-width: 35px; text-align: right; }
    .chart-section { background: #fff; border: 1px solid #e4e4e4; border-radius: 0.5rem; margin-bottom: 1rem; overflow: hidden; }
    .chart-header { display: flex; justify-content: space-between; align-items: center;
      padding: 0.5rem 0.75rem; background: #f5f5f5; font-size: 0.8rem; font-weight: 600; border-bottom: 1px solid #e4e4e4; }
    .eval-badge { background: #e8f5e9; color: #2e7d32; padding: 2px 8px; border-radius: 1rem; font-size: 0.75rem; font-weight: 600; }
    .loss-canvas { width: 100%; display: block; }
    .terminal { background: #0d1117; border-radius: 0.5rem; overflow: hidden; font-family: monospace; font-size: 0.75rem; }
    .terminal-head { background: #161b22; padding: 0.4rem 0.75rem; color: #8b949e; font-size: 0.7rem; font-weight: 600; }
    .terminal-body { padding: 0.5rem 0.75rem; max-height: 180px; overflow-y: auto; display: flex; flex-direction: column; gap: 0.1rem; }
    .log { color: #e6edf3; line-height: 1.4;
      &.line-success { color: #3fb950; }
      &.line-error { color: #f85149; }
      &.line-warn { color: #d29922; }
      &.line-dim { color: #8b949e; } }
  `]
})
export class JobDetailComponent implements OnInit, OnDestroy, AfterViewInit {
  @Input({ required: true }) job!: JobResponse;
  @ViewChild('chartCanvas') private chartCanvas!: ElementRef<HTMLCanvasElement>;
  @ViewChild('logBody') private logBody?: ElementRef;

  private readonly http = inject(HttpClient);
  readonly i18n = inject(I18nService);
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

    const pad = { t: 16, r: 16, b: 28, l: 48 };
    const chartW = W - pad.l - pad.r;
    const chartH = H - pad.t - pad.b;
    const losses = pts.map(p => p[1]);
    const minL = Math.min(...losses) * 0.95;
    const maxL = Math.max(...losses) * 1.05;
    const maxStep = pts[pts.length - 1][0] || 1;

    const xScale = (s: number) => pad.l + (s / maxStep) * chartW;
    const yScale = (l: number) => pad.t + chartH - ((l - minL) / (maxL - minL)) * chartH;

    // Grid
    ctx.strokeStyle = '#30363d22';
    ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const y = pad.t + (chartH / 4) * i;
      ctx.beginPath(); ctx.moveTo(pad.l, y); ctx.lineTo(pad.l + chartW, y); ctx.stroke();
      const val = maxL - ((maxL - minL) / 4) * i;
      ctx.fillStyle = '#8b949e'; ctx.font = '10px system-ui'; ctx.textAlign = 'right';
      ctx.fillText(val.toFixed(3), pad.l - 4, y + 3);
    }

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
    ctx.fillStyle = '#8b949e'; ctx.font = '9px system-ui'; ctx.textAlign = 'center';
    [0, 0.25, 0.5, 0.75, 1].forEach(r => {
      const s = Math.round(r * maxStep);
      ctx.fillText(String(s), xScale(s), H - 6);
    });
  }
}

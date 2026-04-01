import {
  Component,
  OnInit,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  inject,
  computed,
} from '@angular/core';
import { AppStore } from '../../store/app.store';
import { ToastService } from '../../services/toast.service';

interface PlatformComponent {
  icon: string;
  name: string;
  desc: string;
  status: 'healthy' | 'degraded' | 'down';
  statusLabel: string;
}

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">Dashboard</h1>
        <button class="refresh-btn" (click)="refresh()" [disabled]="store.isDashboardLoading()">
          @if (store.isDashboardLoading()) {
            <span class="spin">↻</span> Refreshing…
          } @else {
            ↻ Refresh
          }
        </button>
      </div>

      <!-- Skeleton Loading State -->
      @if (store.isDashboardLoading() && !store.health().data) {
        <div class="stats-grid">
          @for (i of skeletonCards; track i) {
            <div class="stat-card skeleton-card">
              <div class="skeleton shimmer skeleton-value"></div>
              <div class="skeleton shimmer skeleton-label"></div>
              <div class="skeleton shimmer skeleton-sub"></div>
            </div>
          }
        </div>
        <div class="dashboard-grid">
          <div class="info-card skeleton-card">
            <div class="skeleton shimmer skeleton-title"></div>
            @for (i of skeletonRows; track i) {
              <div class="skeleton shimmer skeleton-row"></div>
            }
          </div>
          <div class="info-card skeleton-card">
            <div class="skeleton shimmer skeleton-title"></div>
            @for (i of skeletonCards; track i) {
              <div class="skeleton shimmer skeleton-row"></div>
            }
          </div>
        </div>
      } @else {
        <!-- Stat Cards -->
        <div class="stats-grid">
          <div class="stat-card fade-in-up" [style.animation-delay]="'0ms'">
            <div class="card-accent"></div>
            <div class="stat-value">
              <span [class]="'status-badge ' + store.healthBadge()">{{ store.health().data?.status ?? '—' }}</span>
            </div>
            <div class="stat-label">Service Health</div>
            <div class="stat-sub">{{ store.health().data?.version ?? '' }}</div>
          </div>
          <div class="stat-card fade-in-up" [style.animation-delay]="'60ms'">
            <div class="card-accent"></div>
            <div class="stat-value-row">
              <svg class="gpu-gauge" viewBox="0 0 80 80">
                <circle class="gauge-bg" cx="40" cy="40" r="34" />
                <circle class="gauge-fill" cx="40" cy="40" r="34"
                  [style.stroke-dashoffset]="gaugeOffset()"
                  [style.stroke]="gaugeColor()" />
                <text x="40" y="44" class="gauge-text">{{ store.gpuUtilization() }}%</text>
              </svg>
              <div class="stat-text-group">
                <div class="stat-label">GPU Utilisation</div>
                <div class="stat-sub">{{ store.gpu().data?.gpu_name ?? 'No GPU' }}</div>
              </div>
            </div>
          </div>
          <div class="stat-card fade-in-up" [style.animation-delay]="'120ms'">
            <div class="card-accent"></div>
            <div class="stat-value">{{ store.gpuMemoryUsed() }}<span class="stat-unit"> GB</span></div>
            <div class="stat-label">GPU Memory Used</div>
            <div class="stat-sub">of {{ store.gpuMemoryTotal() }} GB total</div>
          </div>
          <div class="stat-card fade-in-up" [style.animation-delay]="'180ms'">
            <div class="card-accent"></div>
            <div class="stat-value">{{ store.trainingPairCount() }}</div>
            <div class="stat-label">Training Pairs</div>
            <div class="stat-sub">
              <span [class]="store.isGraphAvailable() ? 'trend-up' : 'trend-neutral'">
                {{ store.isGraphAvailable() ? '● Graph active' : '○ Graph unavailable' }}
              </span>
            </div>
          </div>
        </div>

        <!-- Detail Cards -->
        <div class="dashboard-grid">
          <div class="info-card fade-in-up" [style.animation-delay]="'240ms'">
            <h2 class="card-title">GPU Details</h2>
            @if (store.gpu().data; as gpuData) {
              <table class="info-table">
                <tbody>
                  <tr><td>Name</td><td>{{ gpuData.gpu_name }}</td></tr>
                  <tr><td>Driver</td><td>{{ gpuData.driver_version }}</td></tr>
                  <tr><td>CUDA</td><td>{{ gpuData.cuda_version }}</td></tr>
                  <tr><td>Temperature</td><td><span [class]="tempClass()">{{ gpuData.temperature_c }} °C</span></td></tr>
                  <tr><td>Free Memory</td><td>{{ gpuData.free_memory_gb.toFixed(1) }} GB</td></tr>
                </tbody>
              </table>
            } @else if (!store.isDashboardLoading()) {
              <p class="text-muted">GPU data unavailable</p>
            }
          </div>

          <div class="info-card fade-in-up" [style.animation-delay]="'300ms'">
            <h2 class="card-title">Platform Components</h2>
            <ul class="component-list">
              @for (c of components; track c.name) {
                <li class="comp-item">
                  <span class="comp-icon">{{ c.icon }}</span>
                  <div class="comp-info">
                    <span class="comp-name">{{ c.name }}</span>
                    <span class="comp-desc">{{ c.desc }}</span>
                  </div>
                  <span class="status-dot" [class]="'status-dot status-dot--' + c.status"></span>
                  <span class="comp-status">{{ c.statusLabel }}</span>
                </li>
              }
            </ul>
          </div>
        </div>
      }
    </div>
  `,
  styles: [`
    /* ── Refresh Button ── */
    .refresh-btn {
      padding: 0.375rem 0.875rem;
      background: var(--sapBrandColor, #0854a0);
      color: #fff;
      border: none;
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.875rem;
      display: inline-flex;
      align-items: center;
      gap: 0.375rem;
      transition: background 0.2s;
      &:disabled { opacity: 0.6; cursor: default; }
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }
    .spin { display: inline-block; animation: spin 1s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* ── Skeleton Loading ── */
    .skeleton {
      border-radius: 0.25rem;
      background: var(--sapTile_BorderColor, #e4e4e4);
    }
    .shimmer {
      background: linear-gradient(90deg,
        var(--sapTile_BorderColor, #e4e4e4) 25%,
        var(--sapList_Hover_Background, #f5f5f5) 50%,
        var(--sapTile_BorderColor, #e4e4e4) 75%);
      background-size: 200% 100%;
      animation: shimmer 1.5s ease-in-out infinite;
    }
    @keyframes shimmer { 0% { background-position: 200% 0; } 100% { background-position: -200% 0; } }
    .skeleton-card { min-height: 100px; }
    .skeleton-value { height: 2rem; width: 60%; margin-bottom: 0.5rem; }
    .skeleton-label { height: 0.75rem; width: 80%; margin-bottom: 0.375rem; }
    .skeleton-sub { height: 0.625rem; width: 50%; }
    .skeleton-title { height: 1rem; width: 40%; margin-bottom: 1rem; }
    .skeleton-row { height: 1.5rem; width: 100%; margin-bottom: 0.5rem; }

    /* ── Fade-in Animation ── */
    .fade-in-up {
      animation: fadeInUp 0.35s ease-out both;
    }
    @keyframes fadeInUp {
      from { opacity: 0; transform: translateY(12px); }
      to   { opacity: 1; transform: translateY(0); }
    }

    /* ── Stat Cards ── */
    .stat-card {
      position: relative;
      overflow: hidden;
      transition: box-shadow 0.2s, transform 0.2s;
      &:hover {
        box-shadow: 0 4px 16px rgba(0,0,0,0.08);
        transform: translateY(-2px);
      }
    }
    .card-accent {
      position: absolute;
      top: 0; left: 0; right: 0;
      height: 3px;
      background: linear-gradient(90deg, var(--sapBrandColor, #0854a0), #1a73e8);
      border-radius: 0.5rem 0.5rem 0 0;
    }
    .stat-unit { font-size: 1rem; font-weight: 400; color: var(--sapContent_LabelColor, #6a6d70); }
    .stat-sub {
      font-size: 0.7rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      margin-top: 0.25rem;
    }
    .stat-value-row {
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }
    .stat-text-group {
      display: flex;
      flex-direction: column;
      gap: 0.125rem;
    }

    /* ── Trend Indicators ── */
    .trend-up { color: #2e7d32; }
    .trend-down { color: #c62828; }
    .trend-neutral { color: var(--sapContent_LabelColor, #6a6d70); }

    /* ── GPU Gauge ── */
    .gpu-gauge { width: 64px; height: 64px; flex-shrink: 0; }
    .gauge-bg {
      fill: none;
      stroke: var(--sapTile_BorderColor, #e4e4e4);
      stroke-width: 6;
    }
    .gauge-fill {
      fill: none;
      stroke-width: 6;
      stroke-linecap: round;
      stroke-dasharray: 213.63;
      transform: rotate(-90deg);
      transform-origin: 50% 50%;
      transition: stroke-dashoffset 0.6s ease, stroke 0.6s ease;
    }
    .gauge-text {
      fill: var(--sapTextColor, #32363a);
      font-size: 14px;
      font-weight: 700;
      text-anchor: middle;
      dominant-baseline: middle;
    }

    /* ── Detail Cards ── */
    .dashboard-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
      gap: 1rem;
    }
    .info-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1.25rem;
      transition: box-shadow 0.2s, transform 0.2s;
      &:hover {
        box-shadow: 0 4px 16px rgba(0,0,0,0.06);
        transform: translateY(-1px);
      }
    }
    .card-title {
      font-size: 0.9375rem;
      font-weight: 600;
      margin: 0 0 1rem;
      color: var(--sapTextColor, #32363a);
    }
    .info-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.8125rem;
      td {
        padding: 0.4rem 0.5rem;
        border-bottom: 1px solid var(--sapTile_BorderColor, #e4e4e4);
        &:first-child {
          color: var(--sapContent_LabelColor, #6a6d70);
          width: 40%;
        }
      }
    }

    /* ── Platform Components ── */
    .component-list {
      list-style: none;
      padding: 0;
      margin: 0;
      display: flex;
      flex-direction: column;
      gap: 0;
    }
    .comp-item {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      padding: 0.625rem 0.5rem;
      border-radius: 0.375rem;
      transition: background 0.15s, transform 0.15s;
      &:hover {
        background: var(--sapList_Hover_Background, #f5f5f5);
        transform: translateX(2px);
      }
    }
    .comp-icon { font-size: 1.25rem; }
    .comp-info {
      flex: 1;
      display: flex;
      flex-direction: column;
      gap: 0.1rem;
    }
    .comp-name { font-size: 0.875rem; font-weight: 500; color: var(--sapTextColor, #32363a); }
    .comp-desc { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .comp-status { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .status-dot {
      width: 8px; height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
    }
    .status-dot--healthy { background: #2e7d32; box-shadow: 0 0 4px rgba(46,125,50,0.4); }
    .status-dot--degraded { background: #f57f17; box-shadow: 0 0 4px rgba(245,127,23,0.4); }
    .status-dot--down { background: #c62828; box-shadow: 0 0 4px rgba(198,40,40,0.4); }

    /* ── Temperature coloring ── */
    .temp-cool { color: #2e7d32; }
    .temp-warm { color: #f57f17; }
    .temp-hot { color: #c62828; font-weight: 600; }

    /* ── Responsive Grid ── */
    @media (max-width: 1023px) {
      :host .stats-grid { grid-template-columns: repeat(2, 1fr) !important; }
    }
    @media (min-width: 1024px) and (max-width: 1439px) {
      :host .stats-grid { grid-template-columns: repeat(2, 1fr) !important; }
    }
    @media (min-width: 1440px) {
      :host .stats-grid { grid-template-columns: repeat(4, 1fr) !important; gap: 1.25rem !important; }
    }
    @media (min-width: 1920px) {
      :host .stats-grid { gap: 1.5rem !important; }
      :host .dashboard-grid { gap: 1.5rem; }
    }
  `],
})
export class DashboardComponent implements OnInit {
  readonly store = inject(AppStore);
  private readonly toast = inject(ToastService);

  /** Skeleton placeholder arrays for @for loops */
  readonly skeletonCards = [1, 2, 3, 4];
  readonly skeletonRows = [1, 2, 3, 4, 5];

  /** Circumference of gauge circle: 2 * π * 34 ≈ 213.63 */
  private readonly CIRCUMFERENCE = 2 * Math.PI * 34;

  readonly components: PlatformComponent[] = [
    { icon: '🔄', name: 'Pipeline', desc: '7-stage Text-to-SQL data generation', status: 'healthy', statusLabel: 'Active' },
    { icon: '🤖', name: 'Model Optimizer', desc: 'FastAPI + NVIDIA ModelOpt', status: 'healthy', statusLabel: 'Active' },
    { icon: '🕸', name: 'HippoCPP', desc: 'Zig graph database engine', status: 'healthy', statusLabel: 'Active' },
    { icon: '📂', name: 'Data Assets', desc: 'Banking Excel/CSV training data', status: 'healthy', statusLabel: 'Ready' },
  ];

  /** GPU gauge offset: larger offset = less fill */
  readonly gaugeOffset = computed(() => {
    const pct = this.store.gpuUtilization();
    return this.CIRCUMFERENCE * (1 - pct / 100);
  });

  /** GPU gauge color: green→yellow→red based on utilization */
  readonly gaugeColor = computed(() => {
    const pct = this.store.gpuUtilization();
    if (pct < 50) return '#2e7d32';
    if (pct < 80) return '#f57f17';
    return '#c62828';
  });

  /** Temperature CSS class */
  readonly tempClass = computed(() => {
    const temp = this.store.gpu().data?.temperature_c ?? 0;
    if (temp < 60) return 'temp-cool';
    if (temp < 80) return 'temp-warm';
    return 'temp-hot';
  });

  ngOnInit(): void {
    this.store.loadDashboardData();
  }

  refresh(): void {
    this.store.forceRefresh('health');
    this.store.forceRefresh('gpu');
    this.store.forceRefresh('graphStats');
    this.toast.info('Refreshing dashboard data…');
  }
}
import {
  Component,
  OnInit,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  inject,
  computed,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
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
  imports: [CommonModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Dashboard</ui5-title>
        <ui5-button slot="endContent" icon="refresh" design="Transparent"
          (click)="refresh()" [disabled]="store.isDashboardLoading()">
          {{ store.isDashboardLoading() ? 'Refreshing…' : 'Refresh' }}
        </ui5-button>
      </ui5-bar>

      <div style="padding: 1.5rem; display: flex; flex-direction: column; gap: 1.5rem;">

        <!-- Skeleton Loading State -->
        @if (store.isDashboardLoading() && !store.health().data) {
          <ui5-busy-indicator active size="L" style="width: 100%; min-height: 200px;"></ui5-busy-indicator>
        } @else {
          <!-- Stat Cards -->
          <div class="stats-grid">
            <ui5-card class="fade-in-up" style="animation-delay: 0ms;">
              <ui5-card-header slot="header" title-text="Service Health"></ui5-card-header>
              <div style="padding: 1rem; text-align: center;">
                <ui5-tag [design]="store.healthBadge() === 'status-healthy' ? 'Positive' : store.healthBadge() === 'status-degraded' ? 'Critical' : 'Negative'">
                  {{ store.health().data?.status ?? '—' }}
                </ui5-tag>
                <div class="stat-sub">{{ store.health().data?.version ?? '' }}</div>
              </div>
            </ui5-card>
            <ui5-card class="fade-in-up" style="animation-delay: 60ms;">
              <ui5-card-header slot="header" title-text="GPU Utilisation"
                [subtitleText]="store.gpu().data?.gpu_name ?? 'No GPU'"></ui5-card-header>
              <div style="padding: 1rem; text-align: center;">
                <div class="stat-value-row" style="justify-content: center;">
                  <svg class="gpu-gauge" viewBox="0 0 80 80">
                    <circle class="gauge-bg" cx="40" cy="40" r="34" />
                    <circle class="gauge-fill" cx="40" cy="40" r="34"
                      [style.stroke-dashoffset]="gaugeOffset()"
                      [style.stroke]="gaugeColor()" />
                    <text x="40" y="44" class="gauge-text">{{ store.gpuUtilization() }}%</text>
                  </svg>
                </div>
              </div>
            </ui5-card>
            <ui5-card class="fade-in-up" style="animation-delay: 120ms;">
              <ui5-card-header slot="header" title-text="GPU Memory Used"
                [subtitleText]="'of ' + store.gpuMemoryTotal() + ' GB total'"></ui5-card-header>
              <div style="padding: 1rem; text-align: center;">
                <ui5-title level="H1">{{ store.gpuMemoryUsed() }}<span class="stat-unit"> GB</span></ui5-title>
              </div>
            </ui5-card>
            <ui5-card class="fade-in-up" style="animation-delay: 180ms;">
              <ui5-card-header slot="header" title-text="Training Pairs"></ui5-card-header>
              <div style="padding: 1rem; text-align: center;">
                <ui5-title level="H1">{{ store.trainingPairCount() }}</ui5-title>
                <div class="stat-sub">
                  <ui5-tag [design]="store.isGraphAvailable() ? 'Positive' : 'Negative'">
                    {{ store.isGraphAvailable() ? 'Graph active' : 'Graph unavailable' }}
                  </ui5-tag>
                </div>
              </div>
            </ui5-card>
          </div>

          <!-- Detail Cards -->
          <div class="dashboard-grid">
            <ui5-card class="fade-in-up" style="animation-delay: 240ms;">
              <ui5-card-header slot="header" title-text="GPU Details"></ui5-card-header>
              <div style="padding: 1rem;">
                @if (store.gpu().data; as gpuData) {
                  <ui5-list>
                    <ui5-list-item-standard description="Name">{{ gpuData.gpu_name }}</ui5-list-item-standard>
                    <ui5-list-item-standard description="Driver">{{ gpuData.driver_version }}</ui5-list-item-standard>
                    <ui5-list-item-standard description="CUDA">{{ gpuData.cuda_version }}</ui5-list-item-standard>
                    <ui5-list-item-standard description="Temperature">
                      <span [class]="tempClass()">{{ gpuData.temperature_c }} °C</span>
                    </ui5-list-item-standard>
                    <ui5-list-item-standard description="Free Memory">{{ gpuData.free_memory_gb.toFixed(1) }} GB</ui5-list-item-standard>
                  </ui5-list>
                } @else if (!store.isDashboardLoading()) {
                  <ui5-message-strip design="Information" hide-close-button>GPU data unavailable</ui5-message-strip>
                }
              </div>
            </ui5-card>

            <ui5-card class="fade-in-up" style="animation-delay: 300ms;">
              <ui5-card-header slot="header" title-text="Platform Components"></ui5-card-header>
              <div style="padding: 1rem;">
                <ui5-list>
                  @for (c of components; track c.name) {
                    <ui5-list-item-standard [description]="c.desc">
                      <span class="comp-icon" slot="icon">{{ c.icon }}</span>
                      {{ c.name }}
                      <ui5-tag slot="deleteButton"
                        [design]="c.status === 'healthy' ? 'Positive' : c.status === 'degraded' ? 'Critical' : 'Negative'">
                        {{ c.statusLabel }}
                      </ui5-tag>
                    </ui5-list-item-standard>
                  }
                </ui5-list>
              </div>
            </ui5-card>
          </div>
        }
      </div>
    </ui5-page>
  `,
  styles: [`
    /* ── Fade-in Animation ── */
    .fade-in-up {
      animation: fadeInUp 0.35s ease-out both;
    }
    @keyframes fadeInUp {
      from { opacity: 0; transform: translateY(12px); }
      to   { opacity: 1; transform: translateY(0); }
    }

    /* ── Stat Cards Grid ── */
    .stats-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem; }
    .stat-unit { font-size: 1rem; font-weight: 400; color: var(--sapContent_LabelColor, #6a6d70); }
    .stat-sub { font-size: 0.7rem; color: var(--sapContent_LabelColor, #6a6d70); margin-top: 0.25rem; }
    .stat-value-row { display: flex; align-items: center; gap: 0.75rem; }

    /* ── GPU Gauge ── */
    .gpu-gauge { width: 64px; height: 64px; flex-shrink: 0; }
    .gauge-bg { fill: none; stroke: var(--sapTile_BorderColor, #e4e4e4); stroke-width: 6; }
    .gauge-fill {
      fill: none; stroke-width: 6; stroke-linecap: round;
      stroke-dasharray: 213.63; transform: rotate(-90deg);
      transform-origin: 50% 50%; transition: stroke-dashoffset 0.6s ease, stroke 0.6s ease;
    }
    .gauge-text {
      fill: var(--sapTextColor, #32363a); font-size: 14px; font-weight: 700;
      text-anchor: middle; dominant-baseline: middle;
    }

    /* ── Detail Cards Grid ── */
    .dashboard-grid {
      display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem;
    }
    .comp-icon { font-size: 1.25rem; }

    /* ── Temperature coloring ── */
    .temp-cool { color: #2e7d32; }
    .temp-warm { color: #f57f17; }
    .temp-hot { color: #c62828; font-weight: 600; }

    /* ── Responsive Grid ── */
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
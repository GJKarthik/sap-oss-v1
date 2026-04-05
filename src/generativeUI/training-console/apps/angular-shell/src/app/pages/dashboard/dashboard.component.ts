import {
  Component,
  OnInit,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  inject,
  computed,
} from '@angular/core';
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
  tagDesign: string;
}

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [Ui5WebcomponentsModule],
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
        <ui5-busy-indicator [active]="store.isDashboardLoading() && !store.health().data" size="L"
          style="width: 100%;">

          <!-- Stat Cards -->
          <div class="stats-grid">
            <!-- Service Health -->
            <ui5-card>
              <ui5-card-header slot="header" title-text="Service Health"
                [subtitleText]="store.health().data?.version ?? ''"></ui5-card-header>
              <div style="padding: 1rem; display: flex; flex-direction: column; align-items: center; gap: 0.5rem;">
                <ui5-tag [design]="store.health().data?.status === 'healthy' ? 'Positive' : 'Negative'">
                  {{ store.health().data?.status ?? '—' }}
                </ui5-tag>
              </div>
            </ui5-card>

            <!-- GPU Utilisation -->
            <ui5-card>
              <ui5-card-header slot="header" title-text="GPU Utilisation"
                [subtitleText]="store.gpu().data?.gpu_name ?? 'No GPU'"></ui5-card-header>
              <div style="padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem;">
                <ui5-progress-indicator
                  [value]="store.gpuUtilization()"
                  [valueState]="gpuValueState()"
                  [displayValue]="store.gpuUtilization() + '%'">
                </ui5-progress-indicator>
              </div>
            </ui5-card>

            <!-- GPU Memory Used -->
            <ui5-card>
              <ui5-card-header slot="header" title-text="GPU Memory Used"
                [subtitleText]="'of ' + store.gpuMemoryTotal() + ' GB total'"></ui5-card-header>
              <div style="padding: 1rem; text-align: center;">
                <ui5-title level="H1">{{ store.gpuMemoryUsed() }} <span style="font-size: 1rem; font-weight: 400;">GB</span></ui5-title>
              </div>
            </ui5-card>

            <!-- Training Pairs -->
            <ui5-card>
              <ui5-card-header slot="header" title-text="Training Pairs"></ui5-card-header>
              <div style="padding: 1rem; text-align: center; display: flex; flex-direction: column; align-items: center; gap: 0.5rem;">
                <ui5-title level="H1">{{ store.trainingPairCount() }}</ui5-title>
                <ui5-tag [design]="store.isGraphAvailable() ? 'Positive' : 'Set2'">
                  {{ store.isGraphAvailable() ? 'Graph active' : 'Graph unavailable' }}
                </ui5-tag>
              </div>
            </ui5-card>
          </div>

          <!-- Detail Cards -->
          <div class="dashboard-grid">
            <!-- GPU Details -->
            <ui5-card>
              <ui5-card-header slot="header" title-text="GPU Details"
                subtitle-text="Hardware information"></ui5-card-header>
              <div style="padding: 0;">
                @if (store.gpu().data; as gpuData) {
                  <ui5-list>
                    <ui5-list-item-standard description="Name">
                      <ui5-text>{{ gpuData.gpu_name }}</ui5-text>
                    </ui5-list-item-standard>
                    <ui5-list-item-standard description="Driver">
                      <ui5-text>{{ gpuData.driver_version }}</ui5-text>
                    </ui5-list-item-standard>
                    <ui5-list-item-standard description="CUDA">
                      <ui5-text>{{ gpuData.cuda_version }}</ui5-text>
                    </ui5-list-item-standard>
                    <ui5-list-item-standard description="Temperature">
                      <ui5-tag [design]="tempTagDesign()">{{ gpuData.temperature_c }} °C</ui5-tag>
                    </ui5-list-item-standard>
                    <ui5-list-item-standard description="Free Memory">
                      <ui5-text>{{ gpuData.free_memory_gb.toFixed(1) }} GB</ui5-text>
                    </ui5-list-item-standard>
                  </ui5-list>
                } @else if (!store.isDashboardLoading()) {
                  <div style="padding: 1rem;">
                    <ui5-message-strip design="Warning" hide-close-button>GPU data unavailable</ui5-message-strip>
                  </div>
                }
              </div>
            </ui5-card>

            <!-- Platform Components -->
            <ui5-card>
              <ui5-card-header slot="header" title-text="Platform Components"
                subtitle-text="System services"></ui5-card-header>
              <div style="padding: 0;">
                <ui5-list>
                  @for (c of components; track c.name) {
                    <ui5-list-item-standard [description]="c.desc">
                      <ui5-icon slot="icon" [name]="c.icon"></ui5-icon>
                      {{ c.name }}
                      <ui5-tag slot="deleteButton" [design]="c.tagDesign">{{ c.statusLabel }}</ui5-tag>
                    </ui5-list-item-standard>
                  }
                </ui5-list>
              </div>
            </ui5-card>
          </div>

        </ui5-busy-indicator>
      </div>
    </ui5-page>
  `,
  styles: [`
    /* ── Layout Grids (UI5 doesn't dictate layout) ── */
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 1rem;
    }
    .dashboard-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
      gap: 1rem;
    }

    /* ── Responsive Grid ── */
    @media (max-width: 1023px) {
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

  readonly components: PlatformComponent[] = [
    { icon: 'synchronize', name: 'Pipeline', desc: '7-stage Text-to-SQL data generation', status: 'healthy', statusLabel: 'Active', tagDesign: 'Positive' },
    { icon: 'machine', name: 'Model Optimizer', desc: 'FastAPI + NVIDIA ModelOpt', status: 'healthy', statusLabel: 'Active', tagDesign: 'Positive' },
    { icon: 'database', name: 'HippoCPP', desc: 'Zig graph database engine', status: 'healthy', statusLabel: 'Active', tagDesign: 'Positive' },
    { icon: 'folder-full', name: 'Data Assets', desc: 'Banking Excel/CSV training data', status: 'healthy', statusLabel: 'Ready', tagDesign: 'Positive' },
  ];

  /** GPU utilization value-state for progress indicator */
  readonly gpuValueState = computed(() => {
    const pct = this.store.gpuUtilization();
    if (pct < 50) return 'Positive';
    if (pct < 80) return 'Critical';
    return 'Negative';
  });

  /** Temperature tag design */
  readonly tempTagDesign = computed(() => {
    const temp = this.store.gpu().data?.temperature_c ?? 0;
    if (temp < 60) return 'Positive';
    if (temp < 80) return 'Critical';
    return 'Negative';
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
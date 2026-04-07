import {
  Component,
  OnInit,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  inject,
  computed,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { AppStore } from '../../store/app.store';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';

interface PlatformComponent {
  icon: string;
  name: string;
  desc: string;
  status: string;
  badge: string;
}

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule, LocaleNumberPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid" class="dashboard-aura">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ i18n.t('nav.dashboard') }}</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="refresh()" [disabled]="store.isDashboardLoading()">
          {{ store.isDashboardLoading() ? i18n.t('dashboard.refreshing') : i18n.t('dashboard.refresh') }}
        </ui5-button>
      </ui5-bar>

      <div class="dashboard-content" role="main">
        <section class="hero-section" aria-label="Platform overview">
          <div class="hero-copy">
            <span class="eyebrow">{{ i18n.t('app.subtitle') }}</span>
            <ui5-title level="H2">{{ i18n.t('dashboard.welcome') }}</ui5-title>
            <p class="text-muted">{{ i18n.t('dashboard.heroDesc') }}</p>
          </div>
          
          <div class="status-overview">
            <ui5-card class="status-card glass-panel">
              <ui5-card-header slot="header" [title-text]="i18n.t('dashboard.platformHealth')" [subtitle-text]="i18n.t('dashboard.realtimeStatus')">
                <ui5-icon slot="avatar" name="electro-cardiac"></ui5-icon>
              </ui5-card-header>
              <div class="status-card-body">
                <div class="status-item">
                  <span class="status-label">{{ i18n.t('dashboard.coreService') }}</span>
                  <span class="status-value badge {{ store.healthBadge() }}">{{ store.health().data?.status ?? '—' }}</span>
                </div>
                <div class="status-item">
                  <span class="status-label">vLLM TurboQuant</span>
                  <span class="status-value badge {{ getDepBadge('vllm_turboquant') }}">{{ getDepStatus('vllm_turboquant') }}</span>
                </div>
                <div class="status-item">
                  <span class="status-label">HANA Vector Engine</span>
                  <span class="status-value badge {{ getDepBadge('hana_vector') }}">{{ getDepStatus('hana_vector') }}</span>
                </div>
              </div>
            </ui5-card>

            <ui5-card class="status-card glass-panel">
              <ui5-card-header slot="header" [title-text]="i18n.t('dashboard.computeStatus')" [subtitle-text]="store.gpu().data?.gpu_name ?? i18n.t('dashboard.noGpu')">
                <ui5-icon slot="avatar" name="it-host"></ui5-icon>
              </ui5-card-header>
              <div class="status-card-body">
                <div class="gpu-metric">
                  <div class="metric-top">
                    <span>VRAM {{ i18n.t('dashboard.utilization') }}</span>
                    <span>{{ store.gpuMemoryUsed() | localeNumber:'decimal':1:1 }} / {{ store.gpuMemoryTotal() | localeNumber:'decimal':1:1 }} GB</span>
                  </div>
                  <ui5-progress-indicator [value]="store.gpuUtilization()" display-value="{{ store.gpuUtilization() }}%"></ui5-progress-indicator>
                </div>
                <div class="status-item" style="margin-top: 0.5rem;">
                  <span class="status-label">{{ i18n.t('dashboard.cudaVersion') }}</span>
                  <span class="status-value text-muted">{{ store.gpu().data?.cuda_version ?? '—' }}</span>
                </div>
              </div>
            </ui5-card>
          </div>
        </section>

        <section class="components-grid">
          <ui5-title level="H4" style="margin-bottom: 1rem;">{{ i18n.t('dashboard.mainServices') }}</ui5-title>
          <div class="grid-layout">
            @for (comp of components; track comp.name) {
              <ui5-card class="service-card glass-panel" interactive (click)="navigateTo(comp)">
                <ui5-card-header slot="header" [title-text]="comp.name" [subtitle-text]="comp.status">
                  <ui5-icon slot="avatar" [name]="comp.icon"></ui5-icon>
                </ui5-card-header>
                <div class="card-body">
                  <p class="text-small text-muted">{{ comp.desc }}</p>
                  <ui5-button design="Transparent" icon="navigation-right-arrow" icon-end></ui5-button>
                </div>
              </ui5-card>
            }
          </div>
        </section>

        <section class="stats-footer">
          <ui5-message-strip design="Information" [hideCloseButton]="true">
            {{ i18n.t('dashboard.statsMsg', { count: store.trainingPairCount() | localeNumber }) }}
          </ui5-message-strip>
        </section>
      </div>
    </ui5-page>
  `,
  styles: [`
    .dashboard-aura {
      background: radial-gradient(circle at top left, rgba(0, 143, 211, 0.05), transparent 40%),
                  var(--sapBackgroundColor);
    }
    .dashboard-content { padding: 1.5rem; max-width: 1400px; margin: 0 auto; display: grid; gap: 2rem; }
    
    .hero-section { display: grid; grid-template-columns: 1fr 1.5fr; gap: 2rem; align-items: start; }
    @media (max-width: 1024px) { .hero-section { grid-template-columns: 1fr; } }

    .hero-copy { display: grid; gap: 0.5rem; }
    .eyebrow { display: inline-flex; width: fit-content; padding: 0.25rem 0.55rem; border-radius: 999px; background: var(--sapBrandColor); color: #fff; font-size: 0.7rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; }
    
    .glass-panel {
      background: rgba(255, 255, 255, 0.72) !important;
      backdrop-filter: blur(12px);
      border: 1px solid rgba(255, 255, 255, 0.4) !important;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.04) !important;
    }

    .status-overview { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem; }
    .status-card-body { padding: 1rem; display: grid; gap: 0.75rem; }
    .status-item { display: flex; justify-content: space-between; align-items: center; }
    .status-label { font-size: 0.875rem; color: var(--sapContent_LabelColor); }
    .status-value { font-size: 0.8125rem; font-weight: 600; }
    
    .badge { padding: 0.15rem 0.5rem; border-radius: 1rem; font-size: 0.75rem; }
    .status-success { background: var(--sapSuccessBackground, #e8f5e9); color: var(--sapPositiveColor, #2e7d32); }
    .status-error { background: var(--sapErrorBackground, #ffebee); color: var(--sapNegativeColor, #c62828); }
    .status-info { background: var(--sapInformationBackground, #e3f2fd); color: var(--sapInformativeColor, #1565c0); }
    .status-warning { background: var(--sapWarningBackground, #fff3e0); color: var(--sapCriticalColor, #e65100); }

    .gpu-metric { display: grid; gap: 0.35rem; }
    .metric-top { display: flex; justify-content: space-between; font-size: 0.75rem; color: var(--sapContent_LabelColor); }

    .grid-layout { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; }
    .service-card .card-body { padding: 0 1rem 1rem; display: flex; align-items: flex-end; justify-content: space-between; gap: 1rem; }
    .service-card .card-body p { margin: 0; line-height: 1.4; }

    .stats-footer { margin-top: 1rem; }
  `],
})
export class DashboardComponent implements OnInit {
  readonly store = inject(AppStore);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);

  get components(): PlatformComponent[] {
    return [
      { icon: 'process', name: this.i18n.t('nav.pipeline'), desc: 'Automated Text-to-SQL generation pipeline with Zig acceleration', status: 'Production', badge: 'status-success' },
      { icon: 'machine', name: this.i18n.t('nav.training'), desc: 'Model optimization and quantization center (NVIDIA ModelOpt)', status: 'Active', badge: 'status-success' },
      { icon: 'chain-link', name: 'HippoCPP Engine', desc: 'Embedded high-performance graph database for AI indexing', status: 'Ready', badge: 'status-info' },
      { icon: 'folder', name: this.i18n.t('nav.assets'), desc: 'Training data and schema registry manager', status: 'Ready', badge: 'status-info' },
    ];
  }

  ngOnInit(): void {
    this.store.loadDashboardData();
  }

  refresh(): void {
    this.store.forceRefresh('health');
    this.store.forceRefresh('gpu');
    this.store.forceRefresh('graphStats');
    this.toast.info(this.i18n.t('dashboard.refreshMsg'));
  }

  getDepStatus(key: string): string {
    const deps: any = this.store.health().data?.dependencies;
    return deps ? deps[key] || '—' : '—';
  }

  getDepBadge(key: string): string {
    const status = this.getDepStatus(key);
    if (status === 'healthy') return 'status-success';
    if (status === 'unconfigured') return 'status-warning';
    return 'status-error';
  }

  navigateTo(comp: PlatformComponent): void {
    if (comp.icon === 'process') window.location.href = '/training/pipeline';
    if (comp.icon === 'machine') window.location.href = '/training/training';
    if (comp.icon === 'folder') window.location.href = '/training/assets';
  }
}

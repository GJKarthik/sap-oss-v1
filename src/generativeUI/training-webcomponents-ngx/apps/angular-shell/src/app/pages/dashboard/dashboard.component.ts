import {
  Component,
  OnInit,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  inject,
} from '@angular/core';
import { AppStore } from '../../store/app.store';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
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
  imports: [LocaleNumberPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">{{ i18n.t('dashboard.title') }}</h1>
        <ui5-button design="Default" (click)="refresh()" [disabled]="store.isDashboardLoading()">
          {{ store.isDashboardLoading() ? i18n.t('dashboard.refreshing') : i18n.t('dashboard.refresh') }}
        </ui5-button>
      </div>

      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-value">
            <span [class]="'status-badge ' + store.healthBadge()">{{ store.health().data?.status ?? '—' }}</span>
          </div>
          <div class="stat-label">{{ i18n.t('dashboard.serviceHealth') }}</div>
          <div class="stat-sub">{{ store.health().data?.version ?? '' }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ store.gpuUtilization() | localeNumber:'decimal':0:0 }}%</div>
          <div class="stat-label">{{ i18n.t('dashboard.gpuUtil') }}</div>
          <div class="stat-sub">{{ store.gpu().data?.gpu_name ?? i18n.t('dashboard.noGpu') }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ store.gpuMemoryUsed() | localeNumber:'decimal':1:1 }}</div>
          <div class="stat-label">{{ i18n.t('dashboard.gpuMemUsed') }}</div>
          <div class="stat-sub">{{ i18n.t('dashboard.gpuMemTotal', { total: store.gpuMemoryTotal() }) }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ store.trainingPairCount() | localeNumber }}</div>
          <div class="stat-label">{{ i18n.t('dashboard.trainingPairs') }}</div>
          <div class="stat-sub">{{ store.isGraphAvailable() ? i18n.t('dashboard.graphActive') : i18n.t('dashboard.graphUnavailable') }}</div>
        </div>
      </div>

      <div class="dashboard-grid">
        <div class="info-card">
          <h2 class="card-title">{{ i18n.t('dashboard.gpuDetails') }}</h2>
          @if (store.gpu().data; as gpuData) {
            <table class="info-table" [attr.aria-label]="i18n.t('dashboard.gpuDetails')">
              <tbody>
                <tr><th scope="row">{{ i18n.t('dashboard.gpuName') }}</th><td>{{ gpuData.gpu_name }}</td></tr>
                <tr><th scope="row">{{ i18n.t('dashboard.gpuDriver') }}</th><td>{{ gpuData.driver_version }}</td></tr>
                <tr><th scope="row">{{ i18n.t('dashboard.gpuCuda') }}</th><td>{{ gpuData.cuda_version }}</td></tr>
                <tr><th scope="row">{{ i18n.t('dashboard.gpuTemp') }}</th><td>{{ gpuData.temperature_c }} °C</td></tr>
                <tr><th scope="row">{{ i18n.t('dashboard.gpuFreeMem') }}</th><td>{{ gpuData.free_memory_gb | localeNumber:'decimal':1:1 }} GB</td></tr>
              </tbody>
            </table>
          } @else if (!store.isDashboardLoading()) {
            <p class="text-muted">{{ i18n.t('dashboard.gpuUnavailable') }}</p>
          }
          @if (store.isDashboardLoading()) {
            <div class="loading-container" role="status" aria-live="polite">
              <span class="loading-text">{{ i18n.t('dashboard.loading') }}</span>
            </div>
          }
        </div>

        <div class="info-card">
          <h2 class="card-title">{{ i18n.t('dashboard.platformComponents') }}</h2>
          <ul class="component-list">
            @for (c of components; track c.name) {
              <li>
                <span class="comp-icon"><ui5-icon [name]="c.icon"></ui5-icon></span>
                <div class="comp-info">
                  <span class="comp-name">{{ c.name }}</span>
                  <span class="text-muted text-small">{{ c.desc }}</span>
                </div>
                <span class="status-badge {{ c.badge }}">{{ c.status }}</span>
              </li>
            }
          </ul>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .refresh-btn {
      padding: 0.375rem 0.875rem;
      background: var(--sapBrandColor, #0854a0);
      color: var(--sapButton_Emphasized_TextColor, #fff);
      border: none;
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.875rem;

      &:disabled { opacity: 0.5; cursor: default; }
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }

    .stat-sub {
      font-size: 0.7rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      margin-top: 0.25rem;
    }

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

      th, td {
        padding: 0.3rem 0.5rem;
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
      }

      th {
        color: var(--sapContent_LabelColor, #6a6d70);
        width: 40%;
        font-weight: normal;
        text-align: start;
      }
    }

    .component-list {
      list-style: none;
      padding: 0;
      margin: 0;
      display: flex;
      flex-direction: column;
      gap: 0.75rem;

      li {
        display: flex;
        align-items: center;
        gap: 0.75rem;
      }
    }

    .comp-icon {
      width: 1.875rem;
      height: 1.875rem;
      border-radius: 999px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      color: var(--sapBrandColor, #0854a0);
      background: var(--sapList_Background, #f5f5f5);
    }

    .comp-info {
      flex: 1;
      display: flex;
      flex-direction: column;
      gap: 0.1rem;
    }

    .comp-name { font-size: 0.875rem; font-weight: 500; }

    .loading-container {
      padding: 1rem;
      text-align: center;
    }

    .loading-text {
      color: var(--sapContent_LabelColor, #6a6d70);
      font-size: 0.875rem;
    }
  `],
})
export class DashboardComponent implements OnInit {
  readonly store = inject(AppStore);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);

  get components(): PlatformComponent[] {
    return [
      { icon: 'process', name: this.i18n.t('dashboard.comp.pipeline'), desc: this.i18n.t('dashboard.comp.pipelineDesc'), status: 'Active', badge: 'status-success' },
      { icon: 'machine', name: this.i18n.t('dashboard.comp.modelOpt'), desc: this.i18n.t('dashboard.comp.modelOptDesc'), status: 'Active', badge: 'status-success' },
      { icon: 'chain-link', name: this.i18n.t('dashboard.comp.hippocpp'), desc: this.i18n.t('dashboard.comp.hippocppDesc'), status: 'Active', badge: 'status-success' },
      { icon: 'folder', name: this.i18n.t('dashboard.comp.dataAssets'), desc: this.i18n.t('dashboard.comp.dataAssetsDesc'), status: 'Ready', badge: 'status-info' },
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
}

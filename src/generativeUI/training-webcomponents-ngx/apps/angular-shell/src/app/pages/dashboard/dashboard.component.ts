import {
  Component,
  OnInit,
  CUSTOM_ELEMENTS_SCHEMA,
  ChangeDetectionStrategy,
  inject,
} from '@angular/core';
import { DatePipe } from '@angular/common';
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
        <button class="refresh-btn" (click)="refresh()" [disabled]="store.isDashboardLoading()">
          {{ store.isDashboardLoading() ? i18n.t('dashboard.refreshing') : i18n.t('dashboard.refresh') }}
        </button>
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

      <div class="section-header">
        <h2 class="section-title">{{ i18n.t('dashboard.arabic.sectionTitle') }}</h2>
      </div>

      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-value">
            <span [class]="'status-badge ' + (store.arabicModelStatus() === 'online' ? 'status-success' : 'status-error')">
              {{ store.arabicModelStatus() === 'online' ? i18n.t('dashboard.arabic.online') : i18n.t('dashboard.arabic.offline') }}
            </span>
          </div>
          <div class="stat-label">{{ i18n.t('dashboard.arabic.modelStatus') }}</div>
          <div class="stat-sub">{{ store.arabicModelName() }}</div>
          @if (store.arabicModelStatus() === 'offline') {
            <button class="deploy-btn" (click)="deployArabicModel()" [disabled]="store.arabicDeploying()">
              {{ store.arabicDeploying() ? i18n.t('dashboard.arabic.deploying') : i18n.t('dashboard.arabic.deploy') }}
            </button>
          }
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ store.arabicPairCount() | localeNumber }}</div>
          <div class="stat-label">{{ i18n.t('dashboard.arabic.trainingData') }}</div>
          <div class="stat-sub">{{ i18n.t('dashboard.arabic.glossaryTerms', { count: store.arabicGlossaryCount() }) }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">
            <span [class]="'status-badge ' + (store.arabicOcrHealthy() ? 'status-success' : 'status-error')">
              {{ store.arabicOcrHealthy() ? i18n.t('dashboard.arabic.healthy') : i18n.t('dashboard.arabic.unhealthy') }}
            </span>
          </div>
          <div class="stat-label">{{ i18n.t('dashboard.arabic.ocrService') }}</div>
          <div class="stat-sub">{{ i18n.t('dashboard.arabic.ocrStats', { docs: store.arabicOcrDocsProcessed(), confidence: store.arabicOcrAvgConfidence() }) }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ store.arabicTranslationCoverage() | localeNumber:'decimal':1:1 }}%</div>
          <div class="stat-label">{{ i18n.t('dashboard.arabic.translationCoverage') }}</div>
          <div class="stat-sub">{{ i18n.t('dashboard.arabic.uiStringsTranslated') }}</div>
        </div>
      </div>

      @if (store.arabicMetrics().data; as metrics) {
        <div class="dashboard-grid">
          <div class="info-card">
            <h2 class="card-title">{{ i18n.t('dashboard.arabic.domainCoverage') }}</h2>
            <table class="info-table">
              <tbody>
                @for (entry of domainEntries(metrics.training_data.domain_coverage); track entry[0]) {
                  <tr>
                    <td>{{ entry[0] }}</td>
                    <td>
                      <div class="coverage-bar-container">
                        <div class="coverage-bar" [style.width.%]="entry[1]"></div>
                        <span class="coverage-pct">{{ entry[1] }}%</span>
                      </div>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
        </div>
      }

      <div class="dashboard-grid">
        <div class="info-card">
          <h2 class="card-title">{{ i18n.t('dashboard.gpuDetails') }}</h2>
          @if (store.gpu().data; as gpuData) {
            <table class="info-table">
              <tbody>
                <tr><td>{{ i18n.t('dashboard.gpuName') }}</td><td>{{ gpuData.gpu_name }}</td></tr>
                <tr><td>{{ i18n.t('dashboard.gpuDriver') }}</td><td>{{ gpuData.driver_version }}</td></tr>
                <tr><td>{{ i18n.t('dashboard.gpuCuda') }}</td><td>{{ gpuData.cuda_version }}</td></tr>
                <tr><td>{{ i18n.t('dashboard.gpuTemp') }}</td><td>{{ gpuData.temperature_c }} °C</td></tr>
                <tr><td>{{ i18n.t('dashboard.gpuFreeMem') }}</td><td>{{ gpuData.free_memory_gb | localeNumber:'decimal':1:1 }} GB</td></tr>
              </tbody>
            </table>
          } @else if (!store.isDashboardLoading()) {
            <p class="text-muted">{{ i18n.t('dashboard.gpuUnavailable') }}</p>
          }
          @if (store.isDashboardLoading()) {
            <div class="loading-container">
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
      color: #fff;
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

      td {
        padding: 0.3rem 0.5rem;
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);

        &:first-child {
          color: var(--sapContent_LabelColor, #6a6d70);
          width: 40%;
        }
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

    .section-header {
      margin: 1.5rem 0 0.5rem;
    }

    .section-title {
      font-size: 1.0625rem;
      font-weight: 600;
      color: var(--sapTextColor, #32363a);
      margin: 0;
    }

    .deploy-btn {
      margin-top: 0.5rem;
      padding: 0.25rem 0.75rem;
      background: var(--sapPositiveColor, #107e3e);
      color: #fff;
      border: none;
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.8125rem;

      &:disabled { opacity: 0.5; cursor: default; }
      &:hover:not(:disabled) { background: #0d6b34; }
    }

    .coverage-bar-container {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .coverage-bar {
      height: 0.5rem;
      background: var(--sapBrandColor, #0854a0);
      border-radius: 0.25rem;
      min-width: 0.25rem;
    }

    .coverage-pct {
      font-size: 0.75rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      min-width: 2.5rem;
    }
  `],
})
export class DashboardComponent implements OnInit {
  readonly store = inject(AppStore);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);

  readonly components: PlatformComponent[] = [
    { icon: 'process', name: 'Pipeline', desc: '7-stage Text-to-SQL data generation', status: 'Active', badge: 'status-success' },
    { icon: 'machine', name: 'Model Optimizer', desc: 'FastAPI + NVIDIA ModelOpt', status: 'Active', badge: 'status-success' },
    { icon: 'chain-link', name: 'HippoCPP', desc: 'Zig graph database engine', status: 'Active', badge: 'status-success' },
    { icon: 'folder', name: 'Data Assets', desc: 'Banking Excel/CSV training data', status: 'Ready', badge: 'status-info' },
    { icon: 'globe', name: 'Arabic AI Model', desc: 'Gemma 4 fine-tuned Arabic finance', status: 'Ready', badge: 'status-info' },
  ];

  ngOnInit(): void {
    this.store.loadDashboardData();
  }

  refresh(): void {
    this.store.forceRefresh('health');
    this.store.forceRefresh('gpu');
    this.store.forceRefresh('graphStats');
    this.store.forceRefresh('arabicMetrics');
    this.toast.info(this.i18n.t('dashboard.refreshMsg'));
  }

  deployArabicModel(): void {
    const jobs = this.store.completedJobs();
    if (jobs.length > 0) {
      this.store.deployArabicModel(jobs[0].id);
    } else {
      this.toast.error(this.i18n.t('dashboard.arabic.noCompletedJobs'));
    }
  }

  domainEntries(coverage: Record<string, number>): [string, number][] {
    return Object.entries(coverage);
  }
}
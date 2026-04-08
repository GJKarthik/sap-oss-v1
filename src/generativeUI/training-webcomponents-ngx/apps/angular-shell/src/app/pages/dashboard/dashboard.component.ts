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
import { Router } from '@angular/router';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';

interface PlatformComponent {
  icon: string;
  name: string;
  desc: string;
  route: string;
}

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule, LocaleNumberPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="dashboard-viewport fadeIn" [attr.aria-busy]="store.isDashboardLoading()">
      <!-- Floating Header -->
      <div class="glass-panel floating-header slideUp">
        <div class="header-left">
          <ui5-title level="H3">{{ i18n.t('nav.dashboard') }}</ui5-title>
          <span class="pulse-dot" [class.pulse-dot--active]="store.isHealthy()"></span>
        </div>
        <ui5-button design="Transparent" icon="refresh" (click)="refresh()" [disabled]="store.isDashboardLoading()">
          {{ store.isDashboardLoading() ? i18n.t('dashboard.refreshing') : i18n.t('dashboard.refresh') }}
        </ui5-button>
      </div>

      <div class="dashboard-scroll-area">
        <div class="dashboard-layout">
          <!-- Hero State -->
          <section class="hero-unibody">
            <div class="hero-text slideUp">
              <span class="material-label">{{ i18n.t('dashboard.productionIntelligence') }}</span>
              <ui5-title level="H1">{{ i18n.t('dashboard.welcome') }}</ui5-title>
              <p class="narrative-text" role="status" aria-live="polite">{{ i18n.t(store.platformNarrative()) }}</p>
            </div>
            
            <div class="telemetry-grid">
              <div class="glass-panel stat-material slideUp" [style.--stagger]="'0.1s'">
                <div class="stat-header">
                  <ui5-icon name="heart-2"></ui5-icon>
                  <span>{{ i18n.t('dashboard.platformHealth') }}</span>
                </div>
                <div class="stat-main">
                  <span class="stat-value">{{ store.health().data?.status ?? '—' }}</span>
                  <ui5-tag [design]="store.healthBadge()">{{ i18n.t('dashboard.coreService') }}</ui5-tag>
                </div>
                <div class="stat-footer">
                  <div class="mini-dep" [class.active]="getDepStatus('hana_vector') === 'healthy'">HANA</div>
                  <div class="mini-dep" [class.active]="getDepStatus('vllm_turboquant') === 'healthy'">vLLM</div>
                </div>
              </div>

              <div class="glass-panel stat-material slideUp" [style.--stagger]="'0.2s'">
                <div class="stat-header">
                  <ui5-icon name="it-host"></ui5-icon>
                  <span>{{ i18n.t('dashboard.computeStatus') }}</span>
                </div>
                <div class="stat-main">
                  <span class="stat-value">{{ store.gpuUtilization() }}%</span>
                  <span class="stat-label">{{ i18n.t('dashboard.vramUsage') }}</span>
                </div>
                <div class="progress-track">
                  <div class="progress-fill" [style.width.%]="store.gpuUtilization()"></div>
                </div>
              </div>
            </div>
          </section>

          <!-- Core Materials -->
          <section class="materials-section" aria-labelledby="dashboard-ecosystem-title">
            <ui5-title id="dashboard-ecosystem-title" level="H4" class="section-title">{{ i18n.t('dashboard.systemEcosystem') }}</ui5-title>
            <div class="materials-grid" role="list">
              @for (comp of components(); track comp.name; let i = $index) {
                <button
                     type="button"
                     class="glass-panel material-card slideUp"
                     [style.--stagger]="(0.3 + (i * 0.05)) + 's'"
                     [attr.aria-label]="comp.name + '. ' + comp.desc"
                     (click)="navigateTo(comp)">
                  <div class="material-icon-wrap">
                    <ui5-icon [name]="comp.icon"></ui5-icon>
                  </div>
                  <div class="material-content">
                    <ui5-title level="H5">{{ comp.name }}</ui5-title>
                    <p class="text-small">{{ comp.desc }}</p>
                  </div>
                  <div class="material-chevron">
                    <ui5-icon name="navigation-right-arrow"></ui5-icon>
                  </div>
                </button>
              }
            </div>
          </section>

          <!-- Insights Aura -->
          <footer class="insights-aura fadeIn" [style.--stagger]="'0.6s'">
            <div class="aura-message">
              <ui5-icon name="lightbulb"></ui5-icon>
              <span>{{ i18n.t('dashboard.insightsPrefix') }} <strong>{{ store.trainingPairCount() | localeNumber }}</strong> {{ i18n.t('dashboard.insightsSuffix') }}</span>
            </div>
          </footer>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .dashboard-viewport { height: 100%; display: flex; flex-direction: column; overflow: hidden; }
    .dashboard-scroll-area { flex: 1; overflow-y: auto; padding: 1rem 2rem 4rem; }
    .dashboard-layout { max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 3rem; }

    /* ── Floating Header ─────────────────────────────────────────────────── */
    .floating-header {
      margin: 1.5rem 2rem 0.5rem;
      padding: 0.75rem 1.5rem;
      display: flex; justify-content: space-between; align-items: center;
      z-index: 10; border-radius: 999px;
    }
    .header-left { display: flex; align-items: center; gap: 1rem; }
    .pulse-dot { width: 8px; height: 8px; background: var(--sapPositiveColor); border-radius: 50%; opacity: 0.3; }
    .pulse-dot--active { animation: dotPulse 2s infinite; opacity: 1; }
    @keyframes dotPulse { 0% { box-shadow: 0 0 0 0 rgba(46, 125, 50, 0.4); } 70% { box-shadow: 0 0 0 10px rgba(46, 125, 50, 0); } 100% { box-shadow: 0 0 0 0 rgba(46, 125, 50, 0); } }

    /* ── Hero Unibody ────────────────────────────────────────────────────── */
    .hero-unibody { display: grid; grid-template-columns: 1fr 1fr; gap: 4rem; align-items: center; margin-top: 2rem; }
    @media (max-width: 1024px) { .hero-unibody { grid-template-columns: 1fr; gap: 2rem; } }

    .material-label { font-size: 0.75rem; font-weight: 800; text-transform: uppercase; color: var(--sapBrandColor); letter-spacing: 0.1em; margin-bottom: 0.5rem; display: block; }
    .text-secondary { font-size: 1.125rem; line-height: 1.6; opacity: 0.7; max-width: 500px; }
    .narrative-text { font-size: 1.125rem; line-height: 1.6; opacity: 0.8; max-width: 500px; transition: opacity 0.6s var(--spring-easing); }

    .telemetry-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; }
    .slideUp, .fadeIn { animation-delay: var(--stagger, 0s); }
    .stat-material { padding: 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
    .stat-header { display: flex; align-items: center; gap: 0.75rem; font-size: 0.8125rem; font-weight: 600; opacity: 0.6; }
    .stat-main { display: flex; align-items: baseline; gap: 1rem; }
    .stat-value { font-size: 2.5rem; font-weight: 800; letter-spacing: -0.03em; }
    .stat-footer { display: flex; gap: 0.5rem; }
    .mini-dep { font-size: 0.65rem; font-weight: 800; padding: 0.2rem 0.5rem; border-radius: 4px; background: rgba(0,0,0,0.05); opacity: 0.4; }
    .mini-dep.active { background: var(--sapPositiveColor); color: #fff; opacity: 1; }

    .progress-track { width: 100%; height: 6px; background: rgba(0,0,0,0.05); border-radius: 3px; overflow: hidden; }
    .progress-fill { height: 100%; background: var(--sapBrandColor); border-radius: 3px; transition: width 1s var(--spring-easing); }

    /* ── Materials Grid ──────────────────────────────────────────────────── */
    .section-title { margin-bottom: 1.5rem; opacity: 0.8; }
    .materials-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1.5rem; }
    .material-card { 
      width: 100%; padding: 1.5rem; display: flex; align-items: center; gap: 1.5rem; cursor: pointer;
      border: none; color: inherit; text-align: left;
      &:hover { transform: scale(1.02) translateY(-5px); background: rgba(255, 255, 255, 0.95); }
      &:focus-visible { outline: 2px solid var(--sapBrandColor); outline-offset: 3px; }
    }
    .material-icon-wrap { width: 48px; height: 48px; border-radius: 12px; background: color-mix(in srgb, var(--sapBrandColor) 10%, transparent); display: flex; align-items: center; justify-content: center; color: var(--sapBrandColor); font-size: 1.5rem; }
    .material-content { flex: 1; }
    .material-content p { margin: 0.25rem 0 0; opacity: 0.6; }
    .material-chevron { opacity: 0.2; transition: opacity 0.2s; }
    .material-card:hover .material-chevron { opacity: 1; color: var(--sapBrandColor); }

    /* ── Insights Aura ───────────────────────────────────────────────────── */
    .insights-aura { padding: 2rem; border-radius: 2rem; background: linear-gradient(135deg, rgba(0, 143, 211, 0.05), rgba(161, 31, 133, 0.05)); border: 1px solid var(--glass-border); display: flex; justify-content: center; }
    .aura-message { display: flex; align-items: center; gap: 1rem; font-size: 0.9375rem; }
    .aura-message ui5-icon { color: #f57f17; }
  `],
})
export class DashboardComponent implements OnInit {
  readonly store = inject(AppStore);
  private readonly toast = inject(ToastService);
  private readonly router = inject(Router);
  readonly i18n = inject(I18nService);

  readonly components = computed<PlatformComponent[]>(() => [
    { icon: 'process', name: this.i18n.t('dashboard.comp.pipeline'), desc: this.i18n.t('dashboard.comp.pipelineDesc'), route: '/pipeline' },
    { icon: 'machine', name: this.i18n.t('dashboard.comp.modelOpt'), desc: this.i18n.t('dashboard.comp.modelOptDesc'), route: '/model-optimizer' },
    { icon: 'database', name: this.i18n.t('dashboard.comp.hanaCloud'), desc: this.i18n.t('dashboard.comp.hanaCloudDesc'), route: '/hana-explorer' },
    { icon: 'folder', name: this.i18n.t('dashboard.comp.dataAssets'), desc: this.i18n.t('dashboard.comp.dataAssetsDesc'), route: '/data-explorer' },
  ]);

  ngOnInit(): void { this.store.loadDashboardData(); }

  refresh(): void {
    this.store.forceRefresh();
    this.toast.info(this.i18n.t('dashboard.refreshMsg'));
  }

  getDepStatus(key: string): string {
    const deps: any = this.store.health().data?.dependencies;
    return deps ? deps[key] || '—' : '—';
  }

  navigateTo(comp: PlatformComponent): void {
    this.router.navigate([comp.route]);
  }
}

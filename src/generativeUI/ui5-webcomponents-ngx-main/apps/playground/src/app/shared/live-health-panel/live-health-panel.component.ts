import { Component, OnDestroy, OnInit } from '@angular/core';
import { Subject, takeUntil } from 'rxjs';
import {
  LiveDemoHealthService,
  ServiceCheck,
} from '../../core/live-demo-health.service';
import { I18nService } from '@ui5/webcomponents-ngx/i18n';

@Component({
  selector: 'playground-live-health-panel',
  templateUrl: './live-health-panel.component.html',
  styleUrls: ['./live-health-panel.component.scss'],
  standalone: false,
})
export class LiveHealthPanelComponent implements OnInit, OnDestroy {
  checks: ServiceCheck[] = [];
  blocking = true;
  loading = false;
  summaryText = '';
  lastCheckedAt: string | null = null;

  private readonly destroy$ = new Subject<void>();

  constructor(
    private readonly healthService: LiveDemoHealthService,
    private readonly i18nService: I18nService,
  ) {}

  ngOnInit(): void {
    this.refreshHealth();
  }

  refreshHealth(): void {
    this.loading = true;
    this.healthService
      .checkAllServices()
      .pipe(takeUntil(this.destroy$))
      .subscribe((checks) => {
        this.checks = checks;
        this.blocking = checks.some((check) => !check.ok);
        const key = this.blocking ? 'HEALTH_PANEL_UNAVAILABLE' : 'HEALTH_PANEL_HEALTHY';
        this.i18nService.getText(key).pipe(takeUntil(this.destroy$)).subscribe((text) => {
          this.summaryText = text;
        });
        this.lastCheckedAt = new Date().toISOString();
        this.loading = false;
      });
  }

  getCheckStatusText(check: ServiceCheck): string {
    if (check.ok) {
      return `Healthy (${check.status})`;
    }
    const suffix = check.error ? ` - ${check.error}` : '';
    return `Unavailable (${check.status || 'no status'})${suffix}`;
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}

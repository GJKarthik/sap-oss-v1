import { Component, OnDestroy, OnInit } from '@angular/core';
import { Subject, takeUntil } from 'rxjs';
import {
  ExperienceHealthService,
  ServiceCheck,
} from '../../core/experience-health.service';
import { I18nService } from '@ui5/webcomponents-ngx/i18n';

@Component({
  selector: 'ui-angular-service-health-panel',
  templateUrl: './service-health-panel.component.html',
  styleUrls: ['./service-health-panel.component.scss'],
  standalone: false,
})
export class ServiceHealthPanelComponent implements OnInit, OnDestroy {
  checks: ServiceCheck[] = [];
  blocking = true;
  allOffline = false;
  loading = false;
  summaryText = '';
  lastCheckedAt: string | null = null;

  private readonly destroy$ = new Subject<void>();

  constructor(
    private readonly healthService: ExperienceHealthService,
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
        this.allOffline = checks.length > 0 && checks.every(
          (check) => !check.ok && (check.status === 0 || check.status === undefined),
        );
        let key: string;
        if (this.allOffline) {
          key = 'HEALTH_PANEL_OFFLINE_MODE';
        } else if (this.blocking) {
          key = 'HEALTH_PANEL_UNAVAILABLE';
        } else {
          key = 'HEALTH_PANEL_HEALTHY';
        }
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

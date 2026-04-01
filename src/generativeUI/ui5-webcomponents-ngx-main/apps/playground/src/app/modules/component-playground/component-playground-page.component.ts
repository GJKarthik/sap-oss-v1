import { HttpClient } from '@angular/common/http';
import { Component, OnInit } from '@angular/core';
import { LiveDemoHealthService } from '../../core/live-demo-health.service';
import { environment } from '../../../environments/environment';

interface ModelsResponse {
  data?: Array<{ id?: string }>;
}

@Component({
  selector: 'playground-component-playground-page',
  templateUrl: './component-playground-page.component.html',
  styleUrls: ['./component-playground-page.component.scss'],
  standalone: false,
})
export class ComponentPlaygroundPageComponent implements OnInit {
  models: string[] = [];
  loading = false;
  lastError: string | null = null;
  routeBlocked = false;
  blockingReason = '';

  constructor(
    private readonly http: HttpClient,
    private readonly healthService: LiveDemoHealthService,
  ) {}

  ngOnInit(): void {
    this.healthService.checkRouteReadiness('components').subscribe((readiness) => {
      this.routeBlocked = readiness.blocking;
      const failed = readiness.checks.find((check) => !check.ok);
      this.blockingReason = failed
        ? `Live service required: ${failed.name} (${failed.status || 'no status'})`
        : '';
      if (!this.routeBlocked) {
        this.loadModels();
      }
    });
  }

  loadModels(): void {
    this.loading = true;
    this.lastError = null;
    const endpoint = `${environment.openAiBaseUrl.replace(/\/$/, '')}/v1/models`;
    this.http.get<ModelsResponse>(endpoint).subscribe({
      next: (response) => {
        const rawItems = response?.data ?? [];
        this.models = rawItems
          .map((item) => item.id?.trim())
          .filter((id): id is string => Boolean(id));
        const hasInvalidContract =
          Array.isArray(rawItems) &&
          rawItems.length > 0 &&
          this.models.length === 0;
        this.lastError = hasInvalidContract
          ? 'Invalid model catalog contract'
          : null;
        this.loading = false;
      },
      error: (error: { message?: string }) => {
        this.models = [];
        this.lastError = error?.message ?? 'Failed to load live model catalog';
        this.loading = false;
      },
    });
  }
}

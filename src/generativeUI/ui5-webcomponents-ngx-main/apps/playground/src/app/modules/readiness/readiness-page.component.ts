import { Component, OnInit } from '@angular/core';
import { Router } from '@angular/router';
import { forkJoin } from 'rxjs';
import { LiveDemoHealthService, ServiceCheck } from '../../core/live-demo-health.service';
import { DemoTourService } from '../../core/demo-tour.service';

type DemoRoute = 'generative' | 'joule' | 'components' | 'mcp';

interface RouteStatus {
  route: DemoRoute;
  label: string;
  blocking: boolean;
  reason: string;
}

@Component({
  selector: 'playground-readiness-page',
  templateUrl: './readiness-page.component.html',
  styleUrls: ['./readiness-page.component.scss'],
  standalone: false,
})
export class ReadinessPageComponent implements OnInit {
  loading = false;
  demoReady = false;
  lastCheckedAt: string | null = null;
  serviceChecks: ServiceCheck[] = [];
  routeStatuses: RouteStatus[] = [];

  constructor(
    private readonly healthService: LiveDemoHealthService,
    private readonly demoTour: DemoTourService,
    private readonly router: Router,
  ) {}

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    forkJoin({
      services: this.healthService.checkAllServices(),
      generative: this.healthService.checkRouteReadiness('generative'),
      joule: this.healthService.checkRouteReadiness('joule'),
      components: this.healthService.checkRouteReadiness('components'),
      mcp: this.healthService.checkRouteReadiness('mcp'),
    }).subscribe((result) => {
      this.serviceChecks = result.services;
      this.routeStatuses = [
        this.toStatus('generative', 'Generative Renderer', result.generative.blocking, result.generative.checks),
        this.toStatus('joule', 'Joule Chat', result.joule.blocking, result.joule.checks),
        this.toStatus('components', 'Component Playground', result.components.blocking, result.components.checks),
        this.toStatus('mcp', 'MCP Flow', result.mcp.blocking, result.mcp.checks),
      ];

      const servicesHealthy = this.serviceChecks.every((check) => check.ok);
      const routesHealthy = this.routeStatuses.every((route) => !route.blocking);
      this.demoReady = servicesHealthy && routesHealthy;
      this.lastCheckedAt = new Date().toISOString();
      this.loading = false;
    });
  }

  startDemo(): void {
    const firstStep = this.demoTour.start();
    this.router.navigate([firstStep.route]);
  }

  private toStatus(
    route: DemoRoute,
    label: string,
    blocking: boolean,
    checks: ServiceCheck[],
  ): RouteStatus {
    const failed = checks.find((check) => !check.ok);
    return {
      route,
      label,
      blocking,
      reason: failed
        ? `${failed.name} unavailable (${failed.status || 'no status'})`
        : 'Ready',
    };
  }
}

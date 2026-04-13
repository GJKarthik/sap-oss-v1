import { Component, OnInit } from '@angular/core';
import { Router } from '@angular/router';
import { forkJoin } from 'rxjs';
import {
  ExperienceHealthService,
  ExperienceRoute,
  ServiceCheck,
  StackLayerCheck,
} from '../../core/experience-health.service';
import { LearnPathService } from '../../core/learn-path.service';

interface RouteStatus {
  route: ExperienceRoute;
  labelKey: string;
  blocking: boolean;
  reason: string;
}

@Component({
  selector: 'ui-angular-readiness-page',
  templateUrl: './readiness-page.component.html',
  styleUrls: ['./readiness-page.component.scss'],
  standalone: false,
})
export class ReadinessPageComponent implements OnInit {
  loading = false;
  workspaceReady = false;
  lastCheckedAt: string | null = null;
  serviceChecks: ServiceCheck[] = [];
  stackLayers: StackLayerCheck[] = [];
  stackError: string | null = null;
  routeStatuses: RouteStatus[] = [];

  constructor(
    private readonly healthService: ExperienceHealthService,
    private readonly learnPath: LearnPathService,
    private readonly router: Router,
  ) {}

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    forkJoin({
      services: this.healthService.checkAllServices(),
      stack: this.healthService.fetchTrainingStack(),
      generative: this.healthService.checkRouteReadiness('generative'),
      joule: this.healthService.checkRouteReadiness('joule'),
      components: this.healthService.checkRouteReadiness('components'),
      mcp: this.healthService.checkRouteReadiness('mcp'),
      ocr: this.healthService.checkRouteReadiness('ocr'),
    }).subscribe((result) => {
      this.serviceChecks = result.services;
      this.stackLayers = result.stack.layers;
      this.stackError = result.stack.httpError ?? null;
      this.routeStatuses = [
        this.toStatus('generative', 'NAV_GENERATIVE', result.generative.blocking, result.generative.checks),
        this.toStatus('joule', 'NAV_JOULE', result.joule.blocking, result.joule.checks),
        this.toStatus('components', 'NAV_COMPONENTS', result.components.blocking, result.components.checks),
        this.toStatus('mcp', 'NAV_MCP', result.mcp.blocking, result.mcp.checks),
        this.toStatus('ocr', 'NAV_OCR', result.ocr.blocking, result.ocr.checks),
      ];

      const servicesHealthy = this.serviceChecks.every((check) => check.ok);
      const routesHealthy = this.routeStatuses.every((route) => !route.blocking);
      const stackOk = !result.stack.blocksWorkspace;
      this.workspaceReady = servicesHealthy && routesHealthy && stackOk;
      this.lastCheckedAt = new Date().toISOString();
      this.loading = false;
    });
  }

  openLearnPath(): void {
    const firstStep = this.learnPath.start();
    this.router.navigate([firstStep.route]);
  }

  private toStatus(
    route: ExperienceRoute,
    labelKey: string,
    blocking: boolean,
    checks: ServiceCheck[],
  ): RouteStatus {
    const failed = checks.find((check) => !check.ok);
    return {
      route,
      labelKey,
      blocking,
      reason: failed
        ? `${failed.name} (${failed.status || 'no status'})`
        : '',
    };
  }
}

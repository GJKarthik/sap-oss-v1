import { Component, OnInit, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ApiService } from '../../services/api.service';

interface GpuStatus {
  gpu_name: string;
  total_memory_gb: number;
  used_memory_gb: number;
  free_memory_gb: number;
  utilization_percent: number;
  temperature_c: number;
  driver_version: string;
  cuda_version: string;
}

interface GraphStats {
  available: boolean;
  pair_count: number;
}

interface HealthStatus {
  status: string;
  service: string;
  version: string;
}

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">Dashboard</h1>
        <button class="refresh-btn" (click)="loadAll()" [disabled]="loading">
          {{ loading ? 'Refreshing…' : '↻ Refresh' }}
        </button>
      </div>

      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-value">
            <span [class]="'status-badge ' + healthBadge">{{ health?.status ?? '—' }}</span>
          </div>
          <div class="stat-label">Service Health</div>
          <div class="stat-sub">{{ health?.version ?? '' }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ gpu?.utilization_percent ?? '—' }}%</div>
          <div class="stat-label">GPU Utilisation</div>
          <div class="stat-sub">{{ gpu?.gpu_name ?? 'No GPU' }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ gpuMemUsed }}</div>
          <div class="stat-label">GPU Memory Used</div>
          <div class="stat-sub">of {{ gpuMemTotal }} GB total</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ graphStats?.pair_count ?? '—' }}</div>
          <div class="stat-label">Training Pairs (Graph)</div>
          <div class="stat-sub">{{ graphStats?.available ? 'Graph store active' : 'Graph store unavailable' }}</div>
        </div>
      </div>

      <div class="dashboard-grid">
        <div class="info-card">
          <h2 class="card-title">GPU Details</h2>
          <table class="info-table" *ngIf="gpu">
            <tbody>
              <tr><td>Name</td><td>{{ gpu.gpu_name }}</td></tr>
              <tr><td>Driver</td><td>{{ gpu.driver_version }}</td></tr>
              <tr><td>CUDA</td><td>{{ gpu.cuda_version }}</td></tr>
              <tr><td>Temperature</td><td>{{ gpu.temperature_c }} °C</td></tr>
              <tr><td>Free Memory</td><td>{{ gpu.free_memory_gb.toFixed(1) }} GB</td></tr>
            </tbody>
          </table>
          <p class="text-muted" *ngIf="!gpu && !loading">GPU data unavailable</p>
          <div class="loading-container" *ngIf="loading">
            <span class="loading-text">Loading…</span>
          </div>
        </div>

        <div class="info-card">
          <h2 class="card-title">Platform Components</h2>
          <ul class="component-list">
            <li *ngFor="let c of components">
              <span class="comp-icon">{{ c.icon }}</span>
              <div class="comp-info">
                <span class="comp-name">{{ c.name }}</span>
                <span class="text-muted text-small">{{ c.desc }}</span>
              </div>
              <span class="status-badge {{ c.badge }}">{{ c.status }}</span>
            </li>
          </ul>
        </div>
      </div>

      <div class="error-banner" *ngIf="error">⚠ {{ error }}</div>
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

    .comp-icon { font-size: 1.25rem; }

    .comp-info {
      flex: 1;
      display: flex;
      flex-direction: column;
      gap: 0.1rem;
    }

    .comp-name { font-size: 0.875rem; font-weight: 500; }

    .error-banner {
      margin-top: 1rem;
      padding: 0.75rem 1rem;
      background: #ffebee;
      color: #c62828;
      border-radius: 0.25rem;
      font-size: 0.875rem;
    }
  `],
})
export class DashboardComponent implements OnInit {
  health: HealthStatus | null = null;
  gpu: GpuStatus | null = null;
  graphStats: GraphStats | null = null;
  loading = false;
  error = '';

  components = [
    { icon: '🔄', name: 'Pipeline', desc: '7-stage Text-to-SQL data generation', status: 'Active', badge: 'status-success' },
    { icon: '🤖', name: 'Model Optimizer', desc: 'FastAPI + NVIDIA ModelOpt', status: 'Active', badge: 'status-success' },
    { icon: '🕸', name: 'HippoCPP', desc: 'Zig graph database engine', status: 'Active', badge: 'status-success' },
    { icon: '📂', name: 'Data Assets', desc: 'Banking Excel/CSV training data', status: 'Ready', badge: 'status-info' },
  ];

  get healthBadge(): string {
    return this.health?.status === 'healthy' ? 'status-success' : 'status-error';
  }

  get gpuMemUsed(): string {
    return this.gpu ? this.gpu.used_memory_gb.toFixed(1) : '—';
  }

  get gpuMemTotal(): string {
    return this.gpu ? this.gpu.total_memory_gb.toFixed(1) : '—';
  }

  constructor(private api: ApiService) {}

  ngOnInit(): void {
    this.loadAll();
  }

  loadAll(): void {
    this.loading = true;
    this.error = '';

    this.api.get<HealthStatus>('/health').subscribe({
      next: (h) => (this.health = h),
      error: () => (this.error = 'Could not reach backend at /api/health'),
    });

    this.api.get<GpuStatus>('/gpu/status').subscribe({
      next: (g) => (this.gpu = g),
      error: () => {},
    });

    this.api.get<GraphStats>('/graph/stats').subscribe({
      next: (s) => (this.graphStats = s),
      error: () => {},
      complete: () => (this.loading = false),
    });
  }
}

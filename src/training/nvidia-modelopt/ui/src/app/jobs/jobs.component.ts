import { Component, OnInit, OnDestroy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { interval, Subscription } from 'rxjs';
import { switchMap } from 'rxjs/operators';
import { ApiService, Job } from '../services/api.service';

@Component({
  selector: 'app-jobs',
  standalone: true,
  imports: [CommonModule, FormsModule],
  providers: [ApiService],
  template: `
    <div class="jobs-container">
      <header class="page-header">
        <h1>Optimization Jobs</h1>
        <button class="btn-primary" (click)="showCreateModal = true">+ New Job</button>
      </header>

      <!-- Job Stats -->
      <div class="job-stats">
        <div class="stat-card">
          <div class="stat-value">{{ getJobCount('pending') }}</div>
          <div class="stat-label">Pending</div>
        </div>
        <div class="stat-card running">
          <div class="stat-value">{{ getJobCount('running') }}</div>
          <div class="stat-label">Running</div>
        </div>
        <div class="stat-card completed">
          <div class="stat-value">{{ getJobCount('completed') }}</div>
          <div class="stat-label">Completed</div>
        </div>
        <div class="stat-card failed">
          <div class="stat-value">{{ getJobCount('failed') }}</div>
          <div class="stat-label">Failed</div>
        </div>
      </div>

      <!-- Jobs Table -->
      <div class="jobs-table">
        <div class="table-header">
          <span>Job</span>
          <span>Model</span>
          <span>Format</span>
          <span>Status</span>
          <span>Progress</span>
          <span>Actions</span>
        </div>
        <div class="table-row" *ngFor="let job of jobs" [class]="'status-' + job.status">
          <span class="job-name">{{ job.name }}</span>
          <span class="job-model">{{ job.config?.model_name | slice:0:20 }}</span>
          <span class="job-format">{{ job.config?.quant_format | uppercase }}</span>
          <span class="job-status">
            <span class="status-badge" [class]="job.status">{{ job.status | uppercase }}</span>
          </span>
          <span class="job-progress">
            <div class="progress-bar" *ngIf="job.status === 'running'">
              <div class="progress" [style.width.%]="job.progress"></div>
            </div>
            <span class="progress-text">{{ job.progress | number:'1.0-0' }}%</span>
          </span>
          <span class="job-actions">
            <button *ngIf="job.status === 'pending' || job.status === 'running'"
                    class="btn-cancel" (click)="cancelJob(job.id)">Cancel</button>
            <button *ngIf="job.status === 'completed'"
                    class="btn-view" (click)="viewOutput(job)">View</button>
            <button *ngIf="job.status === 'failed'"
                    class="btn-retry" (click)="retryJob(job)">Retry</button>
          </span>
        </div>
        <div *ngIf="jobs.length === 0" class="no-jobs">
          No jobs yet. Click "+ New Job" to create one.
        </div>
      </div>

      <!-- Create Job Modal -->
      <div class="modal-overlay" *ngIf="showCreateModal" (click)="showCreateModal = false">
        <div class="modal" (click)="$event.stopPropagation()">
          <h2>Create Optimization Job</h2>
          <form (ngSubmit)="createJob()">
            <div class="form-group">
              <label>Model</label>
              <select [(ngModel)]="newJob.model_name" name="model_name">
                <option value="Qwen/Qwen3.5-0.6B">Qwen3.5-0.6B (0.6B params)</option>
                <option value="Qwen/Qwen3.5-1.8B">Qwen3.5-1.8B (1.8B params)</option>
                <option value="Qwen/Qwen3.5-4B">Qwen3.5-4B (4B params)</option>
                <option value="Qwen/Qwen3.5-9B">Qwen3.5-9B (9B params)</option>
              </select>
            </div>
            <div class="form-group">
              <label>Quantization Format</label>
              <select [(ngModel)]="newJob.quant_format" name="quant_format">
                <option value="int8">INT8 (2x compression, best quality)</option>
                <option value="int4_awq">INT4 AWQ (4x compression)</option>
                <option value="w4a16">W4A16 (4x compression, weight-only)</option>
              </select>
            </div>
            <div class="form-group">
              <label>Calibration Samples</label>
              <input type="number" [(ngModel)]="newJob.calib_samples" name="calib_samples" min="32" max="2048">
            </div>
            <div class="form-group">
              <label>Export Format</label>
              <select [(ngModel)]="newJob.export_format" name="export_format">
                <option value="hf">Hugging Face</option>
                <option value="tensorrt_llm">TensorRT-LLM</option>
                <option value="vllm">vLLM</option>
              </select>
            </div>
            <div class="form-actions">
              <button type="button" class="btn-secondary" (click)="showCreateModal = false">Cancel</button>
              <button type="submit" class="btn-primary">Create Job</button>
            </div>
          </form>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .jobs-container { padding: 20px; max-width: 1200px; margin: 0 auto; }
    .page-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
    .page-header h1 { margin: 0; color: #333; }
    .btn-primary { padding: 10px 20px; background: #76b900; color: white; border: none; border-radius: 4px; cursor: pointer; }
    .btn-primary:hover { background: #5a8f00; }
    .job-stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 15px; margin-bottom: 20px; }
    .stat-card { background: white; border-radius: 8px; padding: 20px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    .stat-card .stat-value { font-size: 32px; font-weight: bold; color: #333; }
    .stat-card .stat-label { color: #666; font-size: 14px; }
    .stat-card.running .stat-value { color: #1565c0; }
    .stat-card.completed .stat-value { color: #2e7d32; }
    .stat-card.failed .stat-value { color: #c62828; }
    .jobs-table { background: white; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); overflow: hidden; }
    .table-header, .table-row { display: grid; grid-template-columns: 2fr 2fr 1fr 1fr 2fr 1fr; padding: 15px; align-items: center; }
    .table-header { background: #f5f5f5; font-weight: 600; border-bottom: 1px solid #e0e0e0; }
    .table-row { border-bottom: 1px solid #f0f0f0; }
    .table-row:last-child { border-bottom: none; }
    .status-badge { padding: 4px 8px; border-radius: 4px; font-size: 12px; font-weight: 500; }
    .status-badge.pending { background: #fff3e0; color: #e65100; }
    .status-badge.running { background: #e3f2fd; color: #1565c0; }
    .status-badge.completed { background: #e8f5e9; color: #2e7d32; }
    .status-badge.failed { background: #ffebee; color: #c62828; }
    .status-badge.cancelled { background: #f5f5f5; color: #666; }
    .job-progress { display: flex; align-items: center; gap: 10px; }
    .progress-bar { flex: 1; height: 8px; background: #e0e0e0; border-radius: 4px; overflow: hidden; }
    .progress-bar .progress { height: 100%; background: #76b900; transition: width 0.3s; }
    .progress-text { font-size: 12px; color: #666; min-width: 40px; }
    .btn-cancel { padding: 5px 10px; background: #dc3545; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; }
    .btn-view { padding: 5px 10px; background: #2196f3; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; }
    .btn-retry { padding: 5px 10px; background: #ff9800; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; }
    .no-jobs { padding: 40px; text-align: center; color: #666; }
    .modal-overlay { position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 1000; }
    .modal { background: white; border-radius: 8px; padding: 30px; width: 500px; max-width: 90%; }
    .modal h2 { margin: 0 0 20px 0; }
    .form-group { margin-bottom: 15px; }
    .form-group label { display: block; margin-bottom: 5px; font-weight: 500; }
    .form-group input, .form-group select { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; }
    .form-actions { display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px; }
    .btn-secondary { padding: 10px 20px; background: transparent; color: #666; border: 1px solid #ddd; border-radius: 4px; cursor: pointer; }
  `]
})
export class JobsComponent implements OnInit, OnDestroy {
  jobs: Job[] = [];
  showCreateModal = false;
  newJob = {
    model_name: 'Qwen/Qwen3.5-1.8B',
    quant_format: 'int8',
    calib_samples: 512,
    export_format: 'hf'
  };
  private pollSub?: Subscription;

  constructor(private api: ApiService) {}

  ngOnInit(): void {
    this.loadJobs();
    this.pollSub = interval(3000).pipe(
      switchMap(() => this.api.listJobs())
    ).subscribe((jobs) => this.jobs = jobs);
  }

  ngOnDestroy(): void {
    this.pollSub?.unsubscribe();
  }

  loadJobs(): void {
    this.api.listJobs().subscribe((jobs) => this.jobs = jobs);
  }

  getJobCount(status: string): number {
    return this.jobs.filter(j => j.status === status).length;
  }

  createJob(): void {
    const config = {
      config: {
        model_name: this.newJob.model_name,
        quant_format: this.newJob.quant_format,
        calib_samples: this.newJob.calib_samples,
        export_format: this.newJob.export_format,
        enable_pruning: false,
        pruning_sparsity: 0.2
      }
    };
    this.api.createJob(config).subscribe({
      next: () => {
        this.showCreateModal = false;
        this.loadJobs();
      },
      error: (err) => console.error('Create job error:', err)
    });
  }

  cancelJob(jobId: string): void {
    this.api.cancelJob(jobId).subscribe(() => this.loadJobs());
  }

  viewOutput(job: Job): void {
    alert(`Output path: ${job.output_path || 'N/A'}`);
  }

  retryJob(job: Job): void {
    const config = { config: job.config };
    this.api.createJob(config).subscribe(() => this.loadJobs());
  }
}
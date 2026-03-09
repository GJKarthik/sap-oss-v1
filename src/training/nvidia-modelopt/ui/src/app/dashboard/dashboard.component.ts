import { Component, OnInit, OnDestroy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClientModule } from '@angular/common/http';
import { interval, Subscription } from 'rxjs';
import { switchMap } from 'rxjs/operators';

import { ApiService, Model, Job, GpuStatus } from '../services/api.service';

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, FormsModule, HttpClientModule],
  providers: [ApiService],
  template: `
    <div class="dashboard">
      <header class="header">
        <h1>NVIDIA Model Optimizer</h1>
        <span class="status" [class.healthy]="isHealthy" [class.error]="!isHealthy">
          {{ isHealthy ? '● Connected' : '○ Disconnected' }}
        </span>
      </header>

      <!-- GPU Status Card -->
      <section class="card gpu-card">
        <h2>GPU Status</h2>
        <div *ngIf="gpuStatus" class="gpu-info">
          <div class="gpu-main">
            <div class="gpu-name">{{ gpuStatus.gpu_name }}</div>
            <div class="gpu-compute">Compute {{ gpuStatus.compute_capability }}</div>
          </div>
          <div class="gpu-metrics">
            <div class="metric">
              <span class="label">Memory</span>
              <span class="value">{{ gpuStatus.used_memory_gb | number:'1.1-1' }} / {{ gpuStatus.total_memory_gb | number:'1.1-1' }} GB</span>
              <div class="progress-bar">
                <div class="progress" [style.width.%]="(gpuStatus.used_memory_gb / gpuStatus.total_memory_gb) * 100"></div>
              </div>
            </div>
            <div class="metric">
              <span class="label">Utilization</span>
              <span class="value">{{ gpuStatus.utilization_percent }}%</span>
              <div class="progress-bar">
                <div class="progress" [style.width.%]="gpuStatus.utilization_percent"></div>
              </div>
            </div>
            <div class="metric">
              <span class="label">Temperature</span>
              <span class="value">{{ gpuStatus.temperature_c }}°C</span>
            </div>
          </div>
          <div class="gpu-formats">
            <span class="label">Supported Formats:</span>
            <span class="format" *ngFor="let fmt of gpuStatus.supported_formats">{{ fmt }}</span>
          </div>
        </div>
        <div *ngIf="!gpuStatus" class="loading">Loading GPU status...</div>
      </section>

      <!-- Models Card -->
      <section class="card models-card">
        <h2>Available Models</h2>
        <div class="model-list">
          <div class="model-item" *ngFor="let model of models">
            <div class="model-id">{{ model.id }}</div>
            <div class="model-owner">{{ model.owned_by }}</div>
          </div>
        </div>
      </section>

      <!-- Create Job Card -->
      <section class="card create-job-card">
        <h2>Create Optimization Job</h2>
        <form (ngSubmit)="createJob()">
          <div class="form-group">
            <label>Model</label>
            <select [(ngModel)]="newJob.model_name" name="model_name">
              <option value="Qwen/Qwen3.5-0.6B">Qwen3.5-0.6B</option>
              <option value="Qwen/Qwen3.5-1.8B">Qwen3.5-1.8B</option>
              <option value="Qwen/Qwen3.5-4B">Qwen3.5-4B</option>
              <option value="Qwen/Qwen3.5-9B">Qwen3.5-9B</option>
            </select>
          </div>
          <div class="form-group">
            <label>Quantization Format</label>
            <select [(ngModel)]="newJob.quant_format" name="quant_format">
              <option value="int8">INT8 (2x compression)</option>
              <option value="int4_awq">INT4 AWQ (4x compression)</option>
              <option value="w4a16">W4A16 (4x compression)</option>
            </select>
          </div>
          <div class="form-group">
            <label>Calibration Samples</label>
            <input type="number" [(ngModel)]="newJob.calib_samples" name="calib_samples" min="32" max="2048">
          </div>
          <button type="submit" class="btn-primary">Create Job</button>
        </form>
      </section>

      <!-- Jobs List -->
      <section class="card jobs-card">
        <h2>Optimization Jobs</h2>
        <div class="job-list">
          <div class="job-item" *ngFor="let job of jobs" [class]="'status-' + job.status">
            <div class="job-header">
              <span class="job-name">{{ job.name }}</span>
              <span class="job-status">{{ job.status | uppercase }}</span>
            </div>
            <div class="job-progress" *ngIf="job.status === 'running'">
              <div class="progress-bar">
                <div class="progress" [style.width.%]="job.progress"></div>
              </div>
              <span>{{ job.progress | number:'1.0-0' }}%</span>
            </div>
            <div class="job-details">
              <span>{{ job.config.model_name }}</span>
              <span>{{ job.config.quant_format }}</span>
            </div>
            <div class="job-actions">
              <button *ngIf="job.status === 'pending' || job.status === 'running'" 
                      (click)="cancelJob(job.id)" class="btn-danger">Cancel</button>
            </div>
          </div>
          <div *ngIf="jobs.length === 0" class="no-jobs">No jobs yet</div>
        </div>
      </section>
    </div>
  `,
  styles: [`
    .dashboard {
      padding: 20px;
      max-width: 1200px;
      margin: 0 auto;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 20px;
    }
    .header h1 {
      margin: 0;
      color: #76b900;
    }
    .status {
      padding: 5px 10px;
      border-radius: 4px;
      font-size: 14px;
    }
    .status.healthy { color: #76b900; }
    .status.error { color: #dc3545; }
    .card {
      background: #fff;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      padding: 20px;
      margin-bottom: 20px;
    }
    .card h2 {
      margin: 0 0 15px 0;
      font-size: 18px;
      color: #333;
    }
    .gpu-card .gpu-info { display: grid; gap: 15px; }
    .gpu-main { display: flex; justify-content: space-between; align-items: center; }
    .gpu-name { font-size: 24px; font-weight: bold; color: #76b900; }
    .gpu-compute { color: #666; }
    .gpu-metrics { display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; }
    .metric { text-align: center; }
    .metric .label { display: block; color: #666; font-size: 12px; }
    .metric .value { display: block; font-size: 18px; font-weight: bold; }
    .progress-bar {
      height: 8px;
      background: #e0e0e0;
      border-radius: 4px;
      margin-top: 5px;
      overflow: hidden;
    }
    .progress-bar .progress {
      height: 100%;
      background: #76b900;
      border-radius: 4px;
      transition: width 0.3s ease;
    }
    .gpu-formats {
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
    }
    .gpu-formats .format {
      background: #e8f5e9;
      color: #2e7d32;
      padding: 4px 8px;
      border-radius: 4px;
      font-size: 12px;
    }
    .model-list, .job-list {
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    .model-item, .job-item {
      padding: 10px;
      background: #f5f5f5;
      border-radius: 4px;
    }
    .model-id { font-weight: bold; }
    .model-owner { color: #666; font-size: 12px; }
    .job-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .job-name { font-weight: bold; }
    .job-status {
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 12px;
    }
    .status-pending .job-status { background: #fff3e0; color: #e65100; }
    .status-running .job-status { background: #e3f2fd; color: #1565c0; }
    .status-completed .job-status { background: #e8f5e9; color: #2e7d32; }
    .status-failed .job-status { background: #ffebee; color: #c62828; }
    .status-cancelled .job-status { background: #f5f5f5; color: #666; }
    .job-progress {
      display: flex;
      align-items: center;
      gap: 10px;
      margin: 10px 0;
    }
    .job-progress .progress-bar { flex: 1; }
    .job-details {
      display: flex;
      gap: 15px;
      color: #666;
      font-size: 14px;
      margin-top: 5px;
    }
    .form-group {
      margin-bottom: 15px;
    }
    .form-group label {
      display: block;
      margin-bottom: 5px;
      font-weight: 500;
    }
    .form-group input, .form-group select {
      width: 100%;
      padding: 8px;
      border: 1px solid #ddd;
      border-radius: 4px;
      font-size: 14px;
    }
    .btn-primary {
      background: #76b900;
      color: white;
      border: none;
      padding: 10px 20px;
      border-radius: 4px;
      cursor: pointer;
      font-size: 14px;
    }
    .btn-primary:hover { background: #5a8f00; }
    .btn-danger {
      background: #dc3545;
      color: white;
      border: none;
      padding: 5px 10px;
      border-radius: 4px;
      cursor: pointer;
      font-size: 12px;
    }
    .btn-danger:hover { background: #c82333; }
    .no-jobs {
      text-align: center;
      color: #666;
      padding: 20px;
    }
    .loading {
      text-align: center;
      color: #666;
      padding: 20px;
    }
  `]
})
export class DashboardComponent implements OnInit, OnDestroy {
  isHealthy = false;
  gpuStatus: GpuStatus | null = null;
  models: Model[] = [];
  jobs: Job[] = [];
  
  newJob = {
    model_name: 'Qwen/Qwen3.5-1.8B',
    quant_format: 'int8',
    calib_samples: 512
  };
  
  private subscriptions: Subscription[] = [];
  
  constructor(private api: ApiService) {}
  
  ngOnInit() {
    this.loadInitialData();
    this.startPolling();
  }
  
  ngOnDestroy() {
    this.subscriptions.forEach(s => s.unsubscribe());
  }
  
  private loadInitialData() {
    this.api.getHealth().subscribe({
      next: () => this.isHealthy = true,
      error: () => this.isHealthy = false
    });
    
    this.api.getGpuStatus().subscribe({
      next: (status) => this.gpuStatus = status,
      error: (err) => console.error('GPU status error:', err)
    });
    
    this.api.listModels().subscribe({
      next: (response) => this.models = response.data,
      error: (err) => console.error('Models error:', err)
    });
    
    this.loadJobs();
  }
  
  private startPolling() {
    // Poll GPU status every 5 seconds
    const gpuPoll = interval(5000).pipe(
      switchMap(() => this.api.getGpuStatus())
    ).subscribe({
      next: (status) => this.gpuStatus = status,
      error: (err) => console.error('GPU poll error:', err)
    });
    this.subscriptions.push(gpuPoll);
    
    // Poll jobs every 2 seconds
    const jobsPoll = interval(2000).pipe(
      switchMap(() => this.api.listJobs())
    ).subscribe({
      next: (jobs) => this.jobs = jobs,
      error: (err) => console.error('Jobs poll error:', err)
    });
    this.subscriptions.push(jobsPoll);
  }
  
  private loadJobs() {
    this.api.listJobs().subscribe({
      next: (jobs) => this.jobs = jobs,
      error: (err) => console.error('Jobs error:', err)
    });
  }
  
  createJob() {
    const config = {
      config: {
        model_name: this.newJob.model_name,
        quant_format: this.newJob.quant_format,
        calib_samples: this.newJob.calib_samples,
        export_format: 'hf',
        enable_pruning: false,
        pruning_sparsity: 0.2
      }
    };
    
    this.api.createJob(config).subscribe({
      next: (job) => {
        console.log('Job created:', job);
        this.loadJobs();
      },
      error: (err) => console.error('Create job error:', err)
    });
  }
  
  cancelJob(jobId: string) {
    this.api.cancelJob(jobId).subscribe({
      next: () => this.loadJobs(),
      error: (err) => console.error('Cancel job error:', err)
    });
  }
}
import { Component, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ApiService, Model } from '../services/api.service';

@Component({
  selector: 'app-models',
  standalone: true,
  imports: [CommonModule],
  providers: [ApiService],
  template: `
    <div class="models-container">
      <header class="page-header">
        <h1>Available Models</h1>
        <p>OpenAI-compatible models optimized for T4 GPU</p>
      </header>

      <div class="models-grid">
        <div class="model-card" *ngFor="let model of models">
          <div class="model-header">
            <h3><bdi>{{ model.id }}</bdi></h3>
            <span class="model-type"><bdi>{{ getModelType(model.id) }}</bdi></span>
          </div>
          <div class="model-details">
            <div class="detail-row">
              <span class="label">Owner</span>
              <span class="value">{{ model.owned_by }}</span>
            </div>
            <div class="detail-row">
              <span class="label">Created</span>
              <span class="value">{{ formatDate(model.created) }}</span>
            </div>
            <div class="detail-row">
              <span class="label">Quantization</span>
              <span class="value quant-badge" [class]="getQuantClass(model.id)">
                <bdi>{{ getQuantization(model.id) }}</bdi>
              </span>
            </div>
          </div>
          <div class="model-actions">
            <button class="btn-primary" (click)="useInChat(model.id)">Use in Chat</button>
            <button class="btn-secondary" (click)="viewDetails(model.id)">Details</button>
          </div>
        </div>
      </div>

      <section class="info-section">
        <h2>Quantization Formats</h2>
        <div class="formats-table">
          <div class="format-row header">
            <span>Format</span>
            <span>Compression</span>
            <span>T4 Support</span>
            <span>Use Case</span>
          </div>
          <div class="format-row">
            <span>INT8</span>
            <span>2x</span>
            <span class="supported">✓</span>
            <span>Best quality/speed balance</span>
          </div>
          <div class="format-row">
            <span>INT4 AWQ</span>
            <span>4x</span>
            <span class="supported">✓</span>
            <span>Best compression</span>
          </div>
          <div class="format-row">
            <span>W4A16</span>
            <span>4x</span>
            <span class="supported">✓</span>
            <span>Weight-only quantization</span>
          </div>
          <div class="format-row">
            <span>FP8</span>
            <span>2x</span>
            <span class="not-supported">✗</span>
            <span>Requires Ada Lovelace+</span>
          </div>
        </div>
      </section>
    </div>
  `,
  styles: [`
    .models-container {
      padding: 20px;
      max-width: 1200px;
      margin: 0 auto;
    }
    .page-header {
      margin-bottom: 30px;
    }
    .page-header h1 {
      margin: 0 0 5px 0;
      color: #333;
    }
    .page-header p {
      margin: 0;
      color: #666;
    }
    .models-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
      gap: 20px;
      margin-bottom: 40px;
    }
    .model-card {
      background: white;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      padding: 20px;
    }
    .model-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      margin-bottom: 15px;
    }
    .model-header h3 {
      margin: 0;
      font-size: 16px;
      color: #333;
    }
    .model-type {
      background: #e8f5e9;
      color: #2e7d32;
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 12px;
    }
    .model-details {
      margin-bottom: 15px;
    }
    .detail-row {
      display: flex;
      justify-content: space-between;
      padding: 8px 0;
      border-bottom: 1px solid #f0f0f0;
    }
    .detail-row:last-child {
      border-bottom: none;
    }
    .detail-row .label {
      color: #666;
      font-size: 14px;
    }
    .detail-row .value {
      font-size: 14px;
      font-weight: 500;
    }
    .quant-badge {
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 12px;
    }
    .quant-badge.int8 {
      background: #e3f2fd;
      color: #1565c0;
    }
    .quant-badge.int4 {
      background: #f3e5f5;
      color: #7b1fa2;
    }
    .model-actions {
      display: flex;
      gap: 10px;
    }
    .btn-primary {
      flex: 1;
      padding: 10px;
      background: #76b900;
      color: white;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      font-size: 14px;
    }
    .btn-secondary {
      padding: 10px;
      background: transparent;
      color: #666;
      border: 1px solid #ddd;
      border-radius: 4px;
      cursor: pointer;
      font-size: 14px;
    }
    .btn-primary:hover { background: #5a8f00; }
    .btn-secondary:hover { background: #f5f5f5; }
    .info-section {
      background: white;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      padding: 20px;
    }
    .info-section h2 {
      margin: 0 0 15px 0;
      font-size: 18px;
      color: #333;
    }
    .formats-table {
      display: flex;
      flex-direction: column;
    }
    .format-row {
      display: grid;
      grid-template-columns: 1fr 1fr 1fr 2fr;
      padding: 12px;
      border-bottom: 1px solid #f0f0f0;
    }
    .format-row.header {
      font-weight: 600;
      background: #f5f5f5;
      border-radius: 4px 4px 0 0;
    }
    .supported { color: #2e7d32; font-weight: bold; }
    .not-supported { color: #c62828; font-weight: bold; }
  `]
})
export class ModelsComponent implements OnInit {
  models: Model[] = [];

  constructor(private api: ApiService) {}

  ngOnInit(): void {
    this.api.listModels().subscribe({
      next: (response) => this.models = response.data,
      error: (err) => console.error('Models error:', err)
    });
  }

  getModelType(id: string): string {
    if (id.includes('int8')) return 'INT8';
    if (id.includes('int4') || id.includes('awq')) return 'INT4 AWQ';
    return 'FP16';
  }

  getQuantization(id: string): string {
    if (id.includes('int8')) return 'INT8';
    if (id.includes('int4-awq')) return 'INT4 AWQ';
    return 'FP16';
  }

  getQuantClass(id: string): string {
    if (id.includes('int8')) return 'int8';
    if (id.includes('int4') || id.includes('awq')) return 'int4';
    return '';
  }

  formatDate(timestamp: number): string {
    return new Date(timestamp * 1000).toLocaleDateString();
  }

  useInChat(modelId: string): void {
    // Navigate to chat with model
    window.location.href = `/chat?model=${modelId}`;
  }

  viewDetails(modelId: string): void {
    alert(`Model: ${modelId}\nDetails coming soon...`);
  }
}
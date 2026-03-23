import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import {
  DataSource,
  DataSourceConnectionTestResponse,
  DataSourceCreateRequest,
  DatasourcesService,
} from '../../services/api/datasources.service';

interface DataSourceForm {
  name: string;
  source_type: string;
  configText: string;
}

@Component({
  selector: 'app-data-explorer',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Data Explorer</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="refresh()" [disabled]="loading">
          Refresh
        </ui5-button>
      </ui5-bar>
      <div class="data-content">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>

        <div class="data-grid">
          <ui5-card>
            <ui5-card-header slot="header" title-text="Datasources" [additionalText]="datasources.length + ''"></ui5-card-header>
            <ui5-table *ngIf="datasources.length > 0">
              <ui5-table-header-cell><span>Name</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Type</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
              <ui5-table-row *ngFor="let datasource of datasources">
                <ui5-table-cell>{{ datasource.name }}</ui5-table-cell>
                <ui5-table-cell>{{ datasource.source_type }}</ui5-table-cell>
                <ui5-table-cell>
                  <ui5-tag [design]="getConnectionDesign(datasource.connection_status)">
                    {{ datasource.connection_status }}
                  </ui5-tag>
                </ui5-table-cell>
                <ui5-table-cell>
                  <div class="actions-row">
                    <ui5-button design="Transparent" icon="detail-view" (click)="loadDatasource(datasource.id)">
                      View
                    </ui5-button>
                    <ui5-button design="Transparent" icon="connected" (click)="testDatasource(datasource)">
                      Test
                    </ui5-button>
                    <ui5-button design="Transparent" icon="delete" (click)="deleteDatasource(datasource)">
                      Delete
                    </ui5-button>
                  </div>
                </ui5-table-cell>
              </ui5-table-row>
            </ui5-table>

            <div *ngIf="!loading && datasources.length === 0" class="empty-state">
              No datasources found.
            </div>
          </ui5-card>

          <div class="side-panel">
            <ui5-card>
              <ui5-card-header slot="header" title-text="Create Datasource"></ui5-card-header>
              <div class="card-body form-stack">
                <ui5-input [(ngModel)]="newDatasource.name" placeholder="Datasource name"></ui5-input>
                <ui5-input [(ngModel)]="newDatasource.source_type" placeholder="Datasource type"></ui5-input>
                <ui5-textarea [(ngModel)]="newDatasource.configText" placeholder='{"host": "..."}' [rows]="6"></ui5-textarea>
                <ui5-button design="Emphasized" (click)="createDatasource()" [disabled]="createLoading || !newDatasource.name.trim() || !newDatasource.source_type.trim()">
                  {{ createLoading ? 'Creating...' : 'Create Datasource' }}
                </ui5-button>
              </div>
            </ui5-card>

            <ui5-card *ngIf="selectedDatasource || detailLoading">
              <ui5-card-header slot="header" title-text="Datasource Details"></ui5-card-header>
              <div class="card-body" *ngIf="selectedDatasource; else loadingDatasource">
                <div class="detail-row"><strong>ID:</strong> {{ selectedDatasource.id }}</div>
                <div class="detail-row"><strong>Name:</strong> {{ selectedDatasource.name }}</div>
                <div class="detail-row"><strong>Type:</strong> {{ selectedDatasource.source_type }}</div>
                <div class="detail-row">
                  <strong>Status:</strong>
                  <ui5-tag [design]="getConnectionDesign(selectedDatasource.connection_status)">
                    {{ selectedDatasource.connection_status }}
                  </ui5-tag>
                </div>
                <div class="detail-row"><strong>Last Sync:</strong> {{ selectedDatasource.last_sync || 'Never' }}</div>
                <h4>Configuration</h4>
                <pre>{{ selectedDatasource.config | json }}</pre>
                <ui5-message-strip
                  *ngIf="connectionResult?.id === selectedDatasource.id"
                  [design]="connectionResult?.connection_status === 'connected' ? 'Positive' : 'Negative'"
                  [hideCloseButton]="true">
                  Connection test status: {{ connectionResult?.connection_status }}
                </ui5-message-strip>
              </div>
              <ng-template #loadingDatasource>
                <div class="card-body empty-state">Loading datasource details...</div>
              </ng-template>
            </ui5-card>
          </div>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .data-content { padding: 1rem; }
    .data-grid { display: grid; grid-template-columns: minmax(0, 2fr) minmax(280px, 1fr); gap: 1rem; }
    .side-panel { display: flex; flex-direction: column; gap: 1rem; }
    .card-body { padding: 1rem; }
    .form-stack { display: flex; flex-direction: column; gap: 0.75rem; }
    .actions-row { display: flex; flex-wrap: wrap; gap: 0.5rem; }
    .detail-row { margin-bottom: 0.75rem; display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
    pre { background: var(--sapList_Background); padding: 1rem; overflow: auto; max-height: 320px; border-radius: 0.25rem; }
    ui5-message-strip { margin-bottom: 1rem; }
    .empty-state { padding: 1rem; color: var(--sapContent_LabelColor); }
    @media (max-width: 1023px) {
      .data-grid { grid-template-columns: 1fr; }
    }
  `]
})
export class DataExplorerComponent implements OnInit {
  private readonly datasourcesService = inject(DatasourcesService);
  private readonly destroyRef = inject(DestroyRef);

  datasources: DataSource[] = [];
  selectedDatasource: DataSource | null = null;
  connectionResult: DataSourceConnectionTestResponse | null = null;
  loading = false;
  createLoading = false;
  detailLoading = false;
  error = '';
  newDatasource: DataSourceForm = {
    name: '',
    source_type: 'hana',
    configText: '{}',
  };

  ngOnInit(): void {
    this.refresh();
  }

  refresh(selectedDatasourceId = this.selectedDatasource?.id): void {
    this.loading = true;
    this.error = '';

    this.datasourcesService.listDatasources()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          this.datasources = response.datasources;
          this.selectedDatasource = selectedDatasourceId
            ? response.datasources.find(datasource => datasource.id === selectedDatasourceId) ?? this.selectedDatasource
            : this.selectedDatasource;
          this.loading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to load datasources.');
          this.loading = false;
        }
      });
  }

  createDatasource(): void {
    const config = this.parseConfig();
    if (!config) {
      return;
    }

    const body: DataSourceCreateRequest = {
      name: this.newDatasource.name.trim(),
      source_type: this.newDatasource.source_type.trim(),
      config,
    };

    if (!body.name || !body.source_type) {
      return;
    }

    this.createLoading = true;
    this.error = '';

    this.datasourcesService.createDatasource(body)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: datasource => {
          this.newDatasource = { name: '', source_type: 'hana', configText: '{}' };
          this.createLoading = false;
          this.refresh(datasource.id);
          this.loadDatasource(datasource.id);
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to create datasource.');
          this.createLoading = false;
        }
      });
  }

  loadDatasource(datasourceId: string): void {
    this.detailLoading = true;
    this.error = '';

    this.datasourcesService.getDatasource(datasourceId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: datasource => {
          this.selectedDatasource = datasource;
          this.detailLoading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to load datasource details.');
          this.detailLoading = false;
        }
      });
  }

  testDatasource(datasource: DataSource): void {
    this.error = '';

    this.datasourcesService.testConnection(datasource.id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.connectionResult = result;
          this.datasources = this.datasources.map(existingDatasource =>
            existingDatasource.id === datasource.id
              ? { ...existingDatasource, connection_status: result.connection_status }
              : existingDatasource
          );
          if (this.selectedDatasource?.id === datasource.id) {
            this.selectedDatasource = {
              ...this.selectedDatasource,
              connection_status: result.connection_status,
            };
          }
        },
        error: error => {
          this.error = this.getErrorMessage(error, `Failed to test datasource "${datasource.name}".`);
        }
      });
  }

  deleteDatasource(datasource: DataSource): void {
    if (!window.confirm(`Delete datasource "${datasource.name}"?`)) {
      return;
    }

    this.error = '';

    this.datasourcesService.deleteDatasource(datasource.id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          if (this.selectedDatasource?.id === datasource.id) {
            this.selectedDatasource = null;
          }
          this.refresh();
        },
        error: error => {
          this.error = this.getErrorMessage(error, `Failed to delete datasource "${datasource.name}".`);
        }
      });
  }

  getConnectionDesign(status: string): 'Positive' | 'Critical' | 'Negative' | 'Neutral' {
    const normalizedStatus = status.toLowerCase();
    if (normalizedStatus === 'connected' || normalizedStatus === 'active') {
      return 'Positive';
    }
    if (normalizedStatus === 'failed' || normalizedStatus === 'error') {
      return 'Negative';
    }
    if (normalizedStatus === 'disconnected') {
      return 'Critical';
    }
    return 'Neutral';
  }

  private parseConfig(): Record<string, unknown> | null {
    try {
      const parsed = (this.newDatasource.configText.trim() ? JSON.parse(this.newDatasource.configText) : {}) as unknown;
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
      this.error = 'Datasource config must be a JSON object.';
      return null;
    } catch {
      this.error = 'Datasource config must be valid JSON.';
      return null;
    }
  }

  private getErrorMessage(error: unknown, fallback: string): string {
    if (typeof error === 'object' && error !== null) {
      const apiError = error as { error?: { detail?: string }; message?: string };
      if (typeof apiError.error?.detail === 'string') {
        return apiError.error.detail;
      }
      if (typeof apiError.message === 'string') {
        return apiError.message;
      }
    }

    return fallback;
  }
}

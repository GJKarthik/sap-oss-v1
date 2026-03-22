import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService, VectorStore } from '../../services/mcp.service';

@Component({
  selector: 'app-data-explorer',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
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

        <ui5-card>
          <ui5-card-header slot="header" title-text="HANA Vector Stores" [additionalText]="stores.length + ''"></ui5-card-header>
          <ui5-table *ngIf="stores.length > 0">
            <ui5-table-header-cell><span>Table Name</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Embedding Model</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Documents</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let store of stores">
              <ui5-table-cell>{{ store.table_name }}</ui5-table-cell>
              <ui5-table-cell>{{ store.embedding_model }}</ui5-table-cell>
              <ui5-table-cell>{{ store.documents_added }}</ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <div *ngIf="!loading && stores.length === 0" class="empty-state">
            No vector stores found.
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .data-content { padding: 1rem; }
    ui5-message-strip { margin-bottom: 1rem; }
    .empty-state { padding: 1rem; color: var(--sapContent_LabelColor); }
  `]
})
export class DataExplorerComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);

  stores: VectorStore[] = [];
  loading = false;
  error = '';

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';
    this.mcpService.fetchVectorStores()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: s => { this.stores = s; this.loading = false; },
        error: () => { this.error = 'Failed to load vector stores.'; this.loading = false; }
      });
  }
}

import { Component, OnInit, inject } from '@angular/core';
import { McpService, VectorStore } from '../../services/mcp.service';

@Component({
  selector: 'app-data-explorer',
  standalone: false,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Data Explorer</ui5-title>
      </ui5-bar>
      <div class="data-content">
        <ui5-card>
          <ui5-card-header slot="header" title-text="HANA Vector Stores"></ui5-card-header>
          <ui5-table>
            <ui5-table-header-cell><span>Table Name</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Embedding Model</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Documents</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let store of stores">
              <ui5-table-cell>{{ store.table_name }}</ui5-table-cell>
              <ui5-table-cell>{{ store.embedding_model }}</ui5-table-cell>
              <ui5-table-cell>{{ store.documents_added }}</ui5-table-cell>
            </ui5-table-row>
          </ui5-table>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`.data-content { padding: 1rem; }`]
})
export class DataExplorerComponent implements OnInit {
  private readonly mcpService = inject(McpService);

  stores: VectorStore[] = [];

  ngOnInit(): void {
    this.mcpService.fetchVectorStores().subscribe(s => this.stores = s);
  }
}

import { Component, OnInit, inject } from '@angular/core';
import { McpService, StreamSession } from '../../services/mcp.service';

@Component({
  selector: 'app-streaming',
  standalone: false,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Streaming Sessions</ui5-title>
      </ui5-bar>
      <div class="streaming-content">
        <ui5-card>
          <ui5-card-header slot="header" title-text="Active Streams" [additionalText]="streams.length + ''"></ui5-card-header>
          <ui5-table>
            <ui5-table-header-cell><span>Stream ID</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Deployment</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let stream of streams">
              <ui5-table-cell>{{ stream.stream_id }}</ui5-table-cell>
              <ui5-table-cell>{{ stream.deployment_id }}</ui5-table-cell>
              <ui5-table-cell><ui5-tag design="Positive">{{ stream.status }}</ui5-tag></ui5-table-cell>
              <ui5-table-cell><ui5-button design="Negative" icon="stop" (click)="stopStream(stream.stream_id)">Stop</ui5-button></ui5-table-cell>
            </ui5-table-row>
          </ui5-table>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`.streaming-content { padding: 1rem; }`]
})
export class StreamingComponent implements OnInit {
  private readonly mcpService = inject(McpService);

  streams: StreamSession[] = [];
  ngOnInit(): void { this.mcpService.fetchStreams().subscribe(s => this.streams = s); }
  stopStream(id: string): void { this.mcpService.stopStream(id).subscribe(() => this.ngOnInit()); }
}

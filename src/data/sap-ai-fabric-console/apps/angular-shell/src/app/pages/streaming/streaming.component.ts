import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { AuthService } from '../../services/auth.service';
import { McpService, StreamSession } from '../../services/mcp.service';

@Component({
  selector: 'app-streaming',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Streaming Sessions</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="refresh()" [disabled]="loading">
          Refresh
        </ui5-button>
      </ui5-bar>
      <div class="streaming-content">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="!canManage" design="Information" [hideCloseButton]="true">
          Viewer mode: stream control actions are disabled.
        </ui5-message-strip>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Active Streams" [additionalText]="streams.length + ''"></ui5-card-header>
          <ui5-table *ngIf="streams.length > 0">
            <ui5-table-header-cell><span>Stream ID</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Deployment</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let stream of streams">
              <ui5-table-cell>{{ stream.stream_id }}</ui5-table-cell>
              <ui5-table-cell>{{ stream.deployment_id }}</ui5-table-cell>
              <ui5-table-cell><ui5-tag design="Positive">{{ stream.status }}</ui5-tag></ui5-table-cell>
              <ui5-table-cell>
                <ui5-button *ngIf="canManage" design="Negative" icon="stop" (click)="stopStream(stream.stream_id)">Stop</ui5-button>
                <span *ngIf="!canManage" class="read-only-label">Read only</span>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <div *ngIf="!loading && streams.length === 0" class="empty-state">
            No active streaming sessions.
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .streaming-content { padding: 1rem; }
    ui5-message-strip { margin-bottom: 1rem; }
    .empty-state { padding: 1rem; color: var(--sapContent_LabelColor); }
    .read-only-label { color: var(--sapContent_LabelColor); font-size: var(--sapFontSmallSize); }
  `]
})
export class StreamingComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

  streams: StreamSession[] = [];
  loading = false;
  error = '';
  readonly canManage = this.authService.getUser()?.role === 'admin';

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';
    this.mcpService.fetchStreams()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: s => { this.streams = s; this.loading = false; },
        error: () => { this.error = 'Failed to load streaming sessions.'; this.loading = false; }
      });
  }

  stopStream(id: string): void {
    if (!this.canManage) {
      return;
    }
    this.mcpService.stopStream(id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => this.refresh(),
        error: () => { this.error = 'Failed to stop stream.'; }
      });
  }
}

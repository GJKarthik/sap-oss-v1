import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { AuthService } from '../../services/auth.service';
import { McpService, StreamSession } from '../../services/mcp.service';
import { EmptyStateComponent } from '../../shared';

@Component({
  selector: 'app-streaming',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule, EmptyStateComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Streaming Sessions</ui5-title>
        <ui5-button 
          slot="endContent" 
          icon="refresh" 
          (click)="refresh()" 
          [disabled]="loading"
          aria-label="Refresh streaming sessions">
          {{ loading ? 'Loading...' : 'Refresh' }}
        </ui5-button>
      </ui5-bar>
      <div class="streaming-content" role="region" aria-label="Streaming sessions management">
        <!-- Loading indicator -->
        <div class="loading-container" *ngIf="loading" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">Loading streaming sessions...</span>
        </div>

        <ui5-message-strip 
          *ngIf="error" 
          design="Negative" 
          [hideCloseButton]="false"
          (close)="error = ''"
          role="alert">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip 
          *ngIf="success" 
          design="Positive" 
          [hideCloseButton]="false"
          (close)="success = ''"
          role="status">
          {{ success }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="!canManage" design="Information" [hideCloseButton]="true">
          Viewer mode: stream control actions are disabled.
        </ui5-message-strip>

        <ui5-card [class.card-loading]="loading">
          <ui5-card-header 
            slot="header" 
            title-text="Active Streams" 
            subtitle-text="Real-time AI streaming sessions"
            [additionalText]="streams.length + ''">
          </ui5-card-header>
          <ui5-table 
            *ngIf="streams.length > 0" 
            aria-label="Active streaming sessions"
            [class.table-loading]="stopping">
            <ui5-table-header-cell><span>Stream ID</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Deployment</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let stream of streams; trackBy: trackByStreamId">
              <ui5-table-cell>
                <code class="stream-id">{{ stream.stream_id }}</code>
              </ui5-table-cell>
              <ui5-table-cell>{{ stream.deployment_id }}</ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="getStatusDesign(stream.status)">{{ stream.status }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-button 
                  *ngIf="canManage" 
                  design="Negative" 
                  icon="stop" 
                  (click)="stopStream(stream.stream_id)"
                  [disabled]="stopping"
                  [attr.aria-label]="'Stop stream ' + stream.stream_id">
                  {{ stopping ? 'Stopping...' : 'Stop' }}
                </ui5-button>
                <span *ngIf="!canManage" class="read-only-label">Read only</span>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <app-empty-state
            *ngIf="!loading && streams.length === 0"
            icon="play"
            title="No Active Streams"
            description="There are no active streaming sessions at this time. Streams are created when AI models are accessed through the streaming API.">
          </app-empty-state>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .streaming-content { 
      padding: 1rem; 
      max-width: 1200px;
      margin: 0 auto;
    }
    
    .loading-container {
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
      gap: 1rem;
    }

    .loading-text {
      color: var(--sapContent_LabelColor);
    }
    
    ui5-message-strip { 
      margin-bottom: 1rem; 
    }
    
    .card-loading {
      opacity: 0.6;
      pointer-events: none;
    }

    .table-loading {
      opacity: 0.6;
      pointer-events: none;
    }

    .stream-id {
      font-family: monospace;
      font-size: var(--sapFontSmallSize);
      background: var(--sapList_Background);
      padding: 0.125rem 0.375rem;
      border-radius: 4px;
    }
    
    .read-only-label { 
      color: var(--sapContent_LabelColor); 
      font-size: var(--sapFontSmallSize); 
    }

    @media (max-width: 768px) {
      .streaming-content {
        padding: 0.75rem;
      }
    }
  `]
})
export class StreamingComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

  streams: StreamSession[] = [];
  loading = false;
  stopping = false;
  error = '';
  success = '';
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
        next: streams => { 
          this.streams = streams; 
          this.loading = false; 
        },
        error: () => { 
          this.error = 'Failed to load streaming sessions.'; 
          this.loading = false; 
        }
      });
  }

  stopStream(id: string): void {
    if (!this.canManage) {
      return;
    }
    this.stopping = true;
    this.error = '';
    this.success = '';
    this.mcpService.stopStream(id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.success = `Stream "${id}" has been stopped.`;
          this.stopping = false;
          this.refresh();
        },
        error: () => { 
          this.error = `Failed to stop stream "${id}".`; 
          this.stopping = false;
        }
      });
  }

  trackByStreamId(index: number, stream: StreamSession): string {
    return stream.stream_id;
  }

  getStatusDesign(status: string): 'Positive' | 'Critical' | 'Negative' | 'Neutral' {
    const normalizedStatus = status.toLowerCase();
    if (normalizedStatus === 'active' || normalizedStatus === 'running') {
      return 'Positive';
    }
    if (normalizedStatus === 'error' || normalizedStatus === 'failed') {
      return 'Negative';
    }
    if (normalizedStatus === 'stopping' || normalizedStatus === 'pending') {
      return 'Critical';
    }
    return 'Neutral';
  }
}

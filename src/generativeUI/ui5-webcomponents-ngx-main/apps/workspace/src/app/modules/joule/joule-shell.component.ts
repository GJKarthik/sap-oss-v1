// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import {
  Component,
  OnInit,
  OnDestroy,
  ChangeDetectionStrategy,
  ChangeDetectorRef,
} from '@angular/core';
import { Subject } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import { StreamingUiService, StreamingState } from '@ui5/genui-streaming';
import { A2UiSchema } from '@ui5/genui-renderer';
import { GovernanceService, PendingAction } from '@ui5/genui-governance';
import { CollaborationService, Participant } from '@ui5/genui-collab';
import { environment } from '../../../environments/environment';
import { ExperienceHealthService } from '../../core/experience-health.service';
import { WorkspaceService } from '../../core/workspace.service';
import { WorkspaceHistoryService, HistoryEntry } from '../../core/workspace-history.service';

@Component({
  selector: 'ui-angular-joule-shell',
  standalone: false,
  templateUrl: './joule-shell.component.html',
  styleUrls: ['./joule-shell.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class JouleShellComponent implements OnInit, OnDestroy {
  private destroy$ = new Subject<void>();

  state: StreamingState = 'idle';
  schema: A2UiSchema | null = null;
  pendingActions: PendingAction[] = [];
  participants: Participant[] = [];
  showGovernancePanel = false;
  connectionError: string | null = null;
  routeBlocked = false;

  readonly agUiEndpoint = environment.agUiEndpoint;
  sessionHistory: HistoryEntry[] = [];

  constructor(
    private streamingUi: StreamingUiService,
    private governance: GovernanceService,
    private collab: CollaborationService,
    private liveHealthService: ExperienceHealthService,
    private cdr: ChangeDetectorRef,
    private workspaceService: WorkspaceService,
    private historyService: WorkspaceHistoryService,
  ) {}

  ngOnInit(): void {
    this.liveHealthService
      .checkRouteReadiness('joule')
      .pipe(takeUntil(this.destroy$))
      .subscribe((readiness) => {
        this.routeBlocked = readiness.blocking;
        const failed = readiness.checks.find((check) => !check.ok);
        if (failed) {
          this.connectionError = `AG-UI endpoint unavailable (${failed.status}) [x-correlation-id: unavailable]`;
        }
        this.cdr.markForCheck();
      });

    this.streamingUi.state$
      .pipe(takeUntil(this.destroy$))
      .subscribe((s) => {
        this.state = s;
        if (s === 'error' && !this.routeBlocked) {
          this.connectionError =
            'Connection to Joule failed. AG-UI endpoint unavailable [x-correlation-id: unavailable].';
        } else if (s === 'streaming' || s === 'connecting') {
          this.connectionError = null;
        }
        this.cdr.markForCheck();
      });

    this.streamingUi.schema$
      .pipe(takeUntil(this.destroy$))
      .subscribe((s) => {
        this.schema = s;
        this.cdr.markForCheck();
      });

    this.governance.pendingActions$
      .pipe(takeUntil(this.destroy$))
      .subscribe((actions) => {
        this.pendingActions = actions;
        if (actions.length > 0) {
          this.showGovernancePanel = true;
        }
        this.cdr.markForCheck();
      });

    this.collab.participants$
      .pipe(takeUntil(this.destroy$))
      .subscribe((participants) => {
        this.participants = participants;
        this.cdr.markForCheck();
      });

    this.loadSessionHistory();
  }

  clearSession(): void {
    if (this.schema) {
      this.historyService.saveEntry('joule', {
        schema: this.schema,
        state: this.state,
        savedAt: new Date().toISOString(),
      }).pipe(takeUntil(this.destroy$)).subscribe(() => {
        this.loadSessionHistory();
      });
    }
    this.streamingUi.clearSession();
  }

  loadSessionHistory(): void {
    this.historyService.loadHistory('joule')
      .pipe(takeUntil(this.destroy$))
      .subscribe(entries => {
        this.sessionHistory = entries;
        this.cdr.markForCheck();
      });
  }

  deleteHistoryEntry(entryId: string): void {
    this.historyService.deleteEntry('joule', entryId)
      .pipe(takeUntil(this.destroy$))
      .subscribe(() => this.loadSessionHistory());
  }

  dismissError(): void {
    this.connectionError = null;
    this.cdr.markForCheck();
  }

  retryConnection(): void {
    this.connectionError = null;
    this.streamingUi.clearSession();
    this.cdr.markForCheck();
    // Re-check health which will trigger reconnect
    this.liveHealthService
      .checkRouteReadiness('joule')
      .pipe(takeUntil(this.destroy$))
      .subscribe((readiness) => {
        this.routeBlocked = readiness.blocking;
        if (!readiness.blocking) {
          this.connectionError = null;
        } else {
          const failed = readiness.checks.find((check) => !check.ok);
          this.connectionError = `Retry failed — AG-UI endpoint still unavailable (${failed?.status ?? 'unknown'})`;
        }
        this.cdr.markForCheck();
      });
  }

  exportSession(): void {
    const exportData = {
      timestamp: new Date().toISOString(),
      currentSchema: this.schema,
      state: this.state,
      history: this.sessionHistory,
    };
    const blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `joule-session-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  }

  toggleGovernancePanel(): void {
    this.showGovernancePanel = !this.showGovernancePanel;
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}

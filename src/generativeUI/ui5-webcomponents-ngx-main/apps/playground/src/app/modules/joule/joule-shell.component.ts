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

@Component({
  selector: 'playground-joule-shell',
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

  readonly agUiEndpoint = environment.agUiEndpoint;

  constructor(
    private streamingUi: StreamingUiService,
    private governance: GovernanceService,
    private collab: CollaborationService,
    private cdr: ChangeDetectorRef,
  ) {}

  ngOnInit(): void {
    this.streamingUi.state$
      .pipe(takeUntil(this.destroy$))
      .subscribe((s) => {
        this.state = s;
        if (s === 'error') {
          this.connectionError = 'Connection to Joule failed. Check that the AG-UI backend is running and try again.';
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
  }

  clearSession(): void {
    this.streamingUi.clearSession();
  }

  dismissError(): void {
    this.connectionError = null;
    this.cdr.markForCheck();
  }

  toggleGovernancePanel(): void {
    this.showGovernancePanel = !this.showGovernancePanel;
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}

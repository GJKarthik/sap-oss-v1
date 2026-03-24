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

  readonly agUiEndpoint = '/ag-ui/run';

  constructor(
    private streamingUi: StreamingUiService,
    private cdr: ChangeDetectorRef,
  ) {}

  ngOnInit(): void {
    this.streamingUi.state$
      .pipe(takeUntil(this.destroy$))
      .subscribe((s) => {
        this.state = s;
        this.cdr.markForCheck();
      });

    this.streamingUi.schema$
      .pipe(takeUntil(this.destroy$))
      .subscribe((s) => {
        this.schema = s;
        this.cdr.markForCheck();
      });
  }

  clearSession(): void {
    this.streamingUi.clearSession();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}

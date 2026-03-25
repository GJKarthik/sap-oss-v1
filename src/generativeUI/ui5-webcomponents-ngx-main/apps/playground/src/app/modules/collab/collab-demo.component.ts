// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { Component, OnInit, OnDestroy, ChangeDetectionStrategy, ChangeDetectorRef } from '@angular/core';
import { Subject } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import {
  CollaborationService,
  Participant,
  CursorPosition,
  ConnectionState,
} from '@ui5/genui-collab';

@Component({
  selector: 'app-collab-demo',
  templateUrl: './collab-demo.component.html',
  styleUrls: ['./collab-demo.component.scss'],
  standalone: false,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CollabDemoComponent implements OnInit, OnDestroy {
  private destroy$ = new Subject<void>();

  connectionState: ConnectionState = 'disconnected';
  participants: Participant[] = [];
  cursors: CursorPosition[] = [];
  roomId = 'playground-demo-room';
  log: string[] = [];

  constructor(
    private collab: CollaborationService,
    private cdr: ChangeDetectorRef,
  ) {}

  ngOnInit(): void {
    this.collab.connectionState$
      .pipe(takeUntil(this.destroy$))
      .subscribe(state => {
        this.connectionState = state;
        this.addLog(`Connection: ${state}`);
        this.cdr.markForCheck();
      });

    this.collab.participants$
      .pipe(takeUntil(this.destroy$))
      .subscribe(participants => {
        this.participants = participants;
        this.cdr.markForCheck();
      });

    this.collab.cursors$
      .pipe(takeUntil(this.destroy$))
      .subscribe(cursors => {
        this.cursors = cursors;
        this.cdr.markForCheck();
      });
  }

  joinRoom(): void {
    this.addLog(`Joining room: ${this.roomId}`);
    this.collab.joinRoom(this.roomId).catch(err => {
      this.addLog(`Connect failed: ${err?.message ?? err}`);
      this.cdr.markForCheck();
    });
  }

  leaveRoom(): void {
    this.collab.leaveRoom();
    this.addLog('Left room');
  }

  broadcastCursor(event: MouseEvent): void {
    if (this.connectionState !== 'connected') return;
    this.collab.broadcastCursor(event.offsetX, event.offsetY);
  }

  clearLog(): void {
    this.log = [];
  }

  private addLog(msg: string): void {
    const ts = new Date().toLocaleTimeString();
    this.log = [`[${ts}] ${msg}`, ...this.log].slice(0, 50);
  }

  getCursorColor(userId: string): string {
    const colors = ['#0070f2', '#2b7c2b', '#e9730c', '#bb0000', '#6d2ac1', '#0b6e4f'];
    let hash = 0;
    for (let i = 0; i < userId.length; i++) { hash = userId.charCodeAt(i) + ((hash << 5) - hash); }
    return colors[Math.abs(hash) % colors.length];
  }

  ngOnDestroy(): void {
    this.collab.leaveRoom();
    this.destroy$.next();
    this.destroy$.complete();
  }
}

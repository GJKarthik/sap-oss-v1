import {
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  signal,
  viewChild,
  ElementRef,
  afterNextRender,
  inject,
  OnDestroy,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { finalize } from 'rxjs';
import { ChatComponent } from './chat/chat.component';
import { ChecksPanelComponent } from './checks-panel/checks-panel.component';
import {
  CopilotService,
  ChatMessage,
  CheckInfo,
  SessionConfig,
  WorkflowAuditEntry,
  WorkflowReplayEvent,
  WorkflowReview,
  WorkflowSnapshot,
  WorkflowStreamEvent,
} from './copilot.service';

// Register UI5 Fiori Shell Bar
import '@ui5/webcomponents-fiori/dist/ShellBar.js';
import '@ui5/webcomponents-fiori/dist/ShellBarItem.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/Toast.js';
import '@ui5/webcomponents-icons/dist/user-settings.js';
import '@ui5/webcomponents-icons/dist/paper-plane.js';
import '@ui5/webcomponents-icons/dist/delete.js';
import '@ui5/webcomponents-icons/dist/refresh.js';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, ChatComponent, ChecksPanelComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="copilot-layout">

      <!-- Top Shell Bar -->
      <ui5-shellbar
        primary-title="Data Cleaning Copilot"
        secondary-title="AI-powered Database Quality Validation"
        show-notifications
        notifications-count="{{ notifCount() }}"
      >
      </ui5-shellbar>

      <!-- Main content: Chat + Checks Panel -->
      <div class="copilot-body">

        <!-- Left: Chat -->
        <app-chat
          [messages]="messages()"
          (messageSent)="onMessageSent($event)"
          (clearRequested)="onClearRequested()"
          #chatRef
        ></app-chat>

        <!-- Right: Checks, History, Config -->
        <app-checks-panel
          [checks]="checks()"
          [checkHistory]="checkHistory()"
          [sessionConfig]="sessionConfig()"
          [workflowRun]="workflowRun()"
          [workflowReplayLog]="workflowReplayLog()"
          [pendingReview]="pendingReview()"
          [workflowAudit]="workflowAudit()"
          [reviewBusy]="reviewBusy()"
          [checksLoading]="checksLoadingSignal"
          (approveReview)="approvePendingReview()"
          (rejectReview)="rejectPendingReview()"
          (refreshChecks)="loadChecks()"
          (refreshHistory)="loadCheckHistory()"
        ></app-checks-panel>

      </div>
    </div>

    <!-- Toast notifications -->
    <ui5-toast #toast placement="BottomCenter">{{ toastMessage() }}</ui5-toast>
  `,
})
export class App implements OnDestroy {
  private readonly svc = inject(CopilotService);
  private recoveryPollHandle: ReturnType<typeof window.setTimeout> | null = null;
  private readonly recoveryPollIntervalMs = 1500;

  // State signals
  readonly messages = signal<ChatMessage[]>([]);
  readonly checks = signal<Record<string, CheckInfo>>({});
  readonly checkHistory = signal<ChatMessage[]>([]);
  readonly sessionConfig = signal<SessionConfig | null>(null);
  readonly workflowRun = signal<WorkflowSnapshot | null>(null);
  readonly workflowReplayLog = signal<WorkflowReplayEvent[]>([]);
  readonly pendingReview = signal<WorkflowReview | null>(null);
  readonly workflowAudit = signal<WorkflowAuditEntry[]>([]);
  readonly reviewBusy = signal(false);
  readonly notifCount = signal('');
  readonly toastMessage = signal('');
  readonly checksLoadingSignal = signal(false);

  // Child refs
  readonly chatRef = viewChild<ChatComponent>('chatRef');
  readonly toastRef = viewChild<ElementRef>('toast');

  constructor() {
    afterNextRender(() => {
      this.loadSessionHistory();
      this.loadChecks();
      this.loadCheckHistory();
      this.loadSessionConfig();
      this.loadWorkflowAudit();
      this.loadWorkflowState();
    });
  }

  ngOnDestroy() {
    this.stopRecoveryPolling();
  }

  // ---- Handlers ----

  onMessageSent(text: string) {
    this.startWorkflowRun(text, { appendUserMessage: true });
  }

  approvePendingReview() {
    const review = this.pendingReview();
    if (!review || this.reviewBusy()) {
      return;
    }

    this.pendingReview.set(null);
    this.startWorkflowRun(review.userMessage, { reviewId: review.reviewId });
  }

  rejectPendingReview() {
    const review = this.pendingReview();
    if (!review || this.reviewBusy()) {
      return;
    }

    this.reviewBusy.set(true);
    this.svc.rejectWorkflowReview(review.reviewId).subscribe({
      next: () => {
        this.pendingReview.set(null);
        this.reviewBusy.set(false);
        this.messages.update((msgs) => [
          ...msgs,
          { role: 'assistant', content: `Request rejected before execution: ${review.summary}` },
        ]);
        this.updateWorkflowRun((current) => ({
          ...current,
          summary: {
            ...current.summary,
            status: 'error',
            finishedAt: new Date().toISOString(),
            assistantResponse: `Rejected before execution: ${review.summary}`,
          },
        }));
        this.loadWorkflowAudit();
        this.showToast('Request rejected');
      },
      error: () => {
        this.reviewBusy.set(false);
        this.showToast('Could not reject the pending request');
      },
    });
  }

  onClearRequested() {
    this.svc.clearSession().subscribe({
      next: () => {
        this.messages.set([]);
        this.checkHistory.set([]);
        this.checks.set({});
        this.workflowRun.set(null);
        this.workflowReplayLog.set([]);
        this.pendingReview.set(null);
        this.workflowAudit.set([]);
        this.notifCount.set('');
        this.stopRecoveryPolling();
        this.showToast('Chat cleared');
      },
      error: () => {
        this.messages.set([]);
        this.checkHistory.set([]);
        this.checks.set({});
        this.workflowRun.set(null);
        this.workflowReplayLog.set([]);
        this.pendingReview.set(null);
        this.workflowAudit.set([]);
        this.notifCount.set('');
        this.stopRecoveryPolling();
      },
    });
  }

  loadChecks() {
    this.checksLoadingSignal.set(true);
    this.svc.getChecks().subscribe({
      next: data => {
        this.checks.set(data);
        this.notifCount.set(this.formatCheckCount(data));
        this.checksLoadingSignal.set(false);
      },
      error: () => this.checksLoadingSignal.set(false),
    });
  }

  loadSessionHistory() {
    this.svc.getSessionHistory().subscribe({
      next: data => this.messages.set(data),
      error: () => { },
    });
  }

  loadCheckHistory() {
    this.svc.getCheckHistory().subscribe({
      next: data => this.checkHistory.set(data),
      error: () => { },
    });
  }

  loadSessionConfig() {
    this.svc.getSessionConfig().subscribe({
      next: data => this.sessionConfig.set(data),
      error: () => { },
    });
  }

  loadWorkflowAudit() {
    this.svc.getWorkflowAudit().subscribe({
      next: data => this.workflowAudit.set(data),
      error: () => { },
    });
  }

  loadWorkflowReplay(runId?: string) {
    if (!runId) {
      this.workflowReplayLog.set([]);
      return;
    }

    this.svc.getWorkflowEvents(runId).subscribe({
      next: data => this.workflowReplayLog.set(data),
      error: () => { },
    });
  }

  loadWorkflowState() {
    this.svc.getWorkflowState().subscribe({
      next: (state) => {
        this.applyWorkflowState(state.workflowRun, state.pendingReview);
      },
      error: () => { },
    });
  }

  private scrollToBottom() {
    setTimeout(() => {
      const el = document.querySelector('.chat-messages');
      if (el) el.scrollTop = el.scrollHeight;
    }, 50);
  }

  private showToast(msg: string) {
    this.toastMessage.set(msg);
    const toast = (this.toastRef()?.nativeElement as HTMLElement & { show?: () => void });
    toast?.show?.();
  }

  private seedWorkflowRun(userMessage: string) {
    this.workflowRun.set({
      summary: {
        runId: '',
        status: 'processing',
        startedAt: new Date().toISOString(),
        userMessage,
        assistantResponse: 'Preparing workflow run...',
        requestKind: 'analysis',
        newCheckNames: [],
        newCheckCount: 0,
        totalChecks: Object.keys(this.checks()).length,
        sessionModel: this.sessionConfig()?.session_model ?? 'unknown',
        agentModel: this.sessionConfig()?.agent_model ?? 'unknown',
        generatedChecks: [],
      },
      checks: this.checks(),
      sessionHistory: this.messages(),
      checkHistory: this.checkHistory(),
      sessionConfig: this.sessionConfig() ?? {
        main: {},
        check_gen: {},
        session_model: 'unknown',
        agent_model: 'unknown',
      },
    });
  }

  private startWorkflowRun(
    text: string,
    options?: {
      appendUserMessage?: boolean;
      reviewId?: string;
    },
  ) {
    const chat = this.chatRef();
    if (options?.appendUserMessage) {
      this.messages.update((msgs) => [...msgs, { role: 'user', content: text }]);
    }

    if (!options?.reviewId) {
      this.pendingReview.set(null);
    }
    this.reviewBusy.set(Boolean(options?.reviewId));
    this.workflowReplayLog.set([]);
    this.stopRecoveryPolling();
    chat?.setLoading(true);
    this.seedWorkflowRun(text);

    this.svc
      .runWorkflow(text, options?.reviewId)
      .pipe(
        finalize(() => {
          chat?.setLoading(false);
          this.reviewBusy.set(false);
          this.loadWorkflowAudit();
          this.scrollToBottom();
        }),
      )
      .subscribe({
        next: (event) => {
          this.appendWorkflowReplay(event);
          switch (event.type) {
            case 'run.started':
              this.updateWorkflowRun((current) => ({
                ...current,
                summary: {
                  ...current.summary,
                  runId: event.runId,
                  startedAt: event.startedAt,
                  userMessage: event.userMessage,
                  status: 'processing',
                },
              }));
              break;
            case 'run.status':
              this.updateWorkflowRun((current) => ({
                ...current,
                summary: {
                  ...current.summary,
                  runId: event.runId,
                  status: 'processing',
                  assistantResponse: `Processing ${event.phase.replace(/_/g, ' ')}...`,
                },
              }));
              break;
            case 'approval.required':
              this.pendingReview.set(event.review);
              this.updateWorkflowRun((current) => ({
                ...current,
                summary: {
                  ...current.summary,
                  runId: event.runId,
                  status: 'awaiting_approval',
                  requestKind: event.review.requestKind,
                  assistantResponse: `Approval required: ${event.review.summary}`,
                },
              }));
              this.syncRecoveryPolling(event.runId, 'awaiting_approval');
              this.showToast('Approval required before continuing');
              break;
            case 'assistant.message':
              this.pendingReview.set(null);
              this.messages.update((msgs) => [...msgs, { role: 'assistant', content: event.content }]);
              this.updateWorkflowRun((current) => ({
                ...current,
                summary: {
                  ...current.summary,
                  runId: event.runId,
                  assistantResponse: event.content,
                },
              }));
              break;
            case 'workflow.snapshot':
              this.pendingReview.set(null);
              this.workflowRun.set(event.snapshot);
              this.messages.set(event.snapshot.sessionHistory);
              this.checks.set(event.snapshot.checks);
              this.checkHistory.set(event.snapshot.checkHistory);
              this.sessionConfig.set(event.snapshot.sessionConfig);
              this.notifCount.set(this.formatCheckCount(event.snapshot.checks));
              break;
            case 'run.finished':
              this.updateWorkflowRun((current) => ({
                ...current,
                summary: {
                  ...current.summary,
                  runId: event.runId,
                  status: 'completed',
                  finishedAt: event.finishedAt,
                },
              }));
              this.syncRecoveryPolling(event.runId, 'completed');
              break;
            case 'run.error': {
              const errorMessage = `⚠️ Error: ${event.error}`;
              this.pendingReview.set(null);
              this.messages.update((msgs) => [...msgs, { role: 'assistant', content: errorMessage }]);
              this.updateWorkflowRun((current) => ({
                ...current,
                summary: {
                  ...current.summary,
                  runId: event.runId,
                  status: 'error',
                  finishedAt: event.finishedAt,
                  assistantResponse: event.error,
                },
              }));
              this.syncRecoveryPolling(event.runId, 'error');
              break;
            }
          }
        },
        error: (err: unknown) => {
          const errorMsg = err instanceof Error
            ? err.message
            : 'Could not reach the backend. Make sure the API server is running on port 8000.';
          this.messages.update((msgs) => [
            ...msgs,
            { role: 'assistant', content: `⚠️ Error: ${errorMsg}` },
          ]);
          this.updateWorkflowRun((current) => ({
            ...current,
            summary: {
              ...current.summary,
              status: 'error',
              finishedAt: new Date().toISOString(),
              assistantResponse: errorMsg,
            },
          }));
          this.stopRecoveryPolling();
        },
      });
  }

  private applyWorkflowState(
    workflowRun: WorkflowSnapshot | null,
    pendingReview: WorkflowReview | null,
  ) {
    this.pendingReview.set(pendingReview);
    this.workflowRun.set(workflowRun);
    if (!workflowRun) {
      this.workflowReplayLog.set([]);
      this.stopRecoveryPolling();
      return;
    }

    this.messages.set(workflowRun.sessionHistory);
    this.checks.set(workflowRun.checks);
    this.checkHistory.set(workflowRun.checkHistory);
    this.sessionConfig.set(workflowRun.sessionConfig);
    this.notifCount.set(this.formatCheckCount(workflowRun.checks));
    this.loadWorkflowReplay(workflowRun.summary.runId);
    this.syncRecoveryPolling(workflowRun.summary.runId, workflowRun.summary.status);
  }

  private appendWorkflowReplay(event: WorkflowStreamEvent) {
    const currentRunId = event.runId || this.workflowRun()?.summary.runId || 'unknown-run';
    this.workflowReplayLog.update((entries) => [
      ...entries,
      {
        id: `live-${entries.length + 1}-${event.type}`,
        sequence: entries.length + 1,
        timestamp: new Date().toISOString(),
        runId: currentRunId,
        type: event.type,
        payload: event,
      },
    ]);
  }

  private syncRecoveryPolling(runId: string, status: WorkflowSnapshot['summary']['status']) {
    if (status === 'processing') {
      this.ensureRecoveryPolling(runId);
      return;
    }

    this.stopRecoveryPolling();
  }

  private ensureRecoveryPolling(runId: string) {
    if (this.recoveryPollHandle !== null) {
      return;
    }

    const tick = () => {
      this.svc.getWorkflowState().subscribe({
        next: (state) => {
          if (!state.workflowRun || state.workflowRun.summary.runId !== runId) {
            this.stopRecoveryPolling();
            return;
          }

          this.applyWorkflowState(state.workflowRun, state.pendingReview);
          this.loadWorkflowAudit();
          if (state.workflowRun.summary.status !== 'processing') {
            this.stopRecoveryPolling();
            return;
          }

          this.recoveryPollHandle = window.setTimeout(tick, this.recoveryPollIntervalMs);
        },
        error: () => {
          this.recoveryPollHandle = window.setTimeout(tick, this.recoveryPollIntervalMs);
        },
      });
    };

    this.recoveryPollHandle = window.setTimeout(tick, this.recoveryPollIntervalMs);
  }

  private stopRecoveryPolling() {
    if (this.recoveryPollHandle !== null) {
      window.clearTimeout(this.recoveryPollHandle);
      this.recoveryPollHandle = null;
    }
  }

  private updateWorkflowRun(
    update: (current: WorkflowSnapshot) => WorkflowSnapshot,
  ) {
    const current = this.workflowRun();
    if (!current) {
      return;
    }

    this.workflowRun.set(update(current));
  }

  private formatCheckCount(checks: Record<string, CheckInfo>): string {
    const count = Object.keys(checks).length;
    return count > 0 ? String(count) : '';
  }
}

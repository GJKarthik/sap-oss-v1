import {
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  EventEmitter,
  Input,
  Output,
  signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import type {
  CheckInfo,
  ChatMessage,
  SessionConfig,
  WorkflowAuditEntry,
  WorkflowReplayEvent,
  WorkflowReview,
  WorkflowSnapshot,
} from '../copilot.service';

// Register UI5 components used here
import '@ui5/webcomponents/dist/TabContainer.js';
import '@ui5/webcomponents/dist/Tab.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/BusyIndicator.js';
import '@ui5/webcomponents/dist/Tag.js';

@Component({
  selector: 'app-checks-panel',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="right-panel">
      <ui5-tab-container fixed>

        <!-- Latest Workflow Tab -->
        <ui5-tab text="Latest Run">
          <div slot="content">
            <div class="tab-content">
              @if (workflowRun) {
                <div class="check-card">
                  <div class="check-card-header">
                    <h4>{{ workflowRun.summary.requestKind | titlecase }}</h4>
                    <ui5-tag [attr.color-scheme]="workflowRun.summary.status === 'completed' ? '8' : workflowRun.summary.status === 'error' ? '1' : '6'">
                      {{ workflowRun.summary.status }}
                    </ui5-tag>
                  </div>
                  <div class="check-card-body">
                    <div><b>Started:</b> {{ workflowRun.summary.startedAt }}</div>
                    <div><b>Model Pair:</b> {{ workflowRun.summary.sessionModel }} / {{ workflowRun.summary.agentModel }}</div>
                    <div><b>New Checks:</b> {{ workflowRun.summary.newCheckCount }}</div>
                    <div><b>Total Checks:</b> {{ workflowRun.summary.totalChecks }}</div>
                  </div>
                </div>

                <div class="check-card">
                  <div class="check-card-header">
                    <h4>Assistant Outcome</h4>
                  </div>
                  <div class="check-card-body">
                    <div>{{ workflowRun.summary.assistantResponse }}</div>
                  </div>
                </div>

                @if (workflowReplayLog.length > 0) {
                  <div class="check-card">
                    <div class="check-card-header">
                      <h4>Replay Timeline</h4>
                    </div>
                    <div class="check-card-body">
                      @for (entry of workflowReplayLog; track entry.id) {
                        <div class="history-item">
                          <div class="history-role">{{ formatReplayLabel(entry.type) }}</div>
                          <div>
                            <div><b>{{ entry.timestamp }}</b></div>
                            <div>{{ formatReplayDetail(entry) }}</div>
                          </div>
                        </div>
                      }
                    </div>
                  </div>
                }

                @if (workflowRun.summary.generatedChecks.length > 0) {
                  <div class="check-card">
                    <div class="check-card-header">
                      <h4>Generated Artifacts</h4>
                    </div>
                    <div class="check-card-body">
                      @for (artifact of workflowRun.summary.generatedChecks; track artifact.name) {
                        <div class="history-item">
                          <div class="history-role">{{ artifact.isNew ? 'NEW' : 'EXISTING' }}</div>
                          <div>
                            <b>{{ artifact.name }}</b><br>
                            {{ artifact.description }}<br>
                            <small>Scope: {{ artifact.scope }}</small>
                          </div>
                        </div>
                      }
                    </div>
                  </div>
                }
              } @else {
                <p class="no-checks">No structured run snapshot yet. Send a request to populate the workflow surface.</p>
              }
            </div>
          </div>
        </ui5-tab>

        <!-- Review Tab -->
        <ui5-tab text="Review" [additionalText]="reviewCount()">
          <div slot="content">
            <div class="tab-content">
              @if (pendingReview) {
                <div class="check-card">
                  <div class="check-card-header">
                    <h4>{{ pendingReview.title }}</h4>
                    <ui5-tag [attr.color-scheme]="pendingReview.riskLevel === 'high' ? '1' : '6'">
                      {{ pendingReview.riskLevel }} risk
                    </ui5-tag>
                  </div>
                  <div class="check-card-body">
                    <div><b>Request Type:</b> {{ pendingReview.requestKind | titlecase }}</div>
                    <div><b>Submitted:</b> {{ pendingReview.createdAt }}</div>
                    <div><b>User Request:</b> {{ pendingReview.userMessage }}</div>
                    <div><b>Summary:</b> {{ pendingReview.summary }}</div>
                  </div>
                </div>

                <div class="check-card">
                  <div class="check-card-header">
                    <h4>Affected Scope</h4>
                  </div>
                  <div class="check-card-body">
                    <ul>
                      @for (item of pendingReview.affectedScope; track item) {
                        <li>{{ item }}</li>
                      }
                    </ul>
                  </div>
                </div>

                <div class="check-card">
                  <div class="check-card-header">
                    <h4>Guardrails</h4>
                  </div>
                  <div class="check-card-body">
                    <ul>
                      @for (item of pendingReview.guardrails; track item) {
                        <li>{{ item }}</li>
                      }
                    </ul>
                    <div class="tab-actions">
                      <ui5-button
                        design="Transparent"
                        [disabled]="reviewBusy"
                        (click)="rejectReview.emit()">
                        Reject
                      </ui5-button>
                      <ui5-button
                        design="Emphasized"
                        [disabled]="reviewBusy"
                        (click)="approveReview.emit()">
                        {{ reviewBusy ? 'Working...' : 'Approve and Continue' }}
                      </ui5-button>
                    </div>
                  </div>
                </div>

                @if (pendingReview.plannedCalls.length > 0) {
                  <div class="check-card">
                    <div class="check-card-header">
                      <h4>Planned Operations</h4>
                    </div>
                    <div class="check-card-body">
                      <ul>
                        @for (plannedCall of pendingReview.plannedCalls; track plannedCall.name + plannedCall.summary) {
                          <li><b>{{ plannedCall.name }}</b>: {{ plannedCall.summary }}</li>
                        }
                      </ul>
                    </div>
                  </div>
                }
              } @else {
                <p class="no-checks">No pending approval requests.</p>
              }
            </div>
          </div>
        </ui5-tab>

        <!-- Generated Checks Tab -->
        <ui5-tab text="Generated Checks" [additionalText]="checkCount()">
          <div slot="content">
            <div class="tab-actions">
              <ui5-button design="Transparent" icon="refresh" (click)="refreshChecks.emit()">Refresh</ui5-button>
            </div>
            <div class="tab-content">
              @if (checksLoading()) {
                <div class="loading-row">
                  <ui5-busy-indicator size="Small" active></ui5-busy-indicator>
                </div>
              } @else if (checkEntries().length === 0) {
                <p class="no-checks">No generated checks yet.<br>Use the chat to trigger check generation.</p>
              } @else {
                @for (entry of checkEntries(); track entry.name) {
                  <div class="check-card">
                    <div class="check-card-header" (click)="toggleCheck(entry.name)">
                      <h4>{{ entry.name }}</h4>
                      <ui5-tag color-scheme="6">{{ entry.info.scope }}</ui5-tag>
                    </div>
                    <div class="check-card-body">
                      <div>{{ entry.info.description }}</div>
                      <div class="check-code" [class.expanded]="expandedCheck() === entry.name">{{ entry.info.code }}</div>
                      <ui5-button design="Transparent" (click)="toggleCheck(entry.name)">
                        {{ expandedCheck() === entry.name ? 'Hide Code ▲' : 'View Code ▼' }}
                      </ui5-button>
                    </div>
                  </div>
                }
              }
            </div>
          </div>
        </ui5-tab>

        <!-- Check History Tab -->
        <ui5-tab text="Check History">
          <div slot="content">
            <div class="tab-actions">
              <ui5-button design="Transparent" icon="refresh" (click)="refreshHistory.emit()">Refresh</ui5-button>
            </div>
            <div class="tab-content">
              @for (msg of checkHistory; track $index) {
                <div class="history-item" [class]="'role-' + msg.role">
                  <div class="history-role">{{ msg.role }}</div>
                  <div>{{ msg.content | slice:0:300 }}{{ msg.content.length > 300 ? '…' : '' }}</div>
                </div>
              }
              @if (checkHistory.length === 0) {
                <p class="no-checks">No check generation history yet.</p>
              }
            </div>
          </div>
        </ui5-tab>

        <!-- Session Config Tab -->
        <ui5-tab text="Session Config">
          <div slot="content">
            <div class="tab-content">
              @if (sessionConfig) {
                <p class="panel-section-title">Models</p>
                <div class="config-json">Session: {{ sessionConfig.session_model }}\nAgent: {{ sessionConfig.agent_model }}</div>

                <p class="panel-section-title">Main Session</p>
                <div class="config-json">{{ formatJson(sessionConfig.main) }}</div>

                <p class="panel-section-title">Check Generation Session</p>
                <div class="config-json">{{ formatJson(sessionConfig.check_gen) }}</div>
              } @else {
                <p class="no-checks">Config not loaded. Backend may not be running.</p>
              }
            </div>
          </div>
        </ui5-tab>

        <!-- Workflow Audit Tab -->
        <ui5-tab text="Workflow Audit" [additionalText]="auditCount()">
          <div slot="content">
            <div class="tab-content">
              @if (workflowAudit.length === 0) {
                <p class="no-checks">No workflow audit events recorded yet.</p>
              } @else {
                @for (entry of workflowAudit; track entry.id) {
                  <div class="history-item">
                    <div class="history-role">{{ formatAuditLabel(entry.eventType) }}</div>
                    <div>
                      <div>
                        <ui5-tag [attr.color-scheme]="auditColorScheme(entry.status)">
                          {{ entry.status }}
                        </ui5-tag>
                      </div>
                      <div><b>{{ entry.timestamp }}</b></div>
                      <div>{{ entry.message }}</div>
                      @if (entry.detail) {
                        <small>{{ entry.detail }}</small>
                      }
                    </div>
                  </div>
                }
              }
            </div>
          </div>
        </ui5-tab>

      </ui5-tab-container>
    </div>
  `,
})
export class ChecksPanelComponent {
  @Input() checks: Record<string, CheckInfo> = {};
  @Input() checkHistory: ChatMessage[] = [];
  @Input() sessionConfig: SessionConfig | null = null;
  @Input() workflowRun: WorkflowSnapshot | null = null;
  @Input() workflowReplayLog: WorkflowReplayEvent[] = [];
  @Input() pendingReview: WorkflowReview | null = null;
  @Input() workflowAudit: WorkflowAuditEntry[] = [];
  @Input() reviewBusy = false;
  @Input() checksLoading = signal(false);

  @Output() approveReview = new EventEmitter<void>();
  @Output() rejectReview = new EventEmitter<void>();
  @Output() refreshChecks = new EventEmitter<void>();
  @Output() refreshHistory = new EventEmitter<void>();

  readonly expandedCheck = signal<string | null>(null);

  checkCount() {
    const n = Object.keys(this.checks).length;
    return n > 0 ? String(n) : '';
  }

  checkEntries() {
    return Object.entries(this.checks).map(([name, info]) => ({ name, info }));
  }

  toggleCheck(name: string) {
    this.expandedCheck.set(this.expandedCheck() === name ? null : name);
  }

  reviewCount() {
    return this.pendingReview ? '1' : '';
  }

  auditCount() {
    return this.workflowAudit.length > 0 ? String(this.workflowAudit.length) : '';
  }

  auditColorScheme(status: string): string {
    switch (status) {
      case 'completed':
      case 'approved':
        return '8';
      case 'error':
      case 'rejected':
        return '1';
      case 'awaiting_approval':
      case 'processing':
        return '6';
      default:
        return '10';
    }
  }

  formatAuditLabel(eventType: string): string {
    return eventType.replace(/\./g, ' ');
  }

  formatReplayLabel(eventType: string): string {
    return eventType.replace(/\./g, ' ');
  }

  formatReplayDetail(entry: WorkflowReplayEvent): string {
    const payload = entry.payload;
    if (entry.type === 'run.status' && 'phase' in payload) {
      return `Processing ${String(payload.phase).replace(/_/g, ' ')}.`;
    }
    if (entry.type === 'approval.required' && 'review' in payload) {
      const review = payload.review as WorkflowReview;
      return review.summary;
    }
    if (entry.type === 'assistant.message' && 'content' in payload) {
      return String(payload.content);
    }
    if (entry.type === 'run.error' && 'error' in payload) {
      return String(payload.error);
    }
    if ('status' in payload) {
      return `Status: ${String(payload.status)}`;
    }
    return 'Workflow event recorded.';
  }

  formatJson(obj: Record<string, unknown>): string {
    try {
      return JSON.stringify(obj, null, 2);
    } catch {
      return String(obj);
    }
  }
}

import {
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  EventEmitter,
  Input,
  Output,
  signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import type { CheckInfo, ChatMessage, SessionConfig } from '../copilot.service';

// Register UI5 components used here
import '@ui5/webcomponents/dist/TabContainer.js';
import '@ui5/webcomponents/dist/Tab.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/Tag.js';

@Component({
  selector: 'app-checks-panel',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="right-panel">
      <ui5-tab-container fixed>

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
                  <div>{{ msg.content | slice:0:300 }}{{ (msg.content?.length ?? 0) > 300 ? '…' : '' }}</div>
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

      </ui5-tab-container>
    </div>
  `,
})
export class ChecksPanelComponent {
  @Input() checks: Record<string, CheckInfo> = {};
  @Input() checkHistory: ChatMessage[] = [];
  @Input() sessionConfig: SessionConfig | null = null;
  @Input() checksLoading = signal(false);

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

  formatJson(obj: Record<string, unknown>): string {
    try {
      return JSON.stringify(obj, null, 2);
    } catch {
      return String(obj);
    }
  }
}

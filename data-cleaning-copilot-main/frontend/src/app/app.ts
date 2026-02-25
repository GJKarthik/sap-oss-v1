import {
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  signal,
  viewChild,
  ElementRef,
  afterNextRender,
  inject,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { ChatComponent } from './chat/chat.component';
import { ChecksPanelComponent } from './checks-panel/checks-panel.component';
import { CopilotService, ChatMessage, CheckInfo, SessionConfig } from './copilot.service';

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
          [checksLoading]="checksLoadingSignal"
          (refreshChecks)="loadChecks()"
          (refreshHistory)="loadCheckHistory()"
        ></app-checks-panel>

      </div>
    </div>

    <!-- Toast notifications -->
    <ui5-toast #toast placement="BottomCenter">{{ toastMessage() }}</ui5-toast>
  `,
})
export class App {
  private readonly svc = inject(CopilotService);

  // State signals
  readonly messages = signal<ChatMessage[]>([]);
  readonly checks = signal<Record<string, CheckInfo>>({});
  readonly checkHistory = signal<ChatMessage[]>([]);
  readonly sessionConfig = signal<SessionConfig | null>(null);
  readonly notifCount = signal('');
  readonly toastMessage = signal('');
  readonly checksLoadingSignal = signal(false);

  // Child refs
  readonly chatRef = viewChild<ChatComponent>('chatRef');
  readonly toastRef = viewChild<ElementRef>('toast');

  constructor() {
    afterNextRender(() => {
      this.loadChecks();
      this.loadSessionConfig();
    });
  }

  // ---- Handlers ----

  async onMessageSent(text: string) {
    // Optimistically add user message
    this.messages.update(msgs => [...msgs, { role: 'user', content: text }]);
    const chat = this.chatRef();
    chat?.setLoading(true);

    try {
      const result = await this.svc.chat(text).toPromise();
      this.messages.update(msgs => [...msgs, { role: 'assistant', content: result!.response }]);
      // Refresh checks after each AI turn (might have generated new ones)
      this.loadChecks();
    } catch (err: unknown) {
      const errorMsg = (err as { error?: { detail?: string } })?.error?.detail
        ?? 'Could not reach the backend. Make sure the API server is running on port 8000.';
      this.messages.update(msgs => [
        ...msgs,
        { role: 'assistant', content: `⚠️ Error: ${errorMsg}` },
      ]);
    } finally {
      chat?.setLoading(false);
      this.scrollToBottom();
    }
  }

  onClearRequested() {
    this.svc.clearSession().subscribe({
      next: () => {
        this.messages.set([]);
        this.showToast('Chat cleared');
      },
      error: () => this.messages.set([]),
    });
  }

  loadChecks() {
    this.checksLoadingSignal.set(true);
    this.svc.getChecks().subscribe({
      next: data => {
        this.checks.set(data);
        const n = Object.keys(data).length;
        this.notifCount.set(n > 0 ? String(n) : '');
        this.checksLoadingSignal.set(false);
      },
      error: () => this.checksLoadingSignal.set(false),
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
}

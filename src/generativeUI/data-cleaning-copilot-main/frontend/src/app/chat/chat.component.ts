import {
    Component,
    CUSTOM_ELEMENTS_SCHEMA,
    EventEmitter,
    Input,
    Output,
    signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import type { ChatMessage } from '../copilot.service';

// Register UI5 components we use here
import '@ui5/webcomponents/dist/TextArea.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/BusyIndicator.js';

@Component({
    selector: 'app-chat',
    standalone: true,
    imports: [CommonModule],
    schemas: [CUSTOM_ELEMENTS_SCHEMA],
    template: `
    <div class="chat-panel">
      <div class="chat-messages" #messageContainer>
        @if (messages.length === 0) {
          <div class="empty-chat">
            <div class="empty-chat-icon">💬</div>
            <p>Ask me about data quality, request check generation, or explore the database schema.</p>
          </div>
        }
        @for (msg of messages; track $index) {
          <div class="message" [class]="msg.role">
            <div class="message-avatar">
              {{ msg.role === 'user' ? 'You' : 'AI' }}
            </div>
            <div class="message-bubble">{{ msg.content }}</div>
          </div>
        }
        @if (loading()) {
          <div class="message assistant">
            <div class="message-avatar">AI</div>
            <div class="message-bubble">
              <ui5-busy-indicator size="Small" active></ui5-busy-indicator>
              &nbsp;Thinking…
            </div>
          </div>
        }
      </div>

      <div class="chat-input-area">
        <ui5-textarea
          id="chat-input"
          placeholder="Ask about data quality, generate checks, explore the schema…"
          rows="2"
          growing
          growing-max-rows="6"
          [value]="inputValue()"
          (input)="onInput($event)"
          (keydown)="onKeydown($event)"
          [disabled]="loading()"
        ></ui5-textarea>
        <ui5-button
          design="Emphasized"
          icon="paper-plane"
          (click)="sendMessage()"
          [disabled]="loading() || !inputValue().trim()"
          tooltip="Send message (Ctrl+Enter)"
        >Send</ui5-button>
        <ui5-button
          design="Transparent"
          icon="delete"
          (click)="clearRequested.emit()"
          tooltip="Clear chat"
        ></ui5-button>
      </div>
    </div>
  `,
})
export class ChatComponent {
    @Input() messages: ChatMessage[] = [];
    @Output() messageSent = new EventEmitter<string>();
    @Output() clearRequested = new EventEmitter<void>();

    readonly loading = signal(false);
    readonly inputValue = signal('');

    setLoading(v: boolean) {
        this.loading.set(v);
    }

    onInput(event: Event) {
        this.inputValue.set((event.target as HTMLInputElement).value);
    }

    onKeydown(event: KeyboardEvent) {
        if (event.ctrlKey && event.key === 'Enter') {
            this.sendMessage();
        }
    }

    sendMessage() {
        const text = this.inputValue().trim();
        if (!text || this.loading()) return;
        this.inputValue.set('');
        this.messageSent.emit(text);
    }
}

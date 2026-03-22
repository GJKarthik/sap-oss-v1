/**
 * Playground Component - Angular/UI5 Version
 * Chat interface using UI5 Web Components
 */

import { Component, DestroyRef, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService } from '../../services/mcp.service';

@Component({
  selector: 'app-playground',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Prompt Playground</ui5-title>
      </ui5-bar>

      <div class="playground-container">
        <!-- Chat Messages -->
        <div class="chat-messages">
          <div *ngFor="let msg of messages" [class]="'message ' + msg.role">
            <ui5-avatar [initials]="msg.role === 'user' ? 'U' : 'AI'" size="XS"></ui5-avatar>
            <div class="message-content">{{ msg.content }}</div>
          </div>
          <div *ngIf="loading" class="message assistant">
            <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          </div>
        </div>

        <!-- Input Area -->
        <div class="input-area">
          <ui5-textarea 
            [(ngModel)]="inputText"
            placeholder="Type your message..."
            [rows]="3"
            growing
            (keydown.enter)="sendMessage($event)">
          </ui5-textarea>
          <ui5-button design="Emphasized" icon="paper-plane" (click)="sendMessage()" [disabled]="loading || !inputText.trim()">
            Send
          </ui5-button>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .playground-container { display: flex; flex-direction: column; height: 100%; padding: 1rem; }
    .chat-messages { flex: 1; overflow-y: auto; }
    .message { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
    .message.user { justify-content: flex-end; }
    .message-content { padding: 0.75rem; border-radius: 0.5rem; max-width: 70%; }
    .message.user .message-content { background: var(--sapBrandColor); color: white; }
    .message.assistant .message-content { background: var(--sapList_Background); }
    .input-area { display: flex; gap: 0.5rem; }
    .input-area ui5-textarea { flex: 1; }
  `]
})
export class PlaygroundComponent {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);

  messages: Array<{ role: string; content: string }> = [];
  inputText = '';
  loading = false;

  sendMessage(event?: Event): void {
    if (event) event.preventDefault();
    if (!this.inputText.trim() || this.loading) return;

    const userMessage = this.inputText.trim();
    this.messages.push({ role: 'user', content: userMessage });
    this.inputText = '';
    this.loading = true;

    this.mcpService.streamingChat(this.messages)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (result) => {
          this.messages.push({ role: 'assistant', content: result.content });
          this.loading = false;
        },
        error: () => {
          this.messages.push({ role: 'assistant', content: 'Error: Failed to get response from AI backend.' });
          this.loading = false;
        }
      });
  }
}

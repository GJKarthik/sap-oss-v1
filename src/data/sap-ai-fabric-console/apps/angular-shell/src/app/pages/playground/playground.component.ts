/**
 * Playground Component - Angular/UI5 Version
 * Chat interface using UI5 Web Components
 */

import { Component, DestroyRef, inject, ViewChild, ElementRef, AfterViewChecked } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService } from '../../services/mcp.service';
import { EmptyStateComponent } from '../../shared';

interface ChatMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: Date;
}

@Component({
  selector: 'app-playground',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Prompt Playground</ui5-title>
        <ui5-button 
          slot="endContent" 
          icon="delete" 
          design="Transparent"
          (click)="clearChat()"
          [disabled]="messages.length === 0"
          aria-label="Clear chat history">
          Clear
        </ui5-button>
      </ui5-bar>

      <div class="playground-container" role="region" aria-label="AI chat playground">
        <!-- Chat Messages -->
        <div 
          #chatContainer
          class="chat-messages" 
          role="log" 
          aria-live="polite" 
          aria-label="Chat messages">
          
          <app-empty-state
            *ngIf="messages.length === 0 && !loading"
            icon="discussion"
            title="Start a Conversation"
            description="Type a message below to start chatting with the AI model.">
          </app-empty-state>

          <div 
            *ngFor="let msg of messages; let i = index; trackBy: trackByIndex" 
            [class]="'message ' + msg.role"
            [attr.aria-label]="(msg.role === 'user' ? 'You said' : 'AI responded') + ': ' + msg.content">
            <ui5-avatar 
              [initials]="msg.role === 'user' ? 'U' : 'AI'" 
              size="XS"
              [colorScheme]="msg.role === 'user' ? 'Accent1' : 'Accent6'"
              aria-hidden="true">
            </ui5-avatar>
            <div class="message-body">
              <div class="message-header">
                <span class="message-sender">{{ msg.role === 'user' ? 'You' : 'AI Assistant' }}</span>
                <span class="message-time">{{ formatTime(msg.timestamp) }}</span>
              </div>
              <div class="message-content">{{ msg.content }}</div>
            </div>
          </div>
          
          <div *ngIf="loading" class="message assistant loading-message" aria-label="AI is thinking">
            <ui5-avatar initials="AI" size="XS" colorScheme="Accent6" aria-hidden="true"></ui5-avatar>
            <div class="message-body">
              <ui5-busy-indicator active size="S"></ui5-busy-indicator>
              <span class="typing-indicator">AI is typing...</span>
            </div>
          </div>
        </div>

        <!-- Input Area -->
        <div class="input-area">
          <div class="input-wrapper">
            <label for="chat-input" class="visually-hidden">Type your message</label>
            <ui5-textarea 
              id="chat-input"
              ngDefaultControl
              [(ngModel)]="inputText"
              placeholder="Type your message..."
              [rows]="2"
              growing
              [maxLength]="4000"
              (keydown)="handleKeydown($event)"
              accessible-name="Chat message input">
            </ui5-textarea>
            <span class="char-count" *ngIf="inputText.length > 0">
              {{ inputText.length }}/4000
            </span>
          </div>
          <ui5-button 
            design="Emphasized" 
            icon="paper-plane" 
            (click)="sendMessage()" 
            [disabled]="loading || !inputText.trim()"
            aria-label="Send message">
            Send
          </ui5-button>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .playground-container { 
      display: flex; 
      flex-direction: column; 
      height: calc(100vh - 120px); 
      padding: 1rem;
      max-width: 900px;
      margin: 0 auto;
    }

    .chat-messages { 
      flex: 1; 
      overflow-y: auto;
      padding: 1rem 0;
      scroll-behavior: smooth;
    }

    .message { 
      display: flex; 
      gap: 0.75rem; 
      margin-bottom: 1rem;
      animation: fadeIn 0.2s ease-out;
    }

    @keyframes fadeIn {
      from { opacity: 0; transform: translateY(5px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .message.user { 
      flex-direction: row-reverse;
    }

    .message-body {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      max-width: 75%;
    }

    .message.user .message-body {
      align-items: flex-end;
    }

    .message-header {
      display: flex;
      gap: 0.5rem;
      align-items: center;
      font-size: var(--sapFontSmallSize);
    }

    .message.user .message-header {
      flex-direction: row-reverse;
    }

    .message-sender {
      font-weight: 600;
      color: var(--sapTextColor);
    }

    .message-time {
      color: var(--sapContent_LabelColor);
    }

    .message-content { 
      padding: 0.75rem 1rem; 
      border-radius: 1rem; 
      line-height: 1.5;
      white-space: pre-wrap;
      word-break: break-word;
    }

    .message.user .message-content { 
      background: var(--sapBrandColor); 
      color: white;
      border-bottom-right-radius: 0.25rem;
    }

    .message.assistant .message-content { 
      background: var(--sapList_Background);
      border: 1px solid var(--sapList_BorderColor);
      border-bottom-left-radius: 0.25rem;
    }

    .loading-message .message-body {
      display: flex;
      flex-direction: row;
      align-items: center;
      gap: 0.5rem;
      padding: 0.5rem 0;
    }

    .typing-indicator {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
      font-style: italic;
    }

    .input-area { 
      display: flex; 
      gap: 0.75rem;
      padding-top: 1rem;
      border-top: 1px solid var(--sapList_BorderColor);
    }

    .input-wrapper {
      flex: 1;
      position: relative;
    }

    .input-wrapper ui5-textarea {
      width: 100%;
    }

    .char-count {
      position: absolute;
      bottom: 0.5rem;
      right: 0.75rem;
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }

    .visually-hidden {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      margin: -1px;
      overflow: hidden;
      clip: rect(0, 0, 0, 0);
      white-space: nowrap;
      border: 0;
    }

    @media (max-width: 768px) {
      .playground-container {
        padding: 0.75rem;
      }

      .message-body {
        max-width: 85%;
      }
    }

    @media (prefers-reduced-motion: reduce) {
      .message {
        animation: none;
      }
      .chat-messages {
        scroll-behavior: auto;
      }
    }
  `]
})
export class PlaygroundComponent implements AfterViewChecked {
  @ViewChild('chatContainer') chatContainer!: ElementRef;
  
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  private shouldScrollToBottom = false;

  messages: ChatMessage[] = [];
  inputText = '';
  loading = false;

  ngAfterViewChecked(): void {
    if (this.shouldScrollToBottom) {
      this.scrollToBottom();
      this.shouldScrollToBottom = false;
    }
  }

  sendMessage(event?: Event): void {
    if (event) event.preventDefault();
    if (!this.inputText.trim() || this.loading) return;

    const userMessage = this.inputText.trim();
    this.messages.push({ 
      role: 'user', 
      content: userMessage,
      timestamp: new Date()
    });
    this.inputText = '';
    this.loading = true;
    this.shouldScrollToBottom = true;

    // Convert to simple format for API
    const apiMessages = this.messages.map(m => ({ role: m.role, content: m.content }));

    this.mcpService.streamingChat(apiMessages)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (result) => {
          this.messages.push({ 
            role: 'assistant', 
            content: result.content,
            timestamp: new Date()
          });
          this.loading = false;
          this.shouldScrollToBottom = true;
        },
        error: () => {
          this.messages.push({ 
            role: 'assistant', 
            content: 'Error: Failed to get response from AI backend. Please try again.',
            timestamp: new Date()
          });
          this.loading = false;
          this.shouldScrollToBottom = true;
        }
      });
  }

  handleKeydown(event: KeyboardEvent): void {
    // Send on Enter (without Shift for new line)
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      this.sendMessage();
    }
  }

  clearChat(): void {
    this.messages = [];
  }

  trackByIndex(index: number): number {
    return index;
  }

  formatTime(date: Date): string {
    return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  private scrollToBottom(): void {
    if (this.chatContainer?.nativeElement) {
      const container = this.chatContainer.nativeElement;
      container.scrollTop = container.scrollHeight;
    }
  }
}

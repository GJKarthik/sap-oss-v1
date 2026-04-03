import { Component } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService, ChatCompletionRequest, Message } from '../services/api.service';

@Component({
  selector: 'app-chat',
  standalone: true,
  imports: [CommonModule, FormsModule],
  providers: [ApiService],
  template: `
    <div class="chat-container">
      <header class="chat-header">
        <h1>Chat with Model</h1>
        <select [(ngModel)]="selectedModel" class="model-select">
          <option *ngFor="let model of models" [value]="model"><bdi>{{ model }}</bdi></option>
        </select>
      </header>

      <div class="messages" #messagesContainer>
        <div *ngFor="let msg of messages" [class]="'message ' + msg.role">
          <div class="role">{{ msg.role | titlecase }}</div>
          <div class="content"><bdi>{{ msg.content }}</bdi></div>
        </div>
        <div *ngIf="isLoading" class="message assistant loading">
          <div class="role">Assistant</div>
          <div class="content">Thinking...</div>
        </div>
      </div>

      <form (ngSubmit)="sendMessage()" class="input-form">
        <textarea
          [(ngModel)]="userInput"
          name="userInput"
          placeholder="Type your message..."
          (keydown.enter)="onEnter($event)"
          rows="3"
        ></textarea>
        <button type="submit" [disabled]="!userInput.trim() || isLoading">
          Send
        </button>
      </form>
    </div>
  `,
  styles: [`
    .chat-container {
      display: flex;
      flex-direction: column;
      height: 100vh;
      max-width: 900px;
      margin: 0 auto;
      padding: 20px;
    }
    .chat-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-bottom: 15px;
      border-bottom: 1px solid #e0e0e0;
    }
    .chat-header h1 {
      margin: 0;
      font-size: 24px;
      color: #333;
    }
    .model-select {
      padding: 8px 16px;
      border: 1px solid #ddd;
      border-radius: 4px;
      font-size: 14px;
    }
    .messages {
      flex: 1;
      overflow-y: auto;
      padding: 20px 0;
    }
    .message {
      margin-bottom: 20px;
      padding: 15px;
      border-radius: 8px;
    }
    .message.user {
      background: #e3f2fd;
      margin-left: 50px;
    }
    .message.assistant {
      background: #f5f5f5;
      margin-right: 50px;
    }
    .message.system {
      background: #fff3e0;
      font-style: italic;
    }
    .message .role {
      font-weight: 600;
      font-size: 12px;
      text-transform: uppercase;
      color: #666;
      margin-bottom: 5px;
    }
    .message .content {
      white-space: pre-wrap;
      line-height: 1.5;
    }
    .message.loading .content {
      color: #888;
    }
    .input-form {
      display: flex;
      gap: 10px;
      padding-top: 15px;
      border-top: 1px solid #e0e0e0;
    }
    .input-form textarea {
      flex: 1;
      padding: 12px;
      border: 1px solid #ddd;
      border-radius: 8px;
      font-size: 14px;
      resize: none;
      font-family: inherit;
    }
    .input-form button {
      padding: 12px 24px;
      background: #76b900;
      color: white;
      border: none;
      border-radius: 8px;
      cursor: pointer;
      font-size: 14px;
      font-weight: 600;
    }
    .input-form button:disabled {
      background: #ccc;
      cursor: not-allowed;
    }
    .input-form button:hover:not(:disabled) {
      background: #5a8f00;
    }
  `]
})
export class ChatComponent {
  models = [
    'qwen3.5-0.6b-int8',
    'qwen3.5-1.8b-int8',
    'qwen3.5-4b-int8',
    'qwen3.5-9b-int4-awq'
  ];
  selectedModel = 'qwen3.5-1.8b-int8';
  messages: Message[] = [];
  userInput = '';
  isLoading = false;

  constructor(private api: ApiService) {}

  sendMessage(): void {
    if (!this.userInput.trim() || this.isLoading) return;

    const userMessage: Message = { role: 'user', content: this.userInput.trim() };
    this.messages.push(userMessage);
    this.userInput = '';
    this.isLoading = true;

    const request: ChatCompletionRequest = {
      model: this.selectedModel,
      messages: this.messages,
      temperature: 0.7,
      max_tokens: 2048
    };

    this.api.createChatCompletion(request).subscribe({
      next: (response) => {
        const assistantMessage = response.choices[0].message;
        this.messages.push(assistantMessage);
        this.isLoading = false;
      },
      error: (err) => {
        console.error('Chat error:', err);
        this.messages.push({
          role: 'assistant',
          content: 'Error: Could not get response. Please check your API key and try again.'
        });
        this.isLoading = false;
      }
    });
  }

  onEnter(event: KeyboardEvent): void {
    if (!event.shiftKey) {
      event.preventDefault();
      this.sendMessage();
    }
  }
}
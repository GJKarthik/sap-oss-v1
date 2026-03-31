/**
 * Playground Component - Angular/UI5 Version
 * Chat interface using UI5 Web Components
 */

import { AfterViewChecked, Component, DestroyRef, ElementRef, HostListener, OnInit, ViewChild, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService, GenUiSession } from '../../services/mcp.service';
import { TextLayoutService } from '../../services/text-layout.service';
import { EmptyStateComponent } from '../../shared';

interface ChatMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: Date;
  estimatedHeightPx?: number;
}

type SessionHistoryFilter = 'active' | 'all' | 'archived';
type SessionHistoryItem = GenUiSession & { estimatedTitleHeightPx?: number };

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
        <div class="session-toolbar">
          <ui5-input
            class="session-title-input"
            ngDefaultControl
            [(ngModel)]="sessionTitle"
            placeholder="Session title"
            [disabled]="sessionBusy"
            accessible-name="Session title">
          </ui5-input>
          <ui5-button
            icon="save"
            design="Transparent"
            (click)="saveSession()"
            [disabled]="sessionBusy || messages.length === 0"
            aria-label="Save current session">
            Save Session
          </ui5-button>
          <ui5-button
            icon="refresh"
            design="Transparent"
            (click)="refreshSessionHistory()"
            [disabled]="sessionBusy"
            aria-label="Refresh saved session history">
            Refresh History
          </ui5-button>
          <ui5-button
            icon="favorite"
            design="Transparent"
            (click)="toggleBookmark()"
            [disabled]="sessionBusy || !currentSessionId"
            aria-label="Toggle bookmark on current session">
            {{ currentSessionBookmarked ? 'Unbookmark' : 'Bookmark' }}
          </ui5-button>
          <ui5-button
            icon="copy"
            design="Transparent"
            (click)="recreateAsNew()"
            [disabled]="sessionBusy || !currentSessionId"
            aria-label="Recreate current session as new">
            Recreate As New
          </ui5-button>
          <ui5-button
            icon="decline"
            design="Transparent"
            (click)="archiveCurrentSession()"
            [disabled]="sessionBusy || !currentSessionId"
            aria-label="Archive current session">
            Archive
          </ui5-button>
        </div>

        <div class="session-status" *ngIf="sessionStatusMessage">{{ sessionStatusMessage }}</div>

        <div class="session-toolbar">
          <ui5-input
            class="session-title-input"
            ngDefaultControl
            [(ngModel)]="historyQuery"
            placeholder="Search saved sessions"
            [disabled]="sessionBusy"
            accessible-name="Search saved sessions">
          </ui5-input>
          <ui5-button
            icon="filter"
            design="Transparent"
            [disabled]="sessionBusy"
            (click)="cycleHistoryFilter()">
            History: {{ historyFilterLabel }}
          </ui5-button>
          <ui5-button
            icon="search"
            design="Transparent"
            (click)="refreshSessionHistory()"
            [disabled]="sessionBusy"
            aria-label="Search saved sessions">
            Search
          </ui5-button>
        </div>

        <div class="session-history" *ngIf="savedSessions.length > 0">
          <div class="session-history-header">
            <span>Saved Sessions</span>
            <span class="session-history-count">{{ savedSessions.length }}</span>
          </div>
          <div class="session-history-list">
            <div
              *ngFor="let session of savedSessions; trackBy: trackBySessionId"
              class="session-history-item">
              <button
                class="session-history-main"
                type="button"
                (click)="restoreSession(session.id)">
                <span class="session-history-title" [style.minHeight.px]="session.estimatedTitleHeightPx">{{ session.title }}</span>
                <span class="session-history-meta">
                  {{ session.updated_at | date: 'short' }}
                  <span *ngIf="session.is_bookmarked">★</span>
                  <span *ngIf="session.is_archived"> (archived)</span>
                </span>
              </button>
              <ui5-button
                *ngIf="session.is_archived"
                design="Transparent"
                icon="undo"
                [disabled]="sessionBusy"
                (click)="restoreArchivedSession(session.id, $event)">
                Restore
              </ui5-button>
            </div>
          </div>
        </div>

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
              <div class="message-content" [style.minHeight.px]="msg.estimatedHeightPx">{{ msg.content }}</div>
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
              [attr.maxlength]="4000"
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

    .session-toolbar {
      display: flex;
      gap: 0.5rem;
      align-items: center;
      margin-bottom: 0.5rem;
    }

    .session-title-input {
      flex: 1;
      min-width: 220px;
    }

    .session-status {
      font-size: var(--sapFontSmallSize);
      color: var(--sapInformativeColor);
      margin-bottom: 0.5rem;
    }

    .session-history {
      border: 1px solid var(--sapList_BorderColor);
      border-radius: 0.75rem;
      background: var(--sapList_Background);
      padding: 0.5rem;
      margin-bottom: 0.75rem;
      max-height: 180px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .session-history-header {
      display: flex;
      justify-content: space-between;
      font-weight: 600;
      margin-bottom: 0.5rem;
    }

    .session-history-count {
      color: var(--sapContent_LabelColor);
    }

    .session-history-list {
      overflow: auto;
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }

    .session-history-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 0.5rem;
    }

    .session-history-main {
      text-align: left;
      border: 1px solid var(--sapList_BorderColor);
      background: transparent;
      border-radius: 0.5rem;
      padding: 0.4rem 0.55rem;
      cursor: pointer;
      flex: 1;
      display: flex;
      justify-content: space-between;
      gap: 0.5rem;
    }

    .session-history-main:hover {
      background: var(--sapList_Hover_Background);
    }

    .session-history-title {
      display: block;
      font-weight: 500;
    }

    .session-history-meta {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
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

      .session-toolbar {
        flex-wrap: wrap;
      }

      .session-title-input {
        min-width: 100%;
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
export class PlaygroundComponent implements AfterViewChecked, OnInit {
  @ViewChild('chatContainer') chatContainer!: ElementRef;
  
  private readonly mcpService = inject(McpService);
  private readonly textLayoutService = inject(TextLayoutService);
  private readonly destroyRef = inject(DestroyRef);
  private shouldScrollToBottom = false;
  private readonly chatFont = '14px "72", Arial, sans-serif';
  private readonly chatLineHeight = 22;
  private readonly historyLineHeight = 18;

  messages: ChatMessage[] = [];
  inputText = '';
  loading = false;
  sessionBusy = false;
  autosaveInFlight = false;
  sessionTitle = '';
  historyQuery = '';
  historyFilter: SessionHistoryFilter = 'active';
  sessionStatusMessage = '';
  currentSessionId: string | null = null;
  currentSessionBookmarked = false;
  savedSessions: SessionHistoryItem[] = [];

  ngOnInit(): void {
    this.refreshSessionHistory();
  }

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
    this.messages.push(this.createChatMessage('user', userMessage, new Date()));
    this.inputText = '';
    this.loading = true;
    this.shouldScrollToBottom = true;

    // Convert to simple format for API
    const apiMessages = this.messages.map(m => ({ role: m.role, content: m.content }));

    this.mcpService.streamingChat(apiMessages)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (result) => {
          this.messages.push(this.createChatMessage('assistant', result.content, new Date()));
          this.loading = false;
          this.shouldScrollToBottom = true;
          this.autoSaveSession();
        },
        error: () => {
          this.messages.push(
            this.createChatMessage(
              'assistant',
              'Error: Failed to get response from AI backend. Please try again.',
              new Date()
            )
          );
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
    this.currentSessionId = null;
    this.currentSessionBookmarked = false;
    this.sessionTitle = '';
    this.sessionStatusMessage = '';
  }

  trackByIndex(index: number): number {
    return index;
  }

  trackBySessionId(_index: number, session: GenUiSession): string {
    return session.id;
  }

  formatTime(date: Date): string {
    return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  @HostListener('window:resize')
  onResize(): void {
    this.recomputeEstimatedHeights();
  }

  private scrollToBottom(): void {
    if (this.chatContainer?.nativeElement) {
      const container = this.chatContainer.nativeElement;
      container.scrollTop = container.scrollHeight;
    }
  }

  private createChatMessage(role: ChatMessage['role'], content: string, timestamp: Date): ChatMessage {
    return {
      role,
      content,
      timestamp,
      estimatedHeightPx: this.estimateChatHeight(content),
    };
  }

  private withEstimatedSession(session: GenUiSession): SessionHistoryItem {
    return {
      ...session,
      estimatedTitleHeightPx: this.estimateSessionTitleHeight(session.title),
    };
  }

  private estimateChatHeight(content: string): number {
    return this.textLayoutService.measureHeight(content, {
      maxWidth: this.getChatBubbleWidth(),
      lineHeight: this.chatLineHeight,
      font: this.chatFont,
      whiteSpace: 'pre-wrap',
      minLines: 1,
    });
  }

  private estimateSessionTitleHeight(title: string): number {
    return this.textLayoutService.measureHeight(title, {
      maxWidth: this.getHistoryTitleWidth(),
      lineHeight: this.historyLineHeight,
      font: this.chatFont,
      minLines: 1,
      maxLines: 2,
    });
  }

  private getChatBubbleWidth(): number {
    const containerWidth = this.chatContainer?.nativeElement?.clientWidth ?? 720;
    return Math.max(180, Math.floor(containerWidth * 0.72) - 48);
  }

  private getHistoryTitleWidth(): number {
    const containerWidth = this.chatContainer?.nativeElement?.clientWidth ?? 720;
    return Math.max(180, Math.floor(containerWidth * 0.58));
  }

  private recomputeEstimatedHeights(): void {
    this.messages = this.messages.map(message => ({
      ...message,
      estimatedHeightPx: this.estimateChatHeight(message.content),
    }));
    this.savedSessions = this.savedSessions.map(session => this.withEstimatedSession(session));
  }

  saveSession(): void {
    if (this.messages.length === 0 || this.sessionBusy) {
      return;
    }
    this.persistSession(true);
  }

  private persistSession(showStatus: boolean): void {
    this.sessionBusy = true;
    if (showStatus) {
      this.sessionStatusMessage = 'Saving session...';
    }
    const payload = {
      session_id: this.currentSessionId ?? undefined,
      title: this.sessionTitle || this.messages[0]?.content?.slice(0, 60) || 'Untitled session',
      messages: this.messages.map(message => ({
        role: message.role,
        content: message.content,
        timestamp: message.timestamp.toISOString(),
      })),
      ui_state: {},
    };
    this.mcpService.saveGenUiSession(payload)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: session => {
          this.currentSessionId = session.id;
          this.currentSessionBookmarked = session.is_bookmarked;
          this.sessionTitle = session.title;
          this.sessionStatusMessage = showStatus ? 'Session saved.' : 'Autosaved.';
          this.sessionBusy = false;
          this.refreshSessionHistory();
        },
        error: () => {
          this.sessionStatusMessage = showStatus ? 'Failed to save session.' : 'Autosave failed.';
          this.sessionBusy = false;
        }
      });
  }

  private autoSaveSession(): void {
    if (this.autosaveInFlight || this.messages.length === 0) {
      return;
    }
    this.autosaveInFlight = true;
    const payload = {
      session_id: this.currentSessionId ?? undefined,
      title: this.sessionTitle || this.messages[0]?.content?.slice(0, 60) || 'Untitled session',
      messages: this.messages.map(message => ({
        role: message.role,
        content: message.content,
        timestamp: message.timestamp.toISOString(),
      })),
      ui_state: {},
    };
    this.mcpService.saveGenUiSession(payload)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: session => {
          this.currentSessionId = session.id;
          this.currentSessionBookmarked = session.is_bookmarked;
          this.sessionTitle = session.title;
          this.sessionStatusMessage = 'Autosaved.';
          this.autosaveInFlight = false;
          this.refreshSessionHistory();
        },
        error: () => {
          this.autosaveInFlight = false;
        }
      });
  }

  refreshSessionHistory(): void {
    if (this.sessionBusy) {
      return;
    }
    this.sessionBusy = true;
    this.mcpService.listGenUiSessions({
      bookmarkedOnly: false,
      includeArchived: this.historyFilter === 'all',
      archivedOnly: this.historyFilter === 'archived',
      query: this.historyQuery,
      limit: 30,
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.savedSessions = result.sessions.map(session => this.withEstimatedSession(session));
          this.sessionBusy = false;
        },
        error: () => {
          this.sessionStatusMessage = 'Failed to load saved session history.';
          this.sessionBusy = false;
        }
      });
  }

  get historyFilterLabel(): string {
    if (this.historyFilter === 'archived') {
      return 'Archived only';
    }
    if (this.historyFilter === 'all') {
      return 'All';
    }
    return 'Active only';
  }

  cycleHistoryFilter(): void {
    if (this.historyFilter === 'active') {
      this.historyFilter = 'all';
    } else if (this.historyFilter === 'all') {
      this.historyFilter = 'archived';
    } else {
      this.historyFilter = 'active';
    }
    this.refreshSessionHistory();
  }

  restoreSession(sessionId: string): void {
    if (this.sessionBusy) {
      return;
    }
    this.sessionBusy = true;
    this.sessionStatusMessage = 'Restoring session...';
    this.mcpService.getGenUiSession(sessionId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: session => {
          this.currentSessionId = session.id;
          this.currentSessionBookmarked = session.is_bookmarked;
          this.sessionTitle = session.title;
          this.messages = session.messages.map(message =>
            this.createChatMessage(
              message.role,
              message.content,
              message.timestamp ? new Date(message.timestamp) : new Date()
            )
          );
          this.sessionBusy = false;
          this.sessionStatusMessage = 'Session restored.';
          this.shouldScrollToBottom = true;
        },
        error: () => {
          this.sessionStatusMessage = 'Failed to restore session.';
          this.sessionBusy = false;
        }
      });
  }

  toggleBookmark(): void {
    if (!this.currentSessionId || this.sessionBusy) {
      return;
    }
    const nextValue = !this.currentSessionBookmarked;
    this.sessionBusy = true;
    this.mcpService.setGenUiSessionBookmark(this.currentSessionId, nextValue)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: session => {
          this.currentSessionBookmarked = session.is_bookmarked;
          this.sessionStatusMessage = session.is_bookmarked ? 'Session bookmarked.' : 'Session unbookmarked.';
          this.sessionBusy = false;
          this.refreshSessionHistory();
        },
        error: () => {
          this.sessionStatusMessage = 'Failed to update bookmark.';
          this.sessionBusy = false;
        }
      });
  }

  archiveCurrentSession(): void {
    if (!this.currentSessionId || this.sessionBusy) {
      return;
    }
    const sessionId = this.currentSessionId;
    this.sessionBusy = true;
    this.mcpService.archiveGenUiSession(sessionId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.sessionStatusMessage = 'Session archived.';
          this.currentSessionId = null;
          this.currentSessionBookmarked = false;
          this.sessionBusy = false;
          this.refreshSessionHistory();
        },
        error: () => {
          this.sessionStatusMessage = 'Failed to archive session.';
          this.sessionBusy = false;
        }
      });
  }

  recreateAsNew(): void {
    if (!this.currentSessionId || this.sessionBusy) {
      return;
    }
    const sourceSessionId = this.currentSessionId;
    this.sessionBusy = true;
    this.mcpService.cloneGenUiSession(sourceSessionId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: cloned => {
          this.currentSessionId = cloned.id;
          this.currentSessionBookmarked = cloned.is_bookmarked;
          this.sessionTitle = cloned.title;
          this.messages = cloned.messages.map(message =>
            this.createChatMessage(
              message.role,
              message.content,
              message.timestamp ? new Date(message.timestamp) : new Date()
            )
          );
          this.sessionStatusMessage = 'Session recreated as new copy.';
          this.sessionBusy = false;
          this.shouldScrollToBottom = true;
          this.refreshSessionHistory();
        },
        error: () => {
          this.sessionStatusMessage = 'Failed to recreate session.';
          this.sessionBusy = false;
        }
      });
  }

  restoreArchivedSession(sessionId: string, event: Event): void {
    event.stopPropagation();
    if (this.sessionBusy) {
      return;
    }
    this.sessionBusy = true;
    this.mcpService.setGenUiSessionArchived(sessionId, false)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.sessionStatusMessage = 'Session restored from archive.';
          this.sessionBusy = false;
          this.refreshSessionHistory();
        },
        error: () => {
          this.sessionStatusMessage = 'Failed to restore archived session.';
          this.sessionBusy = false;
        }
      });
  }
}

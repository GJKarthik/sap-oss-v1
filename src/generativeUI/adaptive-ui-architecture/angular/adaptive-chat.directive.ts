/**
 * Adaptive UI Architecture — Chat Capture Directive
 *
 * Directive for capturing chat interactions across all channels.
 * Designed to work with Data Cleaning Copilot, SAC Widget, and Joule Chat.
 */

import {
  Directive,
  Input,
  OnInit,
  OnDestroy,
  inject,
} from '@angular/core';
import { captureService } from '../core/capture/capture-service';
import { contextProvider } from '../core/context/context-provider';
import { modelingService } from '../core/modeling/modeling-service';
import type { InteractionType } from '../core/capture/types';

export interface ChatCaptureConfig {
  /** Unique identifier for this chat instance */
  chatId: string;
  /** Channel type (data-cleaning, sac, joule) */
  channel: 'data-cleaning' | 'sac' | 'joule';
  /** Whether to capture message content (privacy-sensitive) */
  captureContent?: boolean;
  /** Additional metadata to include */
  metadata?: Record<string, unknown>;
}

@Directive({
  selector: '[adaptiveChatCapture]',
  standalone: true,
  exportAs: 'adaptiveChatCapture',
})
export class AdaptiveChatCaptureDirective implements OnInit, OnDestroy {
  @Input('adaptiveChatCapture') config: ChatCaptureConfig = {
    chatId: 'default-chat',
    channel: 'data-cleaning',
  };

  private sessionStartTime: number = 0;
  private messageCount = 0;
  private userMessageCount = 0;
  private toolCallCount = 0;

  ngOnInit(): void {
    this.sessionStartTime = Date.now();
    this.captureSessionStart();
  }

  ngOnDestroy(): void {
    this.captureSessionEnd();
  }

  /**
   * Capture when user sends a message
   */
  captureUserMessage(messageLength: number, hasCode = false): void {
    this.messageCount++;
    this.userMessageCount++;

    captureService.capture({
      type: 'submit',
      target: 'user-message',
      componentType: 'chat',
      componentId: this.config.chatId,
      metadata: {
        channel: this.config.channel,
        messageLength,
        hasCode,
        messageIndex: this.messageCount,
        ...this.config.metadata,
      },
    });

    // Update context with task activity
    contextProvider.setTaskMode('execute');
  }

  /**
   * Capture when AI response starts streaming
   */
  captureStreamingStart(): void {
    captureService.capture({
      type: 'click', // Using click as generic interaction
      target: 'streaming-start',
      componentType: 'chat',
      componentId: this.config.chatId,
      metadata: {
        channel: this.config.channel,
        ...this.config.metadata,
      },
    });
  }

  /**
   * Capture when AI response completes
   */
  captureStreamingComplete(responseLength: number, durationMs: number): void {
    this.messageCount++;

    captureService.capture({
      type: 'submit',
      target: 'ai-response',
      componentType: 'chat',
      componentId: this.config.chatId,
      metadata: {
        channel: this.config.channel,
        responseLength,
        durationMs,
        messageIndex: this.messageCount,
        ...this.config.metadata,
      },
    });
  }

  /**
   * Capture when a tool is called
   */
  captureToolCall(toolName: string, success: boolean): void {
    this.toolCallCount++;

    captureService.capture({
      type: 'execute',
      target: toolName,
      componentType: 'chat-tool',
      componentId: this.config.chatId,
      metadata: {
        channel: this.config.channel,
        toolName,
        success,
        toolCallIndex: this.toolCallCount,
        ...this.config.metadata,
      },
    });
  }

  /**
   * Capture when user copies content
   */
  captureCopy(contentType: 'code' | 'text' | 'message'): void {
    captureService.capture({
      type: 'copy',
      target: contentType,
      componentType: 'chat',
      componentId: this.config.chatId,
      metadata: {
        channel: this.config.channel,
        contentType,
        ...this.config.metadata,
      },
    });
  }

  /**
   * Capture scroll behavior (for engagement analysis)
   */
  captureScroll(scrollPercent: number): void {
    captureService.capture({
      type: 'scroll',
      target: 'chat-messages',
      componentType: 'chat',
      componentId: this.config.chatId,
      metadata: {
        channel: this.config.channel,
        scrollPercent,
        ...this.config.metadata,
      },
    });
  }

  private captureSessionStart(): void {
    captureService.capture({
      type: 'navigate',
      target: 'session-start',
      componentType: 'chat',
      componentId: this.config.chatId,
      metadata: {
        channel: this.config.channel,
        ...this.config.metadata,
      },
    });
  }

  private captureSessionEnd(): void {
    const sessionDurationMs = Date.now() - this.sessionStartTime;

    captureService.capture({
      type: 'navigate',
      target: 'session-end',
      componentType: 'chat',
      componentId: this.config.chatId,
      metadata: {
        channel: this.config.channel,
        sessionDurationMs,
        totalMessages: this.messageCount,
        userMessages: this.userMessageCount,
        toolCalls: this.toolCallCount,
        ...this.config.metadata,
      },
    });
  }
}


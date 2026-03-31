// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Accessibility tests for JouleChatComponent
 */

import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ChangeDetectionStrategy } from '@angular/core';
import { JouleChatComponent, ChatMessage } from './joule-chat.component';
import { AgUiClient } from '../services/ag-ui-client.service';
import { AgUiToolRegistry } from '../services/tool-registry.service';
import { BehaviorSubject, Subject } from 'rxjs';

describe('JouleChatComponent Accessibility', () => {
  let component: JouleChatComponent;
  let fixture: ComponentFixture<JouleChatComponent>;
  let mockAgUiClient: Partial<AgUiClient>;

  beforeEach(async () => {
    mockAgUiClient = {
      connectionState$: new BehaviorSubject('disconnected'),
      lifecycle$: new Subject(),
      text$: new Subject(),
      events$: new Subject(),
      connect: jest.fn().mockResolvedValue(undefined),
      disconnect: jest.fn().mockResolvedValue(undefined),
      sendMessage: jest.fn().mockResolvedValue(undefined),
    };

    await TestBed.configureTestingModule({
      imports: [JouleChatComponent],
      providers: [
        { provide: AgUiClient, useValue: mockAgUiClient },
        { provide: AgUiToolRegistry, useValue: {} },
      ],
    })
    .overrideComponent(JouleChatComponent, {
      set: { changeDetection: ChangeDetectionStrategy.Default },
    })
    .compileComponents();

    fixture = TestBed.createComponent(JouleChatComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  describe('ARIA attributes', () => {
    it('should have role="region" on the chat shell', () => {
      const shell = fixture.nativeElement.querySelector('.joule-chat-shell');
      expect(shell.getAttribute('role')).toBe('region');
    });

    it('should have role="log" on the messages container', () => {
      const messages = fixture.nativeElement.querySelector('.joule-chat-messages');
      expect(messages.getAttribute('role')).toBe('log');
    });

    it('should have aria-live="polite" on the messages container', () => {
      const messages = fixture.nativeElement.querySelector('.joule-chat-messages');
      expect(messages.getAttribute('aria-live')).toBe('polite');
    });

    it('should have aria-label on the messages container', () => {
      const messages = fixture.nativeElement.querySelector('.joule-chat-messages');
      expect(messages.getAttribute('aria-label')).toBe('Chat messages');
    });

    it('should have role="status" on the connection indicator', () => {
      const status = fixture.nativeElement.querySelector('.joule-chat-status');
      expect(status.getAttribute('role')).toBe('status');
    });

    it('should have aria-hidden on decorative elements', () => {
      const statusDot = fixture.nativeElement.querySelector('.joule-chat-status-dot');
      expect(statusDot.getAttribute('aria-hidden')).toBe('true');
    });

    it('should have aria-busy when loading', () => {
      component.isLoading = true;
      fixture.detectChanges();
      const shell = fixture.nativeElement.querySelector('.joule-chat-shell');
      expect(shell.getAttribute('aria-busy')).toBe('true');
    });
  });

  describe('Message accessibility', () => {
    it('should generate correct aria-label for user messages', () => {
      const msg: ChatMessage = {
        id: 'test-1',
        role: 'user',
        content: 'Hello world',
        timestamp: new Date('2026-03-18T10:30:00'),
      };
      const label = component.getMessageAriaLabel(msg);
      expect(label).toContain('You said');
      expect(label).toContain('Hello world');
    });

    it('should generate correct aria-label for assistant messages', () => {
      const msg: ChatMessage = {
        id: 'test-2',
        role: 'assistant',
        content: 'Hi there!',
        timestamp: new Date('2026-03-18T10:30:00'),
      };
      const label = component.getMessageAriaLabel(msg);
      expect(label).toContain('Joule replied');
      expect(label).toContain('Hi there!');
    });

    it('should indicate streaming state in aria-label', () => {
      const msg: ChatMessage = {
        id: 'test-3',
        role: 'assistant',
        content: 'Thinking...',
        timestamp: new Date(),
        isStreaming: true,
      };
      const label = component.getMessageAriaLabel(msg);
      expect(label).toContain('still typing');
    });

    it('should truncate long messages in aria-label', () => {
      const longContent = 'a'.repeat(200);
      const msg: ChatMessage = {
        id: 'test-4',
        role: 'assistant',
        content: longContent,
        timestamp: new Date(),
      };
      const label = component.getMessageAriaLabel(msg);
      expect(label).toContain('...');
      expect(label.length).toBeLessThan(250);
    });

    it('should store estimated height metadata for user messages', async () => {
      component.inputValue = 'Hello from user';
      await component.onSubmit();

      expect(component.messages[0].estimatedHeightPx).toBeGreaterThan(0);
    });

    it('should update estimated height metadata while assistant streams', () => {
      (component as any).startAssistantMessage();
      (component as any).appendToAssistantMessage('Streaming output from assistant');

      const assistant = component.messages.find((m) => m.role === 'assistant');
      expect(assistant?.estimatedHeightPx).toBeGreaterThan(0);
    });
  });

  describe('Keyboard navigation', () => {
    it('should have tabindex on messages container for focus', () => {
      const messages = fixture.nativeElement.querySelector('.joule-chat-messages');
      expect(messages.getAttribute('tabindex')).toBe('0');
    });
  });

  describe('Screen reader announcements', () => {
    it('should have a visually hidden live region', () => {
      const srOnly = fixture.nativeElement.querySelector('.sr-only[role="status"]');
      expect(srOnly).toBeTruthy();
      expect(srOnly.getAttribute('aria-live')).toBe('polite');
    });
  });

  describe('Session memory persistence', () => {
    it('should persist chat state after sending a user message', async () => {
      const setItemSpy = jest.spyOn(window.localStorage.__proto__, 'setItem');
      component.inputValue = 'Persist this message';

      await component.onSubmit();

      expect(setItemSpy).toHaveBeenCalled();
      expect(setItemSpy.mock.calls.some((call) => call[0] === 'joule-chat:default')).toBe(true);
      setItemSpy.mockRestore();
    });

    it('should restore persisted chat state on init', () => {
      window.localStorage.setItem(
        'joule-chat:default',
        JSON.stringify({
          messages: [
            {
              id: 'restored-1',
              role: 'assistant',
              content: 'Restored message',
              timestamp: new Date('2026-03-31T00:00:00.000Z').toISOString(),
              isStreaming: false,
              estimatedHeightPx: 20,
            },
          ],
          lastRoute: 'rag',
          currentSchema: { type: 'card' },
        }),
      );

      component.ngOnInit();

      expect(component.messages.some((msg) => msg.id === 'restored-1')).toBe(true);
      expect(component.lastRoute).toBe('rag');
      expect(component.currentSchema).toEqual({ type: 'card' });
    });

    it('should clear persisted chat state when reset is triggered', () => {
      const removeItemSpy = jest.spyOn(window.localStorage.__proto__, 'removeItem');
      component.clearMessages();

      expect(removeItemSpy).toHaveBeenCalledWith('joule-chat:default');
      removeItemSpy.mockRestore();
    });
  });
});


import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { of } from 'rxjs';
import { McpService } from '../../services/mcp.service';
import { TextLayoutService } from '../../services/text-layout.service';
import { PlaygroundComponent } from './playground.component';

describe('PlaygroundComponent', () => {
  let fixture: ComponentFixture<PlaygroundComponent>;
  let component: PlaygroundComponent;
  let mcpService: {
    listGenUiSessions: jest.Mock;
    getGenUiSession: jest.Mock;
    saveGenUiSession: jest.Mock;
    setGenUiSessionBookmark: jest.Mock;
    archiveGenUiSession: jest.Mock;
    cloneGenUiSession: jest.Mock;
    setGenUiSessionArchived: jest.Mock;
    streamingChat: jest.Mock;
  };
  let textLayoutService: {
    measureHeight: jest.Mock;
  };

  beforeEach(async () => {
    mcpService = {
      listGenUiSessions: jest.fn().mockReturnValue(
        of({
          sessions: [
            {
              id: 'session-1',
              title: 'A long dashboard title',
              owner_username: 'admin',
              is_bookmarked: false,
              messages: [],
              ui_state: {},
              created_at: new Date().toISOString(),
              updated_at: new Date().toISOString(),
              is_archived: false,
              archived_at: null,
            },
          ],
          total: 1,
        })
      ),
      getGenUiSession: jest.fn(),
      saveGenUiSession: jest.fn().mockReturnValue(
        of({
          id: 'session-1',
          title: 'A long dashboard title',
          owner_username: 'admin',
          is_bookmarked: false,
          messages: [],
          ui_state: {},
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
          is_archived: false,
          archived_at: null,
        })
      ),
      setGenUiSessionBookmark: jest.fn(),
      archiveGenUiSession: jest.fn(),
      cloneGenUiSession: jest.fn(),
      setGenUiSessionArchived: jest.fn(),
      streamingChat: jest.fn().mockReturnValue(
        of({
          content: 'assistant reply',
          model: 'test-model',
          streaming: true,
        })
      ),
    };

    textLayoutService = {
      measureHeight: jest.fn().mockReturnValue(24),
    };

    await TestBed.configureTestingModule({
      imports: [PlaygroundComponent],
      providers: [
        { provide: McpService, useValue: mcpService },
        { provide: TextLayoutService, useValue: textLayoutService },
        provideHttpClient(),
        provideHttpClientTesting(),
      ],
    })
      .overrideComponent(PlaygroundComponent, {
        add: {
          schemas: [NO_ERRORS_SCHEMA],
        },
      })
      .compileComponents();
  });

  it('measures session title heights when loading history', () => {
    fixture = TestBed.createComponent(PlaygroundComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(mcpService.listGenUiSessions).toHaveBeenCalled();
    expect(textLayoutService.measureHeight).toHaveBeenCalled();
    expect(component.savedSessions[0].estimatedTitleHeightPx).toBe(24);
  });

  it('measures user and assistant message heights during chat flow', () => {
    fixture = TestBed.createComponent(PlaygroundComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    component.inputText = 'Hello pretext';
    component.sendMessage();

    expect(mcpService.streamingChat).toHaveBeenCalled();
    const userMessage = component.messages.find(message => message.role === 'user');
    const assistantMessage = component.messages.find(message => message.role === 'assistant');

    expect(userMessage?.estimatedHeightPx).toBe(24);
    expect(assistantMessage?.estimatedHeightPx).toBe(24);
    expect(textLayoutService.measureHeight).toHaveBeenCalled();
  });
});


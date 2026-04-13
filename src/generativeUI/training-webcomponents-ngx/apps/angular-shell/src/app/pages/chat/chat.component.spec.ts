import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { of } from 'rxjs';
import { Router } from '@angular/router';

import { ChatComponent } from './chat.component';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { ApiService } from '../../services/api.service';
import { GlossaryService } from '../../services/glossary.service';
import { LogService } from '../../services/log.service';
import { PersonalKnowledgeService } from '../../services/personal-knowledge.service';
import { TranslationMemoryService } from '../../services/translation-memory.service';
import { DocumentContextService } from '../../services/document-context.service';
import { WorkspaceService } from '../../services/workspace.service';
import { AppStore } from '../../store/app.store';
import { AppLinkService } from '../../services/app-link.service';
import type { AppMode } from '../../shared/utils/mode.types';

const MOCK_TOAST = {
  success: jest.fn(),
  error: jest.fn(),
  warning: jest.fn(),
  info: jest.fn(),
};

const MOCK_I18N = {
  isRtl: jest.fn(() => false),
  t: jest.fn((key: string, params?: Record<string, unknown>) => {
    const translations: Record<string, string | ((values?: Record<string, unknown>) => string)> = {
      'chat.cleared': 'Chat cleared',
      'chat.confirmClear': 'Are you sure you want to clear the chat?',
      'chat.defaultSystemPrompt': 'You are a helpful SQL assistant.',
      'chat.placeholder': 'Ask a question',
      'chat.suggest1': 'Summarize the latest pipeline output',
      'chat.suggest2': 'Explain the next review step',
      'chat.suggest3': 'Check the active glossary overrides',
      'crossApp.related': 'Related app',
      'crossApp.open': 'Open',
      'crossApp.inApp': 'in',
      'product.training': 'Training',
      'nav.ragStudio': 'RAG Studio',
      'chat.settings': 'Settings',
      'chat.model': 'Model',
      'chat.systemPrompt': 'System prompt',
      'chat.maxTokens': 'Max tokens',
      'chat.temperature': 'Temperature',
      'chat.clearChat': 'Clear chat',
      'chat.emptyState': 'Start chatting',
      'chat.you': 'You',
      'chat.assistant': 'Assistant',
      'chat.languageBadge.ar': 'AR',
      'chat.languageBadge.en': 'EN',
      'chat.assistantTyping': 'Assistant is typing',
      'chat.translationAudit': 'Translation audit',
      'chat.applyOverride': 'Apply override',
      'chat.overridePlaceholder': 'Override term',
      'chat.saveOverride': 'Save override',
      'chat.cancelOverride': 'Cancel',
      'chat.lastTokens': (values) => `Last tokens: ${values?.['count'] ?? 0}`,
    };

    const value = translations[key];
    if (typeof value === 'function') {
      return value(params);
    }
    return value ?? key;
  }),
};

describe('ChatComponent', () => {
  let component: ChatComponent;
  let fixture: ComponentFixture<ChatComponent>;

  const activeMode = signal<AppMode>('chat');
  const api = {
    get: jest.fn(() => of({ models: ['gpt-4o', 'gpt-3.5-turbo'] })),
    post: jest.fn(),
  };
  const glossary = {
    crossCheck: jest.fn(() => []),
  };
  const log = {
    info: jest.fn(),
  };
  const knowledge = {
    listBases: jest.fn(() => of([])),
    queryBase: jest.fn(),
    addDocuments: jest.fn(() => of({
      knowledge_base_id: 'kb-1',
      documents_added: 1,
      wiki_pages_updated: 0,
      status: 'indexed',
      storage_backend: 'preview',
    })),
    ensureBase: jest.fn(),
  };
  const translationMemory = {
    upsert: jest.fn(() => of({})),
  };
  const documentContext = {
    context: signal(null).asReadonly(),
  };
  const workspace = {
    activeWorkspace: jest.fn(() => ({ id: 'workspace-1' })),
  };
  const appStore = {
    activeMode,
    aiCapabilities: signal({
      systemPromptPrefix: 'Use workspace context.',
      confirmationLevel: 'conversational' as const,
    }),
  };
  const router = {
    navigate: jest.fn(),
    navigateByUrl: jest.fn(),
  };
  const appLinks = {
    appDisplayNameKey: jest.fn(() => 'product.training'),
    targetLabelKey: jest.fn(() => null),
    navigate: jest.fn(),
  };

  beforeEach(async () => {
    activeMode.set('chat');
    Object.values(MOCK_TOAST).forEach((spy) => spy.mockClear());
    Object.values(api).forEach((fn) => fn.mockClear());
    Object.values(glossary).forEach((fn) => fn.mockClear());
    Object.values(log).forEach((fn) => fn.mockClear());
    Object.values(knowledge).forEach((fn) => fn.mockClear());
    Object.values(translationMemory).forEach((fn) => fn.mockClear());
    Object.values(workspace).forEach((fn) => fn.mockClear());
    Object.values(router).forEach((fn) => fn.mockClear());
    Object.values(appLinks).forEach((fn) => fn.mockClear());
    api.get.mockReturnValue(of({ models: ['gpt-4o', 'gpt-3.5-turbo'] }));
    knowledge.listBases.mockReturnValue(of([]));
    knowledge.addDocuments.mockReturnValue(of({
      knowledge_base_id: 'kb-1',
      documents_added: 1,
      wiki_pages_updated: 0,
      status: 'indexed',
      storage_backend: 'preview',
    }));

    await TestBed.configureTestingModule({
      imports: [ChatComponent],
      providers: [
        { provide: ToastService, useValue: MOCK_TOAST },
        { provide: I18nService, useValue: MOCK_I18N },
        { provide: ApiService, useValue: api },
        { provide: GlossaryService, useValue: glossary },
        { provide: LogService, useValue: log },
        { provide: PersonalKnowledgeService, useValue: knowledge },
        { provide: TranslationMemoryService, useValue: translationMemory },
        { provide: DocumentContextService, useValue: documentContext },
        { provide: WorkspaceService, useValue: workspace },
        { provide: AppStore, useValue: appStore },
        { provide: Router, useValue: router },
        { provide: AppLinkService, useValue: appLinks },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(ChatComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  afterEach(() => {
    fixture?.destroy();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
    expect(component.messages().length).toBe(0);
    expect(api.get).toHaveBeenCalledWith('/chat/models');
    expect(knowledge.listBases).toHaveBeenCalled();
  });

  it('clearChat() should empty messages and show info toast', () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);

    component.messages.set([{ role: 'user', content: 'test', ts: new Date() }]);
    expect(component.messages().length).toBe(1);

    component.clearChat();

    expect(component.messages().length).toBe(0);
    expect(component.lastUsage()).toBeNull();
    expect(MOCK_TOAST.info).toHaveBeenCalledWith('Chat cleared');
  });

  it('send() should append the user message and request a completion', () => {
    api.post.mockReturnValueOnce(of({
      choices: [{ message: { content: 'Hi there' } }],
      model: 'gpt-4o',
      usage: { prompt_tokens: 8, completion_tokens: 7, total_tokens: 15 },
    }));

    component.prompt = 'Hello world';
    component.send();

    expect(component.messages().length).toBe(2);
    expect(component.messages()[0].role).toBe('user');
    expect(component.messages()[0].content).toBe('Hello world');
    expect(component.prompt).toBe('');
    expect(component.sending()).toBe(false);
    expect(api.post).toHaveBeenCalledWith('/chat/completions', expect.objectContaining({
      model: 'gpt-4o',
      messages: [
        { role: 'system', content: expect.stringContaining('Use workspace context.') },
        { role: 'user', content: 'Hello world' },
      ],
      stream: false,
      max_tokens: 1024,
      temperature: 0.7,
    }));
    expect(component.messages()[1].role).toBe('assistant');
    expect(component.messages()[1].content).toBe('Hi there');
    expect(component.lastUsage()?.total_tokens).toBe(15);
    expect(log.info).toHaveBeenCalledWith('Chat exchanged', 'Chat');
  });

  it('send() should query the selected knowledge base before requesting a completion', () => {
    component.knowledgeBases.set([
      {
        id: 'kb-1',
        owner_id: 'personal-user',
        name: 'Launch Memory',
        slug: 'launch-memory',
        description: '',
        embedding_model: 'default',
        documents_added: 2,
        wiki_pages: 1,
        created_at: '2026-04-08T00:00:00Z',
        updated_at: '2026-04-08T00:00:00Z',
        storage_backend: 'preview',
      },
    ]);
    component.selectedKnowledgeBaseId.set('kb-1');
    component.prompt = 'What matters for launch?';
    knowledge.queryBase.mockReturnValueOnce(of({
      knowledge_base_id: 'kb-1',
      owner_id: 'personal-user',
      query: 'What matters for launch?',
      answer: 'Launch depends on HANA rollout readiness.',
      context_docs: [{ id: 'doc-1', content: 'HANA rollout readiness', metadata: {}, score: 0.92 }],
      suggested_wiki_page: 'overview',
      source: 'preview',
      status: 'completed',
    }));
    api.post.mockReturnValueOnce(of({
      choices: [{ message: { content: 'Focus on the HANA rollout and owner alignment.' } }],
      model: 'gpt-4o',
      usage: { prompt_tokens: 20, completion_tokens: 12, total_tokens: 32 },
    }));

    component.send();

    expect(knowledge.queryBase).toHaveBeenCalledWith('kb-1', 'What matters for launch?');
    expect(api.post).toHaveBeenCalledWith('/chat/completions', expect.objectContaining({
      messages: [
        { role: 'system', content: expect.stringContaining('HANA rollout readiness') },
        { role: 'user', content: 'What matters for launch?' },
      ],
    }));
    expect(knowledge.addDocuments).toHaveBeenCalledWith(
      'kb-1',
      [expect.stringContaining('Conversation turn in Launch Memory')],
      [{ source: 'chat', model: 'gpt-4o', temperature: 0.7 }],
    );
    expect(component.messages()[1].content).toContain('Focus on the HANA rollout');
  });

  it('handleKeyDown() should trigger send on Enter without Shift', () => {
    jest.spyOn(component, 'send');
    const event = {
      key: 'Enter',
      shiftKey: false,
      preventDefault: jest.fn(),
    } as unknown as KeyboardEvent;

    component.handleKeyDown(event);

    expect(event.preventDefault).toHaveBeenCalled();
    expect(component.send).toHaveBeenCalled();
  });

  it('handleKeyDown() should allow a line break on Shift+Enter', () => {
    jest.spyOn(component, 'send');
    const event = {
      key: 'Enter',
      shiftKey: true,
      preventDefault: jest.fn(),
    } as unknown as KeyboardEvent;

    component.handleKeyDown(event);

    expect(event.preventDefault).not.toHaveBeenCalled();
    expect(component.send).not.toHaveBeenCalled();
  });
});

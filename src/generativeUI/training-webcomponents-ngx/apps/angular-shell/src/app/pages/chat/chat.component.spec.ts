import { ComponentFixture, TestBed, fakeAsync, tick } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { ChatComponent } from './chat.component';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';

const MOCK_TOAST = {
  success: jest.fn(),
  error: jest.fn(),
  warning: jest.fn(),
  info: jest.fn(),
};

describe('ChatComponent', () => {
  let component: ChatComponent;
  let fixture: ComponentFixture<ChatComponent>;
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ChatComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: ToastService, useValue: MOCK_TOAST },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(ChatComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);

    // Inject real translations so i18n.t() returns translated strings
    const i18n = TestBed.inject(I18nService);
    (i18n as any).translations = {
      en: {
        'chat.cleared': 'Chat cleared',
        'chat.confirmClear': 'Are you sure you want to clear the chat?',
      },
      ar: {},
    };
    (i18n as any).loaded = true;
    (i18n as any).mfCache.clear();

    // Clear mocks between tests
    Object.values(MOCK_TOAST).forEach(spy => spy.mockClear());
    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.match('/api/v1/models').forEach((request) => request.flush({ data: [] }));
    httpMock.match('/api/rag/tm').forEach((request) => request.flush([]));
    httpMock.match((request) => request.url.startsWith('/api/knowledge/bases')).forEach((request) => request.flush([]));
    httpMock.verify();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
    expect(component.messages().length).toBe(0);
  });

  it('clearChat() should empty messages and show info toast', () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);

    component.messages.set([{ role: 'user', content: 'test', ts: new Date() }]);
    expect(component.messages().length).toBe(1);

    component.clearChat();

    expect(component.messages().length).toBe(0);
    expect(MOCK_TOAST.info).toHaveBeenCalledWith('Chat cleared');
  });

  it('send() should append user message and call api.post', fakeAsync(() => {
    component.userInput = 'Hello world';
    component.send();

    expect(component.messages().length).toBe(1);
    expect(component.messages()[0].role).toBe('user');
    expect(component.messages()[0].content).toBe('Hello world');
    expect(component.userInput).toBe(''); // cleared input
    expect(component.sending()).toBe(true);

    const req = httpMock.expectOne('/api/v1/chat/completions');
    expect(req.request.method).toBe('POST');
    expect(req.request.body.messages.length).toBe(2); // System + User

    req.flush({
      choices: [{ message: { content: 'Hi there' } }],
      usage: { total_tokens: 15 },
    });

    tick();

    expect(component.sending()).toBe(false);
    expect(component.messages().length).toBe(2);
    expect(component.messages()[1].role).toBe('assistant');
    expect(component.messages()[1].content).toBe('Hi there');
    expect(component.lastUsage()?.total_tokens).toBe(15);
  }));

  it('send() should query the selected knowledge base before calling chat completions', fakeAsync(() => {
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
    component.userInput = 'What matters for launch?';

    component.send();

    const knowledgeReq = httpMock.expectOne('/api/knowledge/bases/kb-1/query');
    expect(knowledgeReq.request.method).toBe('POST');
    knowledgeReq.flush({
      knowledge_base_id: 'kb-1',
      owner_id: 'personal-user',
      query: 'What matters for launch?',
      answer: 'Launch depends on HANA rollout readiness.',
      context_docs: [{ id: 'doc-1', content: 'HANA rollout readiness', metadata: {}, score: 0.92 }],
      suggested_wiki_page: 'overview',
      source: 'preview',
      status: 'completed',
    });

    const chatReq = httpMock.expectOne('/api/v1/chat/completions');
    expect(chatReq.request.body.messages[0].content).toContain('Launch depends on HANA rollout readiness.');
    chatReq.flush({
      choices: [{ message: { content: 'Focus on the HANA rollout and owner alignment.' } }],
      usage: { total_tokens: 32 },
    });

    const rememberReq = httpMock.expectOne('/api/knowledge/bases/kb-1/documents');
    expect(rememberReq.request.method).toBe('POST');
    rememberReq.flush({
      knowledge_base_id: 'kb-1',
      documents_added: 1,
      wiki_pages_updated: 0,
      status: 'indexed',
      storage_backend: 'preview',
    });

    tick();
    expect(component.messages()[1].content).toContain('Focus on the HANA rollout');
  }));

  it('onEnter() triggers send if shiftKey is false', () => {
    jest.spyOn(component, 'send');
    const event = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: false });
    jest.spyOn(event, 'preventDefault');

    component.onEnter(event);

    expect(event.preventDefault).toHaveBeenCalled();
    expect(component.send).toHaveBeenCalled();
  });

  it('onEnter() does nothing if shiftKey is true (line break)', () => {
    jest.spyOn(component, 'send');
    const event = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true });
    jest.spyOn(event, 'preventDefault');

    component.onEnter(event);

    expect(event.preventDefault).not.toHaveBeenCalled();
    expect(component.send).not.toHaveBeenCalled();
  });
});

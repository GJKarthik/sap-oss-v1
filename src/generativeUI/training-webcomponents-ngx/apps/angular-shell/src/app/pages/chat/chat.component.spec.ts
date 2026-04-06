import { ComponentFixture, TestBed } from '@angular/core/testing';
import { of } from 'rxjs';

import { ChatComponent } from './chat.component';
import { ApiService } from '../../services/api.service';
import { GlossaryService, CrossCheckFinding } from '../../services/glossary.service';
import { I18nService } from '../../services/i18n.service';
import { ToastService } from '../../services/toast.service';
import { TranslationMemoryService } from '../../services/translation-memory.service';

const MOCK_TOAST = {
  success: jest.fn(),
  error: jest.fn(),
  warning: jest.fn(),
  info: jest.fn(),
};

const MOCK_API = {
  listModels: jest.fn(() => of({ data: [{ id: 'Qwen/Qwen3.5-0.6B', object: 'model' }] })),
  post: jest.fn(),
};

const MOCK_I18N = {
  currentLang: jest.fn(() => 'en'),
  isRtl: jest.fn(() => false),
  dir: jest.fn(() => 'ltr'),
  t: (key: string, params?: Record<string, unknown>) => {
    if (key === 'chat.cleared') return 'Chat cleared';
    if (key === 'chat.tmSaved') return 'Override saved';
    if (key === 'chat.tmError') return 'Override failed';
    if (key === 'chat.errorTitle') return 'Chat Error';
    if (key === 'chat.you') return 'You';
    if (key === 'chat.assistant') return 'Assistant';
    if (key === 'chat.languageBadge.ar') return 'AR';
    if (key === 'chat.languageBadge.en') return 'EN';
    if (key === 'chat.lastTokens') return `Last: ${params?.['count'] ?? 0} tokens`;
    return key;
  },
};

const MOCK_GLOSSARY = {
  getSystemPromptSnippet: jest.fn(() => '\n[CORRECTION OVERRIDES]\n- Net Profit -> صافي الربح'),
  crossCheck: jest.fn((): CrossCheckFinding[] => []),
  loadOverrides: jest.fn(),
};

const MOCK_TM = {
  save: jest.fn(),
};

describe('ChatComponent', () => {
  let component: ChatComponent;
  let fixture: ComponentFixture<ChatComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ChatComponent],
      providers: [
        { provide: ApiService, useValue: MOCK_API },
        { provide: ToastService, useValue: MOCK_TOAST },
        { provide: I18nService, useValue: MOCK_I18N },
        { provide: GlossaryService, useValue: MOCK_GLOSSARY },
        { provide: TranslationMemoryService, useValue: MOCK_TM },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(ChatComponent);
    component = fixture.componentInstance;

    Object.values(MOCK_TOAST).forEach(spy => spy.mockClear());
    Object.values(MOCK_API).forEach(spy => spy.mockClear());
    Object.values(MOCK_GLOSSARY).forEach(spy => spy.mockClear());
    Object.values(MOCK_TM).forEach(spy => spy.mockClear());

    MOCK_API.listModels.mockReturnValue(of({ data: [{ id: 'Qwen/Qwen3.5-0.6B', object: 'model' }] }));
    MOCK_GLOSSARY.getSystemPromptSnippet.mockReturnValue('\n[CORRECTION OVERRIDES]\n- Net Profit -> صافي الربح');
    MOCK_GLOSSARY.crossCheck.mockReturnValue([]);

    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
    expect(component.messages().length).toBe(0);
  });

  it('clearChat() should empty messages and show info toast', () => {
    component.messages.set([{ role: 'user', content: 'test', ts: new Date() }]);

    component.clearChat();

    expect(component.messages().length).toBe(0);
    expect(MOCK_TOAST.info).toHaveBeenCalledWith('Chat cleared');
  });

  it('send() should prepend glossary constraints and attach audit findings', () => {
    MOCK_GLOSSARY.crossCheck.mockReturnValue([
      {
        sourceTerm: 'صافي الربح',
        expectedTerm: 'Net Profit',
        sourceLang: 'ar',
        targetLang: 'en',
      },
    ]);
    MOCK_API.post.mockReturnValue(of({
      choices: [{ message: { content: 'صافي الربح بلغ 10' } }],
      usage: { total_tokens: 15 },
    }));

    component.userInput = 'Summarize the OCR result';
    component.send();

    expect(MOCK_API.post).toHaveBeenCalledWith(
      '/v1/chat/completions',
      expect.objectContaining({
        messages: expect.arrayContaining([
          expect.objectContaining({
            role: 'system',
            content: expect.stringContaining('[CORRECTION OVERRIDES]'),
          }),
        ]),
      }),
    );
    expect(MOCK_GLOSSARY.crossCheck).toHaveBeenCalledWith('صافي الربح بلغ 10', 'ar');
    expect(component.messages()).toHaveLength(2);
    expect(component.messages()[1].auditFindings).toEqual([
      expect.objectContaining({
        sourceTerm: 'صافي الربح',
        expectedTerm: 'Net Profit',
        overrideInput: 'Net Profit',
        showForm: false,
        saving: false,
      }),
    ]);
    expect(component.lastUsage()?.total_tokens).toBe(15);
  });

  it('saveOverride() should persist the override, remove the finding, and reload overrides', () => {
    const ts = new Date('2026-04-05T00:00:00.000Z');
    component.messages.set([
      {
        role: 'assistant',
        content: 'صافي الربح بلغ 10',
        ts,
        auditFindings: [
          {
            sourceTerm: 'صافي الربح',
            expectedTerm: 'Net Profit',
            sourceLang: 'ar',
            targetLang: 'en',
            overrideInput: 'Net Earnings',
            showForm: true,
            saving: false,
          },
        ],
      },
    ]);
    MOCK_TM.save.mockReturnValue(of({
      id: 'tm-1',
      source_text: 'صافي الربح',
      target_text: 'Net Earnings',
      source_lang: 'ar',
      target_lang: 'en',
      category: 'banking',
      is_approved: true,
    }));

    const finding = component.messages()[0].auditFindings?.[0];
    expect(finding).toBeDefined();
    if (!finding) {
      throw new Error('Expected an audit finding to be present');
    }

    component.saveOverride(ts, finding);

    expect(MOCK_TM.save).toHaveBeenCalledWith({
      source_text: 'صافي الربح',
      target_text: 'Net Earnings',
      source_lang: 'ar',
      target_lang: 'en',
      category: 'banking',
      is_approved: true,
    });
    expect(MOCK_GLOSSARY.loadOverrides).toHaveBeenCalled();
    expect(component.messages()[0].auditFindings).toEqual([]);
    expect(MOCK_TOAST.info).toHaveBeenCalledWith('Override saved');
  });

  it('onEnter() triggers send if shiftKey is false', () => {
    jest.spyOn(component, 'send');
    const event = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: false });
    jest.spyOn(event, 'preventDefault');

    component.onEnter(event);

    expect(event.preventDefault).toHaveBeenCalled();
    expect(component.send).toHaveBeenCalled();
  });

  it('onEnter() does nothing if shiftKey is true', () => {
    jest.spyOn(component, 'send');
    const event = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true });
    jest.spyOn(event, 'preventDefault');

    component.onEnter(event);

    expect(event.preventDefault).not.toHaveBeenCalled();
    expect(component.send).not.toHaveBeenCalled();
  });
});

import { ComponentFixture, TestBed, fakeAsync, tick } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { ChatComponent } from './chat.component';
import { ToastService } from '../../services/toast.service';

const MOCK_TOAST = {
  success: jest.fn(),
  error: jest.fn(),
  warning: jest.fn(),
  info: jest.fn(),
};

// JSDOM doesn't support scrollTo
beforeAll(() => {
  Element.prototype.scrollTo = jest.fn();
});

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

    TestBed.overrideComponent(ChatComponent, {
      set: { template: '<div></div>', schemas: [CUSTOM_ELEMENTS_SCHEMA] },
    });

    fixture = TestBed.createComponent(ChatComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    
    // Clear mocks between tests
    Object.values(MOCK_TOAST).forEach(spy => spy.mockClear());
    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
    expect(component.messages().length).toBe(0);
  });

  it('clearChat() should empty messages and show info toast', () => {
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

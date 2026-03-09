import { ComponentFixture, TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ChatComponent } from './chat.component';

describe('ChatComponent', () => {
  let component: ChatComponent;
  let fixture: ComponentFixture<ChatComponent>;
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ChatComponent, HttpClientTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(ChatComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.match(() => true));

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should have default model selected', () => {
    expect(component.selectedModel).toBe('qwen3.5-1.8b-int8');
  });

  it('should start with empty messages', () => {
    expect(component.messages).toEqual([]);
  });

  it('should not be loading initially', () => {
    expect(component.isLoading).toBeFalse();
  });

  it('should have 4 models available', () => {
    expect(component.models.length).toBe(4);
  });

  it('sendMessage does nothing when input is empty', () => {
    component.userInput = '   ';
    component.sendMessage();
    expect(component.messages.length).toBe(0);
  });

  it('sendMessage adds user message and sets loading', () => {
    component.userInput = 'Hello!';
    component.sendMessage();

    expect(component.messages.length).toBe(1);
    expect(component.messages[0].role).toBe('user');
    expect(component.messages[0].content).toBe('Hello!');
    expect(component.isLoading).toBeTrue();
    expect(component.userInput).toBe('');

    // Drain the HTTP request
    const req = httpMock.expectOne('/api/v1/chat/completions');
    req.flush({
      id: 'c1',
      object: 'chat.completion',
      created: 0,
      model: 'qwen3.5-1.8b-int8',
      choices: [{ index: 0, message: { role: 'assistant', content: 'Hi!' }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 4, completion_tokens: 4, total_tokens: 8 },
    });

    expect(component.messages.length).toBe(2);
    expect(component.messages[1].role).toBe('assistant');
    expect(component.isLoading).toBeFalse();
  });

  it('sendMessage handles API error gracefully', () => {
    component.userInput = 'Hello!';
    component.sendMessage();

    const req = httpMock.expectOne('/api/v1/chat/completions');
    req.error(new ProgressEvent('error'));

    expect(component.messages.length).toBe(2);
    expect(component.messages[1].content).toContain('Error');
    expect(component.isLoading).toBeFalse();
  });

  it('onEnter without shift sends message', () => {
    component.userInput = 'test';
    const event = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: false });
    spyOn(event, 'preventDefault');
    component.onEnter(event);
    expect(event.preventDefault).toHaveBeenCalled();
  });

  it('onEnter with shift does not send', () => {
    component.userInput = 'test';
    const event = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true });
    spyOn(event, 'preventDefault');
    component.onEnter(event);
    expect(event.preventDefault).not.toHaveBeenCalled();
  });
});


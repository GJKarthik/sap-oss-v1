import { TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { of } from 'rxjs';
import { ModeSwitcherComponent } from './mode-switcher.component';
import { AppStore } from '../../../store/app.store';

const MOCK_STORE = {
  activeMode: signal<'chat' | 'cowork' | 'training'>('chat'),
  setMode: jest.fn(),
};

describe('ModeSwitcherComponent', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ModeSwitcherComponent],
      providers: [
        { provide: AppStore, useValue: MOCK_STORE },
      ],
    }).compileComponents();

    MOCK_STORE.setMode.mockClear();
  });

  it('exposes three modes: chat, cowork, and training', () => {
    const fixture = TestBed.createComponent(ModeSwitcherComponent);
    const component = fixture.componentInstance;

    expect(component.modes).toHaveLength(3);
    expect(component.modes.map(m => m.key)).toEqual(['chat', 'cowork', 'training']);
  });

  it('reads activeMode from the store', () => {
    const fixture = TestBed.createComponent(ModeSwitcherComponent);
    const component = fixture.componentInstance;

    MOCK_STORE.activeMode.set('cowork');
    expect(component.activeMode()).toBe('cowork');
  });

  it('calls store.setMode when selectMode is invoked', () => {
    const fixture = TestBed.createComponent(ModeSwitcherComponent);
    const component = fixture.componentInstance;

    component.selectMode('training');

    expect(MOCK_STORE.setMode).toHaveBeenCalledTimes(1);
    expect(MOCK_STORE.setMode).toHaveBeenCalledWith('training');
  });

  it('cycles forward through modes on ArrowRight keydown', () => {
    const fixture = TestBed.createComponent(ModeSwitcherComponent);
    const component = fixture.componentInstance;
    MOCK_STORE.activeMode.set('chat');

    const event = { key: 'ArrowRight', preventDefault: jest.fn() } as unknown as KeyboardEvent;
    component.onKeydown(event);

    expect(event.preventDefault).toHaveBeenCalled();
    expect(MOCK_STORE.setMode).toHaveBeenCalledWith('cowork');
  });

  it('cycles backward through modes on ArrowLeft keydown', () => {
    const fixture = TestBed.createComponent(ModeSwitcherComponent);
    const component = fixture.componentInstance;
    MOCK_STORE.activeMode.set('cowork');

    const event = { key: 'ArrowLeft', preventDefault: jest.fn() } as unknown as KeyboardEvent;
    component.onKeydown(event);

    expect(event.preventDefault).toHaveBeenCalled();
    expect(MOCK_STORE.setMode).toHaveBeenCalledWith('chat');
  });

  it('wraps around to last mode when pressing ArrowLeft on first mode', () => {
    const fixture = TestBed.createComponent(ModeSwitcherComponent);
    const component = fixture.componentInstance;
    MOCK_STORE.activeMode.set('chat');

    const event = { key: 'ArrowLeft', preventDefault: jest.fn() } as unknown as KeyboardEvent;
    component.onKeydown(event);

    expect(MOCK_STORE.setMode).toHaveBeenCalledWith('training');
  });

  it('does not call setMode for unhandled keys', () => {
    const fixture = TestBed.createComponent(ModeSwitcherComponent);
    const component = fixture.componentInstance;
    MOCK_STORE.activeMode.set('chat');

    const event = { key: 'Enter', preventDefault: jest.fn() } as unknown as KeyboardEvent;
    component.onKeydown(event);

    expect(MOCK_STORE.setMode).not.toHaveBeenCalled();
  });
});

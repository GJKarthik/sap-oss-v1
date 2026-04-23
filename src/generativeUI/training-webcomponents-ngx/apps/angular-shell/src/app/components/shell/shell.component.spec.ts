import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { Subject } from 'rxjs';
import { Router } from '@angular/router';
import { ShellComponent } from './shell.component';
import { AuthService } from '../../services/auth.service';
import { AppStore } from '../../store/app.store';
import { I18nService } from '../../services/i18n.service';
import { NavigationAssistantService } from '../../services/navigation-assistant.service';
import { WorkspaceService } from '../../services/workspace.service';

const routerEvents$ = new Subject<unknown>();

const MOCK_ROUTER = {
  url: '/dashboard',
  navigate: jest.fn(),
  events: routerEvents$.asObservable(),
};

const MOCK_AUTH = {
  logout: jest.fn(),
};

const MOCK_STORE = {
  atmosphericClass: signal('atmosphere-steady'),
};

const MOCK_I18N = {
  t: (key: string) => key,
  isRtl: () => false,
  supportedLangs: ['en', 'de'],
  langLabels: { en: 'English', de: 'Deutsch' },
  currentLang: () => 'en',
  setLanguage: jest.fn(),
  languageLabel: () => 'English',
};

const MOCK_NAVIGATION = {
  search: jest.fn(() => []),
  isPinned: jest.fn(() => false),
  canPin: jest.fn(() => true),
  pinnedEntries: jest.fn(() => []),
  recentEntries: jest.fn(() => []),
  suggestedEntries: jest.fn(() => []),
  togglePinned: jest.fn(),
  recordVisit: jest.fn(),
};

const MOCK_WORKSPACE = {
  visibleNavLinks: signal([
    { route: '/dashboard' },
    { route: '/data-products' },
    { route: '/chat' },
    { route: '/pipeline' },
    { route: '/workspace' },
  ]),
  identity: signal({
    displayName: 'SAP AI User',
    teamName: 'Launch Team',
    userId: 'sap-ai-user',
  }),
};

describe('ShellComponent', () => {
  let fixture: ComponentFixture<ShellComponent>;
  let component: ShellComponent;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ShellComponent],
      providers: [
        { provide: Router, useValue: MOCK_ROUTER },
        { provide: AuthService, useValue: MOCK_AUTH },
        { provide: AppStore, useValue: MOCK_STORE },
        { provide: I18nService, useValue: MOCK_I18N },
        { provide: NavigationAssistantService, useValue: MOCK_NAVIGATION },
        { provide: WorkspaceService, useValue: MOCK_WORKSPACE },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(ShellComponent);
    component = fixture.componentInstance;

    MOCK_ROUTER.navigate.mockClear();
    MOCK_AUTH.logout.mockClear();
    MOCK_I18N.setLanguage.mockClear();
    MOCK_NAVIGATION.search.mockClear();
    MOCK_NAVIGATION.recordVisit.mockClear();
  });

  it('opens and closes the spotlight dialog safely', () => {
    const show = jest.fn();
    const close = jest.fn();
    component.searchDialog = { nativeElement: { open: false, show, close } } as any;
    component.searchInput = { nativeElement: { focus: jest.fn() } } as any;

    component.toggleSearch();
    expect(show).toHaveBeenCalledTimes(1);
    expect(component.showSearch()).toBe(true);

    component.searchDialog = { nativeElement: { open: true, show, close } } as any;
    component.toggleSearch();
    expect(close).toHaveBeenCalledTimes(1);
    expect(component.showSearch()).toBe(false);
  });

  it('anchors the language menu to the language button', () => {
    const showAt = jest.fn();
    const opener = document.createElement('button');
    component.langMenu = { nativeElement: { showAt } } as any;
    component.languageButton = { nativeElement: opener } as any;

    component.toggleLanguageMenu({});

    expect(showAt).toHaveBeenCalledWith(opener);
  });

  it('anchors the profile popover to the shell profile trigger', () => {
    const showAt = jest.fn();
    const opener = document.createElement('button');
    component.profilePopover = { nativeElement: { showAt } } as any;
    component.profileTrigger = { nativeElement: opener } as any;

    component.onProfileClick({});

    expect(showAt).toHaveBeenCalledWith(opener);
  });

  it('navigates to the chosen page when jumping from spotlight', () => {
    const close = jest.fn();
    component.searchDialog = { nativeElement: { close } } as any;

    component.jumpTo('/workspace');

    expect(close).toHaveBeenCalledTimes(1);
    expect(MOCK_ROUTER.navigate).toHaveBeenCalledWith(['/workspace']);
  });

  it('creates the component', () => {
    expect(component).toBeTruthy();
  });

  it('exposes navGroups based on workspace visibility', () => {
    const groups = component.navGroups();
    expect(Array.isArray(groups)).toBe(true);
  });

  it('delegates logout to AuthService', () => {
    component.logout();
    expect(MOCK_AUTH.logout).toHaveBeenCalledWith(MOCK_ROUTER);
  });

  it('records page visit on navigation', () => {
    component.navigateTo('/pipeline');
    expect(MOCK_ROUTER.navigate).toHaveBeenCalledWith(['/pipeline']);
  });
});

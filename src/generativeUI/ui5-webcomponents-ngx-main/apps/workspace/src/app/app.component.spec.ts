import { Router } from '@angular/router';
import { AppComponent } from './app.component';
import { LearnPathService } from './core/learn-path.service';
import { ProductNavigationService } from './core/product-navigation.service';
import { QuickAccessService } from './core/quick-access.service';
import { WorkspaceService } from './core/workspace.service';

jest.mock('@angular/core', () => {
  const actual = jest.requireActual('@angular/core');
  return {
    ...actual,
    effect: jest.fn((fn: () => void) => fn()),
  };
});

jest.mock('@ui5/webcomponents-ngx/i18n', () => ({
  I18nService: class {
    setLanguage(): void {}
  },
}));

function makeRouter(): Router {
  return {
    events: { pipe: jest.fn().mockReturnValue({ subscribe: jest.fn() }) },
    url: '/',
    navigate: jest.fn(),
  } as unknown as Router;
}

function makeLearnPath(): LearnPathService {
  return {
    active: false,
    currentStep: null,
    currentIndex: 0,
    steps: [],
    syncWithUrl: jest.fn(),
    next: jest.fn().mockReturnValue(null),
    stop: jest.fn(),
  } as unknown as LearnPathService;
}

function makeI18nService(): { setLanguage: jest.Mock } {
  return {
    setLanguage: jest.fn(),
  };
}

function makeWorkspaceService() {
  return {
    settings: () => ({ theme: 'sap_horizon', language: 'en' }),
    navConfig: () => ({ defaultLandingPath: '/' }),
    visibleNavLinks: () => [],
    visibleHomeCards: () => [],
    updateTheme: jest.fn(),
    updateLanguage: jest.fn(),
  } as unknown as WorkspaceService;
}

function makeProductNavigationService() {
  return {
    navigateToLanding: jest.fn(),
    navigateToApp: jest.fn(),
  } as unknown as ProductNavigationService;
}

function makeQuickAccessService() {
  return {
    isPinned: jest.fn().mockReturnValue(false),
    canPin: jest.fn().mockReturnValue(true),
    pinnedEntries: () => [],
    recentEntries: () => [],
    suggestedEntries: () => [],
    search: jest.fn().mockReturnValue([]),
    recordVisit: jest.fn(),
    togglePinned: jest.fn(),
  } as unknown as QuickAccessService;
}

describe('AppComponent language switch', () => {
  beforeEach(() => {
    document.documentElement.setAttribute('dir', 'ltr');
    document.documentElement.setAttribute('lang', 'en');
    localStorage.clear();
  });

  it('switches to Arabic and updates document direction', () => {
    const component = new AppComponent(
      makeRouter(),
      makeLearnPath(),
      makeI18nService() as unknown as any,
      makeWorkspaceService(),
      makeProductNavigationService(),
      makeQuickAccessService(),
    );

    component.onLanguageChange({
      detail: { selectedOption: { value: 'ar' } },
    } as unknown as Event);

    expect(component.currentLanguage).toBe('ar');
    expect(document.documentElement.getAttribute('dir')).toBe('rtl');
    expect(document.documentElement.getAttribute('lang')).toBe('ar');
    expect(localStorage.getItem('ui5-language')).toBe('ar');
  });

  it('switches to English and updates document direction', () => {
    const component = new AppComponent(
      makeRouter(),
      makeLearnPath(),
      makeI18nService() as unknown as any,
      makeWorkspaceService(),
      makeProductNavigationService(),
      makeQuickAccessService(),
    );

    component.onLanguageChange({
      detail: { selectedOption: { value: 'en' } },
    } as unknown as Event);

    expect(component.currentLanguage).toBe('en');
    expect(document.documentElement.getAttribute('dir')).toBe('ltr');
    expect(document.documentElement.getAttribute('lang')).toBe('en');
    expect(localStorage.getItem('ui5-language')).toBe('en');
  });
});

describe('AppComponent navigation', () => {
  it('delegates landing navigation to the product navigation service', () => {
    const productNavigation = makeProductNavigationService();
    const component = new AppComponent(
      makeRouter(),
      makeLearnPath(),
      makeI18nService() as unknown as any,
      makeWorkspaceService(),
      productNavigation,
      makeQuickAccessService(),
    );

    component.openLanding();

    expect(productNavigation.navigateToLanding).toHaveBeenCalled();
  });

  it('delegates product-switch selection through the product navigation service', () => {
    const productNavigation = makeProductNavigationService();
    const component = new AppComponent(
      makeRouter(),
      makeLearnPath(),
      makeI18nService() as unknown as any,
      makeWorkspaceService(),
      productNavigation,
      makeQuickAccessService(),
    );

    component.onProductSelect({
      detail: {
        item: {
          getAttribute: jest.fn().mockReturnValue('training'),
        },
      },
    });

    expect(productNavigation.navigateToApp).toHaveBeenCalledWith('training');
  });
});

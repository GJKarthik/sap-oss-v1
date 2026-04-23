// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, CUSTOM_ELEMENTS_SCHEMA, ElementRef, ViewChild } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { I18nPipe } from '@ui5/webcomponents-ngx/i18n';
import { WorkspaceService } from './core/workspace.service';
import { NavLinkDatum } from './core/workspace.types';
import { QuickAccessService } from './core/quick-access.service';
import { HomeLayoutService, HomeWidgetId } from './core/home-layout.service';
import { ProductNavigationService } from './core/product-navigation.service';
import { Ui5WorkspaceComponentsModule } from './shared/ui5-workspace-components.module';
import { ServiceHealthPanelComponent } from './shared/service-health-panel/service-health-panel.component';

interface HomeStat {
  value: string;
  labelKey: string;
}

interface HomeJourney {
  labelKey: string;
  bodyKey: string;
  cards: NavLinkDatum[];
}

interface QuickAccessCard {
  card: NavLinkDatum;
  contextKey: string;
}

interface PortfolioCard {
  id: 'experience' | 'training';
  icon: string;
  titleKey: string;
  bodyKey: string;
  path: string;
}

const EXPLORE_PATHS = ['/components', '/mcp', '/readiness'];
const WORK_PATHS = ['/joule', '/generative', '/ocr'];
const SUPPORTED_LANGUAGE_COUNT = 7;
const LIVE_SERVICE_COUNT = 3;
const WIDGET_TITLE_KEYS: Record<HomeWidgetId, string> = {
  journeys: 'HOME_FLOW_TITLE',
  quickAccess: 'QUICK_ACCESS_TITLE',
  productAreas: 'HOME_SECTION_TITLE',
  serviceHealth: 'NAV_READINESS',
  productFamily: 'PRODUCT_SWITCHER',
};

@Component({
  selector: 'app-main',
  standalone: true,
  imports: [CommonModule, I18nPipe, Ui5WorkspaceComponentsModule, ServiceHealthPanelComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  templateUrl: './main.component.html',
  styleUrls: ['./main.component.scss'],
})
export class MainComponent {
  @ViewChild('layoutDialog') private layoutDialog?: ElementRef<any>;

  constructor(
    private router: Router,
    private workspaceService: WorkspaceService,
    private quickAccess: QuickAccessService,
    private homeLayout: HomeLayoutService,
    private productNavigation: ProductNavigationService,
  ) {}

  readonly visibleWidgets = this.homeLayout.orderedWidgets;
  readonly widgetIds = Object.keys(WIDGET_TITLE_KEYS) as HomeWidgetId[];

  get homeCards(): NavLinkDatum[] {
    return this.workspaceService.visibleHomeCards();
  }

  get homeStats(): HomeStat[] {
    return [
      { value: String(this.homeCards.length), labelKey: 'HOME_STAT_AREAS' },
      { value: String(LIVE_SERVICE_COUNT), labelKey: 'HOME_STAT_SERVICES' },
      { value: String(SUPPORTED_LANGUAGE_COUNT), labelKey: 'HOME_STAT_LANGUAGES' },
    ];
  }

  get journeys(): HomeJourney[] {
    const cards = this.homeCards;
    return [
      {
        labelKey: 'HOME_JOURNEY_LEARN_LABEL',
        bodyKey: 'HOME_JOURNEY_LEARN_BODY',
        cards: this.cardsForPaths(cards, EXPLORE_PATHS),
      },
      {
        labelKey: 'HOME_JOURNEY_USE_LABEL',
        bodyKey: 'HOME_JOURNEY_USE_BODY',
        cards: this.cardsForPaths(cards, WORK_PATHS),
      },
    ].filter((journey) => journey.cards.length > 0);
  }

  get quickAccessCards(): QuickAccessCard[] {
    const cards = [
      ...this.quickAccess.pinnedEntries().map((card) => ({ card, contextKey: 'QUICK_ACCESS_SAVED' })),
      ...this.quickAccess.recentEntries().map((card) => ({ card, contextKey: 'QUICK_ACCESS_RECENT' })),
    ];
    const seen = new Set<string>();
    return cards
      .filter((entry) => entry.card.path !== '/workspace')
      .filter((entry) => {
        if (seen.has(entry.card.path)) {
          return false;
        }
        seen.add(entry.card.path);
        return true;
      })
      .slice(0, 4);
  }

  get fallbackQuickAccessCards(): QuickAccessCard[] {
    return this.quickAccess
      .suggestedEntries(4)
      .filter((card) => card.path !== '/workspace')
      .map((card) => ({ card, contextKey: 'QUICK_ACCESS_SUGGESTED' }));
  }

  get portfolioCards(): PortfolioCard[] {
    return [
      {
        id: 'experience',
        icon: 'grid',
        titleKey: 'APP_TITLE',
        bodyKey: 'HOME_PRODUCT_EXPERIENCE_DESC',
        path: '/joule',
      },
      {
        id: 'training',
        icon: 'process',
        titleKey: 'PRODUCT_TRAINING',
        bodyKey: 'HOME_PRODUCT_TRAINING_DESC',
        path: '/dashboard',
      },
    ];
  }

  navigateTo(path: string): void {
    this.router.navigate([path]);
  }

  openTrainingWorkbench(): void {
    this.productNavigation.navigateToApp('training', '/dashboard');
  }

  trackByJourney(_index: number, journey: HomeJourney): string {
    return journey.labelKey;
  }

  trackByPath(_index: number, card: NavLinkDatum): string {
    return card.path;
  }

  trackByQuickAccess(_index: number, entry: QuickAccessCard): string {
    return entry.card.path;
  }

  trackByPortfolio(_index: number, entry: PortfolioCard): string {
    return entry.id;
  }

  cardDescriptionId(index: number): string {
    return `home-card-desc-${index}`;
  }

  widgetTitleKey(widgetId: HomeWidgetId): string {
    return WIDGET_TITLE_KEYS[widgetId];
  }

  trackByWidget(_index: number, widgetId: HomeWidgetId): string {
    return widgetId;
  }

  isWidgetVisible(widgetId: HomeWidgetId): boolean {
    return this.homeLayout.isVisible(widgetId);
  }

  toggleWidget(widgetId: HomeWidgetId): void {
    this.homeLayout.toggleVisibility(widgetId);
  }

  moveWidget(widgetId: HomeWidgetId, direction: 'up' | 'down'): void {
    this.homeLayout.move(widgetId, direction);
  }

  resetLayout(): void {
    this.homeLayout.reset();
  }

  openLayoutDialog(): void {
    this.layoutDialog?.nativeElement?.show?.();
  }

  closeLayoutDialog(): void {
    this.layoutDialog?.nativeElement?.close?.();
  }

  openProduct(card: PortfolioCard): void {
    if (card.id === 'training') {
      this.openTrainingWorkbench();
      return;
    }

    this.navigateTo(card.path);
  }

  private cardsForPaths(cards: NavLinkDatum[], paths: string[]): NavLinkDatum[] {
    return paths
      .map((path) => cards.find((card) => card.path === path))
      .filter((card): card is NavLinkDatum => Boolean(card));
  }
}

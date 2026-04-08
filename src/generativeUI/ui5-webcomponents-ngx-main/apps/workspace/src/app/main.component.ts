// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component } from '@angular/core';
import { Router } from '@angular/router';
import { WorkspaceService } from './core/workspace.service';
import { NavLinkDatum } from './core/workspace.types';

interface HomeStat {
  value: string;
  labelKey: string;
}

interface HomeJourney {
  labelKey: string;
  bodyKey: string;
  cards: NavLinkDatum[];
}

const EXPLORE_PATHS = ['/forms', '/components', '/mcp'];
const WORK_PATHS = ['/joule', '/generative', '/ocr'];
const SUPPORTED_LANGUAGE_COUNT = 7;
const LIVE_SERVICE_COUNT = 3;

@Component({
  templateUrl: './main.component.html',
  styleUrls: ['./main.component.scss'],
  standalone: false,
})
export class MainComponent {
  constructor(
    private router: Router,
    private workspaceService: WorkspaceService,
  ) {}

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

  navigateTo(path: string): void {
    this.router.navigate([path]);
  }

  trackByJourney(_index: number, journey: HomeJourney): string {
    return journey.labelKey;
  }

  trackByPath(_index: number, card: NavLinkDatum): string {
    return card.path;
  }

  cardDescriptionId(index: number): string {
    return `home-card-desc-${index}`;
  }

  private cardsForPaths(cards: NavLinkDatum[], paths: string[]): NavLinkDatum[] {
    return paths
      .map((path) => cards.find((card) => card.path === path))
      .filter((card): card is NavLinkDatum => Boolean(card));
  }
}

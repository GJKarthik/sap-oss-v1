import {
  ChangeDetectionStrategy,
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  ElementRef,
  OnInit,
  ViewChild,
  computed,
  inject,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { AppStore } from '../../store/app.store';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';
import { NavigationAssistantService } from '../../services/navigation-assistant.service';
import {
  TRAINING_NAV_GROUPS,
  TRAINING_ROUTE_LINKS,
  TrainingRouteGroupId,
  TrainingRouteLink,
} from '../../app.navigation';
import { DashboardLayoutService, DashboardWidgetId } from '../../services/dashboard-layout.service';
import { AppLinkService } from '../../services/app-link.service';
import type { AppMode } from '../../shared/utils/mode.types';

interface HubCard {
  id: TrainingRouteGroupId;
  icon: string;
  bodyKey: string;
  path: string;
  routes: TrainingRouteLink[];
}

interface ProductCard {
  appId: 'training' | 'experience';
  icon: string;
  titleKey: string;
  bodyKey: string;
  path: string;
}

interface ModeHeroState {
  badge: string;
  body: string;
  primary: TrainingRouteLink;
  secondary: TrainingRouteLink;
}

const PRIORITY_PATHS = ['/pipeline', '/model-optimizer', '/hana-explorer', '/document-linguist'];
const HUB_ICONS: Record<TrainingRouteGroupId, string> = {
  home: 'home',
  data: 'folder',
  assist: 'discussion-2',
  operations: 'process',
};
const HUB_BODY_KEYS: Record<TrainingRouteGroupId, string> = {
  home: 'dashboard.hub.homeDesc',
  data: 'dashboard.hub.dataDesc',
  assist: 'dashboard.hub.assistDesc',
  operations: 'dashboard.hub.operationsDesc',
};
const WIDGET_TITLE_KEYS: Record<DashboardWidgetId, string> = {
  hubMap: 'dashboard.widget.hubs',
  quickAccess: 'dashboard.quickAccess',
  liveSignals: 'dashboard.widget.liveSignals',
  priorityActions: 'dashboard.widget.tasks',
  productFamily: 'dashboard.widget.apps',
};

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, Ui5TrainingComponentsModule, LocaleNumberPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './dashboard.component.html',
  styleUrls: ['./dashboard.component.scss'],
})
export class DashboardComponent implements OnInit {
  readonly store = inject(AppStore);
  private readonly toast = inject(ToastService);
  private readonly router = inject(Router);
  readonly i18n = inject(I18nService);
  readonly navigationAssistant = inject(NavigationAssistantService);
  readonly layout = inject(DashboardLayoutService);
  private readonly appLinks = inject(AppLinkService);

  @ViewChild('layoutDialog') private layoutDialog?: ElementRef<any>;

  readonly visibleWidgets = this.layout.orderedWidgets;
  readonly activeMode = this.store.activeMode;

  readonly quickAccessEntries = computed<TrainingRouteLink[]>(() => {
    const entries = [
      ...this.navigationAssistant.pinnedEntries(),
      ...this.navigationAssistant.recentEntries(),
    ];
    const seen = new Set<string>();
    return entries
      .filter((entry) => entry.path !== '/dashboard')
      .filter((entry) => {
        if (seen.has(entry.path)) {
          return false;
        }
        seen.add(entry.path);
        return true;
      })
      .slice(0, 6);
  });

  readonly fallbackEntries = computed(() =>
    this.navigationAssistant
      .suggestedEntries(6)
      .filter((entry) => entry.path !== '/dashboard'),
  );

  readonly heroContinueEntries = computed<TrainingRouteLink[]>(() => {
    const combined = [...this.quickAccessEntries(), ...this.fallbackEntries()];
    const seen = new Set<string>();
    return combined
      .filter((entry) => {
        if (seen.has(entry.path)) {
          return false;
        }
        seen.add(entry.path);
        return true;
      })
      .slice(0, 3);
  });

  readonly priorityActions = computed(() => {
    const suggested = new Set(this.store.routeRelevance().suggested);
    const modeActions = TRAINING_ROUTE_LINKS.filter((link) => suggested.has(link.path)).slice(0, 4);

    if (modeActions.length > 0) {
      return modeActions;
    }

    return PRIORITY_PATHS
      .map((path) => TRAINING_ROUTE_LINKS.find((link) => link.path === path))
      .filter((entry): entry is TrainingRouteLink => Boolean(entry));
  });

  readonly heroState = computed<ModeHeroState>(() => {
    const states: Record<AppMode, { badge: string; body: string; primary: string; secondary: string }> = {
      chat: {
        badge: 'Chat mode',
        body: 'Conversation-first guidance is in focus. Explore assistant routes before you execute.',
        primary: '/chat',
        secondary: '/semantic-search',
      },
      cowork: {
        badge: 'Cowork mode',
        body: 'Plan-and-preview collaboration is active. Review proposals before changing shared systems.',
        primary: '/rag-studio',
        secondary: '/analytical-dashboard',
      },
      training: {
        badge: 'Training mode',
        body: 'Execution routes are prioritized. Launch jobs, inspect data, and commit operational changes directly.',
        primary: '/pipeline',
        secondary: '/data-products',
      },
    };

    const state = states[this.activeMode()];
    return {
      badge: state.badge,
      body: state.body,
      primary: this.findRoute(state.primary),
      secondary: this.findRoute(state.secondary),
    };
  });

  readonly hubCards = computed<HubCard[]>(() =>
    TRAINING_NAV_GROUPS.map((group) => ({
      id: group.id,
      icon: HUB_ICONS[group.id],
      bodyKey: HUB_BODY_KEYS[group.id],
      path: group.defaultPath,
      routes: TRAINING_ROUTE_LINKS
        .filter((link) => link.group === group.id && link.path !== group.defaultPath)
        .slice(0, 3),
    })),
  );

  readonly productCards = computed<ProductCard[]>(() => [
    {
      appId: 'training',
      icon: 'process',
      titleKey: 'product.training',
      bodyKey: 'dashboard.product.workbenchDesc',
      path: '/dashboard',
    },
    {
      appId: 'experience',
      icon: 'grid',
      titleKey: 'product.joule',
      bodyKey: 'dashboard.product.experienceDesc',
      path: '/',
    },
  ]);

  readonly milestones = [
    { title: 'HANA Vector Engine Sharding', subtitle: 'Baseline Verified', status: 'done' },
    { title: 'Liquid Glass Optical Integrity', subtitle: 'Cycle 4 in Progress (WWDC Standard)', status: 'active' },
    { title: 'GA Release Candidate', subtitle: 'Final Hardware Handoff', status: 'pending' },
  ];

  readonly widgetIds = Object.keys(WIDGET_TITLE_KEYS) as DashboardWidgetId[];

  ngOnInit(): void {
    this.store.loadDashboardData();
  }

  refresh(): void {
    this.store.forceRefresh();
    this.toast.info(this.i18n.t('dashboard.refreshMsg'));
  }

  getDepStatus(key: string): string {
    const deps = this.store.health().data?.dependencies as Record<string, string> | undefined;
    return deps ? deps[key] || '—' : '—';
  }

  getActionDescription(entry: TrainingRouteLink): string {
    const descriptions: Record<string, string> = {
      '/pipeline': 'dashboard.comp.pipelineDesc',
      '/model-optimizer': 'dashboard.comp.modelOptDesc',
      '/hana-explorer': 'dashboard.comp.hanaCloudDesc',
      '/document-linguist': 'linguist.subtitle',
    };
    return descriptions[entry.path] ?? entry.labelKey;
  }

  widgetTitleKey(widgetId: DashboardWidgetId): string {
    return WIDGET_TITLE_KEYS[widgetId];
  }

  isWidgetVisible(widgetId: DashboardWidgetId): boolean {
    return this.layout.isVisible(widgetId);
  }

  toggleWidget(widgetId: DashboardWidgetId): void {
    this.layout.toggleVisibility(widgetId);
  }

  moveWidget(widgetId: DashboardWidgetId, direction: 'up' | 'down'): void {
    this.layout.move(widgetId, direction);
  }

  resetLayout(): void {
    this.layout.reset();
  }

  openLayoutDialog(): void {
    this.layoutDialog?.nativeElement?.show?.();
  }

  closeLayoutDialog(): void {
    this.layoutDialog?.nativeElement?.close?.();
  }

  navigateToRoute(path: string): void {
    void this.router.navigate([path]);
  }

  openExperience(): void {
    this.appLinks.navigate('experience', '/');
  }

  launchProduct(card: ProductCard): void {
    if (card.appId === 'training') {
      this.navigateToRoute(card.path);
      return;
    }

    this.appLinks.navigate(card.appId, card.path);
  }

  groupLabelKey(group: TrainingRouteGroupId): string {
    const keys: Record<TrainingRouteGroupId, string> = {
      home: 'navGroup.home',
      data: 'navGroup.data',
      assist: 'navGroup.assist',
      operations: 'navGroup.operations',
    };
    return keys[group];
  }

  private findRoute(path: string): TrainingRouteLink {
    const route = TRAINING_ROUTE_LINKS.find((link) => link.path === path);
    if (!route) {
      throw new Error(`Missing route definition for ${path}`);
    }
    return route;
  }
}

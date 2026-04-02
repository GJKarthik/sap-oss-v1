/**
 * @sap-oss/sac-webcomponents-ngx/sdk — Widget base, containers, CustomWidget
 *
 * Specs:
 *   standard/basic_widgets_client.odps.yaml — Widget base
 *   standard/customwidget_client.odps.yaml — CustomWidget
 *   containers/panel_client.odps.yaml — Panel
 *   containers/popup_client.odps.yaml — Popup
 *   containers/tabstrip_client.odps.yaml — TabStrip
 *   containers/tab_client.odps.yaml — Tab
 *   containers/pagebook_client.odps.yaml — PageBook
 *   containers/pagebookpage_client.odps.yaml — PageBookPage
 *   containers/flowpanel_client.odps.yaml — FlowPanel
 *   containers/composite_client.odps.yaml — Composite
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/widgets/ + containers/
 */

import type { SACRestAPIClient } from '../client';
import type {
  OperationResult, WidgetState, WidgetSearchOptions, WidgetType, LayoutValue,
  CustomWidgetProperty, CustomWidgetDataBinding, CustomWidgetMessage, CustomWidgetState,
} from '../types';
import { Layout } from '../core';

type EventHandler = (...args: unknown[]) => void;

// ---------------------------------------------------------------------------
// Widget — base class for all SAC widgets
// Spec: basic_widgets_client.odps.yaml + widget_handler.zig
// ---------------------------------------------------------------------------

export class Widget {
  protected _handlers: Map<string, Set<EventHandler>> = new Map();

  constructor(
    protected readonly client: SACRestAPIClient,
    public readonly id: string,
  ) {}

  // -- Visibility -----------------------------------------------------------

  async isVisible(): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/visible`);
  }

  async setVisible(visible: boolean): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/visible`, { visible });
  }

  // -- Enabled --------------------------------------------------------------

  async isEnabled(): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/enabled`);
  }

  async setEnabled(enabled: boolean): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/enabled`, { enabled });
  }

  // -- CSS ------------------------------------------------------------------

  async getCssClass(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/css`);
  }

  async setCssClass(cssClass: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/css`, { cssClass });
  }

  // -- Layout (delegates to Layout class from core) -------------------------

  getLayout(): Layout {
    return new Layout(this.client, this.id);
  }

  async setLayout(layout: {
    top?: LayoutValue; left?: LayoutValue; width?: LayoutValue; height?: LayoutValue;
  }): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/layout`, layout);
  }

  // -- Hierarchy ------------------------------------------------------------

  async getParent(): Promise<string | null> {
    return this.client.get<string | null>(`/widget/${e(this.id)}/parent`);
  }

  async getChildren(): Promise<string[]> {
    return this.client.get<string[]>(`/widget/${e(this.id)}/children`);
  }

  // -- State ----------------------------------------------------------------

  async getState(): Promise<WidgetState> {
    return this.client.get<WidgetState>(`/widget/${e(this.id)}/state`);
  }

  async destroy(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/widget/${e(this.id)}`);
  }

  // -- Events ---------------------------------------------------------------

  on(event: string, handler: EventHandler): this {
    if (!this._handlers.has(event)) this._handlers.set(event, new Set());
    this._handlers.get(event)!.add(handler);
    return this;
  }

  off(event: string, handler: EventHandler): this {
    this._handlers.get(event)?.delete(handler);
    return this;
  }

  once(event: string, handler: EventHandler): this {
    const wrapper: EventHandler = (...args) => { this.off(event, wrapper); handler(...args); };
    return this.on(event, wrapper);
  }

  // -- Factory --------------------------------------------------------------

  static async findWidgets(
    client: SACRestAPIClient, options?: WidgetSearchOptions,
  ): Promise<{ widgets: string[]; totalCount: number }> {
    return client.post('/widget/search', options ?? {});
  }

  static async create(
    client: SACRestAPIClient, widgetType: WidgetType, id?: string,
  ): Promise<Widget> {
    const res = await client.post<{ id: string }>('/widget/create', { widgetType, id });
    return new Widget(client, res.id);
  }
}

// ---------------------------------------------------------------------------
// Panel — container with busy indicator, collapse, title
// Spec: containers/panel_client.odps.yaml
// ---------------------------------------------------------------------------

export class Panel extends Widget {
  // -- Widget management ----------------------------------------------------

  async moveWidget(widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/moveWidget`, { widgetId });
  }

  async addWidget(widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/children`, { widgetId });
  }

  async removeWidget(widgetId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/widget/${e(this.id)}/children/${e(widgetId)}`);
  }

  async getWidgets(): Promise<string[]> { return this.getChildren(); }

  async getChildCount(): Promise<number> {
    return this.client.get<number>(`/widget/${e(this.id)}/childCount`);
  }

  async clearChildren(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/widget/${e(this.id)}/children`);
  }

  async containsWidget(widgetId: string): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/contains/${e(widgetId)}`);
  }

  // -- Busy indicator -------------------------------------------------------

  async showBusyIndicator(text?: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/busyIndicator/show`, { text });
  }

  async hideBusyIndicator(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/busyIndicator/hide`);
  }

  async isBusyIndicatorVisible(): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/busyIndicator/visible`);
  }

  async getBusyIndicatorText(): Promise<string | null> {
    return this.client.get<string | null>(`/widget/${e(this.id)}/busyIndicator/text`);
  }

  // -- Collapse -------------------------------------------------------------

  async collapse(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/collapse`);
  }

  async expand(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/expand`);
  }

  async isCollapsed(): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/collapsed`);
  }

  async setCollapsible(collapsible: boolean): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/collapsible`, { collapsible });
  }

  async isCollapsible(): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/collapsible`);
  }

  // -- Title ----------------------------------------------------------------

  async getTitle(): Promise<string | null> {
    return this.client.get<string | null>(`/widget/${e(this.id)}/title`);
  }

  async setTitle(title: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/title`, { title });
  }
}

// ---------------------------------------------------------------------------
// Popup — modal dialog
// Spec: containers/popup_client.odps.yaml
// ---------------------------------------------------------------------------

export interface PopupButton {
  id: string;
  text: string;
  enabled: boolean;
  type: string;
}

export class Popup extends Widget {
  // -- State ----------------------------------------------------------------

  async isOpen(): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/open`);
  }

  async isModal(): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/modal`);
  }

  // -- Title / CSS ----------------------------------------------------------

  async getTitle(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/title`);
  }

  // -- Buttons --------------------------------------------------------------

  async isButtonEnabled(buttonId: string): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/button/${e(buttonId)}/enabled`);
  }

  async getButtonConfig(buttonId: string): Promise<PopupButton> {
    return this.client.get<PopupButton>(`/widget/${e(this.id)}/button/${e(buttonId)}`);
  }

  // -- Actions --------------------------------------------------------------

  async close(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/close`);
  }

  async hideBusyIndicator(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/busyIndicator/hide`);
  }
}

// ---------------------------------------------------------------------------
// Tab — single tab within TabStrip
// Spec: containers/tab_client.odps.yaml
// ---------------------------------------------------------------------------

export class Tab extends Widget {
  async getKey(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/key`);
  }

  async getText(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/text`);
  }

  async setText(text: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/text`, { text });
  }
}

// ---------------------------------------------------------------------------
// TabStrip — tabbed navigation container
// Spec: containers/tabstrip_client.odps.yaml
// ---------------------------------------------------------------------------

export class TabStrip extends Widget {
  async getSelectedKey(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/selectedKey`);
  }

  async setSelectedKey(key: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/selectedKey`, { key });
  }

  async getTab(tabKey: string): Promise<Tab> {
    const data = await this.client.get<{ id: string }>(
      `/widget/${e(this.id)}/tab/${e(tabKey)}`,
    );
    return new Tab(this.client, data.id);
  }

  async moveWidget(tabName: string, widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/widget/${e(this.id)}/moveWidget`, { tabName, widgetId },
    );
  }

  async hideBusyIndicator(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/busyIndicator/hide`);
  }

  async getTabCount(): Promise<number> {
    return this.client.get<number>(`/widget/${e(this.id)}/tabCount`);
  }

  async getAllTabKeys(): Promise<string[]> {
    return this.client.get<string[]>(`/widget/${e(this.id)}/tabKeys`);
  }

  async hasTab(tabKey: string): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/hasTab/${e(tabKey)}`);
  }

  async isTabSelected(tabKey: string): Promise<boolean> {
    return this.client.get<boolean>(`/widget/${e(this.id)}/isTabSelected/${e(tabKey)}`);
  }
}

// ---------------------------------------------------------------------------
// PageBookPage — single page within PageBook
// Spec: containers/pagebookpage_client.odps.yaml
// ---------------------------------------------------------------------------

export class PageBookPage extends Widget {
  async getKey(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/key`);
  }
}

// ---------------------------------------------------------------------------
// PageBook — multi-page container
// Spec: containers/pagebook_client.odps.yaml
// ---------------------------------------------------------------------------

export class PageBook extends Widget {
  async getSelectedKey(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/selectedKey`);
  }

  async setSelectedKey(pageKey: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/selectedKey`, { pageKey });
  }

  async getPage(pageKey: string): Promise<PageBookPage> {
    const data = await this.client.get<{ id: string }>(
      `/widget/${e(this.id)}/page/${e(pageKey)}`,
    );
    return new PageBookPage(this.client, data.id);
  }

  async moveWidget(pageKey: string, widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/widget/${e(this.id)}/moveWidget`, { pageKey, widgetId },
    );
  }

  async showBusyIndicator(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/busyIndicator/show`);
  }

  async hideBusyIndicator(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/busyIndicator/hide`);
  }
}

// ---------------------------------------------------------------------------
// FlowPanel — flowing layout container
// Spec: containers/flowpanel_client.odps.yaml
// ---------------------------------------------------------------------------

export class FlowPanel extends Widget {
  async moveWidget(widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/moveWidget`, { widgetId });
  }

  async showBusyIndicator(text?: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/busyIndicator/show`, { text });
  }

  async hideBusyIndicator(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/busyIndicator/hide`);
  }
}

// ---------------------------------------------------------------------------
// Composite — grouping container
// Spec: containers/composite_client.odps.yaml
// ---------------------------------------------------------------------------

export class Composite extends Widget {
  async getName(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/name`);
  }
}

// ---------------------------------------------------------------------------
// ScrollContainer — scrollable container (no dedicated spec, from widget_handler)
// ---------------------------------------------------------------------------

export class ScrollContainer extends Widget {
  async scrollTo(top: number, left: number): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/scrollTo`, { top, left });
  }

  async scrollToWidget(widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/scrollToWidget`, { widgetId });
  }

  async getScrollPosition(): Promise<{ top: number; left: number }> {
    return this.client.get(`/widget/${e(this.id)}/scrollPosition`);
  }
}

// ---------------------------------------------------------------------------
// Lane — lane container (no dedicated spec, from widget_handler)
// ---------------------------------------------------------------------------

export class Lane extends Widget {
  async getTitle(): Promise<string> {
    return this.client.get<string>(`/widget/${e(this.id)}/title`);
  }

  async setTitle(title: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/title`, { title });
  }

  async moveWidget(widgetId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/moveWidget`, { widgetId });
  }
}

// ---------------------------------------------------------------------------
// CustomWidget — extensible widget for custom JS/HTML components
// Spec: standard/customwidget_client.odps.yaml
// ---------------------------------------------------------------------------

export class CustomWidget extends Widget {
  // -- Property management --------------------------------------------------

  async getProperty(propertyName: string): Promise<unknown> {
    return this.client.get(`/widget/${e(this.id)}/property/${e(propertyName)}`);
  }

  async setProperty(propertyName: string, value: unknown): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `/widget/${e(this.id)}/property/${e(propertyName)}`, { value },
    );
  }

  async getProperties(): Promise<CustomWidgetProperty[]> {
    return this.client.get<CustomWidgetProperty[]>(`/widget/${e(this.id)}/properties`);
  }

  // -- Data binding ---------------------------------------------------------

  async getDataBinding(): Promise<CustomWidgetDataBinding> {
    return this.client.get<CustomWidgetDataBinding>(`/widget/${e(this.id)}/dataBinding`);
  }

  async setDataBinding(binding: CustomWidgetDataBinding): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/dataBinding`, binding);
  }

  async getBoundData(): Promise<Record<string, unknown>> {
    return this.client.get<Record<string, unknown>>(`/widget/${e(this.id)}/boundData`);
  }

  async refreshData(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/refreshData`);
  }

  // -- Communication --------------------------------------------------------

  async sendMessage(message: CustomWidgetMessage): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/message`, message);
  }

  async dispatchEvent(eventName: string, eventData: Record<string, unknown>): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/widget/${e(this.id)}/dispatchEvent`, { eventName, eventData },
    );
  }

  // -- State ----------------------------------------------------------------

  async getWidgetState(): Promise<CustomWidgetState> {
    return this.client.get<CustomWidgetState>(`/widget/${e(this.id)}/widgetState`);
  }

  async reload(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/widget/${e(this.id)}/reload`);
  }

  // -- Sizing ---------------------------------------------------------------

  async getWidth(): Promise<number> {
    return this.client.get<number>(`/widget/${e(this.id)}/width`);
  }

  async setWidth(width: number): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/width`, { width });
  }

  async getHeight(): Promise<number> {
    return this.client.get<number>(`/widget/${e(this.id)}/height`);
  }

  async setHeight(height: number): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/widget/${e(this.id)}/height`, { height });
  }

  // -- Factory --------------------------------------------------------------

  static async getCustomWidget(client: SACRestAPIClient, widgetId: string): Promise<CustomWidget> {
    return new CustomWidget(client, widgetId);
  }
}

// ---------------------------------------------------------------------------
// Event type maps (Rule 8)
// ---------------------------------------------------------------------------

export interface PopupEvents {
  open: (popupId: string) => void;
  close: (popupId: string) => void;
}

export interface TabStripEvents {
  select: (tabIndex: number, tabId: string) => void;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }

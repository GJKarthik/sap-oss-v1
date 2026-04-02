/**
 * Widget types — from sap-sac-webcomponents-ts/src/widgets
 */

export interface WidgetConfig {
  visible?: boolean;
  enabled?: boolean;
  cssClass?: string;
  width?: string;
  height?: string;
}

export interface PanelConfig extends WidgetConfig {
  title?: string;
  collapsible?: boolean;
  collapsed?: boolean;
}

export interface PopupConfig extends WidgetConfig {
  title?: string;
  modal?: boolean;
}

export interface PopupButton {
  id: string;
  text: string;
  enabled: boolean;
  type: string;
}

export interface TabStripConfig extends WidgetConfig {
  selectedKey?: string;
}

export interface PageBookConfig extends WidgetConfig {
  selectedKey?: string;
}

export interface CustomWidgetConfig extends WidgetConfig {
  properties?: Record<string, unknown>;
  dataBinding?: CustomWidgetDataBinding;
}

export interface CustomWidgetDataBinding {
  dataSource?: string;
  dimensions?: string[];
  measures?: string[];
}

export interface CustomWidgetProperty {
  name: string;
  type: string;
  value: unknown;
  defaultValue?: unknown;
}

export interface CustomWidgetMessage {
  type: string;
  payload: unknown;
}

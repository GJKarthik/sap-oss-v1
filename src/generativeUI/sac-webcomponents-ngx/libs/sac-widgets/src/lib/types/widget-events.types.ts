/**
 * Widget event types — from sap-sac-webcomponents-ts/src/widgets
 */

export interface PopupEvents {
  open: (popupId: string) => void;
  close: (popupId: string) => void;
}

export interface TabStripEvents {
  select: (tabIndex: number, tabId: string) => void;
}

export interface WidgetResizeEvent {
  width: number;
  height: number;
}

export interface WidgetVisibilityEvent {
  visible: boolean;
}

export interface PanelCollapseEvent {
  collapsed: boolean;
}

export interface CustomWidgetMessageEvent {
  type: string;
  payload: unknown;
}

export interface CustomWidgetPropertyChangeEvent {
  propertyName: string;
  oldValue: unknown;
  newValue: unknown;
}

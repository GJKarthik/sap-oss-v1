/**
 * Application Enums
 *
 * Re-exports shared enums from the package SDK bundle (single source of truth).
 * NGX-only extras (Panel, Popup, TabStrip, PageBook, FlowPanel) appended to WidgetType
 * via the local extension below.
 */
export {
  ApplicationMode,
  ApplicationMessageType,
  DeviceOrientation,
  DeviceType,
  ViewMode,
  WidgetType,
  LayoutUnit,
  Direction,
  UrlType,
  UserType,
} from '@sap-oss/sac-sdk';

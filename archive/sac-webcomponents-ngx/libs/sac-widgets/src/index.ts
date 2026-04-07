/**
 * @sap-oss/sac-webcomponents-ngx/widgets
 *
 * Angular Widgets Module for SAP Analytics Cloud containers and base widgets.
 * Covers: Widget, Panel, Popup, TabStrip, Tab, PageBook, PageBookPage,
 *         FlowPanel, Composite, ScrollContainer, Lane, CustomWidget.
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacWidgetsModule } from './lib/sac-widgets.module';

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

export { SacWidgetComponent } from './lib/components/sac-widget.component';
export { SacPanelComponent } from './lib/components/sac-panel.component';
export { SacPopupComponent } from './lib/components/sac-popup.component';
export { SacTabStripComponent } from './lib/components/sac-tabstrip.component';
export { SacPageBookComponent } from './lib/components/sac-pagebook.component';
export { SacCustomWidgetComponent } from './lib/components/sac-custom-widget.component';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { SacWidgetService } from './lib/services/sac-widget.service';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  WidgetConfig,
  PanelConfig,
  PopupConfig,
  PopupButton,
  TabStripConfig,
  PageBookConfig,
  CustomWidgetConfig,
  CustomWidgetDataBinding,
  CustomWidgetProperty,
  CustomWidgetMessage,
} from './lib/types/widget.types';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export type {
  PopupEvents,
  TabStripEvents,
  WidgetResizeEvent,
  WidgetVisibilityEvent,
  PanelCollapseEvent,
  CustomWidgetMessageEvent,
  CustomWidgetPropertyChangeEvent,
} from './lib/types/widget-events.types';

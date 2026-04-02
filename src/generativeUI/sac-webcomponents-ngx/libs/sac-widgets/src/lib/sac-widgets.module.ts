/**
 * SAC Widgets Module
 *
 * Angular module for SAC widget containers and base components.
 * Covers: Widget, Panel, Popup, TabStrip, Tab, PageBook, FlowPanel,
 *         Composite, ScrollContainer, Lane, CustomWidget.
 * Selector prefix: sac-widget-* (from mangle/sac_widget.mg)
 */

import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';

import { SacWidgetComponent } from './components/sac-widget.component';
import { SacPanelComponent } from './components/sac-panel.component';
import { SacPopupComponent } from './components/sac-popup.component';
import { SacTabStripComponent } from './components/sac-tabstrip.component';
import { SacPageBookComponent } from './components/sac-pagebook.component';
import { SacCustomWidgetComponent } from './components/sac-custom-widget.component';
import { SacWidgetService } from './services/sac-widget.service';

const COMPONENTS = [
  SacWidgetComponent,
  SacPanelComponent,
  SacPopupComponent,
  SacTabStripComponent,
  SacPageBookComponent,
  SacCustomWidgetComponent,
];

@NgModule({
  imports: [CommonModule],
  declarations: COMPONENTS,
  exports: COMPONENTS,
  providers: [SacWidgetService],
})
export class SacWidgetsModule {}

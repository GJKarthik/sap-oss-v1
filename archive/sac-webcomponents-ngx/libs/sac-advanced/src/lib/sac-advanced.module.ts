/**
 * SAC Advanced Module
 *
 * Angular module for advanced SAC features: SmartDiscovery, Forecast,
 * Export, MultiAction, LinkedAnalysis, DataBindings, Simulation, Alert,
 * Bookmarks, PageState, Commenting, Display widgets, GeoMap, KPI, VDT.
 * Selector prefix: sac-* (from mangle/sac_widget.mg)
 */

import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';

import { SacGeoMapComponent } from './components/sac-geomap.component';
import { SacKpiComponent } from './components/sac-kpi.component';
import { SacDisplayWidgetComponent } from './components/sac-display-widget.component';
import { SacAdvancedService } from './services/sac-advanced.service';

const COMPONENTS = [
  SacGeoMapComponent,
  SacKpiComponent,
  SacDisplayWidgetComponent,
];

@NgModule({
  imports: [CommonModule],
  declarations: COMPONENTS,
  exports: COMPONENTS,
  providers: [SacAdvancedService],
})
export class SacAdvancedModule {}

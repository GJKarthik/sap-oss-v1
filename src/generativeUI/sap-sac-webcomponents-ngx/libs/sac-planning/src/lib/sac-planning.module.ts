/**
 * SAC Planning Module
 *
 * Angular module for SAC planning operations.
 * Derived from mangle/sac_planning.mg specifications.
 */

import { NgModule, ModuleWithProviders } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClientModule } from '@angular/common/http';

import { SacPlanningModelService } from './services/sac-planning-model.service';
import { SacDataActionService } from './services/sac-data-action.service';
import { SacAllocationService } from './services/sac-allocation.service';
import { SacPlanningPanelComponent } from './components/sac-planning-panel.component';

@NgModule({
  imports: [
    CommonModule,
    HttpClientModule,
  ],
  declarations: [
    SacPlanningPanelComponent,
  ],
  exports: [
    SacPlanningPanelComponent,
  ],
  providers: [
    SacPlanningModelService,
    SacDataActionService,
    SacAllocationService,
  ],
})
export class SacPlanningModule {
  static forRoot(): ModuleWithProviders<SacPlanningModule> {
    return {
      ngModule: SacPlanningModule,
      providers: [
        SacPlanningModelService,
        SacDataActionService,
        SacAllocationService,
      ],
    };
  }
}
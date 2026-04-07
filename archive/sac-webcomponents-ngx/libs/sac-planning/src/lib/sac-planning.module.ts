/**
 * SAC Planning Module
 *
 * Angular module for SAC planning operations.
 * Derived from mangle/sac_planning.mg specifications.
 */

import { NgModule, ModuleWithProviders } from '@angular/core';
import { CommonModule } from '@angular/common';
import { provideHttpClient, withInterceptorsFromDi } from '@angular/common/http';

import { SacPlanningModelService } from './services/sac-planning-model.service';
import { SacDataActionService } from './services/sac-data-action.service';
import { SacAllocationService } from './services/sac-allocation.service';
import { SacPlanningPanelComponent } from './components/sac-planning-panel.component';

@NgModule({
  imports: [
    CommonModule,
  ],
  declarations: [
    SacPlanningPanelComponent,
  ],
  exports: [
    SacPlanningPanelComponent,
  ],
  providers: [
    provideHttpClient(withInterceptorsFromDi()),
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
        provideHttpClient(withInterceptorsFromDi()),
        SacPlanningModelService,
        SacDataActionService,
        SacAllocationService,
      ],
    };
  }
}
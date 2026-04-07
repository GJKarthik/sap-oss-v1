/**
 * SAC DataSource Module
 *
 * Angular module for SAC DataSource operations.
 * Derived from mangle/sac_datasource.mg specifications.
 */

import { NgModule, ModuleWithProviders } from '@angular/core';
import { provideHttpClient, withInterceptorsFromDi } from '@angular/common/http';

import { SacDataSourceService } from './services/sac-datasource.service';
import { SacFilterService } from './services/sac-filter.service';
import { SacVariableService } from './services/sac-variable.service';

@NgModule({
  providers: [
    provideHttpClient(withInterceptorsFromDi()),
    SacDataSourceService,
    SacFilterService,
    SacVariableService,
  ],
})
export class SacDataSourceModule {
  static forRoot(): ModuleWithProviders<SacDataSourceModule> {
    return {
      ngModule: SacDataSourceModule,
      providers: [
        provideHttpClient(withInterceptorsFromDi()),
        SacDataSourceService,
        SacFilterService,
        SacVariableService,
      ],
    };
  }
}
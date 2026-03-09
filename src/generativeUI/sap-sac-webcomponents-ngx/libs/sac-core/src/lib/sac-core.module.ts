/**
 * SAC Core Module
 *
 * Root Angular module providing core SAC services and configuration.
 * Derived from mangle/sac_widget.mg specifications.
 */

import { NgModule, ModuleWithProviders } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClientModule } from '@angular/common/http';

import { SacConfigService } from './services/sac-config.service';
import { SacApiService } from './services/sac-api.service';
import { SacAuthService } from './services/sac-auth.service';
import { SacEventService } from './services/sac-event.service';
import { SAC_CONFIG, SAC_API_URL, SAC_AUTH_TOKEN } from './tokens';
import { SacConfig } from './types/config.types';

@NgModule({
  imports: [
    CommonModule,
    HttpClientModule,
  ],
  providers: [
    SacConfigService,
    SacApiService,
    SacAuthService,
    SacEventService,
  ],
})
export class SacCoreModule {
  /**
   * Configure the SAC Core module with application-specific settings.
   *
   * @param config SAC configuration object
   * @returns Module with providers
   *
   * @example
   * ```typescript
   * @NgModule({
   *   imports: [
   *     SacCoreModule.forRoot({
   *       apiUrl: 'https://tenant.sapanalytics.cloud',
   *       authToken: 'bearer-token',
   *       tenant: 'my-tenant'
   *     })
   *   ]
   * })
   * export class AppModule {}
   * ```
   */
  static forRoot(config: SacConfig): ModuleWithProviders<SacCoreModule> {
    return {
      ngModule: SacCoreModule,
      providers: [
        { provide: SAC_CONFIG, useValue: config },
        { provide: SAC_API_URL, useValue: config.apiUrl },
        { provide: SAC_AUTH_TOKEN, useValue: config.authToken },
        SacConfigService,
        SacApiService,
        SacAuthService,
        SacEventService,
      ],
    };
  }

  /**
   * Import SAC Core module in feature modules without re-providing services.
   */
  static forChild(): ModuleWithProviders<SacCoreModule> {
    return {
      ngModule: SacCoreModule,
      providers: [],
    };
  }
}
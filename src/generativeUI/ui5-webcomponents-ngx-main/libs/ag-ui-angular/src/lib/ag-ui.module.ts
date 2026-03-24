// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AG-UI Angular Module
 *
 * Provides the AG-UI client and related services for Angular applications.
 */

import { NgModule, ModuleWithProviders, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { AgUiClient, AgUiClientConfig, AG_UI_CONFIG } from './services/ag-ui-client.service';
import { AgUiToolRegistry } from './services/tool-registry.service';
import { JouleChatComponent } from './joule-chat/joule-chat.component';

/**
 * AG-UI Module
 *
 * Import this module in your Angular application to enable AG-UI functionality.
 *
 * @example
 * ```typescript
 * @NgModule({
 *   imports: [
 *     AgUiModule.forRoot({
 *       endpoint: 'http://localhost:8080/ag-ui',
 *       transport: 'sse',
 *       autoConnect: true
 *     })
 *   ]
 * })
 * export class AppModule {}
 * ```
 */
@NgModule({
  imports: [CommonModule, JouleChatComponent],
  exports: [JouleChatComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  providers: [],
})
export class AgUiModule {
  /**
   * Configure the AG-UI module for the root application
   *
   * @param config AG-UI client configuration
   * @returns Module with providers
   */
  static forRoot(config: AgUiClientConfig): ModuleWithProviders<AgUiModule> {
    return {
      ngModule: AgUiModule,
      providers: [
        { provide: AG_UI_CONFIG, useValue: config },
        AgUiClient,
        AgUiToolRegistry,
      ],
    };
  }

  /**
   * Import AG-UI module in a feature module (uses parent configuration)
   *
   * @returns Module without providers
   */
  static forChild(): ModuleWithProviders<AgUiModule> {
    return {
      ngModule: AgUiModule,
      providers: [],
    };
  }
}
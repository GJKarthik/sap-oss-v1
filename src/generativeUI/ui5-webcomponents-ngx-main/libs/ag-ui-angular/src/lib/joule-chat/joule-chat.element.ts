// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * joule-chat.element.ts
 *
 * Bootstraps JouleChatComponent as a standalone Angular Elements custom element.
 * Import and call bootstrapJouleChatElement() from your application entry point
 * to register <joule-chat> as a native Custom Element.
 *
 * @example
 * // main.ts (or polyfills.ts)
 * import { bootstrapJouleChatElement } from '@ui5/ag-ui-angular';
 * bootstrapJouleChatElement({ endpoint: '/ag-ui/run' });
 */

import { Injector, ApplicationRef, Provider, EnvironmentProviders } from '@angular/core';
import { createApplication } from '@angular/platform-browser';
import { createCustomElement } from '@angular/elements';
import { JouleChatComponent } from './joule-chat.component';
import { AgUiClient, AG_UI_CONFIG, AgUiClientConfig } from '../services/ag-ui-client.service';
import { AgUiToolRegistry } from '../services/tool-registry.service';

/** Options for bootstrapping the joule-chat custom element */
export interface JouleChatElementOptions {
  /** Default AG-UI endpoint (can be overridden per-instance via the endpoint attribute) */
  endpoint?: string;
  /** Angular element tag name — default: 'joule-chat' */
  tagName?: string;
  /** Additional Angular providers */
  providers?: (Provider | EnvironmentProviders)[];
}

let bootstrapped = false;

/**
 * Register <joule-chat> as a native Custom Element backed by Angular.
 * Safe to call multiple times — only bootstraps once.
 */
export async function bootstrapJouleChatElement(
  options: JouleChatElementOptions = {}
): Promise<void> {
  if (bootstrapped || customElements.get(options.tagName ?? 'joule-chat')) {
    return;
  }
  bootstrapped = true;

  const defaultConfig: AgUiClientConfig = {
    endpoint: options.endpoint ?? '/ag-ui/run',
    transport: 'sse',
    autoConnect: false,
  };

  const appRef: ApplicationRef = await createApplication({
    providers: [
      { provide: AG_UI_CONFIG, useValue: defaultConfig },
      AgUiClient,
      AgUiToolRegistry,
      ...(options.providers ?? []),
    ],
  });

  const injector: Injector = appRef.injector;

  const JouleChatElement = createCustomElement(JouleChatComponent, { injector });

  const tag = options.tagName ?? 'joule-chat';
  customElements.define(tag, JouleChatElement);
}

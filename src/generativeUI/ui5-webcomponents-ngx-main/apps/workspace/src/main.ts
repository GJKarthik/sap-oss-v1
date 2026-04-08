// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE

// Set NODE_ENV to production to eliminate Lit dev mode warning
if (typeof (globalThis as any).process === 'undefined') {
  (globalThis as any).process = { env: { NODE_ENV: 'production' } };
} else if (!(globalThis as any).process.env.NODE_ENV) {
  (globalThis as any).process.env.NODE_ENV = 'production';
}

import {enableProdMode} from '@angular/core';
import {platformBrowserDynamic} from '@angular/platform-browser-dynamic';
import '@ui5/webcomponents-base/dist/Assets.js';
import '@ui5/webcomponents-theming/dist/Assets.js';
import '@ui5/webcomponents-icons/dist/Assets.js';
import '@ui5/webcomponents/dist/generated/json-imports/Themes.js';
import '@ui5/webcomponents-fiori/dist/generated/json-imports/Themes.js';

import {AppModule} from './app/app.module';
import {environment} from './environments/environment';
import './ui5-icons';
import './ui5-locales';
import './ui5-messagebundles';

if (environment.production) {
  enableProdMode();
}

platformBrowserDynamic()
  .bootstrapModule(AppModule).catch((err) => console.error(err));

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE

if (typeof (globalThis as any).process === 'undefined') {
  (globalThis as any).process = { env: { NODE_ENV: 'production' } };
} else if (!(globalThis as any).process.env.NODE_ENV) {
  (globalThis as any).process.env.NODE_ENV = 'production';
}

import { bootstrapApplication } from '@angular/platform-browser';
import { enableProdMode } from '@angular/core';
import '@ui5/webcomponents-base/dist/Assets.js';
import '@ui5/webcomponents-icons/dist/Assets.js';

import { AppComponent } from './app/app.component';
import { appConfig } from './app/app.config';
import { environment } from './environments/environment';
import './ui5-icons';
import './ui5-locales';
import './ui5-messagebundles';
import './ui5-themes';

if (environment.production) {
  enableProdMode();
}

bootstrapApplication(AppComponent, appConfig).catch((err) => console.error(err));
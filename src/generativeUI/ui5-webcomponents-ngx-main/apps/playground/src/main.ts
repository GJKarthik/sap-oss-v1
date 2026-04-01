// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {enableProdMode} from '@angular/core';
import {platformBrowserDynamic} from '@angular/platform-browser-dynamic';
import '@ui5/webcomponents/dist/Assets.js';
import '@ui5/webcomponents-fiori/dist/Assets.js';
import '@ui5/webcomponents-ai/dist/Assets.js';
import '@ui5/webcomponents-localization/dist/Assets.js';
import '@ui5/webcomponents-icons/dist/Assets.js';
import '@ui5/webcomponents-icons-tnt/dist/Assets.js';
import '@ui5/webcomponents-icons-business-suite/dist/Assets.js';
import { registerI18nLoader } from '@ui5/webcomponents-base/dist/asset-registries/i18n.js';

import {AppModule} from './app/app.module';
import {environment} from './environments/environment';

const fallbackIconTexts = {
  ICON_ERROR: 'Error',
  ICON_OVERFLOW: 'More',
  SHELLBAR_IMAGE_BTN: 'Logo',
  SHELLBAR_LABEL: 'Shell Bar',
  SHELLBAR_OVERFLOW: 'More options',
  SHELLBAR_NOTIFICATIONS: 'Notifications',
  SHELLBAR_NOTIFICATIONS_NO_COUNT: 'Notifications',
  SHELLBAR_PROFILE: 'Profile',
  SHELLBAR_PRODUCTS: 'Products',
  SHELLBAR_SEARCH: 'Search',
  SHELLBAR_LOGO_AREA: 'Logo area',
};

// Work around missing i18n asset registration in dev builds.
registerI18nLoader('@ui5/webcomponents-icons', 'en', async () => fallbackIconTexts);
registerI18nLoader('@ui5/webcomponents-fiori', 'en', async () => fallbackIconTexts);

if (environment.production) {
  enableProdMode();
}

platformBrowserDynamic()
  .bootstrapModule(AppModule).catch((err) => console.error(err));

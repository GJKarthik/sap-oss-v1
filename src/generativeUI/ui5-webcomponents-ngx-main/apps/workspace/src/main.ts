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
import '@ui5/webcomponents/dist/generated/json-imports/i18n.js';
import '@ui5/webcomponents-fiori/dist/generated/json-imports/Themes.js';
import '@ui5/webcomponents-fiori/dist/generated/json-imports/i18n.js';
import '@ui5/webcomponents-ai/dist/generated/json-imports/Themes.js';
import '@ui5/webcomponents-ai/dist/generated/json-imports/i18n.js';
import { registerI18nLoader } from '@ui5/webcomponents-base/dist/asset-registries/i18n.js';

import {AppModule} from './app/app.module';
import {environment} from './environments/environment';
import './ui5-icons';
import './ui5-locales';

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
  SHELLBAR_PRODUCT_SWITCH_BTN: 'Product Switch',
};

const fallbackIconTextsAr = {
  ICON_ERROR: 'خطأ',
  ICON_OVERFLOW: 'المزيد',
  SHELLBAR_IMAGE_BTN: 'الشعار',
  SHELLBAR_LABEL: 'شريط القشرة',
  SHELLBAR_OVERFLOW: 'خيارات إضافية',
  SHELLBAR_NOTIFICATIONS: 'الإشعارات',
  SHELLBAR_NOTIFICATIONS_NO_COUNT: 'الإشعارات',
  SHELLBAR_PROFILE: 'الملف الشخصي',
  SHELLBAR_PRODUCTS: 'المنتجات',
  SHELLBAR_SEARCH: 'بحث',
  SHELLBAR_LOGO_AREA: 'منطقة الشعار',
  SHELLBAR_PRODUCT_SWITCH_BTN: 'تبديل المنتج',
};

// Work around missing i18n asset registration in dev builds.
registerI18nLoader('@ui5/webcomponents-icons', 'en', async () => fallbackIconTexts);
registerI18nLoader('@ui5/webcomponents-fiori', 'en', async () => fallbackIconTexts);
registerI18nLoader('@ui5/webcomponents-icons', 'ar', async () => fallbackIconTextsAr);
registerI18nLoader('@ui5/webcomponents-fiori', 'ar', async () => fallbackIconTextsAr);

if (environment.production) {
  enableProdMode();
}

platformBrowserDynamic()
  .bootstrapModule(AppModule).catch((err) => console.error(err));

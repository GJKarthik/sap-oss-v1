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
import '@ui5/webcomponents-icons-business-suite/dist/AllIcons.js';
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
  SHELLBAR_PRODUCT_SWITCH_BTN: 'مبدل المنتجات',
};

const fallbackIconTextsFr = {
  ICON_ERROR: 'Erreur',
  ICON_OVERFLOW: 'Plus',
  SHELLBAR_IMAGE_BTN: 'Logo',
  SHELLBAR_LABEL: 'Barre de shell',
  SHELLBAR_OVERFLOW: 'Plus d options',
  SHELLBAR_NOTIFICATIONS: 'Notifications',
  SHELLBAR_NOTIFICATIONS_NO_COUNT: 'Notifications',
  SHELLBAR_PROFILE: 'Profil',
  SHELLBAR_PRODUCTS: 'Produits',
  SHELLBAR_SEARCH: 'Rechercher',
  SHELLBAR_LOGO_AREA: 'Zone du logo',
  SHELLBAR_PRODUCT_SWITCH_BTN: 'Selecteur de produit',
};

// Work around missing i18n asset registration in dev builds.
registerI18nLoader('@ui5/webcomponents-icons', 'en', async () => fallbackIconTexts);
registerI18nLoader('@ui5/webcomponents-fiori', 'en', async () => fallbackIconTexts);
registerI18nLoader('@ui5/webcomponents-icons', 'ar', async () => fallbackIconTextsAr);
registerI18nLoader('@ui5/webcomponents-fiori', 'ar', async () => fallbackIconTextsAr);
registerI18nLoader('@ui5/webcomponents-icons', 'fr', async () => fallbackIconTextsFr);
registerI18nLoader('@ui5/webcomponents-fiori', 'fr', async () => fallbackIconTextsFr);

if (environment.production) {
  enableProdMode();
}

platformBrowserDynamic()
  .bootstrapModule(AppModule).catch((err) => console.error(err));

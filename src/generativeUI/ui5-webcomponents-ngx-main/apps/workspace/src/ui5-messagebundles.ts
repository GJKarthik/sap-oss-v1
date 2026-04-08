import { registerI18nLoader } from '@ui5/webcomponents-base/dist/asset-registries/i18n.js';

type BundleLoader = () => Promise<unknown>;

const supportedLocales = ['ar', 'de', 'en', 'fr', 'id', 'ko', 'zh_CN'] as const;

const webcomponentsBundles: Record<(typeof supportedLocales)[number], BundleLoader> = {
  ar: () => import('@ui5/webcomponents/dist/generated/assets/i18n/messagebundle_ar.json').then((m) => m.default),
  de: () => import('@ui5/webcomponents/dist/generated/assets/i18n/messagebundle_de.json').then((m) => m.default),
  en: () => import('@ui5/webcomponents/dist/generated/assets/i18n/messagebundle_en.json').then((m) => m.default),
  fr: () => import('@ui5/webcomponents/dist/generated/assets/i18n/messagebundle_fr.json').then((m) => m.default),
  id: () => import('@ui5/webcomponents/dist/generated/assets/i18n/messagebundle_id.json').then((m) => m.default),
  ko: () => import('@ui5/webcomponents/dist/generated/assets/i18n/messagebundle_ko.json').then((m) => m.default),
  zh_CN: () => import('@ui5/webcomponents/dist/generated/assets/i18n/messagebundle_zh_CN.json').then((m) => m.default),
};

const fioriBundles: Record<(typeof supportedLocales)[number], BundleLoader> = {
  ar: () => import('@ui5/webcomponents-fiori/dist/generated/assets/i18n/messagebundle_ar.json').then((m) => m.default),
  de: () => import('@ui5/webcomponents-fiori/dist/generated/assets/i18n/messagebundle_de.json').then((m) => m.default),
  en: () => import('@ui5/webcomponents-fiori/dist/generated/assets/i18n/messagebundle_en.json').then((m) => m.default),
  fr: () => import('@ui5/webcomponents-fiori/dist/generated/assets/i18n/messagebundle_fr.json').then((m) => m.default),
  id: () => import('@ui5/webcomponents-fiori/dist/generated/assets/i18n/messagebundle_id.json').then((m) => m.default),
  ko: () => import('@ui5/webcomponents-fiori/dist/generated/assets/i18n/messagebundle_ko.json').then((m) => m.default),
  zh_CN: () => import('@ui5/webcomponents-fiori/dist/generated/assets/i18n/messagebundle_zh_CN.json').then((m) => m.default),
};

const bundlesByPackage: Record<string, Record<(typeof supportedLocales)[number], BundleLoader>> = {
  '@ui5/webcomponents': webcomponentsBundles,
  '@ui5/webcomponents-fiori': fioriBundles,
};

const loadBundle = async (loader: BundleLoader, localeId: string): Promise<any> => {
  const data = await loader();
  if (typeof data === 'string' && data.endsWith('.json')) {
    throw new Error(`[i18n] Invalid bundling detected for "${localeId}".`);
  }
  return data;
};

Object.entries(bundlesByPackage).forEach(([packageName, localeMap]) => {
  Object.entries(localeMap).forEach(([localeId, loader]) => {
    registerI18nLoader(packageName, localeId, async () => loadBundle(loader, localeId));
  });
});

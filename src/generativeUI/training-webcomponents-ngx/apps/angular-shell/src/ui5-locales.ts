import { registerLocaleDataLoader } from '@ui5/webcomponents-base/dist/asset-registries/LocaleData.js';

type LocaleLoader = () => Promise<unknown>;

const localeLoaders: Record<string, LocaleLoader> = {
  ar: () => import('@ui5/webcomponents-localization/dist/generated/assets/cldr/ar.json').then((m) => m.default),
  de: () => import('@ui5/webcomponents-localization/dist/generated/assets/cldr/de.json').then((m) => m.default),
  en: () => import('@ui5/webcomponents-localization/dist/generated/assets/cldr/en.json').then((m) => m.default),
  fr: () => import('@ui5/webcomponents-localization/dist/generated/assets/cldr/fr.json').then((m) => m.default),
  id: () => import('@ui5/webcomponents-localization/dist/generated/assets/cldr/id.json').then((m) => m.default),
  ko: () => import('@ui5/webcomponents-localization/dist/generated/assets/cldr/ko.json').then((m) => m.default),
  zh_CN: () => import('@ui5/webcomponents-localization/dist/generated/assets/cldr/zh_CN.json').then((m) => m.default),
};

const loadLocale = async (localeId: string): Promise<any> => {
  const data = await localeLoaders[localeId]();
  if (typeof data === 'string' && data.endsWith('.json')) {
    throw new Error(`[LocaleData] Invalid bundling detected for "${localeId}".`);
  }
  return data;
};

Object.keys(localeLoaders).forEach((localeId) => {
  registerLocaleDataLoader(localeId, async () => loadLocale(localeId));
});

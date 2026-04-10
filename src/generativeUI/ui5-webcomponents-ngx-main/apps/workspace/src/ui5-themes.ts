import { registerThemePropertiesLoader } from '@ui5/webcomponents-base/dist/asset-registries/Themes.js';

type ThemeName = 'sap_horizon' | 'sap_horizon_dark';
type ThemeLoader = () => Promise<string>;
type ThemeBundleMap = Record<ThemeName, ThemeLoader>;

const loadThemeBundle = async (loader: ThemeLoader, themeName: ThemeName): Promise<string> => {
  const data = await loader();
  if (typeof data === 'string' && data.endsWith('.json')) {
    throw new Error(`[themes] Invalid bundling detected for "${themeName}".`);
  }
  return data;
};

const webcomponentsThemingBundles: ThemeBundleMap = {
  sap_horizon: () =>
    import('@ui5/webcomponents-theming/dist/generated/assets/themes/sap_horizon/parameters-bundle.css.json').then((m) => m.default as string),
  sap_horizon_dark: () =>
    import('@ui5/webcomponents-theming/dist/generated/assets/themes/sap_horizon_dark/parameters-bundle.css.json').then((m) => m.default as string),
};

const webcomponentsBundles: ThemeBundleMap = {
  sap_horizon: () =>
    import('@ui5/webcomponents/dist/generated/assets/themes/sap_horizon/parameters-bundle.css.json').then((m) => m.default as string),
  sap_horizon_dark: () =>
    import('@ui5/webcomponents/dist/generated/assets/themes/sap_horizon_dark/parameters-bundle.css.json').then((m) => m.default as string),
};

const fioriBundles: ThemeBundleMap = {
  sap_horizon: () =>
    import('@ui5/webcomponents-fiori/dist/generated/assets/themes/sap_horizon/parameters-bundle.css.json').then((m) => m.default as string),
  sap_horizon_dark: () =>
    import('@ui5/webcomponents-fiori/dist/generated/assets/themes/sap_horizon_dark/parameters-bundle.css.json').then((m) => m.default as string),
};

const themeBundlesByPackage: Record<string, ThemeBundleMap> = {
  '@ui5/webcomponents-theming': webcomponentsThemingBundles,
  '@ui5/webcomponents': webcomponentsBundles,
  '@ui5/webcomponents-fiori': fioriBundles,
};

Object.entries(themeBundlesByPackage).forEach(([packageName, themeMap]) => {
  Object.entries(themeMap).forEach(([themeName, loader]) => {
    registerThemePropertiesLoader(
      packageName,
      themeName,
      async () => loadThemeBundle(loader, themeName as ThemeName),
    );
  });
});

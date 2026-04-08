import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { AppComponent } from './app/app.component';
import '@ui5/webcomponents-base/dist/Assets.js';
import '@ui5/webcomponents/dist/Icon.js';
import '@ui5/webcomponents-theming/dist/Assets.js';
import '@ui5/webcomponents-icons/dist/Assets.js';
import '@ui5/webcomponents/dist/generated/json-imports/Themes.js';
import '@ui5/webcomponents/dist/generated/json-imports/i18n.js';
import '@ui5/webcomponents-fiori/dist/generated/json-imports/Themes.js';
import '@ui5/webcomponents-fiori/dist/generated/json-imports/i18n.js';
import './ui5-icons';
import './ui5-locales';

bootstrapApplication(AppComponent, appConfig).catch((err) => console.error(err));

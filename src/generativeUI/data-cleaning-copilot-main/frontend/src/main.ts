import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { App } from './app/app';

// UI5 Web Components & theming
import '@ui5/webcomponents-theming/dist/Assets.js';
import '@ui5/webcomponents/dist/Assets.js';
import '@ui5/webcomponents-fiori/dist/Assets.js';
import '@ui5/webcomponents-icons/dist/Assets.js';

bootstrapApplication(App, appConfig).catch((err) => console.error(err));

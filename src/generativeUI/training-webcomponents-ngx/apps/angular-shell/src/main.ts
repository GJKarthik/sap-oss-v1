import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { AppComponent } from './app/app.component';
import '@ui5/webcomponents/dist/Assets.js';
import '@ui5/webcomponents/dist/Icon.js';
import '@ui5/webcomponents-fiori/dist/Assets.js';
import '@ui5/webcomponents-icons/dist/Assets.js';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
import '@ui5/webcomponents-icons-tnt/dist/AllIcons.js';
import '@ui5/webcomponents-icons-business-suite/dist/AllIcons.js';

bootstrapApplication(AppComponent, appConfig).catch((err) => console.error(err));

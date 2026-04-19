import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { AppComponent } from './app/app.component';
import '@ui5/webcomponents-base/dist/Assets.js';
import '@ui5/webcomponents/dist/Icon.js';
import '@ui5/webcomponents-fiori/dist/ShellBar.js';
import '@ui5/webcomponents-fiori/dist/ShellBarItem.js';

import './ui5-icons';
import './ui5-locales';
import './ui5-messagebundles';
import './ui5-themes';

bootstrapApplication(AppComponent, appConfig).catch((err) => console.error(err));
import { platformBrowserDynamic } from '@angular/platform-browser-dynamic';
import { AppModule } from './app/app.module';

// Initialize UI5 Web Components
import '@ui5/webcomponents/dist/Assets.js';
import '@ui5/webcomponents-fiori/dist/Assets.js';
import '@ui5/webcomponents-icons/dist/AllIcons.js';

// Ignore Angular component prefixes to avoid UI5 waiting for custom element registration
import { ignoreCustomElements } from '@ui5/webcomponents-base/dist/IgnoreCustomElements.js';
ignoreCustomElements('app-');

platformBrowserDynamic().bootstrapModule(AppModule)
  .catch(err => console.error(err));
import { Injectable } from '@angular/core';
import { WebcomponentsThemingProvider } from '@ui5/webcomponents-ngx/theming';

@Injectable({ providedIn: 'root' })
class Ui5WebcomponentsFioriThemingService extends WebcomponentsThemingProvider {
  name = 'ui-5-webcomponents-fiori-theming-service';
  constructor() {
    super(
      () =>
        import(
          '@ui5/webcomponents-fiori/dist/generated/json-imports/Themes.js'
        ),
    );
  }
}

export { Ui5WebcomponentsFioriThemingService };

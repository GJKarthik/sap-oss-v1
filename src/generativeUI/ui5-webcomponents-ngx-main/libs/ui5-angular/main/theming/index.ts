import { Injectable } from '@angular/core';
import { WebcomponentsThemingProvider } from '@ui5/webcomponents-ngx/theming';

@Injectable({ providedIn: 'root' })
class Ui5WebcomponentsMainThemingService extends WebcomponentsThemingProvider {
  name = 'ui-5-webcomponents-main-theming-service';
  constructor() {
    super(
      () => import('@ui5/webcomponents/dist/generated/json-imports/Themes.js'),
    );
  }
}

export { Ui5WebcomponentsMainThemingService };

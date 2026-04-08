import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { ReadinessPageComponent } from './readiness-page.component';

@NgModule({
  declarations: [ReadinessPageComponent],
  imports: [
    CommonModule,
    Ui5WebcomponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: ReadinessPageComponent }]),
  ],
})
export class ReadinessModule {}

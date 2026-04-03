import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { ComponentPlaygroundPageComponent } from './component-playground-page.component';

@NgModule({
  declarations: [ComponentPlaygroundPageComponent],
  imports: [
    CommonModule,
    Ui5WebcomponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: ComponentPlaygroundPageComponent }]),
  ],
})
export class ComponentPlaygroundModule {}

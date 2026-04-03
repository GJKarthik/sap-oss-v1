import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { GenerativePageComponent } from './generative-page.component';
import { GenerativeRendererComponent } from './generative-renderer.component';
import { GenerativeNodeBuilderComponent } from './generative-node-builder.component';

import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';

@NgModule({
  declarations: [GenerativePageComponent, GenerativeRendererComponent, GenerativeNodeBuilderComponent],
  imports: [
    CommonModule,
    Ui5WebcomponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([
      { path: '', component: GenerativePageComponent }
    ])
  ]
})
export class GenerativeModule { }

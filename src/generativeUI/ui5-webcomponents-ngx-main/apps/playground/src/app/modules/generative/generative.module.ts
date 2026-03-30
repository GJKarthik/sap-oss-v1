import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { GenerativePageComponent } from './generative-page.component';
import { GenerativeRendererComponent } from './generative-renderer.component';
import { GenerativeNodeBuilderComponent } from './generative-node-builder.component';

import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

@NgModule({
  declarations: [GenerativePageComponent, GenerativeRendererComponent, GenerativeNodeBuilderComponent],
  imports: [
    CommonModule,
    Ui5WebcomponentsModule,
    RouterModule.forChild([
      { path: '', component: GenerativePageComponent }
    ])
  ]
})
export class GenerativeModule { }

import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { GenerativePageComponent } from './generative-page.component';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { Ui5WorkspaceComponentsModule } from '../../shared/ui5-workspace-components.module';

@NgModule({
  imports: [
    CommonModule,
    Ui5WorkspaceComponentsModule,
    Ui5I18nModule,
    GenerativePageComponent,
    RouterModule.forChild([
      { path: '', component: GenerativePageComponent }
    ])
  ]
})
export class GenerativeModule { }

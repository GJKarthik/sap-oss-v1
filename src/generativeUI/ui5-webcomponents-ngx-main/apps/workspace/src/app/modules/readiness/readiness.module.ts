import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { ReadinessPageComponent } from './readiness-page.component';
import { Ui5WorkspaceComponentsModule } from '../../shared/ui5-workspace-components.module';

@NgModule({
  declarations: [ReadinessPageComponent],
  imports: [
    CommonModule,
    Ui5WorkspaceComponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: ReadinessPageComponent }]),
  ],
})
export class ReadinessModule {}

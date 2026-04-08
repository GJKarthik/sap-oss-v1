import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { ModelCatalogPageComponent } from './model-catalog-page.component';
import { Ui5WorkspaceComponentsModule } from '../../shared/ui5-workspace-components.module';

@NgModule({
  declarations: [ModelCatalogPageComponent],
  imports: [
    CommonModule,
    Ui5WorkspaceComponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: ModelCatalogPageComponent }]),
  ],
})
export class ModelCatalogModule {}

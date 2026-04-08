import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterModule } from '@angular/router';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { OcrPageComponent } from './ocr-page.component';
import { Ui5WorkspaceComponentsModule } from '../../shared/ui5-workspace-components.module';
import {
  WorkspaceLocaleCurrencyPipe,
  WorkspaceLocaleNumberPipe,
  WorkspaceLocalePercentPipe,
} from '../../shared/pipes/locale-format.pipe';

@NgModule({
  declarations: [OcrPageComponent],
  imports: [
    CommonModule,
    FormsModule,
    Ui5WorkspaceComponentsModule,
    Ui5I18nModule,
    WorkspaceLocaleCurrencyPipe,
    WorkspaceLocaleNumberPipe,
    WorkspaceLocalePercentPipe,
    RouterModule.forChild([{ path: '', component: OcrPageComponent }]),
  ],
})
export class OcrModule {}

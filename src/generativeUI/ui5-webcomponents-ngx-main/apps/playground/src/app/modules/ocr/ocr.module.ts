import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterModule } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { OcrPageComponent } from './ocr-page.component';
import {
  PlaygroundLocaleCurrencyPipe,
  PlaygroundLocaleNumberPipe,
  PlaygroundLocalePercentPipe,
} from '../../shared/pipes/locale-format.pipe';

@NgModule({
  declarations: [OcrPageComponent],
  imports: [
    CommonModule,
    FormsModule,
    Ui5WebcomponentsModule,
    Ui5I18nModule,
    PlaygroundLocaleCurrencyPipe,
    PlaygroundLocaleNumberPipe,
    PlaygroundLocalePercentPipe,
    RouterModule.forChild([{ path: '', component: OcrPageComponent }]),
  ],
})
export class OcrModule {}

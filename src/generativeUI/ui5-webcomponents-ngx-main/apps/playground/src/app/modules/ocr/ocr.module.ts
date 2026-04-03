import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterModule } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { OcrPageComponent } from './ocr-page.component';

@NgModule({
  declarations: [OcrPageComponent],
  imports: [
    CommonModule,
    FormsModule,
    Ui5WebcomponentsModule,
    RouterModule.forChild([{ path: '', component: OcrPageComponent }]),
  ],
})
export class OcrModule {}

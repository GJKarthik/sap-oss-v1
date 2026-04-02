import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { ComponentPlaygroundPageComponent } from './component-playground-page.component';

@NgModule({
  declarations: [ComponentPlaygroundPageComponent],
  imports: [
    CommonModule,
    Ui5WebcomponentsModule,
    RouterModule.forChild([{ path: '', component: ComponentPlaygroundPageComponent }]),
  ],
})
export class ComponentPlaygroundModule {}

import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterModule } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { McpPageComponent } from './mcp-page.component';

@NgModule({
  declarations: [McpPageComponent],
  imports: [
    CommonModule,
    FormsModule,
    Ui5WebcomponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: McpPageComponent }]),
  ],
})
export class McpModule {}

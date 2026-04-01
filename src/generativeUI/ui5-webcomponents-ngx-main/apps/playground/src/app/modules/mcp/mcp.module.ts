import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { McpPageComponent } from './mcp-page.component';

@NgModule({
  declarations: [McpPageComponent],
  imports: [
    CommonModule,
    Ui5WebcomponentsModule,
    RouterModule.forChild([{ path: '', component: McpPageComponent }]),
  ],
})
export class McpModule {}

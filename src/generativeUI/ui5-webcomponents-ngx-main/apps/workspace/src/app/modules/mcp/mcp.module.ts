import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterModule } from '@angular/router';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { McpPageComponent } from './mcp-page.component';
import { Ui5WorkspaceComponentsModule } from '../../shared/ui5-workspace-components.module';

@NgModule({
  declarations: [McpPageComponent],
  imports: [
    CommonModule,
    FormsModule,
    Ui5WorkspaceComponentsModule,
    Ui5I18nModule,
    RouterModule.forChild([{ path: '', component: McpPageComponent }]),
  ],
})
export class McpModule {}

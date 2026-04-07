/**
 * SAP AI Fabric Console - Angular App Module
 *
 * Uses UI5 Web Components for Angular following ui5-webcomponents-ngx standards.
 * Page components are loaded lazily via the routing module.
 */

import { NgModule } from '@angular/core';
import { BrowserModule } from '@angular/platform-browser';
import { BrowserAnimationsModule } from '@angular/platform-browser/animations';
import { provideHttpClient, withInterceptorsFromDi, HTTP_INTERCEPTORS } from '@angular/common/http';
import { FormsModule, ReactiveFormsModule } from '@angular/forms';

// UI5 Web Components for Angular
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

// Routing
import { AppRoutingModule } from './app-routing.module';

// Components (eagerly loaded shell)
import { AppComponent } from './app.component';
import { ShellComponent } from './components/shell/shell.component';

// Interceptors
import { AuthInterceptor } from './interceptors/auth.interceptor';

// Services
import { McpService } from './services/mcp.service';
import { AuthService } from './services/auth.service';
import { CollaborationService } from './services/collaboration.service';
import { TeamConfigService } from './services/team-config.service';
import { TeamGovernanceService } from './services/team-governance.service';

@NgModule({
  declarations: [
    AppComponent,
    ShellComponent,
  ],
  imports: [
    BrowserModule,
    BrowserAnimationsModule,
    FormsModule,
    ReactiveFormsModule,
    Ui5WebcomponentsModule,
    AppRoutingModule,
  ],
  providers: [
    provideHttpClient(withInterceptorsFromDi()),
    {
      provide: HTTP_INTERCEPTORS,
      useClass: AuthInterceptor,
      multi: true,
    },
    McpService,
    AuthService,
    CollaborationService,
    TeamConfigService,
    TeamGovernanceService,
  ],
  bootstrap: [AppComponent]
})
export class AppModule { }

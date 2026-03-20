/**
 * SAP AI Fabric Console - Angular App Module
 * 
 * Uses UI5 Web Components for Angular following ui5-webcomponents-ngx standards
 */

import { NgModule } from '@angular/core';
import { BrowserModule } from '@angular/platform-browser';
import { BrowserAnimationsModule } from '@angular/platform-browser/animations';
import { HttpClientModule } from '@angular/common/http';
import { FormsModule, ReactiveFormsModule } from '@angular/forms';

// UI5 Web Components for Angular
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

// Routing
import { AppRoutingModule } from './app-routing.module';

// Components
import { AppComponent } from './app.component';
import { ShellComponent } from './components/shell/shell.component';

// Pages
import { DashboardComponent } from './pages/dashboard/dashboard.component';
import { DeploymentsComponent } from './pages/deployments/deployments.component';
import { StreamingComponent } from './pages/streaming/streaming.component';
import { PlaygroundComponent } from './pages/playground/playground.component';
import { RagStudioComponent } from './pages/rag-studio/rag-studio.component';
import { DataExplorerComponent } from './pages/data-explorer/data-explorer.component';
import { LineageComponent } from './pages/lineage/lineage.component';
import { GovernanceComponent } from './pages/governance/governance.component';
import { LoginComponent } from './pages/login/login.component';

// Services
import { McpService } from './services/mcp.service';
import { AuthService } from './services/auth.service';

// Guards
import { AuthGuard } from './guards/auth.guard';

@NgModule({
  declarations: [
    AppComponent,
    ShellComponent,
    DashboardComponent,
    DeploymentsComponent,
    StreamingComponent,
    PlaygroundComponent,
    RagStudioComponent,
    DataExplorerComponent,
    LineageComponent,
    GovernanceComponent,
    LoginComponent,
  ],
  imports: [
    BrowserModule,
    BrowserAnimationsModule,
    HttpClientModule,
    FormsModule,
    ReactiveFormsModule,
    Ui5WebcomponentsModule,
    AppRoutingModule,
  ],
  providers: [
    McpService,
    AuthService,
    AuthGuard,
  ],
  bootstrap: [AppComponent]
})
export class AppModule { }

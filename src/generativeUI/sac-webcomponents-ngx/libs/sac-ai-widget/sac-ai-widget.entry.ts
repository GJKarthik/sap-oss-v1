// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Custom Widget Entry Point
 *
 * Implements the SAP Analytics Cloud Custom Widget lifecycle callbacks and
 * bootstraps the Angular 17 Elements application inside the SAC iframe.
 *
 * Lifecycle flow:
 *   1. SAC calls onCustomWidgetBeforeUpdate() with widget properties
 *      → extracts SAC bearer token, capBackendUrl, modelId, widgetType
 *      → stores token in SacAuthService for subsequent SSE calls
 *   2. SAC calls onCustomWidgetAfterUpdate()
 *      → bootstraps the Angular app (once) into this HTMLElement's shadow DOM
 *   3. SAC calls onCustomWidgetDestroy()
 *      → destroys the Angular app reference
 *
 * Upload widget.js + widget.json as widget.zip via SAC Designer.
 */

import 'zone.js';
import '@angular/compiler';
import { createApplication } from '@angular/platform-browser';
import {
  ApplicationRef,
  ComponentRef,
  EnvironmentInjector,
  createComponent,
  importProvidersFrom,
} from '@angular/core';
import { SacCoreModule, SacAuthService } from '@sap-oss/sac-webcomponents-ngx/core';
import { SAC_AI_BACKEND_URL, SAC_TENANT_URL, SAC_MODEL_ID } from './tokens';
import { SacAiChatPanelComponent } from './chat/sac-ai-chat-panel.component';
import { SacAiDataWidgetComponent } from './data-widget/sac-ai-data-widget.component';
import { getTenantFromTenantUrl, normalizeConfiguredUrl } from './url-validation';

// P2-002: Import expanded widget components
import { SacFilterDropdownComponent, SacFilterCheckboxComponent } from './components/sac-filter.component';
import { SacSliderComponent } from './components/sac-slider.component';
import { SacHeadingComponent, SacTextBlockComponent, SacDividerComponent } from './components/sac-text.component';
import { SacFlexContainerComponent, SacGridContainerComponent, SacGridItemComponent } from './components/sac-layout.component';
import type { SacWidgetType } from './types/sac-widget-schema';

// =============================================================================
// SAC Custom Widget property bag (from widget.json schema)
// =============================================================================

interface SacWidgetProperties {
  capBackendUrl?: string;
  tenantUrl?: string;
  modelId?: string;
  /** P2-002: Expanded widget types (was: 'chart' | 'table' | 'kpi') */
  widgetType?: SacWidgetType;
  /** SAC injects the session bearer token here at runtime */
  sacBearerToken?: string;
}

// =============================================================================
// Custom Element — bootstraps Angular on demand
// =============================================================================

class SacAiWidgetEntry extends HTMLElement {
  private appRef: ApplicationRef | null = null;
  private chatRef: ComponentRef<SacAiChatPanelComponent> | null = null;
  private dataRef: ComponentRef<SacAiDataWidgetComponent> | null = null;
  private props: SacWidgetProperties = {};
  private bootstrapped = false;

  // ---------------------------------------------------------------------------
  // SAC Custom Widget lifecycle callbacks
  // ---------------------------------------------------------------------------

  /** Called by SAC before rendering, supplying the designer properties. */
  onCustomWidgetBeforeUpdate(changedProperties: Record<string, unknown>): void {
    this.props = { ...this.props, ...(changedProperties as SacWidgetProperties) };
  }

  /** Called by SAC after the widget container is ready in the DOM. */
  onCustomWidgetAfterUpdate(changedProperties: Record<string, unknown>): void {
    const requiresRebootstrap = 'capBackendUrl' in changedProperties || 'tenantUrl' in changedProperties;

    if (!this.bootstrapped || requiresRebootstrap) {
      if (requiresRebootstrap) {
        this.destroyAngular();
      }

      this.bootstrapped = true;
      this.startBootstrap();
      return;
    }

    this.syncToken();
    this.syncInputs();
    this.flushViews();
  }

  /** Called by SAC when the widget is removed from the story. */
  onCustomWidgetDestroy(): void {
    this.destroyAngular();
  }

  // ---------------------------------------------------------------------------
  // Bootstrap
  // ---------------------------------------------------------------------------

  private startBootstrap(): void {
    void this.bootstrap().catch((error: unknown) => {
      this.bootstrapped = false;
      const message = error instanceof Error ? error.message : String(error);
      this.renderBootstrapError(message);
    });
  }

  private async bootstrap(): Promise<void> {
    const {
      capBackendUrl = '',
      tenantUrl = '',
      modelId = '',
      sacBearerToken = '',
    } = this.props;

    const validatedBackendUrl = normalizeConfiguredUrl(capBackendUrl, 'capBackendUrl');
    const validatedTenantUrl = normalizeConfiguredUrl(tenantUrl, 'tenantUrl');
    const tenant = getTenantFromTenantUrl(validatedTenantUrl);

    this.appRef = await createApplication({
      providers: [
        importProvidersFrom(
          SacCoreModule.forRoot({
            apiUrl: validatedTenantUrl,
            authToken: sacBearerToken,
            tenant,
          }),
        ),
        { provide: SAC_AI_BACKEND_URL, useValue: validatedBackendUrl },
        { provide: SAC_TENANT_URL, useValue: validatedTenantUrl },
        { provide: SAC_MODEL_ID, useValue: modelId },
      ],
    });

    const injector = this.appRef.injector.get(EnvironmentInjector);

    // Build the widget DOM inside a shadow root for style isolation
    const shadow = this.shadowRoot ?? this.attachShadow({ mode: 'open' });
    shadow.innerHTML = '';

    const host = document.createElement('div');
    host.style.cssText = 'display:flex;flex-direction:row;height:100%;width:100%;';
    shadow.appendChild(host);

    // Chat panel (left column)
    const chatHost = document.createElement('div');
    chatHost.style.cssText = 'width:320px;min-width:280px;border-right:1px solid var(--sapList_BorderColor, #e5e5e5);flex-shrink:0;';
    host.appendChild(chatHost);

    // Data widget (right column)
    const dataHost = document.createElement('div');
    dataHost.style.cssText = 'flex:1;overflow:hidden;';
    host.appendChild(dataHost);

    this.chatRef = createComponent(SacAiChatPanelComponent, {
      environmentInjector: injector,
      hostElement: chatHost,
    });

    this.dataRef = createComponent(SacAiDataWidgetComponent, {
      environmentInjector: injector,
      hostElement: dataHost,
    });

    this.appRef.attachView(this.chatRef.hostView);
    this.appRef.attachView(this.dataRef.hostView);

    this.syncToken();
    this.syncInputs();
    this.flushViews();
  }

  private renderBootstrapError(message: string): void {
    const shadow = this.shadowRoot ?? this.attachShadow({ mode: 'open' });
    shadow.innerHTML = '';

    const host = document.createElement('div');
    host.setAttribute('role', 'alert');
    host.style.cssText = [
      'display:flex',
      'align-items:center',
      'justify-content:center',
      'height:100%',
      'padding:1rem',
      'box-sizing:border-box',
      'background:#fff5f5',
      'border:1px solid #d32f2f',
      'color:#7f1d1d',
      'font:14px/1.5 sans-serif',
      'text-align:center',
    ].join(';');
    host.textContent = `SAC AI Widget configuration error: ${message}`;
    shadow.appendChild(host);
  }

  private syncToken(): void {
    if (!this.props.sacBearerToken || !this.appRef) return;
    try {
      const auth = this.appRef.injector.get(SacAuthService);
      auth.setToken(this.props.sacBearerToken);
    } catch {
      // no-op if service not resolved
    }
  }

  private syncInputs(): void {
    this.chatRef?.setInput('modelId', this.props.modelId ?? '');
    this.dataRef?.setInput('modelId', this.props.modelId ?? '');
    this.dataRef?.setInput('widgetType', this.props.widgetType ?? 'chart');
  }

  private flushViews(): void {
    this.chatRef?.changeDetectorRef.detectChanges();
    this.dataRef?.changeDetectorRef.detectChanges();
    this.appRef?.tick();
  }

  private destroyAngular(): void {
    if (this.appRef && this.chatRef) {
      this.appRef.detachView(this.chatRef.hostView);
    }
    if (this.appRef && this.dataRef) {
      this.appRef.detachView(this.dataRef.hostView);
    }

    this.chatRef?.destroy();
    this.dataRef?.destroy();
    this.chatRef = null;
    this.dataRef = null;

    this.appRef?.destroy();
    this.appRef = null;
    this.bootstrapped = false;

    if (this.shadowRoot) {
      this.shadowRoot.innerHTML = '';
    }
  }
}

// Register the custom element — SAC will instantiate it via widget.json "id"
if (!customElements.get('sac-ai-widget')) {
  customElements.define('sac-ai-widget', SacAiWidgetEntry);
}

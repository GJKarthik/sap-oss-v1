// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * GenUI Renderer Module
 */

import { NgModule, ModuleWithProviders, InjectionToken } from '@angular/core';
import { CommonModule } from '@angular/common';
import { GenUiOutletComponent } from './components/genui-outlet.component';
import { ComponentRegistry } from './registry/component-registry';
import { SchemaValidator, ValidatorConfig } from './validation/schema-validator';
import { DynamicRenderer } from './renderer/dynamic-renderer.service';

/** Configuration for GenUI Renderer */
export interface GenUiRendererConfig {
  /** Component allowlist preset or custom */
  allowedComponents?: 'fiori-standard' | 'all' | string[];
  /** Enable sanitization */
  sanitize?: boolean;
  /** Maximum nesting depth */
  maxDepth?: number;
  /** Allow unknown components */
  allowUnknown?: boolean;
}

export const GENUI_RENDERER_CONFIG = new InjectionToken<GenUiRendererConfig>('GENUI_RENDERER_CONFIG');

@NgModule({
  imports: [CommonModule],
  declarations: [GenUiOutletComponent],
  exports: [GenUiOutletComponent],
})
export class GenUiRendererModule {
  static forRoot(config?: GenUiRendererConfig): ModuleWithProviders<GenUiRendererModule> {
    return {
      ngModule: GenUiRendererModule,
      providers: [
        { provide: GENUI_RENDERER_CONFIG, useValue: config || {} },
        ComponentRegistry,
        SchemaValidator,
        DynamicRenderer,
      ],
    };
  }

  static forChild(): ModuleWithProviders<GenUiRendererModule> {
    return {
      ngModule: GenUiRendererModule,
      providers: [],
    };
  }
}
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * @ui5/genui-renderer - Public API
 */

// Module
export { GenUiRendererModule, GenUiRendererConfig, GENUI_RENDERER_CONFIG } from './lib/genui-renderer.module';

// Component
export { GenUiOutletComponent, GenUiEvent } from './lib/components/genui-outlet.component';

// Registry
export { ComponentRegistry, ComponentMetadata, ComponentCategory } from './lib/registry/component-registry';

// Renderer
export {
  DynamicRenderer,
  A2UiSchema,
  EventHandler,
  DataBinding,
  RenderedComponent,
  RenderContext,
} from './lib/renderer/dynamic-renderer.service';

// Validation
export {
  SchemaValidator,
  ValidationResult,
  ValidationError,
  ValidationErrorCode,
  ValidatorConfig,
} from './lib/validation/schema-validator';
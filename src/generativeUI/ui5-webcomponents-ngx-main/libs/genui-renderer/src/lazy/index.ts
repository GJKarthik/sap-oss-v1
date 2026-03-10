// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * @ui5/genui-renderer/lazy
 *
 * Lightweight secondary entry point.
 * Re-exports only the outlet component and module so that host apps
 * which import from this path do NOT pull in the full ComponentRegistry
 * allowlist (150+ entries) into their eager bundle.
 *
 * Usage in a lazy Angular module:
 *   import { GenUiRendererModule } from '@ui5/genui-renderer/lazy';
 */
export { GenUiRendererModule, GenUiRendererConfig, GENUI_RENDERER_CONFIG } from '../lib/genui-renderer.module';
export { GenUiOutletComponent, GenUiEvent } from '../lib/components/genui-outlet.component';
export { A2UiSchema, RenderedComponent, RenderContext } from '../lib/renderer/dynamic-renderer.service';

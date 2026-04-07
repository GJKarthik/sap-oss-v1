/**
 * Test-environment shim for @ui5/webcomponents-ngx.
 *
 * The production library's FESM bundle declares `const exports = [...]` which
 * collides with Node.js CJS module scope. Since all component tests use
 * CUSTOM_ELEMENTS_SCHEMA (UI5 elements are custom elements that don't render
 * in JSDOM), we provide a lightweight NgModule that satisfies the import
 * without pulling in the full library bundle.
 */
import { NgModule } from '@angular/core';

@NgModule({})
export class Ui5WebcomponentsModule {}

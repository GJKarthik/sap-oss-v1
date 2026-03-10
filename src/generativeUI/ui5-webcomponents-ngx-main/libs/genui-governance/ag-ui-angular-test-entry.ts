// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
// Test-only barrel for @ui5/ag-ui-angular — excludes joule-chat.element.ts
// which requires @angular/elements (not installed in test environment).
export * from '../ag-ui-angular/src/lib/services/ag-ui-client.service';
export * from '../ag-ui-angular/src/lib/services/tool-registry.service';
export * from '../ag-ui-angular/src/lib/types/ag-ui-events';
export * from '../ag-ui-angular/src/lib/ag-ui.module';
export * from '../ag-ui-angular/src/lib/joule-chat/joule-chat.component';

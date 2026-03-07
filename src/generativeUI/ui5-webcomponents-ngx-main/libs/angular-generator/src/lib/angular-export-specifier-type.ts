// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * The type of Angular export specifier.
 * Currently, the generator only supports declarations, NgModule and providers.
 */
export enum AngularExportSpecifierType {
  Declaration = 'Declaration',
  NgModule = 'NgModule',
  Provider = 'Provider',
}

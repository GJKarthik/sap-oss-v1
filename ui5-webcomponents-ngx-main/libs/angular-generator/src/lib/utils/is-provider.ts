// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {ExportSpecifier} from "@ui5/webcomponents-transformer";
import { AngularExportSpecifierType } from '../angular-export-specifier-type';

/**
 * checks if the specifier is Angular Provider
 * @param specifier
 */
export const isProvider = (specifier: ExportSpecifier<AngularExportSpecifierType>) => {
  return specifier.types.includes(AngularExportSpecifierType.Provider);
}

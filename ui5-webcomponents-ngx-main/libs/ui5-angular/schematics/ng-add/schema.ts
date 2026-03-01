// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Schema } from '../schema';

export interface NgAddSchema extends Schema {
  useI18n: boolean;
  defaultLanguage?: string;
}

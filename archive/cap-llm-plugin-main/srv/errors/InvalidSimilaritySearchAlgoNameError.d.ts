// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
declare class InvalidSimilaritySearchAlgoNameError extends Error {
  code: number;
  constructor(message: string, code: number);
}
export = InvalidSimilaritySearchAlgoNameError;

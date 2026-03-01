// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * This file is used to run code after all tests have been run.
 */
export default async function tearDown() {
  delete process.env.AICORE_SERVICE_KEY;
}

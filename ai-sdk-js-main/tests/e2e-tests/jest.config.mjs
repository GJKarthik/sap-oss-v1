// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import config from '../../jest.config.mjs';

export default {
  ...config,
  globalSetup: undefined,
  globalTeardown: undefined,
  displayName: 'e2e-tests',
  testTimeout: 45000,
};

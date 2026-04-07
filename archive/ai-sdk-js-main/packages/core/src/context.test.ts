// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import nock from 'nock';
import { mockClientCredentialsGrantCall } from '../../../test-util/interceptors.js';
import { getAiCoreDestination } from './context.js';

describe('context', () => {
  afterAll(() => {
    nock.cleanAll();
  });

  it('should throw if client credentials are not fetched', async () => {
    mockClientCredentialsGrantCall(
      {
        error: 'unauthorized',
        error_description: 'Bad credentials'
      },
      401
    );
    await expect(getAiCoreDestination()).rejects.toThrow(
      /Could not fetch client credentials token for service of type "aicore"/
    );
  });
});

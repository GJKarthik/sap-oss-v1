// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Angular dev-server proxy configuration.
 *
 * The agent backend URL is read from the AGENT_URL environment variable so
 * this file works unchanged in containers and cloud deployments.
 *
 * Override example:
 *   AGENT_URL=http://agent-svc:9160 npx nx serve playground
 */

const AGENT_URL = process.env['AGENT_URL'] || 'http://localhost:9160';

module.exports = {
  '/ag-ui': {
    target: AGENT_URL,
    secure: false,
    changeOrigin: true,
    logLevel: 'info',
  },
};

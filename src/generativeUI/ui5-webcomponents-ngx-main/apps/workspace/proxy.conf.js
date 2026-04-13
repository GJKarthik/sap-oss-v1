// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Angular dev-server proxy configuration.
 *
 * The agent backend URL is read from the AGENT_URL environment variable so
 * this file works unchanged in containers and cloud deployments.
 *
 * Override example:
 *   AGENT_URL=http://agent-svc:9160 npx nx serve workspace
 */

const AGENT_URL = process.env['AGENT_URL'] || 'http://localhost:9160';
const COLLAB_URL = process.env['COLLAB_URL'] || 'http://localhost:9161';
const TRAINING_API_URL = process.env['TRAINING_API_URL'] || 'http://localhost:8000';

module.exports = {
  '/ag-ui': {
    target: AGENT_URL,
    secure: false,
    changeOrigin: true,
    logLevel: 'info',
  },
  '/collab': {
    target: COLLAB_URL,
    secure: false,
    changeOrigin: true,
    ws: true,
    logLevel: 'info',
  },
  '/api/training': {
    target: TRAINING_API_URL,
    secure: false,
    changeOrigin: true,
    pathRewrite: { '^/api/training': '' },
    logLevel: 'info',
  },
};

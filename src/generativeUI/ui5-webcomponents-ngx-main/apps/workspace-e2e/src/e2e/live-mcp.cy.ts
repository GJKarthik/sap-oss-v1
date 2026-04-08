// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

const liveOnly = Cypress.env('LIVE_BACKENDS') === true || Cypress.env('LIVE_BACKENDS') === 'true';
const describeLive = liveOnly ? describe : describe.skip;

describeLive('Live workspace — MCP integration', () => {
  it('loads MCP tools from backend', () => {
    cy.visit('/');
    cy.contains('button', 'MCP').click();
    cy.contains('Live service required').should('not.exist');
    cy.get('ui5-option').its('length').should('be.gte', 1);
  });
});

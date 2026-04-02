// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

const liveOnly = Cypress.env('LIVE_BACKENDS') === true || Cypress.env('LIVE_BACKENDS') === 'true';
const describeLive = liveOnly ? describe : describe.skip;

describeLive('Live demo — guided tour', () => {
  it('starts from readiness and walks all demo steps', () => {
    cy.visit('/');
    cy.contains('button', 'Readiness').click();
    cy.url().should('include', '/readiness');

    cy.get('ui5-button[data-testid="readiness-start-demo"]', { timeout: 20000 }).click();
    cy.url().should('include', '/generative');
    cy.contains('Demo Tour 1/4').should('exist');

    cy.get('ui5-button[data-testid="demo-tour-next"]').click();
    cy.url().should('include', '/joule');

    cy.get('ui5-button[data-testid="demo-tour-next"]').click();
    cy.url().should('include', '/components');

    cy.get('ui5-button[data-testid="demo-tour-next"]').click();
    cy.url().should('include', '/mcp');

    cy.get('ui5-button[data-testid="demo-tour-next"]').click();
    cy.url().should('include', '/readiness');
    cy.contains('Demo Tour 1/4').should('not.exist');
  });
});

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

const liveOnly = Cypress.env('LIVE_BACKENDS') === true || Cypress.env('LIVE_BACKENDS') === 'true';
const describeLive = liveOnly ? describe : describe.skip;

describeLive('Live environment — learn path', () => {
  it('starts from readiness and walks all learn-path steps', () => {
    cy.visit('/');
    cy.contains('button', 'Readiness').click();
    cy.url().should('include', '/readiness');

    cy.get('ui5-button[data-testid="readiness-open-learn-path"]', { timeout: 20000 }).click();
    cy.url().should('include', '/generative');
    cy.contains('Learn Path 1/4').should('exist');

    cy.get('ui5-button[data-testid="learn-path-next"]').click();
    cy.url().should('include', '/joule');

    cy.get('ui5-button[data-testid="learn-path-next"]').click();
    cy.url().should('include', '/components');

    cy.get('ui5-button[data-testid="learn-path-next"]').click();
    cy.url().should('include', '/mcp');

    cy.get('ui5-button[data-testid="learn-path-next"]').click();
    cy.url().should('include', '/readiness');
    cy.contains('Learn Path 1/4').should('not.exist');
  });
});

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * E2E: Navigation to /joule route
 */
describe('Joule route navigation', () => {
  beforeEach(() => {
    cy.visit('/');
  });

  it('renders the Joule AI button on the main page', () => {
    cy.get('ui5-button').contains('Joule AI').should('be.visible');
  });

  it('navigates to /joule when the Joule AI button is clicked', () => {
    cy.get('ui5-button').contains('Joule AI').click();
    cy.url().should('include', '/joule');
  });

  it('shows the joule-chat element on /joule', () => {
    cy.visit('/joule');
    cy.get('joule-chat').should('exist');
  });

  it('shows the state label on /joule defaulting to idle', () => {
    cy.visit('/joule');
    cy.get('.state-label').should('contain.text', 'idle');
  });

  it('shows the empty-state placeholder when no schema is loaded', () => {
    cy.visit('/joule');
    cy.get('.empty-state').should('be.visible');
    cy.get('.empty-state').should('contain.text', 'Agent-generated UI will appear here');
  });
});

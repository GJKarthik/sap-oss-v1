// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * E2E: Navigation to /joule route
 */
describe('Joule route navigation', () => {
  beforeEach(() => {
    cy.visit('/');
  });

  it('renders the Joule entry point on the main page', () => {
    cy.get('[data-testid="home-open-joule"]').should('be.visible');
  });

  it('navigates to /joule when the home entry point is clicked', () => {
    cy.get('[data-testid="home-open-joule"]').click();
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

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * E2E: AG-UI agent connection and text streaming
 */
describe('Joule agent — text streaming', () => {
  beforeEach(() => {
    cy.interceptAgUi('text');
    cy.visit('/joule');
  });

  it('sends a POST to /ag-ui/run when a message is submitted', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Hello');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun').its('request.method').should('eq', 'POST');
  });

  it('state transitions to streaming then complete', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Hello');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');
    cy.get('.state-label').should('contain.text', 'complete');
  });

  it('displays the streamed text reply in the chat', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Hello');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');
    cy.get('joule-chat').shadow().contains('Hello from Joule!').should('exist');
  });

  it('shows the Clear button once a run completes', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Hello');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');
    cy.get('.clear-btn').should('be.visible');
  });

  it('clears back to idle when the Clear button is clicked', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Hello');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');
    cy.get('.clear-btn').click();
    cy.get('.state-label').should('contain.text', 'idle');
    cy.get('.clear-btn').should('not.exist');
  });
});

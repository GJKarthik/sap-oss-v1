// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * E2E: Error handling and governance state
 */
describe('Joule agent — error and governance', () => {
  it('shows error state when the agent emits run_error', () => {
    cy.interceptAgUi('error');
    cy.visit('/joule');

    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Do something');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');

    cy.get('.state-label').should('contain.text', 'error');
    cy.get('.state-label').should('have.class', 'state-error');
  });

  it('shows error state badge in error colour scheme', () => {
    cy.interceptAgUi('error');
    cy.visit('/joule');

    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Trigger error');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');

    cy.get('.state-label.state-error').should('exist');
  });

  it('can recover from error state by clearing the session', () => {
    cy.interceptAgUi('error');
    cy.visit('/joule');

    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Trigger error');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');

    cy.get('.clear-btn').click();
    cy.get('.state-label').should('contain.text', 'idle');
    cy.get('.empty-state').should('be.visible');
  });

  it('does not expose /ag-ui/run without a POST body (method guard)', () => {
    cy.request({
      method: 'GET',
      url: '/ag-ui/run',
      failOnStatusCode: false,
    }).then((resp) => {
      expect(resp.status).to.be.oneOf([404, 405, 400]);
    });
  });
});

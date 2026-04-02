// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

const liveOnly = Cypress.env('LIVE_BACKENDS') === true || Cypress.env('LIVE_BACKENDS') === 'true';
const describeLive = liveOnly ? describe : describe.skip;

describeLive('Live demo — generative renderer', () => {
  it('loads renderer route without dependency blocker', () => {
    cy.visit('/');
    cy.contains('button', 'Generative UI').click();
    cy.contains('Live service required').should('not.exist');
    cy.get('ui5-input').should('exist');
    cy.contains('Generate').should('exist');
  });
});

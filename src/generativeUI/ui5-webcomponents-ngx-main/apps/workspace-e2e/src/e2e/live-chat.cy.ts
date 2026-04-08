// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

const liveOnly = Cypress.env('LIVE_BACKENDS') === true || Cypress.env('LIVE_BACKENDS') === 'true';
const describeLive = liveOnly ? describe : describe.skip;

describeLive('Live workspace — Joule chat', () => {
  it('loads Joule route and keeps connection healthy', () => {
    cy.visit('/');
    cy.get('[data-testid="home-open-joule"]').click();
    cy.contains('Live service required').should('not.exist');
    cy.get('joule-chat').should('exist');
    cy.get('.error-banner').should('not.exist');
  });
});

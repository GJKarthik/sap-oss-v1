// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

const liveOnly = Cypress.env('LIVE_BACKENDS') === true || Cypress.env('LIVE_BACKENDS') === 'true';
const describeLive = liveOnly ? describe : describe.skip;

describeLive('Live workspace — model catalog', () => {
  it('loads live model catalog from backend', () => {
    cy.visit('/');
    cy.contains('button', 'Model Catalog').click();
    cy.contains('Live service required').should('not.exist');
    cy.contains('Refresh Catalog').click();
    cy.contains('Live service required').should('not.exist');
  });
});

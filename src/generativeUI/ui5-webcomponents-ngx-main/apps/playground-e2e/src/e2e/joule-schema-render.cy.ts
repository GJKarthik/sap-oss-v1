// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * E2E: GenUI schema rendering via ui_schema_snapshot event
 */
describe('Joule agent — schema rendering', () => {
  beforeEach(() => {
    cy.interceptAgUi('schema');
    cy.visit('/joule');
  });

  it('renders a genui-outlet when a schema snapshot arrives', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Build a button');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');
    cy.get('genui-outlet').should('exist');
  });

  it('hides the empty-state placeholder once a schema is rendered', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Build a button');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');
    cy.get('.empty-state').should('not.exist');
  });

  it('renders the generated ui5-button from the schema', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Build a button');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');
    cy.get('genui-outlet').find('ui5-button').should('exist');
    cy.get('genui-outlet').find('ui5-button').should('have.attr', 'text', 'Generated Button');
  });

  it('state is complete after schema snapshot', () => {
    cy.get('joule-chat').shadow().find('ui5-textarea, textarea').first().type('Build a button');
    cy.get('joule-chat').shadow().find('ui5-button[design="Emphasized"]').first().click();
    cy.wait('@agUiRun');
    cy.get('.state-label').should('contain.text', 'complete');
  });
});

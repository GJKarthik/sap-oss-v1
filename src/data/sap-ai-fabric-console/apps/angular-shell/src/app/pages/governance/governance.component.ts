import { Component } from '@angular/core';

@Component({
  selector: 'app-governance',
  standalone: false,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Governance Rules</ui5-title>
        <ui5-button slot="endContent" design="Emphasized" icon="add">Add Rule</ui5-button>
      </ui5-bar>
      <div class="governance-content">
        <ui5-card>
          <ui5-card-header slot="header" title-text="Active Rules" [additionalText]="rules.length + ''"></ui5-card-header>
          <ui5-table>
            <ui5-table-header-cell><span>Rule Name</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Type</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let rule of rules">
              <ui5-table-cell>{{ rule.name }}</ui5-table-cell>
              <ui5-table-cell>{{ rule.type }}</ui5-table-cell>
              <ui5-table-cell><ui5-tag [design]="rule.active ? 'Positive' : 'Negative'">{{ rule.active ? 'Active' : 'Inactive' }}</ui5-tag></ui5-table-cell>
            </ui5-table-row>
          </ui5-table>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`.governance-content { padding: 1rem; }`]
})
export class GovernanceComponent {
  rules = [
    { name: 'PII Detection', type: 'content-filter', active: true },
    { name: 'Rate Limiting', type: 'access-control', active: true },
    { name: 'Audit Logging', type: 'compliance', active: true },
  ];
}

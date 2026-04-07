import { Component, OnInit, CUSTOM_ELEMENTS_SCHEMA, signal, inject, ChangeDetectionStrategy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { environment } from '../../../environments/environment';

interface VocabularyInfo {
  name: string;
  termsCount: number;
  description: string;
  lastUpdated: string;
}

@Component({
  selector: 'app-vocab-hub',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid" class="vocab-aura">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">OData Semantic Dictionary</ui5-title>
        <ui5-tag slot="endContent" design="Information">v4.0 Standard</ui5-tag>
      </ui5-bar>

      <div class="vocab-content" role="main">
        <section class="hero-header fadeIn">
          <ui5-title level="H2">Semantic Interoperability</ui5-title>
          <p class="text-muted">Direct integration with SAP standard OData vocabularies for cross-application intelligence.</p>
        </section>

        <div class="vocab-grid">
          @for (v of vocabularies(); track v.name) {
            <ui5-card class="glass-card vocab-card fadeIn" interactive (click)="selectVocab(v)">
              <ui5-card-header slot="header" [title-text]="v.name" [subtitle-text]="v.termsCount + ' standard terms'">
                <ui5-icon slot="avatar" [name]="getIcon(v.name)"></ui5-icon>
              </ui5-card-header>
              <div class="card-body">
                <p class="text-small text-muted">{{ v.description }}</p>
                <div class="card-footer">
                  <ui5-tag design="Neutral">Namespace: org.base.{{ v.name.toLowerCase() }}</ui5-tag>
                </div>
              </div>
            </ui5-card>
          }
        </div>

        <!-- Detail Overlay -->
        @if (selectedVocab(); as selected) {
          <div class="detail-overlay slideInRight">
            <div class="glass-card detail-panel">
              <ui5-bar design="Header">
                <ui5-title slot="startContent" level="H4">{{ selected.name }} Details</ui5-title>
                <ui5-button slot="endContent" design="Transparent" icon="decline" (click)="selectedVocab.set(null)"></ui5-button>
              </ui5-bar>
              <div class="p-1">
                <ui5-list separators="All">
                  <ui5-li description="Identifies sensitive or personal data per GDPR" icon="BusinessSuite/privacy">IsPotentiallySensitive</ui5-li>
                  <ui5-li description="Specifies the semantic role of an entity" icon="BusinessSuite/tags">Kind</ui5-li>
                  <ui5-li description="Label used for UI representation" icon="BusinessSuite/label">Label</ui5-li>
                  <ui5-li description="Default value if none provided" icon="BusinessSuite/value-help">DefaultValue</ui5-li>
                </ui5-list>
              </div>
            </div>
          </div>
        }
      </div>
    </ui5-page>
  `,
  styles: [`
    .vocab-aura {
      background: radial-gradient(circle at 50% 0%, rgba(161, 31, 133, 0.05) 0%, transparent 40%),
                  var(--sapBackgroundColor);
    }
    .vocab-content { padding: 1.5rem; max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 2rem; position: relative; }
    
    .hero-header { text-align: center; }
    .hero-header p { max-width: 600px; margin: 0.5rem auto; }

    .vocab-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 1.5rem; }
    .vocab-card { height: 100%; transition: transform 0.2s; }
    .vocab-card:hover { transform: translateY(-5px); }
    .card-body { padding: 0 1rem 1rem; display: flex; flex-direction: column; gap: 1rem; }
    .card-footer { border-top: 1px solid var(--sapList_BorderColor); pt: 0.5rem; }

    .detail-overlay { position: fixed; top: 100px; right: 1.5rem; bottom: 1.5rem; width: 400px; z-index: 100; }
    .detail-panel { height: 100%; display: flex; flex-direction: column; }

    .glass-card {
      background: rgba(255, 255, 255, 0.75);
      backdrop-filter: blur(15px);
      border: 1px solid rgba(255, 255, 255, 0.4);
      border-radius: 1rem;
      box-shadow: 0 12px 40px rgba(0, 0, 0, 0.08);
    }

    .fadeIn { animation: fadeIn 0.5s ease-out; }
    .slideInRight { animation: slideInRight 0.4s cubic-bezier(0.4, 0, 0.2, 1); }
    @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
    @keyframes slideInRight { from { transform: translateX(100%); } to { transform: translateX(0); } }
    .p-1 { padding: 1rem; }
  `]
})
export class VocabHubComponent {
  readonly vocabularies = signal<VocabularyInfo[]>([
    { name: 'Analytics', termsCount: 42, description: 'Terms for analytical metadata and data aggregation.', lastUpdated: '2024-03-12' },
    { name: 'Common', termsCount: 85, description: 'Fundamental terms used across all OData services.', lastUpdated: '2024-03-15' },
    { name: 'Communication', termsCount: 24, description: 'Email, phone, and messaging semantic annotations.', lastUpdated: '2024-02-20' },
    { name: 'PersonalData', termsCount: 38, description: 'GDPR and data privacy classification terms.', lastUpdated: '2024-03-01' },
    { name: 'UI', termsCount: 156, description: 'SAP Fiori-specific UI control and layout hints.', lastUpdated: '2024-03-10' },
    { name: 'Validation', termsCount: 18, description: 'Server-side data validation rules and constraints.', lastUpdated: '2024-01-15' },
  ]);

  readonly selectedVocab = signal<VocabularyInfo | null>(null);

  getIcon(name: string): string {
    const map: Record<string, string> = {
      Analytics: 'BusinessSuite/micro-chart-line',
      Common: 'BusinessSuite/settings',
      Communication: 'BusinessSuite/email',
      PersonalData: 'BusinessSuite/privacy',
      UI: 'BusinessSuite/monitor-payments',
      Validation: 'BusinessSuite/quality-issue'
    };
    return map[name] ?? 'BusinessSuite/database';
  }

  selectVocab(v: VocabularyInfo) { this.selectedVocab.set(v); }
}

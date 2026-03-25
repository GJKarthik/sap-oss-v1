// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { Component, OnInit, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { CopilotService } from '../copilot.service';

/**
 * Training Product interface matching the MCP data_products module.
 */
interface TrainingProduct {
    id: string;
    name: string;
    description: string;
    domain: string;
    version: string;
    owner: string;
    security_class: string;
    tables: string[];
    fields: string[];
}

/**
 * Quality Gate Result from validation.
 */
interface QualityGateResult {
    gate: string;
    passed: boolean;
    score: number;
    threshold: number;
    details: string;
}

/**
 * Training Products Component.
 *
 * Provides a UI for:
 * - Listing training data products (Treasury, ESG, Performance)
 * - Validating products against quality gates
 * - Viewing schemas and generating training data
 */
@Component({
    selector: 'app-training-products',
    standalone: true,
    imports: [CommonModule, FormsModule],
    template: `
        <div class="training-products">
            <header class="header">
                <h1>Training Data Products</h1>
                <p class="subtitle">ODPS 4.1 Registry for Text-to-SQL Fine-tuning</p>
            </header>

            <!-- Domain Filter -->
            <div class="filters">
                <label>
                    Filter by Domain:
                    <select [(ngModel)]="selectedDomain" (change)="loadProducts()">
                        <option value="">All Domains</option>
                        <option value="treasury">Treasury</option>
                        <option value="esg">ESG</option>
                        <option value="performance">Performance</option>
                    </select>
                </label>
                <button (click)="loadProducts()" [disabled]="loading()">
                    {{ loading() ? 'Loading...' : 'Refresh' }}
                </button>
            </div>

            <!-- Product Cards -->
            <div class="products-grid">
                @for (product of products(); track product.id) {
                    <div class="product-card" [class.selected]="selectedProduct()?.id === product.id">
                        <div class="card-header">
                            <span class="domain-badge" [attr.data-domain]="product.domain.toLowerCase()">
                                {{ product.domain }}
                            </span>
                            <span class="version">v{{ product.version }}</span>
                        </div>
                        <h3>{{ product.name }}</h3>
                        <p class="description">{{ product.description }}</p>
                        <div class="card-stats">
                            <span>📊 {{ product.tables.length }} tables</span>
                            <span>📋 {{ product.fields.length }} fields</span>
                            <span class="security" [attr.data-class]="product.security_class">
                                🔒 {{ product.security_class }}
                            </span>
                        </div>
                        <div class="card-actions">
                            <button (click)="selectProduct(product)">View Schema</button>
                            <button (click)="validateProduct(product.id)" [disabled]="validating()">
                                Validate
                            </button>
                        </div>
                    </div>
                } @empty {
                    <div class="empty-state">
                        <p>No products found. {{ loading() ? 'Loading...' : 'Click Refresh to load.' }}</p>
                    </div>
                }
            </div>

            <!-- Schema Panel -->
            @if (selectedProduct()) {
                <div class="schema-panel">
                    <h2>Schema: {{ selectedProduct()!.name }}</h2>
                    <div class="schema-content">
                        <div class="schema-section">
                            <h4>Tables</h4>
                            <ul>
                                @for (table of selectedProduct()!.tables; track table) {
                                    <li>{{ table }}</li>
                                }
                            </ul>
                        </div>
                        <div class="schema-section">
                            <h4>Fields</h4>
                            <ul class="fields-list">
                                @for (field of selectedProduct()!.fields; track field) {
                                    <li>{{ field }}</li>
                                }
                            </ul>
                        </div>
                    </div>
                    <div class="generate-section">
                        <h4>Generate Training Data</h4>
                        <div class="generate-form">
                            <select [(ngModel)]="selectedTable">
                                <option value="">Select Table</option>
                                @for (table of selectedProduct()!.tables; track table) {
                                    <option [value]="table">{{ table }}</option>
                                }
                            </select>
                            <input type="number" [(ngModel)]="numSamples" min="1" max="100" placeholder="Samples" />
                            <button (click)="generateTrainingData()" [disabled]="!selectedTable || generating()">
                                {{ generating() ? 'Generating...' : 'Generate' }}
                            </button>
                        </div>
                    </div>
                </div>
            }

            <!-- Validation Results -->
            @if (validationResults().length > 0) {
                <div class="validation-panel">
                    <h2>Quality Gate Validation</h2>
                    <div class="overall-status" [class.passed]="overallPassed()" [class.failed]="!overallPassed()">
                        {{ overallPassed() ? '✅ All Gates Passed' : '⚠️ Some Gates Failed' }}
                        <span class="score">Score: {{ overallScore() }}%</span>
                    </div>
                    <table class="validation-table">
                        <thead>
                            <tr>
                                <th>Gate</th>
                                <th>Score</th>
                                <th>Threshold</th>
                                <th>Status</th>
                                <th>Details</th>
                            </tr>
                        </thead>
                        <tbody>
                            @for (result of validationResults(); track result.gate) {
                                <tr [class.passed]="result.passed" [class.failed]="!result.passed">
                                    <td>{{ formatGateName(result.gate) }}</td>
                                    <td>{{ result.score }}%</td>
                                    <td>{{ result.threshold }}%</td>
                                    <td>{{ result.passed ? '✅' : '❌' }}</td>
                                    <td>{{ result.details }}</td>
                                </tr>
                            }
                        </tbody>
                    </table>
                </div>
            }

            <!-- Generated Training Data -->
            @if (trainingData().length > 0) {
                <div class="training-data-panel">
                    <h2>Generated Training Data</h2>
                    <div class="training-data-list">
                        @for (sample of trainingData(); track $index) {
                            <div class="training-sample">
                                <div class="prompt">
                                    <label>Prompt:</label>
                                    <code>{{ sample.prompt }}</code>
                                </div>
                                <div class="query">
                                    <label>SQL:</label>
                                    <code>{{ sample.query }}</code>
                                </div>
                            </div>
                        }
                    </div>
                    <button class="export-btn" (click)="exportTrainingData()">
                        Export as JSONL
                    </button>
                </div>
            }
        </div>
    `,
    styles: [
        `
            .training-products {
                padding: 24px;
                font-family: '72', Arial, sans-serif;
            }
            .header {
                margin-bottom: 24px;
            }
            .header h1 {
                margin: 0;
                color: #0a6ed1;
            }
            .subtitle {
                color: #6a6d70;
                margin-top: 4px;
            }
            .filters {
                display: flex;
                gap: 16px;
                align-items: center;
                margin-bottom: 24px;
            }
            .filters select {
                padding: 8px 12px;
                border: 1px solid #89919a;
                border-radius: 4px;
            }
            .filters button {
                padding: 8px 16px;
                background: #0a6ed1;
                color: white;
                border: none;
                border-radius: 4px;
                cursor: pointer;
            }
            .filters button:disabled {
                background: #c4c6c8;
            }
            .products-grid {
                display: grid;
                grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
                gap: 16px;
                margin-bottom: 24px;
            }
            .product-card {
                border: 1px solid #e4e4e4;
                border-radius: 8px;
                padding: 16px;
                background: white;
                transition: all 0.2s;
            }
            .product-card:hover {
                border-color: #0a6ed1;
                box-shadow: 0 2px 8px rgba(10, 110, 209, 0.15);
            }
            .product-card.selected {
                border-color: #0a6ed1;
                background: #f0f6ff;
            }
            .card-header {
                display: flex;
                justify-content: space-between;
                margin-bottom: 8px;
            }
            .domain-badge {
                padding: 2px 8px;
                border-radius: 4px;
                font-size: 12px;
                font-weight: 600;
            }
            .domain-badge[data-domain='treasury'] {
                background: #e8f4fd;
                color: #0a6ed1;
            }
            .domain-badge[data-domain='esg'] {
                background: #e8f8e8;
                color: #107e3e;
            }
            .domain-badge[data-domain='performance'] {
                background: #fff3e0;
                color: #d27900;
            }
            .version {
                color: #6a6d70;
                font-size: 12px;
            }
            .product-card h3 {
                margin: 0 0 8px 0;
                font-size: 16px;
            }
            .description {
                color: #6a6d70;
                font-size: 14px;
                margin-bottom: 12px;
            }
            .card-stats {
                display: flex;
                gap: 12px;
                font-size: 12px;
                color: #6a6d70;
                margin-bottom: 12px;
            }
            .security[data-class='confidential'] {
                color: #bb0000;
            }
            .card-actions {
                display: flex;
                gap: 8px;
            }
            .card-actions button {
                flex: 1;
                padding: 6px 12px;
                border: 1px solid #0a6ed1;
                border-radius: 4px;
                background: white;
                color: #0a6ed1;
                cursor: pointer;
            }
            .card-actions button:hover {
                background: #0a6ed1;
                color: white;
            }
            .schema-panel,
            .validation-panel,
            .training-data-panel {
                margin-top: 24px;
                padding: 20px;
                border: 1px solid #e4e4e4;
                border-radius: 8px;
                background: white;
            }
            .schema-panel h2,
            .validation-panel h2,
            .training-data-panel h2 {
                margin-top: 0;
                color: #0a6ed1;
            }
            .schema-content {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 24px;
            }
            .schema-section h4 {
                margin: 0 0 8px 0;
            }
            .schema-section ul {
                list-style: none;
                padding: 0;
                margin: 0;
            }
            .schema-section li {
                padding: 4px 8px;
                background: #f5f5f5;
                margin-bottom: 4px;
                border-radius: 4px;
                font-family: monospace;
            }
            .fields-list {
                max-height: 200px;
                overflow-y: auto;
            }
            .generate-section {
                margin-top: 20px;
                padding-top: 20px;
                border-top: 1px solid #e4e4e4;
            }
            .generate-form {
                display: flex;
                gap: 12px;
                align-items: center;
            }
            .generate-form select,
            .generate-form input {
                padding: 8px 12px;
                border: 1px solid #89919a;
                border-radius: 4px;
            }
            .generate-form input[type='number'] {
                width: 100px;
            }
            .generate-form button {
                padding: 8px 16px;
                background: #107e3e;
                color: white;
                border: none;
                border-radius: 4px;
                cursor: pointer;
            }
            .overall-status {
                padding: 12px 16px;
                border-radius: 4px;
                margin-bottom: 16px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                font-weight: 600;
            }
            .overall-status.passed {
                background: #e8f8e8;
                color: #107e3e;
            }
            .overall-status.failed {
                background: #fff0f0;
                color: #bb0000;
            }
            .validation-table {
                width: 100%;
                border-collapse: collapse;
            }
            .validation-table th,
            .validation-table td {
                padding: 8px 12px;
                text-align: left;
                border-bottom: 1px solid #e4e4e4;
            }
            .validation-table th {
                background: #f5f5f5;
            }
            .validation-table tr.passed td:first-child {
                border-left: 3px solid #107e3e;
            }
            .validation-table tr.failed td:first-child {
                border-left: 3px solid #bb0000;
            }
            .training-data-list {
                max-height: 400px;
                overflow-y: auto;
            }
            .training-sample {
                padding: 12px;
                margin-bottom: 8px;
                background: #f5f5f5;
                border-radius: 4px;
            }
            .training-sample label {
                display: block;
                font-weight: 600;
                margin-bottom: 4px;
                color: #6a6d70;
            }
            .training-sample code {
                display: block;
                padding: 8px;
                background: white;
                border-radius: 4px;
                font-family: monospace;
                font-size: 13px;
            }
            .training-sample .query code {
                background: #1a1a2e;
                color: #4ec9b0;
            }
            .export-btn {
                margin-top: 16px;
                padding: 10px 20px;
                background: #0a6ed1;
                color: white;
                border: none;
                border-radius: 4px;
                cursor: pointer;
            }
            .empty-state {
                text-align: center;
                padding: 40px;
                color: #6a6d70;
            }
        `,
    ],
})
export class TrainingProductsComponent implements OnInit {
    private copilot = inject(CopilotService);

    // Signals
    products = signal<TrainingProduct[]>([]);
    selectedProduct = signal<TrainingProduct | null>(null);
    validationResults = signal<QualityGateResult[]>([]);
    trainingData = signal<{ prompt: string; query: string; domain: string; table: string }[]>([]);
    loading = signal(false);
    validating = signal(false);
    generating = signal(false);

    // Form state
    selectedDomain = '';
    selectedTable = '';
    numSamples = 10;

    // Computed
    overallPassed = computed(() => this.validationResults().every((r) => r.passed));
    overallScore = computed(() => {
        const results = this.validationResults();
        if (results.length === 0) return 0;
        const avg = results.reduce((sum, r) => sum + r.score, 0) / results.length;
        return Math.round(avg * 10) / 10;
    });

    ngOnInit(): void {
        this.loadProducts();
    }

    async loadProducts(): Promise<void> {
        this.loading.set(true);
        try {
            const result = await this.copilot.callMcpTool('list_training_products', {
                domain: this.selectedDomain,
            });
            const data = JSON.parse(result.content[0].text);
            this.products.set(data.products || []);
        } catch (err) {
            console.error('Failed to load products:', err);
            this.products.set([]);
        } finally {
            this.loading.set(false);
        }
    }

    selectProduct(product: TrainingProduct): void {
        this.selectedProduct.set(product);
        this.selectedTable = product.tables[0] || '';
    }

    async validateProduct(productId: string): Promise<void> {
        this.validating.set(true);
        try {
            const result = await this.copilot.callMcpTool('validate_training_product', {
                product_id: productId,
            });
            const data = JSON.parse(result.content[0].text);
            this.validationResults.set(data.gates || []);
        } catch (err) {
            console.error('Validation failed:', err);
        } finally {
            this.validating.set(false);
        }
    }

    async generateTrainingData(): Promise<void> {
        if (!this.selectedTable) return;
        this.generating.set(true);
        try {
            const domain = this.selectedProduct()?.domain.toLowerCase() || 'general';
            const result = await this.copilot.callMcpTool('generate_training_data', {
                table_name: this.selectedTable,
                domain,
                num_samples: this.numSamples,
            });
            const data = JSON.parse(result.content[0].text);
            this.trainingData.set(data.samples || []);
        } catch (err) {
            console.error('Failed to generate training data:', err);
        } finally {
            this.generating.set(false);
        }
    }

    exportTrainingData(): void {
        const data = this.trainingData();
        const jsonl = data.map((s) => JSON.stringify(s)).join('\n');
        const blob = new Blob([jsonl], { type: 'application/jsonl' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `training_data_${this.selectedTable || 'export'}.jsonl`;
        a.click();
        URL.revokeObjectURL(url);
    }

    formatGateName(gate: string): string {
        return gate.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
    }
}
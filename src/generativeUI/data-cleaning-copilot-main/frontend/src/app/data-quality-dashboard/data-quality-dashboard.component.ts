// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { Component, OnInit, OnDestroy, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import {
    CopilotService,
    DataQualityResponse,
    QualityCheckResult,
    DataProfilingResponse,
    AIChatResponse,
    AIRoutingInfo,
    ChatMessage,
} from '../copilot.service';

interface TableQualityStatus {
    table: string;
    checks: QualityCheckResult[];
    overallStatus: 'PASS' | 'WARN' | 'FAIL';
    score: number;
    lastChecked: Date;
}

interface RoutingIndicator {
    backend: 'vllm' | 'aicore' | 'ollama';
    label: string;
    color: string;
    icon: string;
    description: string;
}

const ROUTING_INDICATORS: Record<string, RoutingIndicator> = {
    vllm: {
        backend: 'vllm',
        label: 'On-Prem (vLLM)',
        color: '#4CAF50',
        icon: '🔒',
        description: 'Processing locally - PII data stays on-premise',
    },
    aicore: {
        backend: 'aicore',
        label: 'Cloud (AI Core)',
        color: '#2196F3',
        icon: '☁️',
        description: 'Processing via SAP AI Core - non-sensitive data',
    },
    ollama: {
        backend: 'ollama',
        label: 'Local (Ollama)',
        color: '#9C27B0',
        icon: '💻',
        description: 'Processing via local Ollama instance',
    },
};

@Component({
    selector: 'app-data-quality-dashboard',
    standalone: true,
    imports: [CommonModule, FormsModule],
    template: `
        <div class="dashboard">
            <header class="dashboard-header">
                <h1>Data Quality Dashboard</h1>
                <div class="mcp-status" [class.connected]="mcpConnected()">
                    <span class="status-dot"></span>
                    {{ mcpConnected() ? 'MCP Connected' : 'MCP Disconnected' }}
                </div>
            </header>

            <!-- Routing Indicator Banner -->
            @if (lastRouting()) {
                <div class="routing-banner" [style.background-color]="getRoutingIndicator().color + '20'" [style.border-color]="getRoutingIndicator().color">
                    <span class="routing-icon">{{ getRoutingIndicator().icon }}</span>
                    <div class="routing-info">
                        <strong>{{ getRoutingIndicator().label }}</strong>
                        <span class="routing-reason">{{ lastRouting()!.routing_reason }}</span>
                    </div>
                    @if (lastRouting()!.contains_pii) {
                        <span class="pii-badge">PII Detected</span>
                    }
                </div>
            }

            <!-- Quick Actions -->
            <section class="quick-actions">
                <div class="action-card" (click)="runQualityCheck()">
                    <div class="action-icon">✅</div>
                    <h3>Quality Check</h3>
                    <p>Run data quality checks on selected table</p>
                </div>
                <div class="action-card" (click)="profileTable()">
                    <div class="action-icon">📊</div>
                    <h3>Profile Data</h3>
                    <p>Analyze data distributions and patterns</p>
                </div>
                <div class="action-card" (click)="detectAnomalies()">
                    <div class="action-icon">🔍</div>
                    <h3>Find Anomalies</h3>
                    <p>Detect outliers using statistical methods</p>
                </div>
                <div class="action-card" (click)="openAIChat()">
                    <div class="action-icon">💬</div>
                    <h3>AI Assistant</h3>
                    <p>Chat with AI (PII-aware routing)</p>
                </div>
            </section>

            <!-- Table Selector -->
            <section class="table-selector">
                <label for="table-select">Select Table:</label>
                <input
                    id="table-select"
                    type="text"
                    [(ngModel)]="selectedTable"
                    placeholder="Enter table name (e.g., Users, Orders)"
                    class="table-input"
                />
                <button class="btn-primary" (click)="runQualityCheck()" [disabled]="!selectedTable || loading()">
                    {{ loading() ? 'Running...' : 'Run Check' }}
                </button>
            </section>

            <!-- Quality Results -->
            @if (qualityResults().length > 0) {
                <section class="quality-results">
                    <h2>Quality Check Results</h2>
                    <div class="results-grid">
                        @for (result of qualityResults(); track result.table) {
                            <div class="result-card" [class]="'status-' + result.overallStatus.toLowerCase()">
                                <div class="card-header">
                                    <h3>{{ result.table }}</h3>
                                    <span class="status-badge" [class]="result.overallStatus.toLowerCase()">
                                        {{ result.overallStatus }}
                                    </span>
                                </div>
                                <div class="score-ring">
                                    <svg viewBox="0 0 36 36" class="circular-chart">
                                        <path
                                            class="circle-bg"
                                            d="M18 2.0845
                                               a 15.9155 15.9155 0 0 1 0 31.831
                                               a 15.9155 15.9155 0 0 1 0 -31.831"
                                        />
                                        <path
                                            class="circle"
                                            [class]="result.overallStatus.toLowerCase()"
                                            [attr.stroke-dasharray]="result.score + ', 100'"
                                            d="M18 2.0845
                                               a 15.9155 15.9155 0 0 1 0 31.831
                                               a 15.9155 15.9155 0 0 1 0 -31.831"
                                        />
                                        <text x="18" y="20.35" class="percentage">{{ result.score | number: '1.0-0' }}%</text>
                                    </svg>
                                </div>
                                <div class="checks-list">
                                    @for (check of result.checks; track check.check) {
                                        <div class="check-item" [class]="check.status.toLowerCase()">
                                            <span class="check-icon">
                                                {{ check.status === 'PASS' ? '✓' : check.status === 'WARN' ? '⚠' : '✗' }}
                                            </span>
                                            <span class="check-name">{{ check.check }}</span>
                                            <span class="check-score">{{ check.score | number: '1.0-1' }}%</span>
                                        </div>
                                    }
                                </div>
                                <div class="card-footer">
                                    <small>Last checked: {{ result.lastChecked | date: 'short' }}</small>
                                </div>
                            </div>
                        }
                    </div>
                </section>
            }

            <!-- Data Profiling Results -->
            @if (profilingResult()) {
                <section class="profiling-results">
                    <h2>Data Profile: {{ profilingResult()!.table }}</h2>
                    <div class="profile-summary">
                        <div class="stat-card">
                            <div class="stat-value">{{ profilingResult()!.row_count | number }}</div>
                            <div class="stat-label">Total Rows</div>
                        </div>
                        <div class="stat-card">
                            <div class="stat-value">{{ getColumnCount() }}</div>
                            <div class="stat-label">Columns</div>
                        </div>
                    </div>
                    <div class="column-stats">
                        @for (col of getColumns(); track col.name) {
                            <div class="column-card">
                                <h4>{{ col.name }}</h4>
                                <span class="type-badge">{{ col.type }}</span>
                                @if (col.pii) {
                                    <span class="pii-badge small">PII</span>
                                }
                            </div>
                        }
                    </div>
                </section>
            }

            <!-- AI Chat Panel -->
            @if (showAIChat()) {
                <section class="ai-chat-panel">
                    <div class="chat-header">
                        <h2>AI Assistant</h2>
                        <button class="btn-close" (click)="closeAIChat()">×</button>
                    </div>
                    <div class="chat-messages" #chatContainer>
                        @for (message of chatMessages(); track $index) {
                            <div class="message" [class]="message.role">
                                <div class="message-content">{{ message.content }}</div>
                                @if (message.role === 'assistant' && chatRoutingInfo()) {
                                    <div class="routing-tag" [style.background-color]="getRoutingIndicator().color + '30'">
                                        {{ getRoutingIndicator().icon }} {{ chatRoutingInfo()!.backend }}
                                    </div>
                                }
                            </div>
                        }
                    </div>
                    <div class="chat-input">
                        <input
                            type="text"
                            [(ngModel)]="chatInput"
                            placeholder="Ask about your data quality..."
                            (keyup.enter)="sendChatMessage()"
                            [disabled]="chatLoading()"
                        />
                        <button class="btn-send" (click)="sendChatMessage()" [disabled]="!chatInput || chatLoading()">
                            {{ chatLoading() ? '...' : 'Send' }}
                        </button>
                    </div>
                    @if (lastRouting()) {
                        <div class="routing-explanation">
                            <small>
                                {{ getRoutingIndicator().description }}
                                @if (lastRouting()!.pii_indicators.length > 0) {
                                    <br />Detected: {{ lastRouting()!.pii_indicators.join(', ') }}
                                }
                            </small>
                        </div>
                    }
                </section>
            }

            <!-- Error Display -->
            @if (error()) {
                <div class="error-banner">
                    <span>{{ error() }}</span>
                    <button (click)="clearError()">×</button>
                </div>
            }
        </div>
    `,
    styles: [
        `
            .dashboard {
                padding: 20px;
                max-width: 1400px;
                margin: 0 auto;
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            }

            .dashboard-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 20px;
            }

            .dashboard-header h1 {
                margin: 0;
                color: #333;
            }

            .mcp-status {
                display: flex;
                align-items: center;
                gap: 8px;
                padding: 8px 16px;
                border-radius: 20px;
                background: #f5f5f5;
                font-size: 14px;
            }

            .mcp-status.connected {
                background: #e8f5e9;
                color: #2e7d32;
            }

            .status-dot {
                width: 10px;
                height: 10px;
                border-radius: 50%;
                background: #bbb;
            }

            .mcp-status.connected .status-dot {
                background: #4caf50;
            }

            .routing-banner {
                display: flex;
                align-items: center;
                gap: 12px;
                padding: 12px 20px;
                border-radius: 8px;
                border: 2px solid;
                margin-bottom: 20px;
            }

            .routing-icon {
                font-size: 24px;
            }

            .routing-info {
                flex: 1;
            }

            .routing-info strong {
                display: block;
            }

            .routing-reason {
                font-size: 12px;
                color: #666;
            }

            .pii-badge {
                background: #ff5722;
                color: white;
                padding: 4px 10px;
                border-radius: 12px;
                font-size: 12px;
                font-weight: 600;
            }

            .pii-badge.small {
                padding: 2px 6px;
                font-size: 10px;
            }

            .quick-actions {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 16px;
                margin-bottom: 24px;
            }

            .action-card {
                background: white;
                border: 1px solid #e0e0e0;
                border-radius: 12px;
                padding: 20px;
                cursor: pointer;
                transition: all 0.2s;
            }

            .action-card:hover {
                border-color: #2196f3;
                box-shadow: 0 4px 12px rgba(33, 150, 243, 0.15);
                transform: translateY(-2px);
            }

            .action-icon {
                font-size: 32px;
                margin-bottom: 8px;
            }

            .action-card h3 {
                margin: 0 0 8px;
                color: #333;
            }

            .action-card p {
                margin: 0;
                color: #666;
                font-size: 14px;
            }

            .table-selector {
                display: flex;
                align-items: center;
                gap: 12px;
                margin-bottom: 24px;
                padding: 16px;
                background: #f5f5f5;
                border-radius: 8px;
            }

            .table-input {
                flex: 1;
                padding: 10px 14px;
                border: 1px solid #ddd;
                border-radius: 6px;
                font-size: 14px;
            }

            .btn-primary {
                background: #2196f3;
                color: white;
                border: none;
                padding: 10px 20px;
                border-radius: 6px;
                cursor: pointer;
                font-size: 14px;
                font-weight: 500;
            }

            .btn-primary:disabled {
                background: #bbb;
                cursor: not-allowed;
            }

            .btn-primary:hover:not(:disabled) {
                background: #1976d2;
            }

            .quality-results h2,
            .profiling-results h2 {
                margin-bottom: 16px;
                color: #333;
            }

            .results-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
                gap: 20px;
            }

            .result-card {
                background: white;
                border-radius: 12px;
                padding: 20px;
                border: 1px solid #e0e0e0;
            }

            .result-card.status-fail {
                border-color: #f44336;
                border-width: 2px;
            }

            .result-card.status-warn {
                border-color: #ff9800;
                border-width: 2px;
            }

            .card-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 16px;
            }

            .card-header h3 {
                margin: 0;
            }

            .status-badge {
                padding: 4px 12px;
                border-radius: 12px;
                font-size: 12px;
                font-weight: 600;
                text-transform: uppercase;
            }

            .status-badge.pass {
                background: #e8f5e9;
                color: #2e7d32;
            }

            .status-badge.warn {
                background: #fff3e0;
                color: #ef6c00;
            }

            .status-badge.fail {
                background: #ffebee;
                color: #c62828;
            }

            .score-ring {
                width: 100px;
                height: 100px;
                margin: 0 auto 16px;
            }

            .circular-chart {
                display: block;
                max-width: 100%;
            }

            .circle-bg {
                fill: none;
                stroke: #eee;
                stroke-width: 3.8;
            }

            .circle {
                fill: none;
                stroke-width: 2.8;
                stroke-linecap: round;
                animation: progress 1s ease-out forwards;
            }

            .circle.pass {
                stroke: #4caf50;
            }

            .circle.warn {
                stroke: #ff9800;
            }

            .circle.fail {
                stroke: #f44336;
            }

            .percentage {
                fill: #333;
                font-size: 8px;
                text-anchor: middle;
                font-weight: 600;
            }

            @keyframes progress {
                0% {
                    stroke-dasharray: 0 100;
                }
            }

            .checks-list {
                border-top: 1px solid #eee;
                padding-top: 12px;
            }

            .check-item {
                display: flex;
                align-items: center;
                gap: 8px;
                padding: 6px 0;
            }

            .check-icon {
                width: 20px;
                text-align: center;
            }

            .check-item.pass .check-icon {
                color: #4caf50;
            }

            .check-item.warn .check-icon {
                color: #ff9800;
            }

            .check-item.fail .check-icon {
                color: #f44336;
            }

            .check-name {
                flex: 1;
                font-size: 14px;
            }

            .check-score {
                font-size: 14px;
                font-weight: 500;
            }

            .card-footer {
                margin-top: 12px;
                padding-top: 12px;
                border-top: 1px solid #eee;
                color: #999;
            }

            .profile-summary {
                display: flex;
                gap: 16px;
                margin-bottom: 20px;
            }

            .stat-card {
                background: white;
                padding: 20px;
                border-radius: 8px;
                border: 1px solid #e0e0e0;
                text-align: center;
            }

            .stat-value {
                font-size: 32px;
                font-weight: 600;
                color: #2196f3;
            }

            .stat-label {
                font-size: 14px;
                color: #666;
            }

            .column-stats {
                display: flex;
                flex-wrap: wrap;
                gap: 12px;
            }

            .column-card {
                background: white;
                padding: 12px;
                border-radius: 6px;
                border: 1px solid #e0e0e0;
            }

            .column-card h4 {
                margin: 0 0 4px;
                font-size: 14px;
            }

            .type-badge {
                background: #e3f2fd;
                color: #1976d2;
                padding: 2px 8px;
                border-radius: 4px;
                font-size: 12px;
            }

            .ai-chat-panel {
                position: fixed;
                right: 20px;
                bottom: 20px;
                width: 400px;
                max-height: 500px;
                background: white;
                border-radius: 12px;
                box-shadow: 0 8px 32px rgba(0, 0, 0, 0.15);
                display: flex;
                flex-direction: column;
                z-index: 1000;
            }

            .chat-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 12px 16px;
                border-bottom: 1px solid #eee;
            }

            .chat-header h2 {
                margin: 0;
                font-size: 16px;
            }

            .btn-close {
                background: none;
                border: none;
                font-size: 24px;
                cursor: pointer;
                color: #999;
            }

            .chat-messages {
                flex: 1;
                overflow-y: auto;
                padding: 16px;
                max-height: 300px;
            }

            .message {
                margin-bottom: 12px;
            }

            .message.user .message-content {
                background: #2196f3;
                color: white;
                margin-left: auto;
            }

            .message.assistant .message-content {
                background: #f5f5f5;
            }

            .message-content {
                display: inline-block;
                max-width: 80%;
                padding: 10px 14px;
                border-radius: 16px;
            }

            .routing-tag {
                display: inline-block;
                padding: 2px 8px;
                border-radius: 10px;
                font-size: 11px;
                margin-top: 4px;
            }

            .chat-input {
                display: flex;
                gap: 8px;
                padding: 12px;
                border-top: 1px solid #eee;
            }

            .chat-input input {
                flex: 1;
                padding: 10px;
                border: 1px solid #ddd;
                border-radius: 20px;
            }

            .btn-send {
                background: #2196f3;
                color: white;
                border: none;
                padding: 10px 20px;
                border-radius: 20px;
                cursor: pointer;
            }

            .routing-explanation {
                padding: 8px 12px;
                background: #f9f9f9;
                border-top: 1px solid #eee;
                font-size: 12px;
                color: #666;
            }

            .error-banner {
                position: fixed;
                bottom: 20px;
                left: 50%;
                transform: translateX(-50%);
                background: #f44336;
                color: white;
                padding: 12px 20px;
                border-radius: 8px;
                display: flex;
                align-items: center;
                gap: 12px;
            }

            .error-banner button {
                background: none;
                border: none;
                color: white;
                font-size: 20px;
                cursor: pointer;
            }
        `,
    ],
})
export class DataQualityDashboardComponent implements OnInit, OnDestroy {
    private readonly copilotService = inject(CopilotService);
    private readonly destroy$ = new Subject<void>();

    // State signals
    mcpConnected = signal(false);
    loading = signal(false);
    error = signal<string | null>(null);
    selectedTable = '';

    // Quality results
    qualityResults = signal<TableQualityStatus[]>([]);

    // Profiling results
    profilingResult = signal<DataProfilingResponse | null>(null);

    // AI Chat
    showAIChat = signal(false);
    chatMessages = signal<ChatMessage[]>([]);
    chatInput = '';
    chatLoading = signal(false);
    chatRoutingInfo = signal<AIRoutingInfo | null>(null);
    lastRouting = signal<AIRoutingInfo | null>(null);

    ngOnInit(): void {
        this.checkMCPHealth();
    }

    ngOnDestroy(): void {
        this.destroy$.next();
        this.destroy$.complete();
    }

    checkMCPHealth(): void {
        this.copilotService
            .mcpHealth()
            .pipe(takeUntil(this.destroy$))
            .subscribe({
                next: () => this.mcpConnected.set(true),
                error: () => this.mcpConnected.set(false),
            });
    }

    runQualityCheck(): void {
        if (!this.selectedTable) return;

        this.loading.set(true);
        this.error.set(null);

        this.copilotService
            .runDataQualityCheck(this.selectedTable)
            .pipe(takeUntil(this.destroy$))
            .subscribe({
                next: (response) => {
                    const avgScore = response.checks.reduce((sum, c) => sum + c.score, 0) / response.checks.length;
                    const status: TableQualityStatus = {
                        table: response.table,
                        checks: response.checks,
                        overallStatus: this.getOverallStatus(response.checks),
                        score: avgScore,
                        lastChecked: new Date(),
                    };

                    this.qualityResults.update((results) => {
                        const existing = results.findIndex((r) => r.table === status.table);
                        if (existing >= 0) {
                            results[existing] = status;
                            return [...results];
                        }
                        return [...results, status];
                    });
                    this.loading.set(false);
                },
                error: (err) => {
                    this.error.set(err.message || 'Failed to run quality check');
                    this.loading.set(false);
                },
            });
    }

    profileTable(): void {
        if (!this.selectedTable) return;

        this.loading.set(true);
        this.error.set(null);

        this.copilotService
            .profileData(this.selectedTable)
            .pipe(takeUntil(this.destroy$))
            .subscribe({
                next: (response) => {
                    this.profilingResult.set(response);
                    this.loading.set(false);
                },
                error: (err) => {
                    this.error.set(err.message || 'Failed to profile data');
                    this.loading.set(false);
                },
            });
    }

    detectAnomalies(): void {
        if (!this.selectedTable) return;

        this.loading.set(true);
        this.error.set(null);

        // For simplicity, detect anomalies on first column
        this.copilotService
            .detectAnomalies(this.selectedTable, '*')
            .pipe(takeUntil(this.destroy$))
            .subscribe({
                next: (response) => {
                    this.chatMessages.update((msgs) => [
                        ...msgs,
                        {
                            role: 'assistant',
                            content: `Found ${response.anomalies_found} anomalies in ${response.table}.${response.column} using ${response.method} method.`,
                        },
                    ]);
                    this.showAIChat.set(true);
                    this.loading.set(false);
                },
                error: (err) => {
                    this.error.set(err.message || 'Failed to detect anomalies');
                    this.loading.set(false);
                },
            });
    }

    openAIChat(): void {
        this.showAIChat.set(true);
    }

    closeAIChat(): void {
        this.showAIChat.set(false);
    }

    sendChatMessage(): void {
        if (!this.chatInput.trim()) return;

        const userMessage: ChatMessage = {
            role: 'user',
            content: this.chatInput,
        };

        this.chatMessages.update((msgs) => [...msgs, userMessage]);
        this.chatInput = '';
        this.chatLoading.set(true);

        const context = this.selectedTable ? { table_name: this.selectedTable } : undefined;

        this.copilotService
            .aiChat(this.chatMessages(), context)
            .pipe(takeUntil(this.destroy$))
            .subscribe({
                next: (response) => {
                    this.chatMessages.update((msgs) => [...msgs, { role: 'assistant', content: response.content }]);
                    this.chatRoutingInfo.set(response.routing);
                    this.lastRouting.set(response.routing);
                    this.chatLoading.set(false);
                },
                error: (err) => {
                    this.chatMessages.update((msgs) => [...msgs, { role: 'assistant', content: `Error: ${err.message}` }]);
                    this.chatLoading.set(false);
                },
            });
    }

    getRoutingIndicator(): RoutingIndicator {
        const backend = this.lastRouting()?.backend || 'aicore';
        return ROUTING_INDICATORS[backend] || ROUTING_INDICATORS['aicore'];
    }

    getOverallStatus(checks: QualityCheckResult[]): 'PASS' | 'WARN' | 'FAIL' {
        if (checks.some((c) => c.status === 'FAIL')) return 'FAIL';
        if (checks.some((c) => c.status === 'WARN')) return 'WARN';
        return 'PASS';
    }

    getColumnCount(): number {
        const profile = this.profilingResult();
        return profile ? Object.keys(profile.column_stats).length : 0;
    }

    getColumns(): Array<{ name: string; type: string; pii?: boolean }> {
        const profile = this.profilingResult();
        if (!profile) return [];
        return Object.entries(profile.column_stats).map(([name, stats]) => ({
            name,
            type: stats.type || 'unknown',
            pii: (stats as Record<string, unknown>)['is_pii'] === true,
        }));
    }

    clearError(): void {
        this.error.set(null);
    }
}
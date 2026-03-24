// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { Component, OnInit, OnDestroy, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil, interval } from 'rxjs';
import { HttpClient } from '@angular/common/http';

interface ApprovalRequest {
    id: string;
    query: string;
    table_name: string;
    tool: string;
    estimated_rows: number;
    risk_level: 'low' | 'medium' | 'high';
    status: 'pending' | 'approved' | 'rejected';
    requested_by: string;
    requested_at: string;
    reviewed_by?: string;
    reviewed_at?: string;
    reason?: string;
    pii_columns?: string[];
    affected_tables?: string[];
}

interface ApprovalStats {
    pending: number;
    approved: number;
    rejected: number;
    total: number;
}

@Component({
    selector: 'app-approval-workflow',
    standalone: true,
    imports: [CommonModule, FormsModule],
    template: `
        <div class="approval-container">
            <header class="approval-header">
                <h1>Query Approval Workflow</h1>
                <div class="stats-bar">
                    <div class="stat pending">
                        <span class="stat-value">{{ stats().pending }}</span>
                        <span class="stat-label">Pending</span>
                    </div>
                    <div class="stat approved">
                        <span class="stat-value">{{ stats().approved }}</span>
                        <span class="stat-label">Approved</span>
                    </div>
                    <div class="stat rejected">
                        <span class="stat-value">{{ stats().rejected }}</span>
                        <span class="stat-label">Rejected</span>
                    </div>
                </div>
            </header>

            <!-- Filter Tabs -->
            <div class="filter-tabs">
                <button 
                    [class.active]="filter() === 'pending'" 
                    (click)="setFilter('pending')">
                    Pending ({{ stats().pending }})
                </button>
                <button 
                    [class.active]="filter() === 'approved'" 
                    (click)="setFilter('approved')">
                    Approved
                </button>
                <button 
                    [class.active]="filter() === 'rejected'" 
                    (click)="setFilter('rejected')">
                    Rejected
                </button>
                <button 
                    [class.active]="filter() === 'all'" 
                    (click)="setFilter('all')">
                    All
                </button>
            </div>

            <!-- Requests List -->
            <div class="requests-list">
                @for (request of filteredRequests(); track request.id) {
                    <div class="request-card" [class]="'risk-' + request.risk_level">
                        <div class="card-header">
                            <div class="request-meta">
                                <span class="request-id">{{ request.id.slice(0, 8) }}...</span>
                                <span class="tool-badge">{{ request.tool }}</span>
                                <span class="risk-badge" [class]="request.risk_level">
                                    {{ request.risk_level | uppercase }}
                                </span>
                                @if (request.pii_columns && request.pii_columns.length > 0) {
                                    <span class="pii-warning">⚠️ PII</span>
                                }
                            </div>
                            <span class="status-badge" [class]="request.status">
                                {{ request.status | uppercase }}
                            </span>
                        </div>

                        <div class="request-info">
                            <div class="info-row">
                                <span class="label">Table:</span>
                                <span class="value">{{ request.table_name }}</span>
                            </div>
                            <div class="info-row">
                                <span class="label">Estimated Rows:</span>
                                <span class="value" [class.high-impact]="request.estimated_rows > 1000">
                                    {{ request.estimated_rows | number }}
                                </span>
                            </div>
                            <div class="info-row">
                                <span class="label">Requested By:</span>
                                <span class="value">{{ request.requested_by }}</span>
                            </div>
                            <div class="info-row">
                                <span class="label">Requested At:</span>
                                <span class="value">{{ request.requested_at | date:'medium' }}</span>
                            </div>
                        </div>

                        @if (request.pii_columns && request.pii_columns.length > 0) {
                            <div class="pii-warning-box">
                                <strong>⚠️ PII Columns Affected:</strong>
                                <div class="pii-columns">
                                    @for (col of request.pii_columns; track col) {
                                        <span class="pii-col">{{ col }}</span>
                                    }
                                </div>
                            </div>
                        }

                        <div class="query-section">
                            <div class="query-header" (click)="toggleQuery(request.id)">
                                <span>SQL Query</span>
                                <span class="toggle-icon">{{ expandedQueries().has(request.id) ? '▼' : '▶' }}</span>
                            </div>
                            @if (expandedQueries().has(request.id)) {
                                <pre class="query-code">{{ request.query }}</pre>
                            }
                        </div>

                        @if (request.status === 'pending') {
                            <div class="action-section">
                                <div class="reason-input">
                                    <input 
                                        type="text" 
                                        [(ngModel)]="reviewReasons[request.id]"
                                        placeholder="Optional: Add review comment..."
                                    />
                                </div>
                                <div class="action-buttons">
                                    <button 
                                        class="btn-approve" 
                                        (click)="approveRequest(request)"
                                        [disabled]="processing()">
                                        ✓ Approve
                                    </button>
                                    <button 
                                        class="btn-reject" 
                                        (click)="rejectRequest(request)"
                                        [disabled]="processing()">
                                        ✗ Reject
                                    </button>
                                </div>
                            </div>
                        }

                        @if (request.reviewed_by) {
                            <div class="review-info">
                                <span>Reviewed by {{ request.reviewed_by }}</span>
                                @if (request.reviewed_at) {
                                    <span> at {{ request.reviewed_at | date:'medium' }}</span>
                                }
                                @if (request.reason) {
                                    <div class="review-reason">{{ request.reason }}</div>
                                }
                            </div>
                        }
                    </div>
                }

                @if (filteredRequests().length === 0) {
                    <div class="empty-state">
                        <div class="empty-icon">📋</div>
                        <h3>No {{ filter() === 'all' ? '' : filter() }} requests</h3>
                        <p>Query approval requests will appear here when generated.</p>
                    </div>
                }
            </div>

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
            .approval-container {
                padding: 20px;
                max-width: 1200px;
                margin: 0 auto;
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            }

            .approval-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 24px;
            }

            .approval-header h1 {
                margin: 0;
                color: #333;
            }

            .stats-bar {
                display: flex;
                gap: 16px;
            }

            .stat {
                text-align: center;
                padding: 8px 16px;
                border-radius: 8px;
                background: #f5f5f5;
            }

            .stat.pending {
                background: #fff3e0;
            }

            .stat.approved {
                background: #e8f5e9;
            }

            .stat.rejected {
                background: #ffebee;
            }

            .stat-value {
                display: block;
                font-size: 24px;
                font-weight: 600;
            }

            .stat.pending .stat-value {
                color: #ef6c00;
            }

            .stat.approved .stat-value {
                color: #2e7d32;
            }

            .stat.rejected .stat-value {
                color: #c62828;
            }

            .stat-label {
                font-size: 12px;
                color: #666;
            }

            .filter-tabs {
                display: flex;
                gap: 8px;
                margin-bottom: 20px;
                padding-bottom: 16px;
                border-bottom: 1px solid #e0e0e0;
            }

            .filter-tabs button {
                padding: 8px 16px;
                border: 1px solid #ddd;
                background: white;
                border-radius: 20px;
                cursor: pointer;
                font-size: 14px;
                transition: all 0.2s;
            }

            .filter-tabs button:hover {
                border-color: #2196f3;
            }

            .filter-tabs button.active {
                background: #2196f3;
                color: white;
                border-color: #2196f3;
            }

            .requests-list {
                display: flex;
                flex-direction: column;
                gap: 16px;
            }

            .request-card {
                background: white;
                border: 1px solid #e0e0e0;
                border-radius: 12px;
                padding: 20px;
                border-left: 4px solid #2196f3;
            }

            .request-card.risk-high {
                border-left-color: #f44336;
            }

            .request-card.risk-medium {
                border-left-color: #ff9800;
            }

            .request-card.risk-low {
                border-left-color: #4caf50;
            }

            .card-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 16px;
            }

            .request-meta {
                display: flex;
                align-items: center;
                gap: 10px;
            }

            .request-id {
                font-family: monospace;
                color: #666;
                font-size: 12px;
            }

            .tool-badge {
                background: #e3f2fd;
                color: #1976d2;
                padding: 2px 8px;
                border-radius: 4px;
                font-size: 12px;
            }

            .risk-badge {
                padding: 2px 8px;
                border-radius: 4px;
                font-size: 11px;
                font-weight: 600;
            }

            .risk-badge.high {
                background: #ffebee;
                color: #c62828;
            }

            .risk-badge.medium {
                background: #fff3e0;
                color: #ef6c00;
            }

            .risk-badge.low {
                background: #e8f5e9;
                color: #2e7d32;
            }

            .pii-warning {
                background: #ff5722;
                color: white;
                padding: 2px 8px;
                border-radius: 4px;
                font-size: 11px;
            }

            .status-badge {
                padding: 4px 12px;
                border-radius: 12px;
                font-size: 12px;
                font-weight: 600;
            }

            .status-badge.pending {
                background: #fff3e0;
                color: #ef6c00;
            }

            .status-badge.approved {
                background: #e8f5e9;
                color: #2e7d32;
            }

            .status-badge.rejected {
                background: #ffebee;
                color: #c62828;
            }

            .request-info {
                display: grid;
                grid-template-columns: repeat(2, 1fr);
                gap: 8px;
                margin-bottom: 16px;
            }

            .info-row {
                display: flex;
                gap: 8px;
            }

            .info-row .label {
                color: #666;
                font-size: 14px;
            }

            .info-row .value {
                font-weight: 500;
                font-size: 14px;
            }

            .info-row .value.high-impact {
                color: #c62828;
            }

            .pii-warning-box {
                background: #fff8e1;
                border: 1px solid #ffca28;
                border-radius: 8px;
                padding: 12px;
                margin-bottom: 16px;
            }

            .pii-columns {
                margin-top: 8px;
                display: flex;
                flex-wrap: wrap;
                gap: 6px;
            }

            .pii-col {
                background: #ff5722;
                color: white;
                padding: 2px 8px;
                border-radius: 4px;
                font-size: 12px;
            }

            .query-section {
                border: 1px solid #e0e0e0;
                border-radius: 8px;
                margin-bottom: 16px;
            }

            .query-header {
                display: flex;
                justify-content: space-between;
                padding: 10px 14px;
                background: #f5f5f5;
                cursor: pointer;
                border-radius: 8px 8px 0 0;
                font-size: 14px;
                font-weight: 500;
            }

            .query-code {
                margin: 0;
                padding: 14px;
                background: #263238;
                color: #b2ff59;
                font-family: 'Fira Code', monospace;
                font-size: 13px;
                overflow-x: auto;
                border-radius: 0 0 8px 8px;
            }

            .action-section {
                display: flex;
                gap: 12px;
                align-items: center;
            }

            .reason-input {
                flex: 1;
            }

            .reason-input input {
                width: 100%;
                padding: 10px;
                border: 1px solid #ddd;
                border-radius: 6px;
                font-size: 14px;
            }

            .action-buttons {
                display: flex;
                gap: 8px;
            }

            .btn-approve,
            .btn-reject {
                padding: 10px 20px;
                border: none;
                border-radius: 6px;
                cursor: pointer;
                font-size: 14px;
                font-weight: 500;
                transition: all 0.2s;
            }

            .btn-approve {
                background: #4caf50;
                color: white;
            }

            .btn-approve:hover:not(:disabled) {
                background: #43a047;
            }

            .btn-reject {
                background: #f44336;
                color: white;
            }

            .btn-reject:hover:not(:disabled) {
                background: #e53935;
            }

            .btn-approve:disabled,
            .btn-reject:disabled {
                opacity: 0.5;
                cursor: not-allowed;
            }

            .review-info {
                margin-top: 12px;
                padding-top: 12px;
                border-top: 1px solid #e0e0e0;
                font-size: 13px;
                color: #666;
            }

            .review-reason {
                margin-top: 4px;
                padding: 8px;
                background: #f5f5f5;
                border-radius: 4px;
                font-style: italic;
            }

            .empty-state {
                text-align: center;
                padding: 60px 20px;
                color: #666;
            }

            .empty-icon {
                font-size: 48px;
                margin-bottom: 16px;
            }

            .empty-state h3 {
                margin: 0 0 8px;
            }

            .empty-state p {
                margin: 0;
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
export class ApprovalWorkflowComponent implements OnInit, OnDestroy {
    private readonly http = inject(HttpClient);
    private readonly destroy$ = new Subject<void>();
    private readonly baseUrl = 'http://localhost:9110';

    // State
    requests = signal<ApprovalRequest[]>([]);
    filter = signal<'pending' | 'approved' | 'rejected' | 'all'>('pending');
    expandedQueries = signal<Set<string>>(new Set());
    processing = signal(false);
    error = signal<string | null>(null);
    reviewReasons: Record<string, string> = {};

    // Computed
    stats = computed<ApprovalStats>(() => {
        const all = this.requests();
        return {
            pending: all.filter((r) => r.status === 'pending').length,
            approved: all.filter((r) => r.status === 'approved').length,
            rejected: all.filter((r) => r.status === 'rejected').length,
            total: all.length,
        };
    });

    filteredRequests = computed(() => {
        const f = this.filter();
        const all = this.requests();
        if (f === 'all') return all;
        return all.filter((r) => r.status === f);
    });

    ngOnInit(): void {
        this.loadRequests();
        // Poll for updates
        interval(10000)
            .pipe(takeUntil(this.destroy$))
            .subscribe(() => this.loadRequests());
    }

    ngOnDestroy(): void {
        this.destroy$.next();
        this.destroy$.complete();
    }

    loadRequests(): void {
        this.http
            .get<ApprovalRequest[]>(`${this.baseUrl}/api/approvals`)
            .pipe(takeUntil(this.destroy$))
            .subscribe({
                next: (requests) => this.requests.set(requests),
                error: (err) => {
                    // Use mock data for demo
                    this.requests.set(this.getMockRequests());
                },
            });
    }

    setFilter(f: 'pending' | 'approved' | 'rejected' | 'all'): void {
        this.filter.set(f);
    }

    toggleQuery(id: string): void {
        this.expandedQueries.update((set) => {
            const newSet = new Set(set);
            if (newSet.has(id)) {
                newSet.delete(id);
            } else {
                newSet.add(id);
            }
            return newSet;
        });
    }

    approveRequest(request: ApprovalRequest): void {
        this.processRequest(request, 'approved');
    }

    rejectRequest(request: ApprovalRequest): void {
        this.processRequest(request, 'rejected');
    }

    private processRequest(request: ApprovalRequest, status: 'approved' | 'rejected'): void {
        this.processing.set(true);
        const reason = this.reviewReasons[request.id] || '';

        this.http
            .post(`${this.baseUrl}/api/approvals/${request.id}/${status}`, {
                reason,
                reviewed_by: 'current_user@example.com',
            })
            .pipe(takeUntil(this.destroy$))
            .subscribe({
                next: () => {
                    this.requests.update((list) =>
                        list.map((r) =>
                            r.id === request.id
                                ? {
                                      ...r,
                                      status,
                                      reviewed_by: 'current_user@example.com',
                                      reviewed_at: new Date().toISOString(),
                                      reason: reason || undefined,
                                  }
                                : r
                        )
                    );
                    this.processing.set(false);
                    delete this.reviewReasons[request.id];
                },
                error: (err) => {
                    // Optimistic update for demo
                    this.requests.update((list) =>
                        list.map((r) =>
                            r.id === request.id
                                ? {
                                      ...r,
                                      status,
                                      reviewed_by: 'current_user@example.com',
                                      reviewed_at: new Date().toISOString(),
                                      reason: reason || undefined,
                                  }
                                : r
                        )
                    );
                    this.processing.set(false);
                },
            });
    }

    clearError(): void {
        this.error.set(null);
    }

    private getMockRequests(): ApprovalRequest[] {
        return [
            {
                id: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
                query: "DELETE FROM Users WHERE last_login < '2023-01-01' AND status = 'inactive'",
                table_name: 'Users',
                tool: 'generate_cleaning_query',
                estimated_rows: 1523,
                risk_level: 'high',
                status: 'pending',
                requested_by: 'admin@example.com',
                requested_at: new Date(Date.now() - 3600000).toISOString(),
                pii_columns: ['email', 'phone', 'first_name', 'last_name'],
                affected_tables: ['Users', 'UserProfiles'],
            },
            {
                id: 'b2c3d4e5-f6g7-8901-bcde-f12345678901',
                query: "UPDATE Orders SET status = 'archived' WHERE created_at < '2022-01-01'",
                table_name: 'Orders',
                tool: 'generate_cleaning_query',
                estimated_rows: 456,
                risk_level: 'medium',
                status: 'pending',
                requested_by: 'analyst@example.com',
                requested_at: new Date(Date.now() - 7200000).toISOString(),
            },
            {
                id: 'c3d4e5f6-g7h8-9012-cdef-012345678902',
                query: "DELETE FROM TempLogs WHERE created_at < NOW() - INTERVAL 30 DAY",
                table_name: 'TempLogs',
                tool: 'generate_cleaning_query',
                estimated_rows: 89,
                risk_level: 'low',
                status: 'approved',
                requested_by: 'admin@example.com',
                requested_at: new Date(Date.now() - 86400000).toISOString(),
                reviewed_by: 'reviewer@example.com',
                reviewed_at: new Date(Date.now() - 82800000).toISOString(),
                reason: 'Routine cleanup, safe to execute',
            },
        ];
    }
}
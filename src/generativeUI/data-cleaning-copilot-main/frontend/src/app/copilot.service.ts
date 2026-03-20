import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

export interface ChatMessage {
    role: 'user' | 'assistant';
    content: string;
    timestamp?: string;
}

export interface CheckInfo {
    description: string;
    scope: string;
    code: string;
}

export interface SessionConfig {
    main: Record<string, unknown>;
    check_gen: Record<string, unknown>;
    session_model: string;
    agent_model: string;
}

export interface WorkflowGeneratedCheck extends CheckInfo {
    name: string;
    isNew: boolean;
}

export interface WorkflowSummary {
    runId: string;
    status: 'processing' | 'awaiting_approval' | 'completed' | 'error';
    startedAt: string;
    finishedAt?: string;
    userMessage: string;
    assistantResponse: string;
    requestKind: string;
    newCheckNames: string[];
    newCheckCount: number;
    totalChecks: number;
    sessionModel: string;
    agentModel: string;
    generatedChecks: WorkflowGeneratedCheck[];
}

export interface WorkflowSnapshot {
    summary: WorkflowSummary;
    checks: Record<string, CheckInfo>;
    sessionHistory: ChatMessage[];
    checkHistory: ChatMessage[];
    sessionConfig: SessionConfig;
}

export interface WorkflowReview {
    reviewId: string;
    createdAt: string;
    requestKind: string;
    riskLevel: 'medium' | 'high';
    title: string;
    summary: string;
    affectedScope: string[];
    guardrails: string[];
    plannedCalls: Array<{ name: string; summary: string }>;
    userMessage: string;
}

export interface WorkflowAuditEntry {
    id: string;
    timestamp: string;
    runId: string;
    eventType: string;
    status: string;
    message: string;
    requestKind?: string;
    reviewId?: string;
    detail?: string;
}

export interface WorkflowState {
    workflowRun: WorkflowSnapshot | null;
    pendingReview: WorkflowReview | null;
}

export interface WorkflowReplayEvent {
    id: string;
    sequence: number;
    timestamp: string;
    runId: string;
    type: WorkflowStreamEvent['type'];
    payload: WorkflowStreamEvent | Record<string, unknown>;
}

export type WorkflowStreamEvent =
    | { type: 'run.started'; runId: string; startedAt: string; userMessage: string }
    | { type: 'run.status'; runId: string; status: 'processing'; phase: string }
    | { type: 'approval.required'; runId: string; status: 'awaiting_approval'; review: WorkflowReview }
    | { type: 'assistant.message'; runId: string; content: string }
    | { type: 'workflow.snapshot'; runId: string; snapshot: WorkflowSnapshot }
    | { type: 'run.finished'; runId: string; status: 'completed'; finishedAt: string }
    | { type: 'run.error'; runId: string; status: 'error'; finishedAt: string; error: string };

@Injectable({ providedIn: 'root' })
export class CopilotService {
    private readonly http = inject(HttpClient);
    private readonly base = 'http://localhost:8000/api';

    chat(message: string): Observable<{ response: string }> {
        return this.http.post<{ response: string }>(`${this.base}/chat`, { message });
    }

    runWorkflow(message: string, reviewId?: string): Observable<WorkflowStreamEvent> {
        return new Observable<WorkflowStreamEvent>((subscriber) => {
            const controller = new AbortController();

            fetch(`${this.base}/workflow/run`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    Accept: 'text/event-stream',
                },
                body: JSON.stringify({ message, review_id: reviewId }),
                signal: controller.signal,
            })
                .then(async (response) => {
                    if (!response.ok) {
                        throw new Error(`Workflow stream failed: HTTP ${response.status}`);
                    }

                    const reader = response.body?.getReader();
                    if (!reader) {
                        throw new Error('Workflow stream is not readable');
                    }

                    const decoder = new TextDecoder();
                    let buffer = '';

                    while (true) {
                        const { done, value } = await reader.read();
                        if (done) {
                            break;
                        }

                        buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n');
                        const frames = buffer.split('\n\n');
                        buffer = frames.pop() ?? '';

                        for (const frame of frames) {
                            const event = this.parseWorkflowEvent(frame);
                            if (!event) {
                                continue;
                            }

                            subscriber.next(event);
                            if (event.type === 'run.finished' || event.type === 'run.error') {
                                subscriber.complete();
                                return;
                            }
                        }
                    }

                    const trailingEvent = this.parseWorkflowEvent(buffer);
                    if (trailingEvent) {
                        subscriber.next(trailingEvent);
                    }
                    subscriber.complete();
                })
                .catch((error: Error) => {
                    if (error.name === 'AbortError') {
                        subscriber.complete();
                        return;
                    }

                    subscriber.error(error);
                });

            return () => controller.abort();
        });
    }

    getChecks(): Observable<Record<string, CheckInfo>> {
        return this.http.get<Record<string, CheckInfo>>(`${this.base}/checks`);
    }

    getSessionHistory(limit = 10): Observable<ChatMessage[]> {
        return this.http.get<ChatMessage[]>(`${this.base}/session-history`, { params: { limit } });
    }

    getCheckHistory(limit = 5): Observable<ChatMessage[]> {
        return this.http.get<ChatMessage[]>(`${this.base}/check-history`, { params: { limit } });
    }

    getSessionConfig(): Observable<SessionConfig> {
        return this.http.get<SessionConfig>(`${this.base}/session-config`);
    }

    getWorkflowAudit(limit = 50): Observable<WorkflowAuditEntry[]> {
        return this.http.get<WorkflowAuditEntry[]>(`${this.base}/workflow/audit`, { params: { limit } });
    }

    getWorkflowState(): Observable<WorkflowState> {
        return this.http.get<WorkflowState>(`${this.base}/workflow/state`);
    }

    getWorkflowEvents(runId?: string, limit = 100): Observable<WorkflowReplayEvent[]> {
        const params: Record<string, string | number> = { limit };
        if (runId) {
            params['run_id'] = runId;
        }
        return this.http.get<WorkflowReplayEvent[]>(`${this.base}/workflow/events`, { params });
    }

    rejectWorkflowReview(reviewId: string): Observable<{ status: string; reviewId: string }> {
        return this.http.post<{ status: string; reviewId: string }>(`${this.base}/workflow/reviews/${reviewId}/reject`, {});
    }

    clearSession(): Observable<{ status: string }> {
        return this.http.delete<{ status: string }>(`${this.base}/session`);
    }

    health(): Observable<{ status: string; session_ready: boolean }> {
        return this.http.get<{ status: string; session_ready: boolean }>(`${this.base}/health`);
    }

    private parseWorkflowEvent(frame: string): WorkflowStreamEvent | null {
        const payload = frame
            .split('\n')
            .filter((line) => line.startsWith('data:'))
            .map((line) => line.slice(5).trim())
            .join('\n');

        if (!payload) {
            return null;
        }

        return JSON.parse(payload) as WorkflowStreamEvent;
    }
}

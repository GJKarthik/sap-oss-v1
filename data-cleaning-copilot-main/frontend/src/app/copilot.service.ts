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

@Injectable({ providedIn: 'root' })
export class CopilotService {
    private readonly http = inject(HttpClient);
    private readonly base = 'http://localhost:8000/api';

    chat(message: string): Observable<{ response: string }> {
        return this.http.post<{ response: string }>(`${this.base}/chat`, { message });
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

    clearSession(): Observable<{ status: string }> {
        return this.http.delete<{ status: string }>(`${this.base}/session`);
    }

    health(): Observable<{ status: string; session_ready: boolean }> {
        return this.http.get<{ status: string; session_ready: boolean }>(`${this.base}/health`);
    }
}

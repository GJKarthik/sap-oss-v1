import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

import { environment } from '../../../environments/environment';

export interface GovernanceRule {
  id: string;
  name: string;
  rule_type: string;
  active: boolean;
  description: string | null;
}

export interface GovernanceRuleCreateRequest {
  name: string;
  rule_type: string;
  active?: boolean;
  description?: string | null;
}

export interface GovernanceRuleListResponse {
  rules: GovernanceRule[];
  total: number;
}

export interface GovernanceRuleToggleResponse {
  id: string;
  active: boolean;
}

@Injectable({ providedIn: 'root' })
export class GovernanceService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.apiBaseUrl}/governance`;

  listRules(): Observable<GovernanceRuleListResponse> {
    return this.http.get<GovernanceRuleListResponse>(this.baseUrl);
  }

  createRule(body: GovernanceRuleCreateRequest): Observable<GovernanceRule> {
    return this.http.post<GovernanceRule>(this.baseUrl, body);
  }

  getRule(ruleId: string): Observable<GovernanceRule> {
    return this.http.get<GovernanceRule>(`${this.baseUrl}/${ruleId}`);
  }

  toggleRule(ruleId: string): Observable<GovernanceRuleToggleResponse> {
    return this.http.patch<GovernanceRuleToggleResponse>(`${this.baseUrl}/${ruleId}/toggle`, null);
  }

  deleteRule(ruleId: string): Observable<void> {
    return this.http.delete<void>(`${this.baseUrl}/${ruleId}`);
  }
}
/**
 * Team Configuration Service for Training Console
 *
 * Manages team-level settings: members, roles, shared model configs,
 * data source connections, and governance policies.
 * Persists via the api-server backend.
 */

import { Injectable, OnDestroy } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { BehaviorSubject, Subject, of } from 'rxjs';
import { catchError, takeUntil, tap } from 'rxjs/operators';
import { environment } from '../../environments/environment';

export type TeamRole = 'admin' | 'editor' | 'viewer';

export interface TeamMemberConfig {
  userId: string;
  displayName: string;
  role: TeamRole;
  avatarUrl?: string;
  joinedAt: string;
}

export interface TeamConfig {
  teamId: string;
  teamName: string;
  members: TeamMemberConfig[];
  settings: TeamSettings;
  createdAt: string;
  updatedAt: string;
}

export interface TeamSettings {
  /** Default LLM model for the team */
  defaultModel: string;
  /** Shared data source connections */
  dataSources: DataSourceConfig[];
  /** Team-level governance policy overrides */
  governancePolicies: GovernancePolicyConfig[];
  /** Shared prompt templates */
  promptTemplates: PromptTemplate[];
}

export interface DataSourceConfig {
  id: string;
  name: string;
  type: 'hana' | 'pal' | 'custom';
  connectionString: string;
  enabled: boolean;
}

export interface GovernancePolicyConfig {
  id: string;
  name: string;
  ruleType: string;
  active: boolean;
  requireApprovalCount: number;
  approverRoles: TeamRole[];
}

export interface PromptTemplate {
  id: string;
  name: string;
  content: string;
  category: string;
  createdBy: string;
  createdAt: string;
  usageCount: number;
}

const DEFAULT_TEAM_SETTINGS: TeamSettings = {
  defaultModel: 'gpt-4',
  dataSources: [],
  governancePolicies: [],
  promptTemplates: [],
};

@Injectable({ providedIn: 'root' })
export class TeamConfigService implements OnDestroy {
  private readonly destroy$ = new Subject<void>();
  private readonly apiUrl = `${environment.apiBaseUrl}/team`;

  private readonly teamConfigSubject = new BehaviorSubject<TeamConfig | null>(null);
  readonly teamConfig$ = this.teamConfigSubject.asObservable();

  private readonly loadingSubject = new BehaviorSubject<boolean>(false);
  readonly loading$ = this.loadingSubject.asObservable();

  constructor(private readonly http: HttpClient) {}

  /** Load the current team configuration */
  loadTeamConfig(): void {
    this.loadingSubject.next(true);
    this.http.get<TeamConfig>(this.apiUrl)
      .pipe(
        takeUntil(this.destroy$),
        catchError(() => of(this.createDefaultTeamConfig())),
        tap(() => this.loadingSubject.next(false)),
      )
      .subscribe(config => this.teamConfigSubject.next(config));
  }

  /** Get current team config synchronously */
  getTeamConfig(): TeamConfig | null {
    return this.teamConfigSubject.value;
  }

  /** Update team settings */
  updateSettings(settings: Partial<TeamSettings>): void {
    const current = this.teamConfigSubject.value;
    if (!current) return;
    const updated = { ...current, settings: { ...current.settings, ...settings }, updatedAt: new Date().toISOString() };
    this.teamConfigSubject.next(updated);
    this.http.patch<TeamConfig>(`${this.apiUrl}/settings`, settings)
      .pipe(takeUntil(this.destroy$), catchError(() => of(updated)))
      .subscribe();
  }

  /** Add a team member */
  addMember(member: Omit<TeamMemberConfig, 'joinedAt'>): void {
    const current = this.teamConfigSubject.value;
    if (!current) return;
    const newMember: TeamMemberConfig = { ...member, joinedAt: new Date().toISOString() };
    const updated = { ...current, members: [...current.members, newMember], updatedAt: new Date().toISOString() };
    this.teamConfigSubject.next(updated);
    this.http.post(`${this.apiUrl}/members`, newMember)
      .pipe(takeUntil(this.destroy$), catchError(() => of(null)))
      .subscribe();
  }

  /** Update a member's role */
  updateMemberRole(userId: string, role: TeamRole): void {
    const current = this.teamConfigSubject.value;
    if (!current) return;
    const updated = { ...current, members: current.members.map(m => m.userId === userId ? { ...m, role } : m), updatedAt: new Date().toISOString() };
    this.teamConfigSubject.next(updated);
    this.http.patch(`${this.apiUrl}/members/${userId}`, { role })
      .pipe(takeUntil(this.destroy$), catchError(() => of(null)))
      .subscribe();
  }

  /** Check if user has a given role */
  hasRole(userId: string, role: TeamRole): boolean {
    const config = this.teamConfigSubject.value;
    if (!config) return false;
    const member = config.members.find(m => m.userId === userId);
    if (!member) return false;
    if (role === 'viewer') return true;
    if (role === 'editor') return member.role === 'editor' || member.role === 'admin';
    return member.role === 'admin';
  }

  private createDefaultTeamConfig(): TeamConfig {
    return { teamId: 'default', teamName: 'Default Team', members: [], settings: { ...DEFAULT_TEAM_SETTINGS }, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}

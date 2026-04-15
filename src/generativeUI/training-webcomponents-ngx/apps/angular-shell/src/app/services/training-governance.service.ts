import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import { ApiService } from './api.service';

export type TrainingWorkflowType = 'pipeline' | 'optimization' | 'deployment';
export type TrainingRiskTier = 'low' | 'medium' | 'high' | 'critical';
export type ApprovalStatus = 'pending' | 'approved' | 'rejected' | 'not_required';
export type GateStatus = 'draft' | 'blocked' | 'pending_approval' | 'passed';
export type TrainingRunStatus = 'draft' | 'submitted' | 'running' | 'completed' | 'failed';

export interface BlockingCheck {
  gate_key: string;
  category: string;
  detail: string;
  status: string;
}

export interface GovernanceSummary {
  run_id: string;
  workflow_type: TrainingWorkflowType;
  tag?: string | null;
  risk_tier: TrainingRiskTier;
  approval_status: ApprovalStatus;
  gate_status: GateStatus;
  blocking_checks: BlockingCheck[];
}

export interface TrainingJobResponse {
  id: string;
  status: string;
  progress: number;
  config: Record<string, unknown>;
  error?: string | null;
  history?: Array<Record<string, unknown>>;
  evaluation?: {
    perplexity: number;
    eval_loss: number;
    runtime_sec: number;
  } | null;
  deployed?: boolean;
  created_at: string;
  governance?: GovernanceSummary;
}

export interface TrainingApprovalDecision {
  id?: string;
  approver: string;
  action: 'approve' | 'reject';
  comment?: string;
  decided_at?: string;
}

export interface TrainingApproval {
  id: string;
  run_id: string;
  workflow_type: TrainingWorkflowType;
  title: string;
  description: string;
  risk_level: TrainingRiskTier;
  requested_by: string;
  approvers: string[];
  status: ApprovalStatus;
  decisions: TrainingApprovalDecision[];
  created_at: string;
  updated_at: string;
}

export interface TrainingPolicy {
  id: string;
  name: string;
  description: string;
  workflow_type?: TrainingWorkflowType | null;
  rule_type: string;
  enabled: boolean;
  severity: string;
  condition_json: Record<string, unknown>;
  created_at?: string;
  updated_at?: string;
}

export interface TrainingGateCheck {
  id?: string;
  run_id?: string;
  gate_key: string;
  category: string;
  status: string;
  detail: string;
  blocking: boolean;
  current_value?: number | null;
  threshold_min?: number | null;
  threshold_max?: number | null;
  metadata_json?: Record<string, unknown>;
  created_at?: string;
  updated_at?: string;
}

export interface TrainingMetricSnapshot {
  id?: string;
  run_id?: string;
  workflow_type: TrainingWorkflowType;
  team: string;
  metric_key: string;
  stage: string;
  value: number;
  unit: string;
  numerator?: number | null;
  denominator?: number | null;
  threshold_min?: number | null;
  threshold_max?: number | null;
  passed: boolean;
  metadata_json?: Record<string, unknown>;
  created_at?: string;
}

export interface TrainingArtifact {
  id?: string;
  run_id?: string;
  artifact_type: string;
  artifact_ref: string;
  metadata_json?: Record<string, unknown>;
  created_at?: string;
}

export interface TrainingRun {
  id: string;
  workflow_type: TrainingWorkflowType;
  use_case_family: string;
  team: string;
  requested_by: string;
  run_name: string;
  model_name?: string | null;
  dataset_ref?: string | null;
  job_id?: string | null;
  config_json: Record<string, unknown>;
  risk_tier: TrainingRiskTier;
  risk_score: number;
  approval_status: ApprovalStatus;
  gate_status: GateStatus;
  status: TrainingRunStatus;
  tag?: string | null;
  blocking_checks: BlockingCheck[];
  created_at: string;
  updated_at?: string;
  submitted_at?: string | null;
  launched_at?: string | null;
  completed_at?: string | null;
  approvals?: TrainingApproval[];
  gate_checks?: TrainingGateCheck[];
  metrics?: TrainingMetricSnapshot[];
  artifacts?: TrainingArtifact[];
  audit_entries?: Array<Record<string, unknown>>;
  job?: TrainingJobResponse | null;
}

export interface TrainingRunCreate {
  workflow_type: TrainingWorkflowType;
  use_case_family?: string;
  team?: string;
  requested_by?: string;
  run_name?: string;
  model_name?: string;
  dataset_ref?: string;
  config_json?: Record<string, unknown>;
  tag?: string;
}

export interface TrainingMetricsOverview {
  window_days: number;
  workflow_type?: string | null;
  team?: string | null;
  total_runs: number;
  gate_pass_rate: number;
  blocked_run_count: number;
  run_success_rate: number;
  approval_latency_sec_avg: number;
  evaluation_completeness_rate: number;
}

export interface TrainingMetricsTrendRow {
  date: string;
  runs: number;
  blocked_runs: number;
  completed_runs: number;
  gate_passed_runs: number;
  pending_approvals: number;
  gate_pass_rate: number;
  run_success_rate: number;
}

export interface TrainingMetricsTrends {
  window_days: number;
  rows: TrainingMetricsTrendRow[];
}

@Injectable({ providedIn: 'root' })
export class TrainingGovernanceService {
  private readonly api = inject(ApiService);

  listRuns(filters: Record<string, string | number> = {}): Observable<{ runs: TrainingRun[]; total: number }> {
    return this.api.get('/governance/training-runs', filters);
  }

  getRun(runId: string): Observable<TrainingRun> {
    return this.api.get(`/governance/training-runs/${runId}`);
  }

  createRun(body: TrainingRunCreate): Observable<TrainingRun> {
    return this.api.post('/governance/training-runs', body);
  }

  updateRun(runId: string, body: Partial<TrainingRunCreate> & { status?: string; tag?: string; job_id?: string }): Observable<TrainingRun> {
    return this.api.patch(`/governance/training-runs/${runId}`, body);
  }

  submitRun(runId: string): Observable<TrainingRun> {
    return this.api.post(`/governance/training-runs/${runId}/submit`, {});
  }

  launchRun(runId: string): Observable<TrainingRun> {
    return this.api.post(`/governance/training-runs/${runId}/launch`, {});
  }

  listApprovals(filters: Record<string, string | number> = {}): Observable<{ approvals: TrainingApproval[]; total: number }> {
    return this.api.get('/governance/approvals', filters);
  }

  decideApproval(approvalId: string, body: TrainingApprovalDecision): Observable<TrainingApproval> {
    return this.api.post(`/governance/approvals/${approvalId}/decide`, body);
  }

  listPolicies(workflowType?: TrainingWorkflowType): Observable<{ policies: TrainingPolicy[] }> {
    return this.api.get('/governance/policies', workflowType ? { workflow_type: workflowType } : undefined);
  }

  getMetricsOverview(filters: { window?: number; workflow_type?: string; team?: string } = {}): Observable<TrainingMetricsOverview> {
    return this.api.get('/governance/metrics/overview', filters);
  }

  getMetricsTrends(filters: { window?: number; workflow_type?: string; team?: string } = {}): Observable<TrainingMetricsTrends> {
    return this.api.get('/governance/metrics/trends', filters);
  }

  getRunMetrics(runId: string): Observable<{ metrics: TrainingMetricSnapshot[] }> {
    return this.api.get(`/governance/training-runs/${runId}/metrics`);
  }

  getRunGateChecks(runId: string): Observable<{ gate_checks: TrainingGateCheck[] }> {
    return this.api.get(`/governance/training-runs/${runId}/gate-checks`);
  }

  listJobs(): Observable<TrainingJobResponse[]> {
    return this.api.get('/jobs');
  }

  getJob(jobId: string): Observable<TrainingJobResponse> {
    return this.api.get(`/jobs/${jobId}`);
  }

  deleteJob(jobId: string): Observable<{ status: string }> {
    return this.api.delete(`/jobs/${jobId}`);
  }

  createJob(config: Record<string, unknown>, governanceRunId?: string): Observable<TrainingJobResponse> {
    return this.api.post('/jobs', {
      config,
      governance_run_id: governanceRunId,
    });
  }

  deployJob(jobId: string, governanceRunId?: string): Observable<Record<string, unknown>> {
    const path = governanceRunId
      ? `/jobs/${jobId}/deploy?governance_run_id=${encodeURIComponent(governanceRunId)}`
      : `/jobs/${jobId}/deploy`;
    return this.api.post(path, {});
  }

  summarizeBlockingChecks(run: Pick<TrainingRun, 'blocking_checks'> | GovernanceSummary | null | undefined): string[] {
    return (run?.blocking_checks ?? []).map((check) => `${check.category}: ${check.detail}`);
  }
}

export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'degraded' | 'error';

export interface MoonshotApiConfig {
  baseUrl: string;
  useMockFallback: boolean;
  timeoutMs: number;
}

export interface MoonshotHealthResponse {
  status: string;
  service: string;
  moonshot_root: string;
  moonshot_binary: string;
  binary_exists: boolean;
  odata_base_url: string;
  odata_reachable: boolean;
}

export interface MoonshotConfigSummaryResponse {
  status: string;
  common: {
    max_concurrency: number;
    max_calls_per_minute: number;
    max_attempts: number;
  };
  connectors: string[];
  metrics: string[];
  attack_modules: string[];
  connector_count: number;
  metric_count: number;
  attack_module_count: number;
}

export interface MoonshotTestConfigsResponse {
  status: string;
  test_config_ids: string[];
  test_configs: Record<string, unknown>;
}

export interface MoonshotRunRequest {
  run_id: string;
  test_config_id: string;
  connector: string;
  dry_run?: boolean;
}

export interface MoonshotRunOutput {
  status: string;
  run_id: string;
  test_config_id: string;
  connector: string;
  result_path: string;
  tests_executed: number;
  dry_run_prompts: number;
  duration_seconds: number;
}

export interface MoonshotRunResponse {
  status: string;
  run?: MoonshotRunOutput;
  persisted_to_odata?: boolean;
  error?: string;
  stdout?: string;
  stderr?: string;
}

export interface MoonshotStoredRun {
  run_id: string;
  test_config_id: string;
  connector: string;
  status: string;
  result_path: string;
  start_time_unix: number;
  end_time_unix: number;
  duration_seconds: number;
  dry_run_prompts: number;
}

export interface MoonshotRunListResponse {
  runs: MoonshotStoredRun[];
}

export interface MoonshotRunDetailResponse {
  run: MoonshotStoredRun | null;
}

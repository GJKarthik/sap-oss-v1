export interface LiveDemoConfig {
  agUiEndpoint: string;
  openAiBaseUrl: string;
  mcpBaseUrl: string;
  requireRealBackends: true;
}

export function validateLiveDemoConfig(config: LiveDemoConfig): LiveDemoConfig {
  const requiredKeys: Array<keyof LiveDemoConfig> = [
    'agUiEndpoint',
    'openAiBaseUrl',
    'mcpBaseUrl',
  ];

  for (const key of requiredKeys) {
    const value = config[key];
    if (typeof value !== 'string' || value.trim().length === 0) {
      throw new Error(`Missing required live demo config: ${String(key)}`);
    }
  }

  if (!config.requireRealBackends) {
    throw new Error('Live demo must require real backends');
  }

  return config;
}

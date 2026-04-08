export interface ExperienceRuntimeConfig {
  agUiEndpoint: string;
  openAiBaseUrl: string;
  mcpBaseUrl: string;
  requireRealBackends: true;
}

export function validateExperienceRuntimeConfig(config: ExperienceRuntimeConfig): ExperienceRuntimeConfig {
  const requiredKeys: Array<keyof ExperienceRuntimeConfig> = [
    'agUiEndpoint',
    'openAiBaseUrl',
    'mcpBaseUrl',
  ];

  for (const key of requiredKeys) {
    const value = config[key];
    if (typeof value !== 'string' || value.trim().length === 0) {
      throw new Error(`Missing required runtime config: ${String(key)}`);
    }
  }

  if (!config.requireRealBackends) {
    throw new Error('Runtime config must require real backends');
  }

  return config;
}

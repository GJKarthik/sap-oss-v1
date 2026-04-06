type RuntimeConfig = {
  apiBaseUrl?: string;
  elasticsearchMcpUrl?: string;
  palMcpUrl?: string;
  langchainMcpUrl?: string;
  streamingMcpUrl?: string;
};

export function getRuntimeConfig(): RuntimeConfig {
  return (window as Window & { __SAP_CONFIG__?: RuntimeConfig }).__SAP_CONFIG__ || {};
}

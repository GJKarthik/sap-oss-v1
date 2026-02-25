/**
 * Elastic Cloud Configuration Module
 * 
 * Provides centralized configuration loading and validation
 * for connecting to Elastic Cloud deployments.
 */

import 'dotenv/config';

// ============================================================================
// Types
// ============================================================================

export interface CloudConfig {
  cloudId: string;
  auth: {
    apiKey?: string;
    username?: string;
    password?: string;
  };
  indexName: string;
  embeddingDimension: number;
  similarity: 'cosine' | 'dot_product' | 'l2_norm';
  requestTimeout: number;
  maxRetries: number;
  debug: boolean;
}

export interface ConfigValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
}

// ============================================================================
// Configuration Loading
// ============================================================================

/**
 * Load configuration from environment variables
 */
export function loadConfig(): CloudConfig {
  return {
    cloudId: process.env.ELASTIC_CLOUD_ID || '',
    auth: {
      apiKey: process.env.ELASTIC_API_KEY,
      username: process.env.ELASTIC_USERNAME,
      password: process.env.ELASTIC_PASSWORD,
    },
    indexName: process.env.INDEX_NAME || 'knowledge-base',
    embeddingDimension: parseInt(process.env.EMBEDDING_DIMENSION || '1536', 10),
    similarity: (process.env.SIMILARITY as CloudConfig['similarity']) || 'cosine',
    requestTimeout: parseInt(process.env.REQUEST_TIMEOUT || '30000', 10),
    maxRetries: parseInt(process.env.MAX_RETRIES || '3', 10),
    debug: process.env.DEBUG === 'true',
  };
}

/**
 * Validate configuration
 */
export function validateConfig(config: CloudConfig): ConfigValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];
  
  // Required: Cloud ID
  if (!config.cloudId) {
    errors.push('ELASTIC_CLOUD_ID is required. Get it from Elastic Cloud console.');
  } else if (!config.cloudId.includes(':')) {
    errors.push('ELASTIC_CLOUD_ID appears invalid. Format: deployment-name:base64-config');
  }
  
  // Required: Authentication
  if (!config.auth.apiKey && !(config.auth.username && config.auth.password)) {
    errors.push('Authentication required: Set ELASTIC_API_KEY or both ELASTIC_USERNAME and ELASTIC_PASSWORD');
  }
  
  // Warnings
  if (config.auth.username && config.auth.password && !config.auth.apiKey) {
    warnings.push('Consider using API key authentication instead of username/password for better security');
  }
  
  if (config.embeddingDimension < 1 || config.embeddingDimension > 4096) {
    warnings.push(`Unusual embedding dimension: ${config.embeddingDimension}. Common values: 384, 768, 1536`);
  }
  
  if (!['cosine', 'dot_product', 'l2_norm'].includes(config.similarity)) {
    errors.push(`Invalid similarity: ${config.similarity}. Must be cosine, dot_product, or l2_norm`);
  }
  
  return {
    valid: errors.length === 0,
    errors,
    warnings,
  };
}

/**
 * Print configuration status
 */
export function printConfigStatus(config: CloudConfig): void {
  const validation = validateConfig(config);
  
  console.log('='.repeat(60));
  console.log('Elastic Cloud Configuration');
  console.log('='.repeat(60));
  console.log();
  
  // Connection info (masked)
  console.log('Connection:');
  const cloudIdParts = config.cloudId.split(':');
  console.log(`  Deployment: ${cloudIdParts[0] || '(not set)'}`);
  console.log(`  Cloud ID: ${config.cloudId ? config.cloudId.slice(0, 20) + '...' : '(not set)'}`);
  console.log();
  
  // Authentication
  console.log('Authentication:');
  if (config.auth.apiKey) {
    console.log(`  Method: API Key`);
    console.log(`  API Key: ${config.auth.apiKey.slice(0, 8)}...`);
  } else if (config.auth.username) {
    console.log(`  Method: Username/Password`);
    console.log(`  Username: ${config.auth.username}`);
  } else {
    console.log('  Method: (not configured)');
  }
  console.log();
  
  // Index settings
  console.log('Index Settings:');
  console.log(`  Index Name: ${config.indexName}`);
  console.log(`  Embedding Dimension: ${config.embeddingDimension}`);
  console.log(`  Similarity: ${config.similarity}`);
  console.log();
  
  // Options
  console.log('Options:');
  console.log(`  Request Timeout: ${config.requestTimeout}ms`);
  console.log(`  Max Retries: ${config.maxRetries}`);
  console.log(`  Debug: ${config.debug}`);
  console.log();
  
  // Validation result
  if (validation.valid) {
    console.log('✅ Configuration is valid');
  } else {
    console.log('❌ Configuration has errors:');
    validation.errors.forEach(err => console.log(`   - ${err}`));
  }
  
  if (validation.warnings.length > 0) {
    console.log();
    console.log('⚠️  Warnings:');
    validation.warnings.forEach(warn => console.log(`   - ${warn}`));
  }
  
  console.log();
}

/**
 * Get configuration or exit if invalid
 */
export function requireValidConfig(): CloudConfig {
  const config = loadConfig();
  const validation = validateConfig(config);
  
  if (!validation.valid) {
    console.error('Configuration errors:');
    validation.errors.forEach(err => console.error(`  ❌ ${err}`));
    console.error();
    console.error('Please check your .env file. See .env.example for reference.');
    process.exit(1);
  }
  
  return config;
}

export { loadConfig as default };
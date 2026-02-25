/**
 * SAP BTP Object Store
 * 
 * S3-compatible object storage client for SAP Business Technology Platform
 * 
 * @packageDocumentation
 */

// Main client
export {
  BTPObjectStore,
  createBTPObjectStore,
  createBTPObjectStoreFromEnv,
} from './s3-client.js';

// Types
export type {
  BTPObjectStoreConfig,
  BTPObjectStoreBinding,
  ObjectMetadata,
  ObjectInfo,
  UploadOptions,
  DownloadOptions,
  ListOptions,
  ListResult,
  MultipartUploadOptions,
  UploadProgress,
  PresignedUrlOptions,
  PresignedUploadOptions,
  CopyOptions,
} from './types.js';

// Error handling
export {
  ObjectStoreError,
  ObjectStoreErrorCode,
} from './types.js';

// Utility functions
export {
  parseBinding,
  getConfigFromVcap,
  detectContentType,
  formatBytes,
  validateKey,
} from './types.js';
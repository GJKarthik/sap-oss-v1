// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAP BTP Object Store Types
 * 
 * Configuration and data types for S3-compatible Object Store operations
 */

// ============================================================================
// Configuration Types
// ============================================================================

/**
 * BTP Object Store configuration from service binding
 */
export interface BTPObjectStoreConfig {
  /** S3 bucket name (from BTP service binding) */
  bucket: string;
  
  /** AWS region (e.g., 'us-east-1') */
  region: string;
  
  /** S3 host (usually 's3.amazonaws.com') */
  host?: string;
  
  /** AWS Access Key ID */
  accessKeyId: string;
  
  /** AWS Secret Access Key */
  secretAccessKey: string;
  
  /** Optional endpoint override (for S3-compatible services) */
  endpoint?: string;
  
  /** Force path-style URLs (required for some S3-compatible services) */
  forcePathStyle?: boolean;
  
  /** Request timeout in milliseconds */
  requestTimeout?: number;
  
  /** Maximum retry attempts */
  maxRetries?: number;
}

/**
 * BTP Object Store service binding format (from VCAP_SERVICES)
 */
export interface BTPObjectStoreBinding {
  access_key_id: string;
  bucket: string;
  host: string;
  region: string;
  secret_access_key: string;
  uri: string;
  username: string;
}

// ============================================================================
// Object Types
// ============================================================================

/**
 * Object metadata
 */
export interface ObjectMetadata {
  /** Content type (MIME type) */
  contentType?: string;
  
  /** Content length in bytes */
  contentLength?: number;
  
  /** Content encoding (e.g., 'gzip') */
  contentEncoding?: string;
  
  /** Content language */
  contentLanguage?: string;
  
  /** Cache control header */
  cacheControl?: string;
  
  /** Content disposition header */
  contentDisposition?: string;
  
  /** ETag (entity tag) for versioning */
  etag?: string;
  
  /** Last modified timestamp */
  lastModified?: Date;
  
  /** Custom metadata (key-value pairs) */
  customMetadata?: Record<string, string>;
}

/**
 * Object information returned from list/head operations
 */
export interface ObjectInfo {
  /** Object key (path) */
  key: string;
  
  /** Size in bytes */
  size: number;
  
  /** Last modified date */
  lastModified: Date;
  
  /** ETag (entity tag) */
  etag: string;
  
  /** Storage class */
  storageClass?: string;
  
  /** Owner information */
  owner?: {
    id?: string;
    displayName?: string;
  };
}

/**
 * Upload options
 */
export interface UploadOptions {
  /** Content type override */
  contentType?: string;
  
  /** Content encoding */
  contentEncoding?: string;
  
  /** Cache control header */
  cacheControl?: string;
  
  /** Content disposition */
  contentDisposition?: string;
  
  /** Custom metadata */
  metadata?: Record<string, string>;
  
  /** Storage class (STANDARD, REDUCED_REDUNDANCY, etc.) */
  storageClass?: 'STANDARD' | 'REDUCED_REDUNDANCY' | 'STANDARD_IA' | 'ONEZONE_IA' | 'INTELLIGENT_TIERING' | 'GLACIER' | 'DEEP_ARCHIVE';
  
  /** Server-side encryption */
  serverSideEncryption?: 'AES256' | 'aws:kms';
  
  /** Tags as key-value pairs */
  tags?: Record<string, string>;
  
  /** ACL (access control list) */
  acl?: 'private' | 'public-read' | 'public-read-write' | 'authenticated-read';
}

/**
 * Download options
 */
export interface DownloadOptions {
  /** Range request (e.g., 'bytes=0-999') */
  range?: string;
  
  /** Only return if modified since this date */
  ifModifiedSince?: Date;
  
  /** Only return if ETag matches */
  ifMatch?: string;
  
  /** Only return if ETag does not match */
  ifNoneMatch?: string;
  
  /** Response content type override */
  responseContentType?: string;
  
  /** Response content disposition override */
  responseContentDisposition?: string;
}

/**
 * List objects options
 */
export interface ListOptions {
  /** Prefix filter */
  prefix?: string;
  
  /** Delimiter for hierarchy (usually '/') */
  delimiter?: string;
  
  /** Maximum keys to return */
  maxKeys?: number;
  
  /** Continuation token for pagination */
  continuationToken?: string;
  
  /** Start after this key */
  startAfter?: string;
}

/**
 * List objects result
 */
export interface ListResult {
  /** Object information */
  objects: ObjectInfo[];
  
  /** Common prefixes (folders) when using delimiter */
  commonPrefixes: string[];
  
  /** Whether there are more results */
  isTruncated: boolean;
  
  /** Continuation token for next page */
  nextContinuationToken?: string;
  
  /** Key count in this response */
  keyCount: number;
}

// ============================================================================
// Multipart Upload Types
// ============================================================================

/**
 * Multipart upload options
 */
export interface MultipartUploadOptions extends UploadOptions {
  /** Part size in bytes (minimum 5MB, default 5MB) */
  partSize?: number;
  
  /** Concurrent upload limit */
  concurrency?: number;
  
  /** Progress callback */
  onProgress?: (progress: UploadProgress) => void;
  
  /** Abort signal for cancellation */
  abortSignal?: AbortSignal;
}

/**
 * Upload progress information
 */
export interface UploadProgress {
  /** Loaded bytes */
  loaded: number;
  
  /** Total bytes */
  total: number;
  
  /** Progress percentage (0-100) */
  percentage: number;
  
  /** Current part number */
  part?: number;
  
  /** Total parts */
  totalParts?: number;
}

// ============================================================================
// Presigned URL Types
// ============================================================================

/**
 * Presigned URL options
 */
export interface PresignedUrlOptions {
  /** URL expiration in seconds (default 3600) */
  expiresIn?: number;
  
  /** Response content type */
  responseContentType?: string;
  
  /** Response content disposition */
  responseContentDisposition?: string;
  
  /** Version ID for versioned buckets */
  versionId?: string;
}

/**
 * Presigned upload URL options
 */
export interface PresignedUploadOptions extends PresignedUrlOptions {
  /** Content type requirement */
  contentType?: string;
  
  /** Content length range (min, max) */
  contentLengthRange?: [number, number];
  
  /** Required metadata */
  metadata?: Record<string, string>;
}

// ============================================================================
// Copy/Move Types
// ============================================================================

/**
 * Copy object options
 */
export interface CopyOptions {
  /** Source bucket (default: same bucket) */
  sourceBucket?: string;
  
  /** Metadata directive */
  metadataDirective?: 'COPY' | 'REPLACE';
  
  /** New metadata (when metadataDirective is REPLACE) */
  metadata?: Record<string, string>;
  
  /** New content type (when metadataDirective is REPLACE) */
  contentType?: string;
  
  /** Storage class */
  storageClass?: string;
  
  /** ACL */
  acl?: string;
}

// ============================================================================
// Error Types
// ============================================================================

/**
 * Object Store error codes
 */
export enum ObjectStoreErrorCode {
  /** Invalid configuration */
  INVALID_CONFIG = 'INVALID_CONFIG',
  
  /** Connection failed */
  CONNECTION_FAILED = 'CONNECTION_FAILED',
  
  /** Object not found */
  NOT_FOUND = 'NOT_FOUND',
  
  /** Access denied */
  ACCESS_DENIED = 'ACCESS_DENIED',
  
  /** Bucket not found */
  BUCKET_NOT_FOUND = 'BUCKET_NOT_FOUND',
  
  /** Object already exists */
  ALREADY_EXISTS = 'ALREADY_EXISTS',
  
  /** Upload failed */
  UPLOAD_FAILED = 'UPLOAD_FAILED',
  
  /** Download failed */
  DOWNLOAD_FAILED = 'DOWNLOAD_FAILED',
  
  /** Operation timeout */
  TIMEOUT = 'TIMEOUT',
  
  /** Rate limit exceeded */
  RATE_LIMITED = 'RATE_LIMITED',
  
  /** Invalid input */
  INVALID_INPUT = 'INVALID_INPUT',
  
  /** Unknown error */
  UNKNOWN = 'UNKNOWN',
}

/**
 * Object Store error
 */
export class ObjectStoreError extends Error {
  constructor(
    message: string,
    public readonly code: ObjectStoreErrorCode,
    public readonly statusCode?: number,
    public readonly requestId?: string,
    public readonly cause?: Error
  ) {
    super(message);
    this.name = 'ObjectStoreError';
    
    // Maintain proper stack trace
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, ObjectStoreError);
    }
  }

  toJSON() {
    return {
      name: this.name,
      message: this.message,
      code: this.code,
      statusCode: this.statusCode,
      requestId: this.requestId,
    };
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Parse BTP Object Store binding from environment
 */
export function parseBinding(binding: BTPObjectStoreBinding): BTPObjectStoreConfig {
  return {
    bucket: binding.bucket,
    region: binding.region,
    host: binding.host,
    accessKeyId: binding.access_key_id,
    secretAccessKey: binding.secret_access_key,
  };
}

/**
 * Get Object Store config from VCAP_SERVICES
 */
export function getConfigFromVcap(): BTPObjectStoreConfig | undefined {
  const vcapServices = process.env.VCAP_SERVICES;
  if (!vcapServices) {
    return undefined;
  }
  
  try {
    const services = JSON.parse(vcapServices);
    const objectStore = services.objectstore?.[0]?.credentials;
    
    if (!objectStore) {
      return undefined;
    }
    
    return parseBinding(objectStore);
  } catch {
    return undefined;
  }
}

/**
 * Detect content type from file extension
 */
export function detectContentType(key: string): string {
  const ext = key.split('.').pop()?.toLowerCase();
  
  const mimeTypes: Record<string, string> = {
    // Documents
    txt: 'text/plain',
    html: 'text/html',
    htm: 'text/html',
    css: 'text/css',
    js: 'application/javascript',
    json: 'application/json',
    xml: 'application/xml',
    pdf: 'application/pdf',
    doc: 'application/msword',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xls: 'application/vnd.ms-excel',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ppt: 'application/vnd.ms-powerpoint',
    pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    
    // Images
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    png: 'image/png',
    gif: 'image/gif',
    webp: 'image/webp',
    svg: 'image/svg+xml',
    ico: 'image/x-icon',
    
    // Audio/Video
    mp3: 'audio/mpeg',
    mp4: 'video/mp4',
    webm: 'video/webm',
    ogg: 'audio/ogg',
    wav: 'audio/wav',
    
    // Archives
    zip: 'application/zip',
    tar: 'application/x-tar',
    gz: 'application/gzip',
    '7z': 'application/x-7z-compressed',
    rar: 'application/vnd.rar',
    
    // Data
    csv: 'text/csv',
    parquet: 'application/vnd.apache.parquet',
    
    // ML/AI
    onnx: 'application/octet-stream',
    pb: 'application/octet-stream',
    h5: 'application/x-hdf5',
    pkl: 'application/octet-stream',
    safetensors: 'application/octet-stream',
  };
  
  return mimeTypes[ext || ''] || 'application/octet-stream';
}

/**
 * Format bytes to human-readable string
 */
export function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(2))} ${sizes[i]}`;
}

/**
 * Validate object key
 */
export function validateKey(key: string): void {
  if (!key || typeof key !== 'string') {
    throw new ObjectStoreError(
      'Object key is required',
      ObjectStoreErrorCode.INVALID_INPUT
    );
  }
  
  if (key.length > 1024) {
    throw new ObjectStoreError(
      'Object key exceeds maximum length of 1024 characters',
      ObjectStoreErrorCode.INVALID_INPUT
    );
  }
  
  // Check for invalid characters
  const invalidChars = /[\x00-\x1f\x7f]/;
  if (invalidChars.test(key)) {
    throw new ObjectStoreError(
      'Object key contains invalid characters',
      ObjectStoreErrorCode.INVALID_INPUT
    );
  }
}
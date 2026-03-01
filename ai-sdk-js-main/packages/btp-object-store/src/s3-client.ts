// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAP BTP Object Store S3 Client
 * 
 * S3-compatible client for SAP BTP Object Store service
 */

import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  CopyObjectCommand,
  DeleteObjectsCommand,
  type PutObjectCommandInput,
  type GetObjectCommandInput,
  type HeadObjectCommandOutput,
  type ListObjectsV2CommandInput,
  type CopyObjectCommandInput,
} from '@aws-sdk/client-s3';
import { Upload } from '@aws-sdk/lib-storage';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { Readable } from 'stream';

import {
  type BTPObjectStoreConfig,
  type ObjectInfo,
  type ObjectMetadata,
  type UploadOptions,
  type DownloadOptions,
  type ListOptions,
  type ListResult,
  type MultipartUploadOptions,
  type PresignedUrlOptions,
  type PresignedUploadOptions,
  type CopyOptions,
  ObjectStoreError,
  ObjectStoreErrorCode,
  detectContentType,
  validateKey,
} from './types.js';

// ============================================================================
// BTP Object Store Client
// ============================================================================

/**
 * BTP Object Store S3 Client
 * 
 * Provides S3-compatible object storage operations for SAP BTP
 */
export class BTPObjectStore {
  private client: S3Client;
  private bucket: string;
  private config: BTPObjectStoreConfig;

  /**
   * Create a new BTP Object Store client
   */
  constructor(config: BTPObjectStoreConfig) {
    this.validateConfig(config);
    this.config = config;
    this.bucket = config.bucket;
    
    this.client = new S3Client({
      region: config.region,
      credentials: {
        accessKeyId: config.accessKeyId,
        secretAccessKey: config.secretAccessKey,
      },
      endpoint: config.endpoint,
      forcePathStyle: config.forcePathStyle ?? false,
      maxAttempts: config.maxRetries ?? 3,
      requestHandler: config.requestTimeout ? {
        requestTimeout: config.requestTimeout,
      } as any : undefined,
    });
  }

  /**
   * Validate configuration
   */
  private validateConfig(config: BTPObjectStoreConfig): void {
    if (!config.bucket) {
      throw new ObjectStoreError(
        'Bucket name is required',
        ObjectStoreErrorCode.INVALID_CONFIG
      );
    }
    
    if (!config.region) {
      throw new ObjectStoreError(
        'Region is required',
        ObjectStoreErrorCode.INVALID_CONFIG
      );
    }
    
    if (!config.accessKeyId || !config.secretAccessKey) {
      throw new ObjectStoreError(
        'Access credentials are required',
        ObjectStoreErrorCode.INVALID_CONFIG
      );
    }
  }

  /**
   * Map S3 errors to ObjectStoreError
   */
  private mapError(error: any, operation: string): ObjectStoreError {
    const statusCode = error.$metadata?.httpStatusCode;
    const requestId = error.$metadata?.requestId;
    
    // Map specific error codes
    if (error.name === 'NoSuchKey' || statusCode === 404) {
      return new ObjectStoreError(
        `Object not found`,
        ObjectStoreErrorCode.NOT_FOUND,
        statusCode,
        requestId,
        error
      );
    }
    
    if (error.name === 'NoSuchBucket') {
      return new ObjectStoreError(
        `Bucket not found: ${this.bucket}`,
        ObjectStoreErrorCode.BUCKET_NOT_FOUND,
        statusCode,
        requestId,
        error
      );
    }
    
    if (error.name === 'AccessDenied' || statusCode === 403) {
      return new ObjectStoreError(
        `Access denied for ${operation}`,
        ObjectStoreErrorCode.ACCESS_DENIED,
        statusCode,
        requestId,
        error
      );
    }
    
    if (error.name === 'SlowDown' || statusCode === 503) {
      return new ObjectStoreError(
        `Rate limited during ${operation}`,
        ObjectStoreErrorCode.RATE_LIMITED,
        statusCode,
        requestId,
        error
      );
    }
    
    if (error.name === 'TimeoutError' || error.code === 'ETIMEDOUT') {
      return new ObjectStoreError(
        `Operation timed out during ${operation}`,
        ObjectStoreErrorCode.TIMEOUT,
        statusCode,
        requestId,
        error
      );
    }
    
    return new ObjectStoreError(
      error.message || `Failed to ${operation}`,
      ObjectStoreErrorCode.UNKNOWN,
      statusCode,
      requestId,
      error
    );
  }

  // ==========================================================================
  // Basic Operations
  // ==========================================================================

  /**
   * Upload an object to the bucket
   */
  async upload(
    key: string,
    body: Buffer | string | Readable,
    options: UploadOptions = {}
  ): Promise<void> {
    validateKey(key);
    
    const contentType = options.contentType || detectContentType(key);
    
    const input: PutObjectCommandInput = {
      Bucket: this.bucket,
      Key: key,
      Body: body,
      ContentType: contentType,
      ContentEncoding: options.contentEncoding,
      CacheControl: options.cacheControl,
      ContentDisposition: options.contentDisposition,
      Metadata: options.metadata,
      StorageClass: options.storageClass,
      ServerSideEncryption: options.serverSideEncryption,
      ACL: options.acl,
    };
    
    // Add tags if provided
    if (options.tags) {
      input.Tagging = Object.entries(options.tags)
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
        .join('&');
    }
    
    try {
      await this.client.send(new PutObjectCommand(input));
    } catch (error) {
      throw this.mapError(error, 'upload');
    }
  }

  /**
   * Download an object from the bucket
   */
  async download(key: string, options: DownloadOptions = {}): Promise<Buffer> {
    validateKey(key);
    
    const input: GetObjectCommandInput = {
      Bucket: this.bucket,
      Key: key,
      Range: options.range,
      IfModifiedSince: options.ifModifiedSince,
      IfMatch: options.ifMatch,
      IfNoneMatch: options.ifNoneMatch,
      ResponseContentType: options.responseContentType,
      ResponseContentDisposition: options.responseContentDisposition,
    };
    
    try {
      const response = await this.client.send(new GetObjectCommand(input));
      
      if (!response.Body) {
        throw new ObjectStoreError(
          'Empty response body',
          ObjectStoreErrorCode.DOWNLOAD_FAILED
        );
      }
      
      // Convert stream to buffer
      const chunks: Buffer[] = [];
      const body = response.Body as Readable;
      
      for await (const chunk of body) {
        chunks.push(Buffer.from(chunk));
      }
      
      return Buffer.concat(chunks);
    } catch (error) {
      if (error instanceof ObjectStoreError) {
        throw error;
      }
      throw this.mapError(error, 'download');
    }
  }

  /**
   * Download an object as a readable stream
   */
  async downloadStream(key: string, options: DownloadOptions = {}): Promise<Readable> {
    validateKey(key);
    
    const input: GetObjectCommandInput = {
      Bucket: this.bucket,
      Key: key,
      Range: options.range,
      IfModifiedSince: options.ifModifiedSince,
      IfMatch: options.ifMatch,
      IfNoneMatch: options.ifNoneMatch,
      ResponseContentType: options.responseContentType,
      ResponseContentDisposition: options.responseContentDisposition,
    };
    
    try {
      const response = await this.client.send(new GetObjectCommand(input));
      
      if (!response.Body) {
        throw new ObjectStoreError(
          'Empty response body',
          ObjectStoreErrorCode.DOWNLOAD_FAILED
        );
      }
      
      return response.Body as Readable;
    } catch (error) {
      if (error instanceof ObjectStoreError) {
        throw error;
      }
      throw this.mapError(error, 'download stream');
    }
  }

  /**
   * Delete an object from the bucket
   */
  async delete(key: string): Promise<void> {
    validateKey(key);
    
    try {
      await this.client.send(new DeleteObjectCommand({
        Bucket: this.bucket,
        Key: key,
      }));
    } catch (error) {
      throw this.mapError(error, 'delete');
    }
  }

  /**
   * Delete multiple objects from the bucket
   */
  async deleteMany(keys: string[]): Promise<{ deleted: string[]; errors: Array<{ key: string; error: string }> }> {
    if (keys.length === 0) {
      return { deleted: [], errors: [] };
    }
    
    // S3 limits batch delete to 1000 objects
    const batches: string[][] = [];
    for (let i = 0; i < keys.length; i += 1000) {
      batches.push(keys.slice(i, i + 1000));
    }
    
    const deleted: string[] = [];
    const errors: Array<{ key: string; error: string }> = [];
    
    for (const batch of batches) {
      try {
        const response = await this.client.send(new DeleteObjectsCommand({
          Bucket: this.bucket,
          Delete: {
            Objects: batch.map(key => ({ Key: key })),
            Quiet: false,
          },
        }));
        
        // Track deleted objects
        if (response.Deleted) {
          for (const obj of response.Deleted) {
            if (obj.Key) {
              deleted.push(obj.Key);
            }
          }
        }
        
        // Track errors
        if (response.Errors) {
          for (const err of response.Errors) {
            errors.push({
              key: err.Key || 'unknown',
              error: err.Message || 'Unknown error',
            });
          }
        }
      } catch (error: any) {
        // Add all keys in batch to errors
        for (const key of batch) {
          errors.push({
            key,
            error: error.message || 'Batch delete failed',
          });
        }
      }
    }
    
    return { deleted, errors };
  }

  /**
   * Check if an object exists
   */
  async exists(key: string): Promise<boolean> {
    validateKey(key);
    
    try {
      await this.client.send(new HeadObjectCommand({
        Bucket: this.bucket,
        Key: key,
      }));
      return true;
    } catch (error: any) {
      if (error.name === 'NotFound' || error.$metadata?.httpStatusCode === 404) {
        return false;
      }
      throw this.mapError(error, 'check exists');
    }
  }

  /**
   * Get object metadata
   */
  async getMetadata(key: string): Promise<ObjectMetadata> {
    validateKey(key);
    
    try {
      const response: HeadObjectCommandOutput = await this.client.send(
        new HeadObjectCommand({
          Bucket: this.bucket,
          Key: key,
        })
      );
      
      return {
        contentType: response.ContentType,
        contentLength: response.ContentLength,
        contentEncoding: response.ContentEncoding,
        contentLanguage: response.ContentLanguage,
        cacheControl: response.CacheControl,
        contentDisposition: response.ContentDisposition,
        etag: response.ETag?.replace(/"/g, ''),
        lastModified: response.LastModified,
        customMetadata: response.Metadata,
      };
    } catch (error) {
      throw this.mapError(error, 'get metadata');
    }
  }

  // ==========================================================================
  // List Operations
  // ==========================================================================

  /**
   * List objects in the bucket
   */
  async list(options: ListOptions = {}): Promise<ListResult> {
    const input: ListObjectsV2CommandInput = {
      Bucket: this.bucket,
      Prefix: options.prefix,
      Delimiter: options.delimiter,
      MaxKeys: options.maxKeys || 1000,
      ContinuationToken: options.continuationToken,
      StartAfter: options.startAfter,
    };
    
    try {
      const response = await this.client.send(new ListObjectsV2Command(input));
      
      const objects: ObjectInfo[] = (response.Contents || []).map(obj => ({
        key: obj.Key || '',
        size: obj.Size || 0,
        lastModified: obj.LastModified || new Date(),
        etag: obj.ETag?.replace(/"/g, '') || '',
        storageClass: obj.StorageClass,
        owner: obj.Owner ? {
          id: obj.Owner.ID,
          displayName: obj.Owner.DisplayName,
        } : undefined,
      }));
      
      const commonPrefixes = (response.CommonPrefixes || [])
        .map(p => p.Prefix || '')
        .filter(p => p);
      
      return {
        objects,
        commonPrefixes,
        isTruncated: response.IsTruncated || false,
        nextContinuationToken: response.NextContinuationToken,
        keyCount: response.KeyCount || 0,
      };
    } catch (error) {
      throw this.mapError(error, 'list');
    }
  }

  /**
   * List all objects with prefix (handles pagination)
   */
  async listAll(prefix?: string): Promise<ObjectInfo[]> {
    const allObjects: ObjectInfo[] = [];
    let continuationToken: string | undefined;
    
    do {
      const result = await this.list({
        prefix,
        continuationToken,
      });
      
      allObjects.push(...result.objects);
      continuationToken = result.nextContinuationToken;
    } while (continuationToken);
    
    return allObjects;
  }

  /**
   * List folders (common prefixes) at a path
   */
  async listFolders(prefix?: string): Promise<string[]> {
    const result = await this.list({
      prefix: prefix?.endsWith('/') ? prefix : (prefix ? `${prefix}/` : ''),
      delimiter: '/',
    });
    
    return result.commonPrefixes;
  }

  // ==========================================================================
  // Multipart Upload
  // ==========================================================================

  /**
   * Upload a large file using multipart upload
   */
  async uploadMultipart(
    key: string,
    body: Buffer | Readable,
    options: MultipartUploadOptions = {}
  ): Promise<void> {
    validateKey(key);
    
    const contentType = options.contentType || detectContentType(key);
    const partSize = options.partSize || 5 * 1024 * 1024; // 5MB default
    const queueSize = options.concurrency || 4;
    
    const upload = new Upload({
      client: this.client,
      params: {
        Bucket: this.bucket,
        Key: key,
        Body: body,
        ContentType: contentType,
        ContentEncoding: options.contentEncoding,
        CacheControl: options.cacheControl,
        ContentDisposition: options.contentDisposition,
        Metadata: options.metadata,
        StorageClass: options.storageClass,
        ServerSideEncryption: options.serverSideEncryption,
        ACL: options.acl,
      },
      partSize,
      queueSize,
      leavePartsOnError: false,
    });
    
    // Handle progress callback
    if (options.onProgress) {
      upload.on('httpUploadProgress', (progress) => {
        options.onProgress?.({
          loaded: progress.loaded || 0,
          total: progress.total || 0,
          percentage: progress.total 
            ? Math.round((progress.loaded || 0) / progress.total * 100) 
            : 0,
          part: progress.part,
        });
      });
    }
    
    // Handle abort signal
    if (options.abortSignal) {
      options.abortSignal.addEventListener('abort', () => {
        upload.abort();
      });
    }
    
    try {
      await upload.done();
    } catch (error) {
      throw this.mapError(error, 'multipart upload');
    }
  }

  // ==========================================================================
  // Presigned URLs
  // ==========================================================================

  /**
   * Generate a presigned URL for downloading an object
   */
  async getPresignedDownloadUrl(
    key: string,
    options: PresignedUrlOptions = {}
  ): Promise<string> {
    validateKey(key);
    
    const command = new GetObjectCommand({
      Bucket: this.bucket,
      Key: key,
      ResponseContentType: options.responseContentType,
      ResponseContentDisposition: options.responseContentDisposition,
      VersionId: options.versionId,
    });
    
    try {
      return await getSignedUrl(this.client, command, {
        expiresIn: options.expiresIn || 3600,
      });
    } catch (error) {
      throw this.mapError(error, 'generate presigned download URL');
    }
  }

  /**
   * Generate a presigned URL for uploading an object
   */
  async getPresignedUploadUrl(
    key: string,
    options: PresignedUploadOptions = {}
  ): Promise<string> {
    validateKey(key);
    
    const command = new PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      ContentType: options.contentType,
      Metadata: options.metadata,
    });
    
    try {
      return await getSignedUrl(this.client, command, {
        expiresIn: options.expiresIn || 3600,
      });
    } catch (error) {
      throw this.mapError(error, 'generate presigned upload URL');
    }
  }

  // ==========================================================================
  // Copy Operations
  // ==========================================================================

  /**
   * Copy an object within or between buckets
   */
  async copy(
    sourceKey: string,
    destinationKey: string,
    options: CopyOptions = {}
  ): Promise<void> {
    validateKey(sourceKey);
    validateKey(destinationKey);
    
    const sourceBucket = options.sourceBucket || this.bucket;
    
    const input: CopyObjectCommandInput = {
      Bucket: this.bucket,
      Key: destinationKey,
      CopySource: `${sourceBucket}/${sourceKey}`,
      MetadataDirective: options.metadataDirective || 'COPY',
      ContentType: options.contentType,
      Metadata: options.metadata,
      StorageClass: options.storageClass as any,
      ACL: options.acl as any,
    };
    
    try {
      await this.client.send(new CopyObjectCommand(input));
    } catch (error) {
      throw this.mapError(error, 'copy');
    }
  }

  /**
   * Move an object (copy + delete source)
   */
  async move(
    sourceKey: string,
    destinationKey: string,
    options: CopyOptions = {}
  ): Promise<void> {
    // Copy first
    await this.copy(sourceKey, destinationKey, options);
    
    // Delete source
    const sourceBucket = options.sourceBucket || this.bucket;
    if (sourceBucket === this.bucket) {
      await this.delete(sourceKey);
    }
  }

  // ==========================================================================
  // Utility Methods
  // ==========================================================================

  /**
   * Get the bucket name
   */
  getBucket(): string {
    return this.bucket;
  }

  /**
   * Get the S3 client
   */
  getClient(): S3Client {
    return this.client;
  }

  /**
   * Close the client
   */
  destroy(): void {
    this.client.destroy();
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a BTP Object Store client
 */
export function createBTPObjectStore(config: BTPObjectStoreConfig): BTPObjectStore {
  return new BTPObjectStore(config);
}

/**
 * Create a BTP Object Store client from environment variables
 */
export function createBTPObjectStoreFromEnv(): BTPObjectStore {
  const config: BTPObjectStoreConfig = {
    bucket: process.env.BTP_OBJECT_STORE_BUCKET || process.env.S3_BUCKET || '',
    region: process.env.BTP_OBJECT_STORE_REGION || process.env.AWS_REGION || 'us-east-1',
    accessKeyId: process.env.BTP_OBJECT_STORE_ACCESS_KEY || process.env.AWS_ACCESS_KEY_ID || '',
    secretAccessKey: process.env.BTP_OBJECT_STORE_SECRET_KEY || process.env.AWS_SECRET_ACCESS_KEY || '',
    endpoint: process.env.BTP_OBJECT_STORE_ENDPOINT || process.env.S3_ENDPOINT,
    forcePathStyle: process.env.BTP_OBJECT_STORE_FORCE_PATH_STYLE === 'true',
  };
  
  return new BTPObjectStore(config);
}
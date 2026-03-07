# @sap-ai-sdk/btp-object-store

S3-compatible object storage client for SAP Business Technology Platform.

## Features

- 🪣 **S3-Compatible** - Works with BTP Object Store and any S3-compatible service
- 📤 **Upload/Download** - Simple and streaming operations
- 📦 **Multipart Upload** - Large file support with progress tracking
- 🔗 **Presigned URLs** - Generate temporary access URLs
- 📋 **List & Search** - Paginated listing with prefix filtering
- 🔄 **Copy/Move** - Within or between buckets
- ⚡ **TypeScript** - Full type safety and IntelliSense

## Installation

```bash
npm install @sap-ai-sdk/btp-object-store
```

## Quick Start

```typescript
import { createBTPObjectStore } from '@sap-ai-sdk/btp-object-store';

// Create client with config
const store = createBTPObjectStore({
  bucket: 'my-bucket',
  region: 'us-east-1',
  accessKeyId: 'your-access-key',
  secretAccessKey: 'your-secret-key',
});

// Upload a file
await store.upload('documents/report.pdf', fileBuffer);

// Download a file
const data = await store.download('documents/report.pdf');

// List files
const result = await store.list({ prefix: 'documents/' });
console.log(result.objects);
```

## Configuration

### From Service Binding (BTP)

When deployed to BTP Cloud Foundry, configuration comes from VCAP_SERVICES:

```typescript
import { getConfigFromVcap, createBTPObjectStore } from '@sap-ai-sdk/btp-object-store';

const config = getConfigFromVcap();
if (config) {
  const store = createBTPObjectStore(config);
}
```

### From Environment Variables

```typescript
import { createBTPObjectStoreFromEnv } from '@sap-ai-sdk/btp-object-store';

// Uses BTP_OBJECT_STORE_* or AWS_* env vars
const store = createBTPObjectStoreFromEnv();
```

Environment variables:
- `BTP_OBJECT_STORE_BUCKET` / `S3_BUCKET`
- `BTP_OBJECT_STORE_REGION` / `AWS_REGION`
- `BTP_OBJECT_STORE_ACCESS_KEY` / `AWS_ACCESS_KEY_ID`
- `BTP_OBJECT_STORE_SECRET_KEY` / `AWS_SECRET_ACCESS_KEY`
- `BTP_OBJECT_STORE_ENDPOINT` / `S3_ENDPOINT`

### Manual Configuration

```typescript
const store = createBTPObjectStore({
  bucket: 'hcp-055af4b0-2344-40d2-88fe-ddc1c4aad6c5',
  region: 'us-east-1',
  accessKeyId: process.env.ACCESS_KEY_ID!,
  secretAccessKey: process.env.SECRET_ACCESS_KEY!,
  
  // Optional
  endpoint: 'https://s3.custom-endpoint.com', // For S3-compatible services
  forcePathStyle: true, // Required for some S3-compatible services
  requestTimeout: 30000, // Request timeout in ms
  maxRetries: 3, // Max retry attempts
});
```

## API Reference

### Upload Operations

```typescript
// Simple upload
await store.upload('path/file.txt', 'Hello World');
await store.upload('path/file.txt', Buffer.from('Hello World'));

// Upload with options
await store.upload('path/file.txt', data, {
  contentType: 'text/plain',
  metadata: { author: 'John' },
  storageClass: 'STANDARD',
  cacheControl: 'max-age=3600',
});

// Multipart upload for large files
await store.uploadMultipart('large-file.zip', fileBuffer, {
  partSize: 10 * 1024 * 1024, // 10MB parts
  concurrency: 4,
  onProgress: (progress) => {
    console.log(`${progress.percentage}% uploaded`);
  },
});
```

### Download Operations

```typescript
// Download to buffer
const data = await store.download('path/file.txt');

// Download as stream
const stream = await store.downloadStream('path/file.txt');
stream.pipe(fs.createWriteStream('local-file.txt'));

// Download with options
const data = await store.download('path/file.txt', {
  range: 'bytes=0-999', // Partial download
  ifModifiedSince: lastModifiedDate,
});
```

### List Operations

```typescript
// List with prefix
const result = await store.list({
  prefix: 'documents/',
  maxKeys: 100,
});

// Paginate through all results
let token: string | undefined;
do {
  const result = await store.list({
    prefix: 'documents/',
    continuationToken: token,
  });
  console.log(result.objects);
  token = result.nextContinuationToken;
} while (token);

// List all (handles pagination automatically)
const allObjects = await store.listAll('documents/');

// List folders
const folders = await store.listFolders('documents/');
```

### Other Operations

```typescript
// Check existence
const exists = await store.exists('path/file.txt');

// Get metadata
const metadata = await store.getMetadata('path/file.txt');

// Delete
await store.delete('path/file.txt');

// Delete multiple
const result = await store.deleteMany(['file1.txt', 'file2.txt']);
console.log(`Deleted: ${result.deleted.length}, Errors: ${result.errors.length}`);

// Copy
await store.copy('source.txt', 'destination.txt');

// Move
await store.move('old-path.txt', 'new-path.txt');

// Generate presigned URLs
const downloadUrl = await store.getPresignedDownloadUrl('file.txt', {
  expiresIn: 3600, // 1 hour
});

const uploadUrl = await store.getPresignedUploadUrl('new-file.txt', {
  expiresIn: 3600,
  contentType: 'application/pdf',
});
```

## Error Handling

```typescript
import { ObjectStoreError, ObjectStoreErrorCode } from '@sap-ai-sdk/btp-object-store';

try {
  await store.download('missing-file.txt');
} catch (error) {
  if (error instanceof ObjectStoreError) {
    switch (error.code) {
      case ObjectStoreErrorCode.NOT_FOUND:
        console.log('File not found');
        break;
      case ObjectStoreErrorCode.ACCESS_DENIED:
        console.log('Access denied');
        break;
      case ObjectStoreErrorCode.RATE_LIMITED:
        console.log('Rate limited, retry later');
        break;
      default:
        console.log(`Error: ${error.message}`);
    }
  }
}
```

## Utility Functions

```typescript
import {
  detectContentType,
  formatBytes,
  validateKey,
} from '@sap-ai-sdk/btp-object-store';

// Detect content type from extension
detectContentType('report.pdf'); // 'application/pdf'
detectContentType('image.png'); // 'image/png'

// Format bytes
formatBytes(1024); // '1 KB'
formatBytes(1048576); // '1 MB'

// Validate object key
validateKey('valid/path/file.txt'); // OK
validateKey(''); // Throws ObjectStoreError
```

## Use Cases

### Document Storage for RAG

```typescript
// Store documents for AI retrieval
await store.upload(`documents/${docId}.txt`, content, {
  metadata: {
    source: 'user-upload',
    category: 'technical',
  },
});

// List all documents
const docs = await store.listAll('documents/');
```

### Model Artifact Storage

```typescript
// Store model weights
await store.uploadMultipart(
  `models/${modelId}/weights.safetensors`,
  weightsBuffer,
  {
    onProgress: (p) => console.log(`Uploading: ${p.percentage}%`),
  }
);

// Store model config
await store.upload(
  `models/${modelId}/config.json`,
  JSON.stringify(modelConfig),
  { contentType: 'application/json' }
);
```

### Presigned URLs for Client Uploads

```typescript
// Generate upload URL for client
const uploadUrl = await store.getPresignedUploadUrl(
  `uploads/${userId}/${filename}`,
  {
    expiresIn: 300, // 5 minutes
    contentType: 'application/pdf',
  }
);

// Client can upload directly to S3
// POST uploadUrl with file body
```

## License

Apache-2.0
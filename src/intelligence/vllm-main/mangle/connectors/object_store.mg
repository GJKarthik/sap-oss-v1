// ============================================================================
// SAP Object Store Connector Schema - Shared contract for all BTP services
// ============================================================================
// S3-compatible object storage interface used across BTP services.

// --- Store Configuration ---
Decl object_store_config(
    service_id: String,          // BTP service using this config
    endpoint: String,            // S3-compatible endpoint
    region: String,              // AWS-style region
    bucket: String,              // Default bucket
    credential_ref: String       // BTP destination or secret name
).

// --- Object Metadata ---
Decl object_metadata(
    object_id: String,
    bucket: String,
    key: String,                 // Full path in bucket
    size_bytes: i64,
    content_type: String,        // MIME type
    etag: String,                // Content hash
    last_modified: i64
).

// --- Object Operations ---
Decl object_get(
    request_id: String,
    service_id: String,
    bucket: String,
    key: String,
    range_start: i64,            // For partial reads, -1 for full
    range_end: i64,
    requested_at: i64
).

Decl object_put(
    request_id: String,
    service_id: String,
    bucket: String,
    key: String,
    content_type: String,
    size_bytes: i64,
    requested_at: i64
).

Decl object_delete(
    request_id: String,
    service_id: String,
    bucket: String,
    key: String,
    requested_at: i64
).

Decl object_operation_result(
    request_id: String,
    status: String,              // success, error, not_found
    duration_ms: i64,
    error_message: String
).

// --- Presigned URLs ---
Decl presigned_url(
    url_id: String,
    service_id: String,
    bucket: String,
    key: String,
    operation: String,           // get, put
    expires_at: i64,
    url: String
).

// --- TOON Data Pointers ---
Decl toon_pointer(
    pointer_id: String,
    pointer_type: String,        // sap-obj, hdl
    location: String,            // bucket/key
    format: String,              // parquet, arrow, json, csv
    credentials_ref: String,
    ttl_seconds: i32,
    created_at: i64
).

// --- Batch Operations ---
Decl object_batch(
    batch_id: String,
    service_id: String,
    operation: String,           // get, put, delete
    objects: String,             // JSON array of keys
    requested_at: i64
).

Decl object_batch_result(
    batch_id: String,
    success_count: i32,
    failure_count: i32,
    failures: String,            // JSON array of {key, error}
    duration_ms: i64
).

// ============================================================================
// Rules - Object Store Operations
// ============================================================================

// Object is available if metadata exists and recent
object_available(Bucket, Key) :-
    object_metadata(_, Bucket, Key, _, _, _, LastMod),
    now(Now),
    Now - LastMod < 86400000.    // 24 hours in ms

// Resolve store config for service
resolve_object_store(ServiceId, Endpoint, Bucket) :-
    object_store_config(ServiceId, Endpoint, _, Bucket, _).

// TOON pointer is valid if not expired
toon_pointer_valid(PointerId) :-
    toon_pointer(PointerId, _, _, _, _, TtlSec, CreatedAt),
    now(Now),
    Now - CreatedAt < TtlSec * 1000.

// Generate presigned URL for TOON pointer
toon_pointer_url(PointerId, Url) :-
    toon_pointer(PointerId, "sap-obj", Location, _, CredRef, _, _),
    presigned_url(_, _, _, Location, "get", _, Url),
    toon_pointer_valid(PointerId).

// Parquet file available
parquet_available(Bucket, Key) :-
    object_metadata(_, Bucket, Key, _, "application/parquet", _, _),
    object_available(Bucket, Key).

// Arrow file available
arrow_available(Bucket, Key) :-
    object_metadata(_, Bucket, Key, _, "application/vnd.apache.arrow.file", _, _),
    object_available(Bucket, Key).
//! Storage Backends Module
//!
//! Provides pluggable storage backends for HippoCPP:
//! - Local filesystem (default)
//! - SAP Object Store (cloud storage)
//! - SAP HANA (database backend with vector support)

pub const sap_object_store = @import("sap_object_store.zig");
pub const sap_hana = @import("sap_hana.zig");

// Re-export main types
pub const SAPObjectStoreBackend = sap_object_store.SAPObjectStoreBackend;
pub const ObjectStoreConfig = sap_object_store.ObjectStoreConfig;

pub const SAPHANABackend = sap_hana.SAPHANABackend;
pub const HANAConfig = sap_hana.HANAConfig;
pub const HANAVectorIndex = sap_hana.HANAVectorIndex;

/// Storage backend type
pub const BackendType = enum {
    LOCAL_FILESYSTEM,
    SAP_OBJECT_STORE,
    SAP_HANA,
    IN_MEMORY,
};

/// Unified backend configuration
pub const BackendConfig = union(BackendType) {
    LOCAL_FILESYSTEM: struct {
        path: []const u8,
    },
    SAP_OBJECT_STORE: ObjectStoreConfig,
    SAP_HANA: HANAConfig,
    IN_MEMORY: void,
};
//! Re-export TOON pointer types for use by SAP connectors.
//! Canonical definition lives in src/toon/pointer.zig.

const pointer = @import("../toon/pointer.zig");

pub const ToonPointer = pointer.ToonPointer;
pub const PointerType = pointer.PointerType;
pub const PointerResolution = pointer.PointerResolution;
pub const ResolutionType = pointer.ResolutionType;
pub const DataFormat = pointer.DataFormat;


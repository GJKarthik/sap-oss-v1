//! Enums - All enumeration types for the database
//!
//! Purpose:
//! Centralized enumeration types used across the database
//! for type safety and consistency.

const std = @import("std");

// ============================================================================
// Statement Types
// ============================================================================

pub const StatementType = enum {
    SELECT,
    INSERT,
    UPDATE,
    DELETE,
    CREATE_TABLE,
    DROP_TABLE,
    ALTER_TABLE,
    CREATE_INDEX,
    DROP_INDEX,
    BEGIN_TRANSACTION,
    COMMIT,
    ROLLBACK,
    MATCH,           // Cypher MATCH
    CREATE,          // Cypher CREATE
    MERGE,           // Cypher MERGE
    COPY,
    EXPLAIN,
    CALL,
    SET,
    UNWIND,
    USE_DATABASE,
    ATTACH_DATABASE,
    DETACH_DATABASE,
};

// ============================================================================
// Expression Types
// ============================================================================

pub const ExpressionType = enum {
    // Literals
    LITERAL,
    PARAMETER,
    VARIABLE,
    
    // Comparison
    EQUALS,
    NOT_EQUALS,
    LESS_THAN,
    LESS_THAN_OR_EQUALS,
    GREATER_THAN,
    GREATER_THAN_OR_EQUALS,
    
    // Boolean
    AND,
    OR,
    NOT,
    
    // Arithmetic
    ADD,
    SUBTRACT,
    MULTIPLY,
    DIVIDE,
    MODULO,
    NEGATE,
    
    // Functions
    FUNCTION,
    AGGREGATE,
    
    // Access
    PROPERTY,
    SUBSCRIPT,
    
    // Special
    CASE,
    CAST,
    IS_NULL,
    IS_NOT_NULL,
    IN,
    BETWEEN,
    LIKE,
    EXISTS,
    SUBQUERY,
    
    // Graph
    NODE,
    REL,
    PATH,
};

// ============================================================================
// Logical Types
// ============================================================================

pub const LogicalTypeID = enum(u8) {
    ANY = 0,
    NULL = 1,
    BOOL = 2,
    INT8 = 3,
    INT16 = 4,
    INT32 = 5,
    INT64 = 6,
    INT128 = 7,
    UINT8 = 8,
    UINT16 = 9,
    UINT32 = 10,
    UINT64 = 11,
    FLOAT = 12,
    DOUBLE = 13,
    STRING = 14,
    BLOB = 15,
    DATE = 16,
    TIMESTAMP = 17,
    INTERVAL = 18,
    UUID = 19,
    SERIAL = 20,
    INTERNAL_ID = 21,
    LIST = 22,
    ARRAY = 23,
    STRUCT = 24,
    MAP = 25,
    UNION = 26,
    NODE = 27,
    REL = 28,
    RECURSIVE_REL = 29,
    PATH = 30,
    
    pub fn isNumeric(self: LogicalTypeID) bool {
        return switch (self) {
            .INT8, .INT16, .INT32, .INT64, .INT128,
            .UINT8, .UINT16, .UINT32, .UINT64,
            .FLOAT, .DOUBLE => true,
            else => false,
        };
    }
    
    pub fn isInteger(self: LogicalTypeID) bool {
        return switch (self) {
            .INT8, .INT16, .INT32, .INT64, .INT128,
            .UINT8, .UINT16, .UINT32, .UINT64 => true,
            else => false,
        };
    }
    
    pub fn isTemporal(self: LogicalTypeID) bool {
        return switch (self) {
            .DATE, .TIMESTAMP, .INTERVAL => true,
            else => false,
        };
    }
    
    pub fn isNested(self: LogicalTypeID) bool {
        return switch (self) {
            .LIST, .ARRAY, .STRUCT, .MAP, .UNION => true,
            else => false,
        };
    }
};

// ============================================================================
// Table Types
// ============================================================================

pub const TableType = enum {
    NODE,
    REL,
    RDF,
    FOREIGN,
};

// ============================================================================
// Join Types
// ============================================================================

pub const JoinType = enum {
    INNER,
    LEFT,
    RIGHT,
    FULL,
    CROSS,
    SEMI,
    ANTI,
    MARK,
};

// ============================================================================
// Aggregate Functions
// ============================================================================

pub const AggregateFunction = enum {
    COUNT,
    COUNT_STAR,
    SUM,
    AVG,
    MIN,
    MAX,
    COLLECT,
    FIRST,
    LAST,
    STDDEV,
    VARIANCE,
};

// ============================================================================
// Order Direction
// ============================================================================

pub const OrderDirection = enum {
    ASC,
    DESC,
};

pub const NullOrder = enum {
    NULLS_FIRST,
    NULLS_LAST,
};

// ============================================================================
// Relationship Direction
// ============================================================================

pub const RelDirection = enum {
    FWD,       // Source -> Destination
    BWD,       // Destination -> Source
    BOTH,      // Bidirectional
    
    pub fn opposite(self: RelDirection) RelDirection {
        return switch (self) {
            .FWD => .BWD,
            .BWD => .FWD,
            .BOTH => .BOTH,
        };
    }
};

pub const RelMultiplicity = enum {
    ONE_ONE,
    ONE_MANY,
    MANY_ONE,
    MANY_MANY,
};

// ============================================================================
// Transaction State
// ============================================================================

pub const TransactionState = enum {
    STARTED,
    COMMITTED,
    ROLLED_BACK,
    FAILED,
};

pub const TransactionAction = enum {
    BEGIN,
    COMMIT,
    ROLLBACK,
};

pub const IsolationLevel = enum {
    READ_UNCOMMITTED,
    READ_COMMITTED,
    REPEATABLE_READ,
    SERIALIZABLE,
};

// ============================================================================
// Access Mode
// ============================================================================

pub const AccessMode = enum {
    READ_ONLY,
    READ_WRITE,
};

// ============================================================================
// Scan Source Type
// ============================================================================

pub const ScanSourceType = enum {
    TABLE,
    INDEX,
    FILE,
    FUNCTION,
    SUBQUERY,
};

// ============================================================================
// Conflict Action
// ============================================================================

pub const ConflictAction = enum {
    NOTHING,
    UPDATE,
    REPLACE,
    ERROR,
};

// ============================================================================
// DDL Actions
// ============================================================================

pub const DropType = enum {
    TABLE,
    INDEX,
    COLUMN,
    CONSTRAINT,
};

pub const AlterType = enum {
    ADD_COLUMN,
    DROP_COLUMN,
    RENAME_COLUMN,
    ALTER_COLUMN_TYPE,
    ADD_CONSTRAINT,
    DROP_CONSTRAINT,
    RENAME_TABLE,
};

// ============================================================================
// Physical Operator Types
// ============================================================================

pub const PhysicalOperatorType = enum {
    RESULT_COLLECTOR,
    TABLE_SCAN,
    INDEX_SCAN,
    FILTER,
    PROJECTION,
    HASH_JOIN,
    MERGE_JOIN,
    NESTED_LOOP_JOIN,
    HASH_AGGREGATE,
    ORDER_BY,
    LIMIT,
    UNION,
    INTERSECT,
    EXCEPT,
    RECURSIVE_JOIN,
    PATH_SCAN,
    EXTEND,
    INSERT,
    UPDATE,
    DELETE,
};

// ============================================================================
// Logical Operator Types
// ============================================================================

pub const LogicalOperatorType = enum {
    SCAN,
    FILTER,
    PROJECTION,
    JOIN,
    AGGREGATE,
    ORDER_BY,
    LIMIT,
    DISTINCT,
    UNION,
    EXTEND,
    FLATTEN,
    CREATE,
    INSERT,
    UPDATE,
    DELETE,
    SET_OPERATION,
    RECURSIVE_EXTEND,
    ACCUMULATE,
};

// ============================================================================
// Index Types
// ============================================================================

pub const IndexType = enum {
    HASH,
    BTREE,
    ART,        // Adaptive Radix Tree
    ZONEMAP,
    BLOOM,
};

// ============================================================================
// Compression Types
// ============================================================================

pub const CompressionType = enum {
    NONE,
    RLE,
    DICTIONARY,
    BIT_PACKING,
    DELTA,
    CONSTANT,
    FSST,       // Fast Static Symbol Table
};

// ============================================================================
// Tests
// ============================================================================

test "logical type id numeric" {
    try std.testing.expect(LogicalTypeID.INT64.isNumeric());
    try std.testing.expect(LogicalTypeID.DOUBLE.isNumeric());
    try std.testing.expect(!LogicalTypeID.STRING.isNumeric());
}

test "logical type id integer" {
    try std.testing.expect(LogicalTypeID.INT32.isInteger());
    try std.testing.expect(!LogicalTypeID.FLOAT.isInteger());
}

test "logical type id temporal" {
    try std.testing.expect(LogicalTypeID.DATE.isTemporal());
    try std.testing.expect(LogicalTypeID.TIMESTAMP.isTemporal());
    try std.testing.expect(!LogicalTypeID.INT64.isTemporal());
}

test "rel direction opposite" {
    try std.testing.expectEqual(RelDirection.BWD, RelDirection.FWD.opposite());
    try std.testing.expectEqual(RelDirection.FWD, RelDirection.BWD.opposite());
    try std.testing.expectEqual(RelDirection.BOTH, RelDirection.BOTH.opposite());
}

test "statement type" {
    try std.testing.expectEqual(StatementType.SELECT, StatementType.SELECT);
}

test "expression type" {
    try std.testing.expectEqual(ExpressionType.ADD, ExpressionType.ADD);
}
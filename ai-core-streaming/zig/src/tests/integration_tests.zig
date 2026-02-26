//! BDC AIPrompt Streaming - Integration Tests
//! Comprehensive test suite for broker, protocol, storage, and authentication

const std = @import("std");
const testing = std.testing;

// Import modules under test
const broker = @import("../broker/broker.zig");
const protocol = @import("../protocol/aiprompt_protocol.zig");
const storage = @import("../storage/managed_ledger.zig");
const hana = @import("../hana/hana_db.zig");
const xsuaa = @import("../auth/xsuaa.zig");

// ============================================================================
// Test Fixtures
// ============================================================================

const TestContext = struct {
    allocator: std.mem.Allocator,
    temp_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator) !TestContext {
        return .{
            .allocator = allocator,
            .temp_dir = "/tmp/aiprompt-test",
        };
    }

    pub fn deinit(self: *TestContext) void {
        _ = self;
    }
};

// ============================================================================
// Protocol Tests
// ============================================================================

test "Protocol - CONNECT command serialization" {
    const allocator = testing.allocator;

    const cmd = protocol.BaseCommand{
        .type = .CONNECT,
        .connect = .{
            .client_version = "test-client-1.0.0",
            .protocol_version = protocol.PROTOCOL_VERSION,
        },
    };

    const serialized = try cmd.serialize(allocator);
    defer allocator.free(serialized);

    // Verify serialization produces valid output
    try testing.expect(serialized.len > 0);
}

test "Protocol - CONNECTED response creation" {
    const allocator = testing.allocator;

    var handler = protocol.ProtocolHandler.init(allocator);
    const response = try handler.createConnectedResponse("BDC-AIPrompt-1.0.0");
    defer allocator.free(response);

    // Verify response contains expected data
    try testing.expect(response.len > 8); // At least frame header + some data
}

test "Protocol - PONG response creation" {
    const allocator = testing.allocator;

    var handler = protocol.ProtocolHandler.init(allocator);
    const response = try handler.createPongResponse();
    defer allocator.free(response);

    try testing.expect(response.len > 0);
}

test "Protocol - SUCCESS response creation" {
    const allocator = testing.allocator;

    var handler = protocol.ProtocolHandler.init(allocator);
    const response = try handler.createSuccessResponse(12345);
    defer allocator.free(response);

    try testing.expect(response.len > 0);
}

test "Protocol - Frame serialization and parsing" {
    const allocator = testing.allocator;

    const cmd = protocol.BaseCommand{
        .type = .PING,
        .ping = .{},
    };

    const frame = try protocol.Frame.serialize(allocator, cmd);
    defer allocator.free(frame);

    // Verify frame structure
    try testing.expect(frame.len >= 8); // Min: total_size (4) + cmd_size (4)

    // Parse the frame back
    const parsed = try protocol.Frame.parse(allocator, frame);
    try testing.expect(parsed.cmd_data.len > 0);
}

// ============================================================================
// Storage Tests
// ============================================================================

test "Storage - Position comparison" {
    const p1 = storage.Position{ .ledger_id = 1, .entry_id = 10 };
    const p2 = storage.Position{ .ledger_id = 1, .entry_id = 20 };
    const p3 = storage.Position{ .ledger_id = 2, .entry_id = 5 };

    // p1 < p2 (same ledger, lower entry)
    try testing.expectEqual(std.math.Order.lt, p1.compare(p2));

    // p2 < p3 (lower ledger)
    try testing.expectEqual(std.math.Order.lt, p2.compare(p3));

    // p3 > p1
    try testing.expectEqual(std.math.Order.gt, p3.compare(p1));

    // p1 == p1
    try testing.expectEqual(std.math.Order.eq, p1.compare(p1));
}

test "Storage - Position next" {
    const p1 = storage.Position{ .ledger_id = 1, .entry_id = 10 };
    const p2 = p1.next();

    try testing.expectEqual(@as(i64, 1), p2.ledger_id);
    try testing.expectEqual(@as(i64, 11), p2.entry_id);
}

test "Storage - Position special values" {
    const earliest = storage.Position.earliest;
    const latest = storage.Position.latest;

    // Earliest should be less than any real position
    const real = storage.Position{ .ledger_id = 0, .entry_id = 0 };
    try testing.expectEqual(std.math.Order.lt, earliest.compare(real));

    // Latest should be greater than any real position
    try testing.expectEqual(std.math.Order.gt, latest.compare(real));
}

test "Storage - LedgerInfo entry count" {
    const ledger = storage.LedgerInfo{
        .ledger_id = 1,
        .state = .Open,
        .first_entry_id = 0,
        .last_entry_id = 99,
        .size = 10240,
        .entries_count = 100,
        .created_at = 0,
        .closed_at = null,
    };

    try testing.expectEqual(@as(i64, 100), ledger.getEntryCount());
}

test "Storage - LedgerInfo empty" {
    const ledger = storage.LedgerInfo{
        .ledger_id = 1,
        .state = .Open,
        .first_entry_id = 0,
        .last_entry_id = -1, // No entries
        .size = 0,
        .entries_count = 0,
        .created_at = 0,
        .closed_at = null,
    };

    try testing.expectEqual(@as(i64, 0), ledger.getEntryCount());
}

// ============================================================================
// HANA Security Tests
// ============================================================================

test "HANA - validateIdentifier accepts valid identifiers" {
    // Simple name
    _ = try hana.validateIdentifier("my_topic");

    // Topic name with slashes
    _ = try hana.validateIdentifier("persistent://public/default/test");

    // Name with dashes
    _ = try hana.validateIdentifier("topic-name-123");

    // Name with dots
    _ = try hana.validateIdentifier("Schema.Table");

    // Name with colons
    _ = try hana.validateIdentifier("ns:topic");
}

test "HANA - validateIdentifier rejects empty string" {
    try testing.expectError(error.EmptyIdentifier, hana.validateIdentifier(""));
}

test "HANA - validateIdentifier rejects SQL injection" {
    // Single quotes
    try testing.expectError(
        error.InvalidIdentifierCharacter,
        hana.validateIdentifier("topic'; DROP TABLE--"),
    );

    // Null bytes
    try testing.expectError(
        error.InvalidIdentifierCharacter,
        hana.validateIdentifier("topic\x00name"),
    );

    // Newlines
    try testing.expectError(
        error.InvalidIdentifierCharacter,
        hana.validateIdentifier("topic\nname"),
    );

    // Semicolons
    try testing.expectError(
        error.InvalidIdentifierCharacter,
        hana.validateIdentifier("topic;name"),
    );
}

test "HANA - escapeString escapes single quotes" {
    const allocator = testing.allocator;
    const escaped = try hana.escapeString(allocator, "test's value");
    defer allocator.free(escaped);

    try testing.expectEqualStrings("test''s value", escaped);
}

test "HANA - escapeString escapes backslashes" {
    const allocator = testing.allocator;
    const escaped = try hana.escapeString(allocator, "path\\to\\file");
    defer allocator.free(escaped);

    try testing.expectEqualStrings("path\\\\to\\\\file", escaped);
}

test "HANA - escapeString removes null bytes" {
    const allocator = testing.allocator;
    const escaped = try hana.escapeString(allocator, "test\x00value");
    defer allocator.free(escaped);

    try testing.expectEqualStrings("testvalue", escaped);
}

test "HANA - PreparedStatement builds with string parameter" {
    const allocator = testing.allocator;

    var stmt = hana.PreparedStatement.init(allocator, "SELECT * FROM users WHERE name = ?");
    defer stmt.deinit();

    try stmt.bindString("John");

    const sql = try stmt.build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("SELECT * FROM users WHERE name = 'John'", sql);
}

test "HANA - PreparedStatement builds with multiple parameters" {
    const allocator = testing.allocator;

    var stmt = hana.PreparedStatement.init(allocator, "SELECT * FROM users WHERE name = ? AND age = ?");
    defer stmt.deinit();

    try stmt.bindString("John");
    try stmt.bindInt32(25);

    const sql = try stmt.build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("SELECT * FROM users WHERE name = 'John' AND age = 25", sql);
}

test "HANA - PreparedStatement handles blob parameters" {
    const allocator = testing.allocator;

    var stmt = hana.PreparedStatement.init(allocator, "INSERT INTO data (payload) VALUES (?)");
    defer stmt.deinit();

    try stmt.bindBlob(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    const sql = try stmt.build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("INSERT INTO data (payload) VALUES (X'deadbeef')", sql);
}

test "HANA - PreparedStatement escapes SQL injection in strings" {
    const allocator = testing.allocator;

    var stmt = hana.PreparedStatement.init(allocator, "SELECT * FROM users WHERE name = ?");
    defer stmt.deinit();

    try stmt.bindString("Robert'; DROP TABLE users;--");

    const sql = try stmt.build();
    defer allocator.free(sql);

    // Quotes should be escaped
    try testing.expectEqualStrings("SELECT * FROM users WHERE name = 'Robert''; DROP TABLE users;--'", sql);
}

test "HANA - PreparedStatement fails with too few parameters" {
    const allocator = testing.allocator;

    var stmt = hana.PreparedStatement.init(allocator, "SELECT * FROM users WHERE name = ? AND age = ?");
    defer stmt.deinit();

    try stmt.bindString("John");
    // Missing second parameter

    try testing.expectError(error.TooFewParameters, stmt.build());
}

test "HANA - PreparedStatement fails with too many parameters" {
    const allocator = testing.allocator;

    var stmt = hana.PreparedStatement.init(allocator, "SELECT * FROM users WHERE name = ?");
    defer stmt.deinit();

    try stmt.bindString("John");
    try stmt.bindInt32(25); // Extra parameter

    try testing.expectError(error.TooManyParameters, stmt.build());
}

test "HANA - PreparedStatement handles NULL values" {
    const allocator = testing.allocator;

    var stmt = hana.PreparedStatement.init(allocator, "INSERT INTO users (name, age) VALUES (?, ?)");
    defer stmt.deinit();

    try stmt.bindString("John");
    try stmt.bindNull();

    const sql = try stmt.build();
    defer allocator.free(sql);

    try testing.expectEqualStrings("INSERT INTO users (name, age) VALUES ('John', NULL)", sql);
}

// ============================================================================
// Authentication Tests
// ============================================================================

test "Auth - JwtToken expiry check (not expired)" {
    const allocator = testing.allocator;

    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test.token.string",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{
            .exp = std.time.timestamp() + 3600, // 1 hour from now
            .iat = std.time.timestamp(),
        },
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };

    try testing.expect(!token.isExpired());
}

test "Auth - JwtToken expiry check (expired)" {
    const allocator = testing.allocator;

    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test.token.string",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{
            .exp = std.time.timestamp() - 100, // Expired
            .iat = std.time.timestamp() - 3700,
        },
        .signature = "sig",
        .expires_at = std.time.timestamp() - 100,
        .issued_at = std.time.timestamp() - 3700,
    };

    try testing.expect(token.isExpired());
}

test "Auth - JwtToken scope check" {
    const allocator = testing.allocator;
    const scopes = [_][]const u8{ "aiprompt.produce", "aiprompt.consume" };

    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{
            .scope = &scopes,
        },
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };

    try testing.expect(token.hasScope("aiprompt.produce"));
    try testing.expect(token.hasScope("aiprompt.consume"));
    try testing.expect(!token.hasScope("aiprompt.admin"));
}

test "Auth - JwksCache staleness check" {
    const allocator = testing.allocator;

    var cache = xsuaa.JwksCache.init(allocator, 3600);
    defer cache.deinit();

    // Fresh cache should not be stale
    cache.fetched_at = std.time.timestamp();
    try testing.expect(!cache.isStale());

    // Old cache should be stale
    cache.fetched_at = std.time.timestamp() - 7200;
    try testing.expect(cache.isStale());
}

test "Auth - AIPromptScopes constants" {
    try testing.expectEqualStrings("aiprompt.produce", xsuaa.AIPromptScopes.PRODUCE);
    try testing.expectEqualStrings("aiprompt.consume", xsuaa.AIPromptScopes.CONSUME);
    try testing.expectEqualStrings("aiprompt.admin", xsuaa.AIPromptScopes.ADMIN);
}

// ============================================================================
// Broker Tests
// ============================================================================

test "Broker - BrokerOptions default values" {
    const options = broker.BrokerOptions{};

    try testing.expectEqualStrings("standalone", options.cluster_name);
    try testing.expectEqual(@as(u16, 6650), options.broker_service_port);
    try testing.expectEqual(@as(u16, 8080), options.web_service_port);
    try testing.expectEqual(@as(u32, 8), options.num_io_threads);
    try testing.expectEqual(false, options.authentication_enabled);
}

test "Broker - BrokerState enum values" {
    const state = broker.BrokerState.Initializing;
    try testing.expect(state == .Initializing);

    const running = broker.BrokerState.Running;
    try testing.expect(running == .Running);
}

test "Broker - Producer init and deinit" {
    const allocator = testing.allocator;

    var producer = try broker.Producer.init(allocator, 1, "test-producer", "test-topic");
    defer producer.deinit();

    try testing.expectEqual(@as(u64, 1), producer.id);
    try testing.expectEqualStrings("test-producer", producer.name);
    try testing.expectEqualStrings("test-topic", producer.topic);
}

test "Broker - Consumer permits" {
    const allocator = testing.allocator;

    // Create mock connection (simplified)
    var consumer = broker.Consumer{
        .allocator = allocator,
        .id = 1,
        .name = "test-consumer",
        .subscription = "test-sub",
        .permits = std.atomic.Value(u32).init(0),
        .connection = undefined, // Not used in this test
    };

    // Initially no permits
    try testing.expectEqual(@as(u32, 0), consumer.permits.load(.monotonic));

    // Add permits
    consumer.addPermits(1000);
    try testing.expectEqual(@as(u32, 1000), consumer.permits.load(.monotonic));

    // Use permit
    try testing.expect(consumer.usePermit());
    try testing.expectEqual(@as(u32, 999), consumer.permits.load(.monotonic));

    // Drain permits
    while (consumer.permits.load(.monotonic) > 0) {
        _ = consumer.usePermit();
    }

    // usePermit should fail when no permits
    try testing.expect(!consumer.usePermit());
}

test "Broker - SubscriptionType enum" {
    const exclusive = broker.SubscriptionType.Exclusive;
    const shared = broker.SubscriptionType.Shared;
    const failover = broker.SubscriptionType.Failover;
    const key_shared = broker.SubscriptionType.Key_Shared;

    try testing.expect(exclusive == .Exclusive);
    try testing.expect(shared == .Shared);
    try testing.expect(failover == .Failover);
    try testing.expect(key_shared == .Key_Shared);
}

// ============================================================================
// Connection Pool Tests
// ============================================================================

test "ConnectionPool - initialization" {
    const allocator = testing.allocator;

    var pool = hana.ConnectionPool.init(allocator, .{
        .host = "test-host",
        .port = 443,
        .schema = "TEST_SCHEMA",
        .min_connections = 1,
        .max_connections = 5,
    });
    defer pool.deinit();

    try testing.expect(!pool.is_initialized);
    try testing.expectEqual(@as(u64, 0), pool.total_queries_executed.load(.monotonic));
}

test "ConnectionPool - stats tracking" {
    const allocator = testing.allocator;

    var pool = hana.ConnectionPool.init(allocator, .{
        .host = "test-host",
        .port = 443,
        .schema = "TEST_SCHEMA",
    });
    defer pool.deinit();

    const stats = pool.getStats();
    try testing.expectEqual(@as(u32, 0), stats.total_connections);
    try testing.expectEqual(@as(u64, 0), stats.total_queries);
}

// ============================================================================
// End-to-End Integration Test (requires running services)
// ============================================================================

// Note: These tests are marked as skip by default and should be run
// manually when integration environment is available

// test "E2E - Connect to broker and produce message" {
//     // This test requires a running broker
//     // Skip in unit test context
// }

// test "E2E - Connect to HANA and execute query" {
//     // This test requires HANA connection
//     // Skip in unit test context
// }

// ============================================================================
// Test Runner
// ============================================================================

pub fn main() !void {
    // Run all tests
    std.testing.refAllDecls(@This());
}
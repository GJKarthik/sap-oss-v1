//! Unit tests for signal labeling pipeline
//!
//! Run with: zig build test
//! Or: zig test src/tests.zig

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

// ============================================================================
// Pattern Matching Tests
// ============================================================================

test "pattern_match_exact" {
    const pattern = "hello";
    const text = "hello world";
    try testing.expect(main.matchPattern(pattern, text));
}

test "pattern_match_case_insensitive" {
    const pattern = "HELLO";
    const text = "hello world";
    try testing.expect(main.matchPatternIgnoreCase(pattern, text));
}

test "pattern_match_not_found" {
    const pattern = "goodbye";
    const text = "hello world";
    try testing.expect(!main.matchPattern(pattern, text));
}

test "pattern_match_empty" {
    const pattern = "";
    const text = "hello";
    try testing.expect(main.matchPattern(pattern, text));
}

test "pattern_match_full_string" {
    const pattern = "hello world";
    const text = "hello world";
    try testing.expect(main.matchPattern(pattern, text));
}

// ============================================================================
// Label Detection Tests
// ============================================================================

test "detect_intent_query" {
    const text = "What is the total amount for UK?";
    const labels = main.detectLabels(text);
    try testing.expect(labels.intent == .query);
}

test "detect_intent_command" {
    const text = "Show me all positions";
    const labels = main.detectLabels(text);
    try testing.expect(labels.intent == .command);
}

test "detect_intent_analysis" {
    const text = "Compare the trends between Q1 and Q2";
    const labels = main.detectLabels(text);
    try testing.expect(labels.intent == .analysis);
}

test "detect_domain_finance" {
    const text = "What is the RWA for treasury positions?";
    const labels = main.detectLabels(text);
    try testing.expect(labels.domain == .finance);
}

test "detect_domain_esg" {
    const text = "Show financed emissions by sector";
    const labels = main.detectLabels(text);
    try testing.expect(labels.domain == .esg);
}

test "detect_domain_treasury" {
    const text = "List all bond positions with DV01";
    const labels = main.detectLabels(text);
    try testing.expect(labels.domain == .treasury);
}

// ============================================================================
// Entity Extraction Tests
// ============================================================================

test "extract_country_code" {
    const text = "Show positions for UK and SG";
    var allocator = testing.allocator;
    const entities = try main.extractEntities(allocator, text);
    defer allocator.free(entities);
    
    try testing.expect(entities.len >= 2);
    try testing.expectEqualStrings("UK", entities[0].value);
    try testing.expectEqualStrings("SG", entities[1].value);
}

test "extract_date" {
    const text = "Get data for 2024-01-31";
    var allocator = testing.allocator;
    const entities = try main.extractEntities(allocator, text);
    defer allocator.free(entities);
    
    try testing.expect(entities.len >= 1);
    try testing.expect(entities[0].entity_type == .date);
}

test "extract_amount" {
    const text = "Find transactions over 1000000 USD";
    var allocator = testing.allocator;
    const entities = try main.extractEntities(allocator, text);
    defer allocator.free(entities);
    
    try testing.expect(entities.len >= 1);
    try testing.expect(entities[0].entity_type == .amount);
}

test "extract_product" {
    const text = "Show all BOND and IRS positions";
    var allocator = testing.allocator;
    const entities = try main.extractEntities(allocator, text);
    defer allocator.free(entities);
    
    try testing.expect(entities.len >= 2);
}

// ============================================================================
// JSON Parsing Tests
// ============================================================================

test "parse_json_simple" {
    const json_str = 
        \\{"question": "What is the total?", "domain": "finance"}
    ;
    var allocator = testing.allocator;
    const parsed = try main.parseJsonLine(allocator, json_str);
    defer parsed.deinit();
    
    try testing.expectEqualStrings("What is the total?", parsed.question);
    try testing.expectEqualStrings("finance", parsed.domain);
}

test "parse_json_with_query" {
    const json_str = 
        \\{"question": "Show UK data", "query": "SELECT * FROM BTP.FACT WHERE COUNTRY_CODE = 'UK'"}
    ;
    var allocator = testing.allocator;
    const parsed = try main.parseJsonLine(allocator, json_str);
    defer parsed.deinit();
    
    try testing.expect(parsed.query != null);
    try testing.expect(std.mem.indexOf(u8, parsed.query.?, "UK") != null);
}

test "parse_json_invalid" {
    const json_str = "not valid json";
    var allocator = testing.allocator;
    const result = main.parseJsonLine(allocator, json_str);
    try testing.expectError(error.InvalidJson, result);
}

test "parse_json_empty" {
    const json_str = "{}";
    var allocator = testing.allocator;
    const parsed = try main.parseJsonLine(allocator, json_str);
    defer parsed.deinit();
    
    try testing.expect(parsed.question.len == 0);
}

// ============================================================================
// SIMD String Search Tests (if available)
// ============================================================================

test "simd_search_present" {
    if (!main.simd_available) return error.SkipZigTest;
    
    const haystack = "The quick brown fox jumps over the lazy dog";
    const needle = "fox";
    const result = main.simdSearch(haystack, needle);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 16), result.?);
}

test "simd_search_not_present" {
    if (!main.simd_available) return error.SkipZigTest;
    
    const haystack = "The quick brown fox";
    const needle = "cat";
    const result = main.simdSearch(haystack, needle);
    try testing.expect(result == null);
}

test "simd_search_at_start" {
    if (!main.simd_available) return error.SkipZigTest;
    
    const haystack = "hello world";
    const needle = "hello";
    const result = main.simdSearch(haystack, needle);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?);
}

test "simd_search_at_end" {
    if (!main.simd_available) return error.SkipZigTest;
    
    const haystack = "hello world";
    const needle = "world";
    const result = main.simdSearch(haystack, needle);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 6), result.?);
}

// ============================================================================
// Label Output Tests
// ============================================================================

test "label_to_json" {
    var allocator = testing.allocator;
    const labels = main.Labels{
        .intent = .query,
        .domain = .finance,
        .sentiment = .neutral,
        .confidence = 0.95,
    };
    
    const json = try main.labelsToJson(allocator, labels);
    defer allocator.free(json);
    
    try testing.expect(std.mem.indexOf(u8, json, "\"intent\":\"query\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"domain\":\"finance\"") != null);
}

test "label_confidence_range" {
    const text = "What is the total amount?";
    const labels = main.detectLabels(text);
    
    try testing.expect(labels.confidence >= 0.0);
    try testing.expect(labels.confidence <= 1.0);
}

// ============================================================================
// Batch Processing Tests
// ============================================================================

test "process_batch_empty" {
    var allocator = testing.allocator;
    const lines = [_][]const u8{};
    const results = try main.processBatch(allocator, &lines);
    defer allocator.free(results);
    
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "process_batch_single" {
    var allocator = testing.allocator;
    const lines = [_][]const u8{
        \\{"question": "What is the total?"}
    };
    const results = try main.processBatch(allocator, &lines);
    defer {
        for (results) |r| r.deinit();
        allocator.free(results);
    }
    
    try testing.expectEqual(@as(usize, 1), results.len);
}

test "process_batch_multiple" {
    var allocator = testing.allocator;
    const lines = [_][]const u8{
        \\{"question": "Show UK data"}
        ,
        \\{"question": "List all positions"}
        ,
        \\{"question": "Compare Q1 vs Q2"}
    };
    const results = try main.processBatch(allocator, &lines);
    defer {
        for (results) |r| r.deinit();
        allocator.free(results);
    }
    
    try testing.expectEqual(@as(usize, 3), results.len);
}

// ============================================================================
// Memory Safety Tests
// ============================================================================

test "memory_no_leaks_labels" {
    var allocator = testing.allocator;
    
    // Run multiple iterations to detect leaks
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const text = "What is the total RWA for UK treasury positions?";
        const labels = main.detectLabels(text);
        _ = labels;
    }
    // If we get here without OOM, no leaks
}

test "memory_no_leaks_entities" {
    var allocator = testing.allocator;
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const text = "Show data for UK, SG, and JP on 2024-01-31";
        const entities = try main.extractEntities(allocator, text);
        allocator.free(entities);
    }
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "edge_case_unicode" {
    const text = "Zeige Daten für München";  // German with umlaut
    const labels = main.detectLabels(text);
    // Should not crash
    try testing.expect(labels.confidence >= 0.0);
}

test "edge_case_very_long_text" {
    var long_text: [10000]u8 = undefined;
    @memset(&long_text, 'a');
    
    const labels = main.detectLabels(&long_text);
    try testing.expect(labels.confidence >= 0.0);
}

test "edge_case_special_chars" {
    const text = "SELECT * FROM table WHERE col = 'O''Brien' AND x > 1.5e-10";
    const labels = main.detectLabels(text);
    try testing.expect(labels.confidence >= 0.0);
}

test "edge_case_newlines" {
    const text = "Line 1\nLine 2\r\nLine 3\n";
    const labels = main.detectLabels(text);
    try testing.expect(labels.confidence >= 0.0);
}

test "edge_case_null_bytes" {
    const text = "Hello\x00World";
    // Should handle gracefully or return error
    const labels = main.detectLabels(text);
    _ = labels;
}

// ============================================================================
// Performance Benchmark (optional, run with --bench)
// ============================================================================

test "benchmark_label_detection" {
    const iterations = 10000;
    const text = "What is the total RWA for UK treasury positions in Q4 2024?";
    
    var timer = std.time.Timer{};
    timer.reset();
    
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const labels = main.detectLabels(text);
        std.mem.doNotOptimizeAway(&labels);
    }
    
    const elapsed_ns = timer.read();
    const ns_per_op = elapsed_ns / iterations;
    
    // Should be under 1ms per operation
    try testing.expect(ns_per_op < 1_000_000);
    
    std.debug.print("\nBenchmark: {d} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        @divTrunc(1_000_000_000, ns_per_op),
    });
}
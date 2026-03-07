// ============================================================================
// BDC AIPrompt Streaming - Contract Tests
// ============================================================================
// Mangle-based contract validation tests for aiprompt integration.

// ============================================================================
// Contract Test Declarations
// ============================================================================

Decl contract_test(
    test_id: String,
    test_name: String,
    query: String,
    expected_result: String,      // success, failure, count
    priority: i32                 // 1=critical, 2=high, 3=medium
).

Decl contract_test_result(
    test_id: String,
    passed: i32,
    message: String,
    executed_at: i64
).

// ============================================================================
// Arrow Schema Tests
// ============================================================================

// Test: Arrow schema for aiprompt messages is registered
contract_test(
    "test-arrow-schema-registered",
    "Arrow schema aiprompt-message-v1 exists",
    "arrow_schema(_, 'aiprompt-message-v1', _, _)",
    "success",
    1
).

// Test: Arrow Flight endpoint is configured
contract_test(
    "test-flight-endpoint",
    "Arrow Flight endpoint for aiprompt streaming",
    "arrow_flight_endpoint(_, 'bdc-aiprompt-streaming', _, _, _)",
    "success",
    1
).

// Test: Arrow Flight is available when service ready
contract_test(
    "test-flight-available",
    "Arrow Flight available rule",
    "arrow_flight_available('bdc-aiprompt-streaming')",
    "success",
    2
).

// ============================================================================
// Fabric Node Tests
// ============================================================================

// Test: AIPrompt registered as fabric node
contract_test(
    "test-fabric-node",
    "AIPrompt fabric node registration",
    "fabric_node('node-aiprompt', 'bdc-aiprompt-streaming', _, _, _)",
    "success",
    1
).

// Test: Service can be discovered
contract_test(
    "test-service-discovery",
    "AIPrompt discoverable in connect fabric",
    "discovered_model(_, 'BDC AIPrompt Streaming', 'streaming', _, _, _, _, _)",
    "success",
    1
).

// ============================================================================
// Integration Tests
// ============================================================================

// Test: HANA configuration present
contract_test(
    "test-hana-config",
    "HANA storage configuration",
    "hana_config('bdc-aiprompt-streaming', _, _, _, _)",
    "success",
    1
).

// Test: All required HANA tables defined
contract_test(
    "test-hana-tables",
    "Required HANA tables exist",
    "all_tables_exist('bdc-aiprompt-streaming')",
    "success",
    1
).

// Test: Object store configuration present
contract_test(
    "test-objectstore-config",
    "Object store tiered storage config",
    "object_store_config('bdc-aiprompt-streaming', _, _, _, _)",
    "success",
    2
).

// Test: LLM gateway configuration present
contract_test(
    "test-llm-config",
    "LLM gateway for ML processing",
    "llm_gateway_config('bdc-aiprompt-streaming', _, _, _, _, _)",
    "success",
    2
).

// ============================================================================
// Blackboard Integration Tests
// ============================================================================

// Test: Can share cursor state via blackboard
contract_test(
    "test-blackboard-cursor",
    "Cursor state sharing via blackboard",
    "can_share_cursor_state('bdc-aiprompt-streaming')",
    "success",
    2
).

// Test: Main blackboard instance configured
contract_test(
    "test-blackboard-main",
    "Main blackboard instance exists",
    "blackboard_instance('bb-main', 'bdc', _, _, _)",
    "success",
    2
).

// ============================================================================
// Fabric Channel Tests
// ============================================================================

// Test: AIPrompt to LLM channel exists
contract_test(
    "test-channel-aiprompt-llm",
    "Channel to PrivateLLM for inference",
    "fabric_channel('channel-aiprompt-llm', 'node-aiprompt', 'node-privatellm', _, _, _)",
    "success",
    2
).

// Test: AIPrompt to Events channel exists
contract_test(
    "test-channel-aiprompt-events",
    "Channel to Events for streaming",
    "fabric_channel('channel-aiprompt-events', 'node-aiprompt', 'node-events', _, _, _)",
    "success",
    2
).

// Test: AIPrompt to Search channel (Arrow Flight)
contract_test(
    "test-channel-aiprompt-search",
    "Arrow Flight channel to Search",
    "fabric_channel('channel-aiprompt-search', 'node-aiprompt', 'node-search', 'arrow_flight', _, _)",
    "success",
    2
).

// ============================================================================
// Health Tests
// ============================================================================

// Test: Health status can be determined
contract_test(
    "test-health-status",
    "Health status rule exists",
    "health_status('bdc-aiprompt-streaming', _)",
    "success",
    1
).

// Test: Component health rules exist
contract_test(
    "test-component-health-hana",
    "HANA component health",
    "component_health('bdc-aiprompt-streaming', 'hana', _)",
    "success",
    2
).

contract_test(
    "test-component-health-flight",
    "Arrow Flight component health",
    "component_health('bdc-aiprompt-streaming', 'arrow_flight', _)",
    "success",
    2
).

// ============================================================================
// Contract Compliance Tests
// ============================================================================

// Test: Service is HANA compliant
contract_test(
    "test-compliance-hana",
    "HANA compliance",
    "service_hana_compliant('bdc-aiprompt-streaming')",
    "success",
    1
).

// Test: Service is storage compliant
contract_test(
    "test-compliance-storage",
    "Storage compliance",
    "service_storage_compliant('bdc-aiprompt-streaming')",
    "success",
    1
).

// Test: Service is fully compliant
contract_test(
    "test-compliance-full",
    "Full service compliance",
    "service_fully_compliant('bdc-aiprompt-streaming')",
    "success",
    1
).

// ============================================================================
// Test Execution Rules
// ============================================================================

// All critical tests must pass
all_critical_tests_pass() :-
    !contract_test(TestId, _, _, "success", 1),
    contract_test_result(TestId, 0, _, _).

// Count passed tests
passed_test_count(Count) :-
    aggregate(contract_test_result(_, 1, _, _), count, Count).

// Count failed tests
failed_test_count(Count) :-
    aggregate(contract_test_result(_, 0, _, _), count, Count).

// Overall test status
test_suite_status("passed") :-
    all_critical_tests_pass(),
    failed_test_count(0).

test_suite_status("failed") :-
    !all_critical_tests_pass().

test_suite_status("partial") :-
    all_critical_tests_pass(),
    failed_test_count(Count),
    Count > 0.
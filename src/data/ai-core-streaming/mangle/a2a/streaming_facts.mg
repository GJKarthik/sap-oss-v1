// ============================================================================
// BDC AIPrompt Streaming - Core Facts
// ============================================================================
// Datalog facts for the AIPrompt messaging system.
// These define the core entities and relationships.

// ============================================================================
// Message Facts
// ============================================================================

// Message fact - represents a single message in the system
// message(message_id, topic, partition, ledger_id, entry_id, publish_time, producer_name, sequence_id)
Decl message(
    message_id: String,
    topic: String,
    partition: i32,
    ledger_id: i64,
    entry_id: i64,
    publish_time: i64,
    producer_name: String,
    sequence_id: i64
).

// Message payload (separate for efficiency)
// message_payload(message_id, payload_bytes, compression_type)
Decl message_payload(
    message_id: String,
    payload_bytes: Bytes,
    compression_type: String
).

// Message properties (key-value metadata)
// message_property(message_id, key, value)
Decl message_property(
    message_id: String,
    key: String,
    value: String
).

// Message schema info
// message_schema(message_id, schema_version, schema_type)
Decl message_schema(
    message_id: String,
    schema_version: Bytes,
    schema_type: String
).

// ============================================================================
// Topic Facts
// ============================================================================

// Topic definition
// topic(topic_name, tenant, namespace, local_name, persistence_type, num_partitions)
Decl topic(
    topic_name: String,
    tenant: String,
    namespace: String,
    local_name: String,
    persistence_type: String,  // "persistent" | "non-persistent"
    num_partitions: i32
).

// Topic statistics
// topic_stats(topic_name, msg_rate_in, msg_rate_out, storage_size, backlog_size)
Decl topic_stats(
    topic_name: String,
    msg_rate_in: f64,
    msg_rate_out: f64,
    storage_size: i64,
    backlog_size: i64
).

// Topic policy
// topic_policy(topic_name, policy_type, policy_value)
Decl topic_policy(
    topic_name: String,
    policy_type: String,
    policy_value: String
).

// ============================================================================
// Producer Facts
// ============================================================================

// Producer connection
// producer(producer_id, producer_name, topic, connection_id, create_time)
Decl producer(
    producer_id: i64,
    producer_name: String,
    topic: String,
    connection_id: String,
    create_time: i64
).

// Producer statistics
// producer_stats(producer_id, msg_rate, msg_throughput, pending_count)
Decl producer_stats(
    producer_id: i64,
    msg_rate: f64,
    msg_throughput: f64,
    pending_count: i32
).

// ============================================================================
// Consumer Facts
// ============================================================================

// Consumer connection
// consumer(consumer_id, consumer_name, subscription, topic, connection_id, create_time)
Decl consumer(
    consumer_id: i64,
    consumer_name: String,
    subscription: String,
    topic: String,
    connection_id: String,
    create_time: i64
).

// Consumer statistics
// consumer_stats(consumer_id, msg_rate, msg_throughput, unacked_count)
Decl consumer_stats(
    consumer_id: i64,
    msg_rate: f64,
    msg_throughput: f64,
    unacked_count: i32
).

// Consumer permit count
// consumer_permits(consumer_id, available_permits)
Decl consumer_permits(
    consumer_id: i64,
    available_permits: i32
).

// ============================================================================
// Subscription Facts
// ============================================================================

// Subscription definition
// subscription(subscription_name, topic, subscription_type, create_time)
Decl subscription(
    subscription_name: String,
    topic: String,
    subscription_type: String,  // "Exclusive" | "Shared" | "Failover" | "Key_Shared"
    create_time: i64
).

// Subscription cursor position
// subscription_cursor(subscription_name, topic, ledger_id, entry_id, mark_delete_ledger, mark_delete_entry)
Decl subscription_cursor(
    subscription_name: String,
    topic: String,
    ledger_id: i64,
    entry_id: i64,
    mark_delete_ledger: i64,
    mark_delete_entry: i64
).

// Subscription backlog
// subscription_backlog(subscription_name, topic, backlog_messages, backlog_size)
Decl subscription_backlog(
    subscription_name: String,
    topic: String,
    backlog_messages: i64,
    backlog_size: i64
).

// ============================================================================
// Ledger Facts (Storage)
// ============================================================================

// Ledger definition
// ledger(ledger_id, topic, state, first_entry, last_entry, size)
Decl ledger(
    ledger_id: i64,
    topic: String,
    state: String,  // "Open" | "Closed" | "Offloaded"
    first_entry: i64,
    last_entry: i64,
    size: i64
).

// Ledger entry
// ledger_entry(ledger_id, entry_id, size, checksum)
Decl ledger_entry(
    ledger_id: i64,
    entry_id: i64,
    size: i64,
    checksum: i64
).

// ============================================================================
// Cluster Facts
// ============================================================================

// Broker definition
// broker(broker_id, host, port, cluster, state)
Decl broker(
    broker_id: String,
    host: String,
    port: i32,
    cluster: String,
    state: String  // "Active" | "Draining" | "Offline"
).

// Broker load
// broker_load(broker_id, cpu_usage, memory_usage, msg_rate_in, msg_rate_out, topic_count)
Decl broker_load(
    broker_id: String,
    cpu_usage: f64,
    memory_usage: f64,
    msg_rate_in: f64,
    msg_rate_out: f64,
    topic_count: i32
).

// Topic ownership
// topic_owner(topic, broker_id)
Decl topic_owner(
    topic: String,
    broker_id: String
).

// ============================================================================
// Namespace Facts
// ============================================================================

// Namespace definition
// namespace(namespace_name, tenant, policies)
Decl namespace(
    namespace_name: String,
    tenant: String,
    policies: String  // JSON policies
).

// Tenant definition
// tenant(tenant_name, admin_roles, allowed_clusters)
Decl tenant(
    tenant_name: String,
    admin_roles: String,  // JSON array
    allowed_clusters: String  // JSON array
).

// ============================================================================
// Transaction Facts
// ============================================================================

// Transaction state
// transaction(txn_id_most, txn_id_least, state, timeout_at)
Decl transaction(
    txn_id_most: i64,
    txn_id_least: i64,
    state: String,  // "Open" | "Committing" | "Committed" | "Aborting" | "Aborted"
    timeout_at: i64
).

// Transaction produced topic
// txn_produced(txn_id_most, txn_id_least, topic, partition)
Decl txn_produced(
    txn_id_most: i64,
    txn_id_least: i64,
    topic: String,
    partition: i32
).

// Transaction acked subscription
// txn_acked(txn_id_most, txn_id_least, topic, subscription)
Decl txn_acked(
    txn_id_most: i64,
    txn_id_least: i64,
    topic: String,
    subscription: String
).

// ============================================================================
// Authentication Facts
// ============================================================================

// Authenticated principal
// auth_principal(connection_id, principal_type, principal_name)
Decl auth_principal(
    connection_id: String,
    principal_type: String,  // "token" | "oidc" | "anonymous"
    principal_name: String
).

// Authorization role
// auth_role(principal_name, role, resource, permission)
Decl auth_role(
    principal_name: String,
    role: String,
    resource: String,
    permission: String  // "produce" | "consume" | "admin"
).

// ============================================================================
// Connection Facts
// ============================================================================

// Client connection
// connection(connection_id, client_address, protocol_version, create_time, state)
Decl connection(
    connection_id: String,
    client_address: String,
    protocol_version: i32,
    create_time: i64,
    state: String  // "Connected" | "Closing" | "Closed"
).

// ============================================================================
// Schema Facts
// ============================================================================

// Schema definition
// schema(topic, schema_version, schema_type, schema_data)
Decl schema(
    topic: String,
    schema_version: Bytes,
    schema_type: String,  // "AVRO" | "JSON" | "PROTOBUF" | "BYTES" | "STRING"
    schema_data: String
).

// Schema compatibility
// schema_compatibility(topic, compatibility_strategy)
Decl schema_compatibility(
    topic: String,
    compatibility_strategy: String  // "FULL" | "FORWARD" | "BACKWARD" | "NONE"
).
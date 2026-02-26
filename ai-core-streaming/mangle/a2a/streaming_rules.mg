// ============================================================================
// BDC AIPrompt Streaming - Core Rules
// ============================================================================
// Datalog rules for message routing, delivery, and system management.

// ============================================================================
// Message Routing Rules
// ============================================================================

// Message is deliverable to a subscription
message_deliverable(MsgId, SubName, Topic) :-
    message(MsgId, Topic, _, LedgerId, EntryId, _, _, _),
    subscription_cursor(SubName, Topic, CursorLedger, CursorEntry, _, _),
    position_after(LedgerId, EntryId, CursorLedger, CursorEntry).

// Position comparison (LedgerId:EntryId > CursorLedger:CursorEntry)
position_after(LedgerId, EntryId, CursorLedger, CursorEntry) :-
    LedgerId > CursorLedger.

position_after(LedgerId, EntryId, CursorLedger, CursorEntry) :-
    LedgerId = CursorLedger,
    EntryId > CursorEntry.

// Message pending for consumer
message_pending(MsgId, ConsumerId, SubName) :-
    message_deliverable(MsgId, SubName, Topic),
    consumer(ConsumerId, _, SubName, Topic, _, _),
    consumer_permits(ConsumerId, Permits),
    Permits > 0.

// ============================================================================
// Subscription Type Rules
// ============================================================================

// Exclusive subscription - single active consumer
exclusive_subscription(SubName, Topic) :-
    subscription(SubName, Topic, "Exclusive", _).

// Shared subscription - round-robin delivery
shared_subscription(SubName, Topic) :-
    subscription(SubName, Topic, "Shared", _).

// Failover subscription - active/standby consumers
failover_subscription(SubName, Topic) :-
    subscription(SubName, Topic, "Failover", _).

// Key_Shared subscription - key-based sticky routing
key_shared_subscription(SubName, Topic) :-
    subscription(SubName, Topic, "Key_Shared", _).

// ============================================================================
// Consumer Selection Rules
// ============================================================================

// Select consumer for exclusive subscription
select_consumer_exclusive(SubName, Topic, ConsumerId) :-
    exclusive_subscription(SubName, Topic),
    consumer(ConsumerId, _, SubName, Topic, _, CreateTime),
    oldest_consumer(SubName, Topic, CreateTime).

// Oldest consumer in subscription (for exclusive/failover)
oldest_consumer(SubName, Topic, MinTime) :-
    consumer(_, _, SubName, Topic, _, CreateTime),
    MinTime = min(CreateTime).

// Select consumer for shared subscription (round-robin)
select_consumer_shared(SubName, Topic, ConsumerId) :-
    shared_subscription(SubName, Topic),
    consumer(ConsumerId, _, SubName, Topic, _, _),
    consumer_permits(ConsumerId, Permits),
    Permits > 0.

// Select consumer for failover subscription (active consumer)
select_consumer_failover(SubName, Topic, ConsumerId) :-
    failover_subscription(SubName, Topic),
    consumer(ConsumerId, _, SubName, Topic, _, CreateTime),
    oldest_consumer(SubName, Topic, CreateTime).

// ============================================================================
// Acknowledgment Rules
// ============================================================================

// Message is acknowledged
message_acknowledged(MsgId, SubName) :-
    message(MsgId, Topic, _, LedgerId, EntryId, _, _, _),
    subscription_cursor(SubName, Topic, _, _, MarkDeleteLedger, MarkDeleteEntry),
    position_before_or_equal(LedgerId, EntryId, MarkDeleteLedger, MarkDeleteEntry).

// Position before or equal
position_before_or_equal(LedgerId, EntryId, MarkDeleteLedger, MarkDeleteEntry) :-
    LedgerId < MarkDeleteLedger.

position_before_or_equal(LedgerId, EntryId, MarkDeleteLedger, MarkDeleteEntry) :-
    LedgerId = MarkDeleteLedger,
    EntryId <= MarkDeleteEntry.

// Can advance cursor
can_advance_cursor(SubName, Topic, NewLedger, NewEntry) :-
    subscription_cursor(SubName, Topic, _, _, MarkDeleteLedger, MarkDeleteEntry),
    position_after(NewLedger, NewEntry, MarkDeleteLedger, MarkDeleteEntry).

// ============================================================================
// Backlog Rules
// ============================================================================

// Subscription has backlog
has_backlog(SubName, Topic) :-
    subscription_backlog(SubName, Topic, BacklogMessages, _),
    BacklogMessages > 0.

// Backlog exceeds threshold
backlog_exceeded(SubName, Topic, Threshold) :-
    subscription_backlog(SubName, Topic, BacklogMessages, _),
    BacklogMessages > Threshold.

// Subscription is healthy (no excessive backlog)
subscription_healthy(SubName, Topic) :-
    subscription(SubName, Topic, _, _),
    subscription_backlog(SubName, Topic, BacklogMessages, _),
    BacklogMessages < 10000.

// ============================================================================
// Topic Ownership Rules
// ============================================================================

// Topic is owned by active broker
topic_available(Topic) :-
    topic_owner(Topic, BrokerId),
    broker(BrokerId, _, _, _, "Active").

// Topic needs reassignment
topic_needs_reassignment(Topic) :-
    topic_owner(Topic, BrokerId),
    broker(BrokerId, _, _, _, State),
    State != "Active".

// Broker can accept topic
broker_can_accept(BrokerId, Topic) :-
    broker(BrokerId, _, _, _, "Active"),
    broker_load(BrokerId, CpuUsage, _, _, _, _),
    CpuUsage < 0.8.

// ============================================================================
// Load Balancing Rules
// ============================================================================

// Broker is overloaded
broker_overloaded(BrokerId) :-
    broker_load(BrokerId, CpuUsage, _, _, _, _),
    CpuUsage > 0.9.

broker_overloaded(BrokerId) :-
    broker_load(BrokerId, _, MemoryUsage, _, _, _),
    MemoryUsage > 0.9.

// Broker is underloaded
broker_underloaded(BrokerId) :-
    broker_load(BrokerId, CpuUsage, MemoryUsage, _, _, _),
    CpuUsage < 0.3,
    MemoryUsage < 0.3.

// Topic should be moved (rebalancing)
topic_should_move(Topic, FromBroker, ToBroker) :-
    topic_owner(Topic, FromBroker),
    broker_overloaded(FromBroker),
    broker_underloaded(ToBroker),
    broker_can_accept(ToBroker, Topic).

// ============================================================================
// Retention Rules
// ============================================================================

// Ledger can be deleted (retention)
ledger_deletable(LedgerId, Topic) :-
    ledger(LedgerId, Topic, "Closed", _, _, _),
    all_cursors_past(LedgerId, Topic).

// All subscription cursors have passed this ledger
all_cursors_past(LedgerId, Topic) :-
    ledger(LedgerId, Topic, _, _, _, _),
    !cursor_in_ledger(LedgerId, Topic).

cursor_in_ledger(LedgerId, Topic) :-
    subscription_cursor(_, Topic, CursorLedger, _, _, _),
    CursorLedger <= LedgerId.

// Message expired (TTL)
message_expired(MsgId, Topic) :-
    message(MsgId, Topic, _, _, _, PublishTime, _, _),
    topic_policy(Topic, "messageTTLSeconds", TTLStr),
    parse_int(TTLStr, TTL),
    current_time(Now),
    (Now - PublishTime) > (TTL * 1000).

// ============================================================================
// Transaction Rules
// ============================================================================

// Transaction is active
transaction_active(TxnIdMost, TxnIdLeast) :-
    transaction(TxnIdMost, TxnIdLeast, "Open", _).

// Transaction timed out
transaction_timed_out(TxnIdMost, TxnIdLeast) :-
    transaction(TxnIdMost, TxnIdLeast, "Open", TimeoutAt),
    current_time(Now),
    Now > TimeoutAt.

// Transaction can commit
transaction_can_commit(TxnIdMost, TxnIdLeast) :-
    transaction_active(TxnIdMost, TxnIdLeast),
    !transaction_timed_out(TxnIdMost, TxnIdLeast).

// ============================================================================
// Authorization Rules
// ============================================================================

// Principal can produce to topic
can_produce(Principal, Topic) :-
    auth_role(Principal, _, Topic, "produce").

can_produce(Principal, Topic) :-
    auth_role(Principal, "admin", _, _).

// Principal can consume from topic
can_consume(Principal, Topic) :-
    auth_role(Principal, _, Topic, "consume").

can_consume(Principal, Topic) :-
    auth_role(Principal, "admin", _, _).

// Principal can administer topic
can_admin(Principal, Topic) :-
    auth_role(Principal, _, Topic, "admin").

can_admin(Principal, Topic) :-
    auth_role(Principal, "admin", _, _).

// Connection is authorized for operation
connection_authorized(ConnectionId, Topic, Operation) :-
    auth_principal(ConnectionId, _, Principal),
    can_produce(Principal, Topic),
    Operation = "produce".

connection_authorized(ConnectionId, Topic, Operation) :-
    auth_principal(ConnectionId, _, Principal),
    can_consume(Principal, Topic),
    Operation = "consume".

// ============================================================================
// Health Check Rules
// ============================================================================

// Broker is healthy
broker_healthy(BrokerId) :-
    broker(BrokerId, _, _, _, "Active"),
    broker_load(BrokerId, CpuUsage, MemoryUsage, _, _, _),
    CpuUsage < 0.95,
    MemoryUsage < 0.95.

// Cluster is healthy
cluster_healthy(ClusterName) :-
    broker(_, _, _, ClusterName, "Active"),
    healthy_broker_count(ClusterName, Count),
    Count >= 1.

healthy_broker_count(ClusterName, Count) :-
    broker(BrokerId, _, _, ClusterName, "Active"),
    broker_healthy(BrokerId),
    Count = count(BrokerId).

// System is ready
system_ready() :-
    cluster_healthy(_),
    hana_connected().

// ============================================================================
// Schema Rules
// ============================================================================

// Schema is compatible
schema_compatible(Topic, NewSchema, NewType) :-
    schema_compatibility(Topic, "NONE").

schema_compatible(Topic, NewSchema, NewType) :-
    schema_compatibility(Topic, Strategy),
    schema(Topic, _, ExistingType, _),
    NewType = ExistingType,
    Strategy != "NONE".

// Can evolve schema
can_evolve_schema(Topic, NewSchema) :-
    schema_compatibility(Topic, "BACKWARD"),
    backward_compatible(Topic, NewSchema).

can_evolve_schema(Topic, NewSchema) :-
    schema_compatibility(Topic, "FORWARD"),
    forward_compatible(Topic, NewSchema).

can_evolve_schema(Topic, NewSchema) :-
    schema_compatibility(Topic, "FULL"),
    backward_compatible(Topic, NewSchema),
    forward_compatible(Topic, NewSchema).
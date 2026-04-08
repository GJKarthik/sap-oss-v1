// Mangle: MVCC Transaction Rules
//
// Purpose:
// Defines rules for Multi-Version Concurrency Control (MVCC).
// Ensures serializability, conflict detection, and version visibility.

// ============================================================================
// Version Visibility Rules
// ============================================================================

// A version is visible to a transaction if it was committed before the txn started
Decl version_visible(txn_id: i64, version_id: i64).

version_visible(TxnID, VerID) :-
    transaction(TxnID, _, StartTS, "active", _),
    version(VerID, _, CommitTS, _),
    CommitTS < StartTS.

// A version created by the same transaction is visible
version_visible(TxnID, VerID) :-
    version(VerID, TxnID, _, _).

// ============================================================================
// Write-Write Conflict Detection
// ============================================================================

// Two active transactions conflict if they write to the same row
Decl write_write_conflict(txn1: i64, txn2: i64, table_id: i64, row_id: i64).

write_write_conflict(T1, T2, TableID, RowID) :-
    tx_active(T1),
    tx_active(T2),
    T1 != T2,
    write_set(T1, TableID, RowID),
    write_set(T2, TableID, RowID).

// ============================================================================
// Read-Write Conflict (for Serializable isolation)
// ============================================================================

Decl read_write_conflict(reader: i64, writer: i64, table_id: i64, row_id: i64).

read_write_conflict(R, W, TableID, RowID) :-
    tx_active(R),
    tx_active(W),
    R != W,
    read_set(R, TableID, RowID),
    write_set(W, TableID, RowID).

// ============================================================================
// Undo Chain Rules
// ============================================================================

// Head of undo chain for a row
Decl undo_chain_head(table_id: i64, row_id: i64, version_id: i64).

undo_chain_head(TableID, RowID, VerID) :-
    version(VerID, _, _, _),
    version_row(VerID, TableID, RowID),
    !version_superseded(VerID).

// A version is superseded if a newer version exists for same row
Decl version_superseded(version_id: i64).

version_superseded(V1) :-
    version(V1, _, TS1, _),
    version(V2, _, TS2, _),
    version_row(V1, TableID, RowID),
    version_row(V2, TableID, RowID),
    TS2 > TS1.

// ============================================================================
// Garbage Collection Rules
// ============================================================================

// A version is reclaimable if no active transaction can see it
Decl version_reclaimable(version_id: i64).

version_reclaimable(VerID) :-
    version(VerID, _, _, _),
    version_superseded(VerID),
    !any_tx_can_see(VerID).

Decl any_tx_can_see(version_id: i64).

any_tx_can_see(VerID) :-
    tx_active(TxnID),
    version_visible(TxnID, VerID).

// ============================================================================
// Snapshot Isolation Invariants
// ============================================================================

// A transaction's snapshot is consistent if it sees a complete set
Decl snapshot_consistent(txn_id: i64).

snapshot_consistent(TxnID) :-
    tx_active(TxnID),
    !snapshot_anomaly(TxnID).

// Snapshot anomaly: seeing partial commit of another transaction
Decl snapshot_anomaly(txn_id: i64).

snapshot_anomaly(TxnID) :-
    tx_active(TxnID),
    version_visible(TxnID, V1),
    version(V1, OtherTxn, _, _),
    version(V2, OtherTxn, _, _),
    V1 != V2,
    !version_visible(TxnID, V2).

// ============================================================================
// Commit Ordering Rules
// ============================================================================

// Transaction can commit if no write-write conflicts exist
Decl can_commit(txn_id: i64).

can_commit(TxnID) :-
    tx_active(TxnID),
    !has_conflict(TxnID).

Decl has_conflict(txn_id: i64).

has_conflict(TxnID) :-
    write_write_conflict(TxnID, _, _, _).

// ============================================================================
// Base Fact Declarations
// ============================================================================

Decl version(version_id: i64, txn_id: i64, commit_ts: i64, data: String).
Decl version_row(version_id: i64, table_id: i64, row_id: i64).
Decl write_set(txn_id: i64, table_id: i64, row_id: i64).
Decl read_set(txn_id: i64, table_id: i64, row_id: i64).


// Mangle: Page Management Rules
//
// Purpose:
// Defines invariants and derived relations for page-level storage management.
// Covers page allocation, free-space tracking, and WAL page management.

// ============================================================================
// Page State Rules
// ============================================================================

// Page is in use if allocated or dirty
Decl page_in_use(page_idx: i64, file_id: String).

page_in_use(P, F) :-
    page_state(P, F, "allocated").

page_in_use(P, F) :-
    page_state(P, F, "dirty").

// Page is available for allocation
Decl page_available(page_idx: i64, file_id: String).

page_available(P, F) :-
    page_state(P, F, "free"),
    !page_pending_operation(P, F).

// ============================================================================
// Page Group Rules (for columnar storage)
// ============================================================================

// Pages belonging to same column chunk
Decl same_column_chunk(page1: i64, page2: i64, table_id: i64, col_id: i64).

same_column_chunk(P1, P2, T, C) :-
    column_page(P1, T, C, ChunkID),
    column_page(P2, T, C, ChunkID),
    P1 != P2.

// Column chunk is complete (all pages present)
Decl chunk_complete(table_id: i64, col_id: i64, chunk_id: i64).

chunk_complete(T, C, ChunkID) :-
    column_chunk_meta(T, C, ChunkID, ExpectedPages),
    actual_count = fn:count<P> { column_page(P, T, C, ChunkID) },
    actual_count >= ExpectedPages.

// ============================================================================
// Free Space Management
// ============================================================================

// Pages with available free space
Decl page_has_free_space(page_idx: i64, free_bytes: i64).

page_has_free_space(P, Free) :-
    page_usage(P, _, Used, Total),
    Free = Total - Used,
    Free > 0.

// Best-fit page for an insertion of given size
Decl best_fit_page(size_needed: i64, page_idx: i64).

best_fit_page(Size, P) :-
    page_has_free_space(P, Free),
    Free >= Size,
    !better_fit_exists(Size, P, Free).

Decl better_fit_exists(size: i64, page_idx: i64, current_free: i64).

better_fit_exists(Size, P, CF) :-
    page_has_free_space(P2, Free2),
    P2 != P,
    Free2 >= Size,
    Free2 < CF.

// ============================================================================
// WAL Page Rules
// ============================================================================

// Page has WAL entry (needs recovery on crash)
Decl page_in_wal(page_idx: i64, lsn: i64).

page_in_wal(P, LSN) :-
    wal_record_page(LSN, P, _).

// Page needs recovery (WAL entry exists but not yet checkpointed)
Decl page_needs_recovery(page_idx: i64).

page_needs_recovery(P) :-
    page_in_wal(P, LSN),
    !page_checkpointed_after(P, LSN).

Decl page_checkpointed_after(page_idx: i64, lsn: i64).

page_checkpointed_after(P, LSN) :-
    checkpoint_page(P, CheckpointLSN),
    CheckpointLSN >= LSN.

// ============================================================================
// Page Integrity Invariants
// ============================================================================

// No page should be both free and dirty
Decl page_invariant_violation(page_idx: i64, reason: String).

page_invariant_violation(P, "free_and_dirty") :-
    page_state(P, F, "free"),
    page_state(P, F, "dirty").

// No page should be allocated to two different column chunks
page_invariant_violation(P, "double_allocation") :-
    column_page(P, T1, C1, _),
    column_page(P, T2, C2, _),
    T1 != T2.

page_invariant_violation(P, "double_allocation") :-
    column_page(P, T, C1, _),
    column_page(P, T, C2, _),
    C1 != C2.

// ============================================================================
// Base Fact Declarations
// ============================================================================

Decl page_state(page_idx: i64, file_id: String, state: String).
Decl page_pending_operation(page_idx: i64, file_id: String).
Decl column_page(page_idx: i64, table_id: i64, col_id: i64, chunk_id: i64).
Decl column_chunk_meta(table_id: i64, col_id: i64, chunk_id: i64, expected_pages: i64).
Decl page_usage(page_idx: i64, file_id: String, used_bytes: i64, total_bytes: i64).
Decl wal_record_page(lsn: i64, page_idx: i64, data: String).
Decl checkpoint_page(page_idx: i64, checkpoint_lsn: i64).

